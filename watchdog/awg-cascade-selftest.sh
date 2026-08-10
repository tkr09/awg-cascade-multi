#!/bin/bash
# =============================================================================
# AWG Cascade Multi — self-test (активные проверки локальной ноды)
# Вывод: одна строка на проверку, TAB-separated: STATUS<TAB>СЕКЦИЯ<TAB>ДЕТАЛЬ
# STATUS ∈ OK | WARN | FAIL.  Бот парсит и рисует ✅/⚠️/🔴.
# Запускается ботом через `sudo` (sudoers wildcard /usr/local/sbin/awg-cascade-*.sh).
# =============================================================================
set -u
. /etc/awg-cascade/config 2>/dev/null || true
: "${BOT_USER:=awgbot}"
STATE=/etc/awg-cascade/state.json
NOW=$(date +%s)

emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# ─── Сервисы ──────────────────────────────────────────────────────────────────
svc_bad=""
for s in awg-cascade-bot awg-cascade-watchdog awg-quick@awg0 ${CLIENT3_IFACE:+awg-quick@$CLIENT3_IFACE}; do
    systemctl is-active --quiet "$s" 2>/dev/null || svc_bad="$svc_bad $s"
done
[ -z "$svc_bad" ] && emit OK "Сервисы" "bot/watchdog/awg0${CLIENT3_IFACE:+/$CLIENT3_IFACE} active" \
                   || emit FAIL "Сервисы" "не active:$svc_bad"

# ─── Policy routing (ip rules) ───────────────────────────────────────────────
if ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 100"; then
    emit OK "ip rule (клиенты)" "fwmark 0x1 → table 100"
else
    emit FAIL "ip rule (клиенты)" "ОТСУТСТВУЕТ — трафик мимо каскада!"
fi
if ip rule show 2>/dev/null | grep -q "uidrange.*lookup 100"; then
    emit OK "ip rule (бот)" "uidrange → table 100"
else
    emit WARN "ip rule (бот)" "uidrange → 100 отсутствует"
fi

# ─── ECMP table 100 ───────────────────────────────────────────────────────────
nh=$(ip route show table 100 2>/dev/null | grep -c nexthop)
ifs=$(ip route show table 100 2>/dev/null | grep -oE 'dev awg[0-9]+' | awk '{print $2}' | tr '\n' ' ')
if [ "$nh" -gt 0 ]; then
    emit OK "ECMP (table 100)" "$nh exits: $ifs"
elif ip route show table 100 2>/dev/null | grep -q default; then
    emit OK "ECMP (table 100)" "single: $ifs"
else
    emit FAIL "ECMP (table 100)" "ПУСТА — kill-switch активен (нет exits)"
fi

# ─── Kill-switch + MASQUERADE ────────────────────────────────────────────────
iptables -S FORWARD 2>/dev/null | grep -q "awg-cascade-killsw" \
    && emit OK "Kill-switch" "FORWARD-правило на месте" \
    || emit WARN "Kill-switch" "правило не найдено"

m1=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c "awg-cascade-masq")
m2=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c "tunnel-masq")
if [ "$m1" -gt 0 ] && [ "$m2" -gt 0 ]; then
    emit OK "MASQUERADE" "client + tunnel"
elif [ "$m1" -gt 0 ]; then
    emit WARN "MASQUERADE" "tunnel-masq отсутствует — egress может флапать"
else
    emit FAIL "MASQUERADE" "правила отсутствуют"
fi

# ─── Интерфейсы: клиентские + exits из state ─────────────────────────────────
ip link show awg0 >/dev/null 2>&1 && emit OK "awg0 (клиенты 2.0)" "up" || emit FAIL "awg0 (клиенты 2.0)" "DOWN"
if [ -n "${CLIENT3_IFACE:-}" ]; then
    if ! ip link show "$CLIENT3_IFACE" >/dev/null 2>&1; then
        emit FAIL "$CLIENT3_IFACE (клиенты 3.0)" "DOWN"
    elif [ "$(awg showconf "$CLIENT3_IFACE" 2>/dev/null | grep -c '^HeaderProtectionKey')" -eq 0 ]; then
        # Ядро молча игнорирует ключ при S1-S4 < 12 — интерфейс жив, но защиты нет
        emit FAIL "$CLIENT3_IFACE (клиенты 3.0)" "up, но HeaderProtectionKey НЕ применён"
    else
        emit OK "$CLIENT3_IFACE (клиенты 3.0)" "up, header protection активен"
    fi
fi
if [ -f "$STATE" ]; then
    while IFS= read -r row; do
        iface=$(jq -r .interface <<<"$row"); name=$(jq -r .name <<<"$row")
        [ "$(jq -r .enabled <<<"$row")" = "true" ] || continue
        if ip link show "$iface" >/dev/null 2>&1; then
            hs=$(awg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            if [ -n "$hs" ] && [ "$hs" != "0" ]; then
                age=$(( NOW - hs ))
                [ "$age" -lt 200 ] && emit OK "$name ($iface)" "handshake ${age}s назад" \
                                   || emit WARN "$name ($iface)" "handshake устарел: ${age}s"
            else
                emit WARN "$name ($iface)" "нет handshake"
            fi
        else
            emit FAIL "$name ($iface)" "интерфейс DOWN"
        fi
    done < <(jq -c '.exits[]' "$STATE" 2>/dev/null)
fi

# ─── Egress бота → Telegram (через каскад) ───────────────────────────────────
code=$(sudo -u "$BOT_USER" curl -s -o /dev/null -w '%{http_code}' --max-time 12 https://api.telegram.org 2>/dev/null)
if [ -n "$code" ] && [ "$code" != "000" ]; then
    emit OK "Egress бота" "Telegram HTTP $code (каскад жив)"
else
    emit FAIL "Egress бота" "Telegram HTTP ${code:-timeout} — бот не выходит!"
fi

# ─── Ресурсы ──────────────────────────────────────────────────────────────────
disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')
ram=$(free 2>/dev/null | awk '/^Mem:/{printf "%d",$3*100/$2}')
load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
[ "${disk:-0}" -ge 90 ] && emit WARN "Диск /" "${disk}%" || emit OK "Диск /" "${disk}% занято"
[ "${ram:-0}" -ge 90 ]  && emit WARN "RAM" "${ram}%"     || emit OK "RAM" "${ram}% занято"
emit OK "Load / uptime" "load1 ${load1:-?} · up $(uptime -p 2>/dev/null | sed 's/^up //')"

# ─── Версия (version-stamp) ──────────────────────────────────────────────────
if [ -f /etc/awg-cascade/version ]; then
    emit OK "Версия" "$(cut -d' ' -f1-2 /etc/awg-cascade/version)"
else
    emit WARN "Версия" "stamp отсутствует (старая установка — нужен sync)"
fi
