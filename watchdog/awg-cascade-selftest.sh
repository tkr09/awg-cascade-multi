#!/bin/bash
# =============================================================================
# AWG Cascade Multi — self-test (активные проверки локальной ноды)
# Вывод: одна строка на проверку, TAB-separated: STATUS<TAB>СЕКЦИЯ<TAB>ДЕТАЛЬ
# STATUS ∈ OK | WARN | FAIL.  Бот парсит и рисует ✅/⚠️/🔴.
# Запускается ботом через `sudo` (sudoers wildcard /usr/local/sbin/awg-cascade-*.sh).
# =============================================================================
set -u
# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || true
: "${BOT_USER:=awgbot}"
STATE=/etc/awg-cascade/state.json
NOW=$(date +%s)

emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# ─── Сервисы ──────────────────────────────────────────────────────────────────
svc_bad=""
for s in $([ "${BOT_ENABLED:-1}" = 1 ] && echo awg-cascade-bot) awg-cascade-watchdog awg-quick@awg0 ${CLIENT3_IFACE:+awg-quick@$CLIENT3_IFACE}; do
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
# blackhole default ставит watchdog, когда живых exit нет вообще. Это ровно
# kill-switch, и раньше он проходил как «OK single:» — `grep -q default` ловит
# и blackhole тоже. Зелёная строка при полностью отрезанных клиентах.
elif ip route show table 100 2>/dev/null | grep -q "^blackhole default"; then
    emit FAIL "ECMP (table 100)" "blackhole — kill-switch активен, живых exit нет"
elif ip route show table 100 2>/dev/null | grep -q default; then
    emit OK "ECMP (table 100)" "single: $ifs"
else
    emit FAIL "ECMP (table 100)" "ПУСТА — kill-switch активен (нет exits)"
fi

# Managed chains and the complete default-deny policy.
if iptables -C FORWARD -m comment --comment awg-cascade-managed -j AWGC-FORWARD 2>/dev/null &&
   iptables -C AWGC-FORWARD -i awg0 -j DROP 2>/dev/null; then
    emit OK "Kill-switch" "managed chain + default deny"
else emit FAIL "Kill-switch" "managed policy missing"; fi
if iptables -t nat -S AWGC-NAT 2>/dev/null | grep -q MASQUERADE; then
    emit OK "MASQUERADE" "managed NAT chain"
else emit FAIL "MASQUERADE" "managed NAT missing"; fi
if [ -e /etc/awg-cascade/activation-pending ]; then emit WARN "Activation" "installed files are pending runtime activation"; fi

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

# ─── Управление exit'ами по SSH — глазами БОТА, а не root ────────────────────
#
# Заведено по дефекту, прожившему с установки незамеченным: /etc/awg-cascade/
# ssh/known_hosts принадлежал root:root 600 в каталоге бота. Файл создаёт ssh,
# запущенный от root (bootstrap-exit.sh вызывается из setup.sh), а владельца
# никто не выравнивал. Бот терял разом ВСЕ операции с exit'ами по SSH — статус,
# WARP, удаление, обновление, добавление нового exit'а, — и падал с
# PermissionError прямо посреди диалога.
#
# Незаметно было потому, что снаружи это выглядело как зависший экран в
# Telegram, а здесь всё горело зелёным: проверки выше ходят от root и через
# curl. Отсюда правило этой секции — проверять ИМЕННО от имени бота и ИМЕННО
# тем способом, которым он работает.
KH=/etc/awg-cascade/ssh/known_hosts
if [ ! -f "$KH" ]; then
    emit OK "Реестр host-ключей" "пуст — exit'ов ещё не было"
elif ! runuser -u "$BOT_USER" -- test -r "$KH" 2>/dev/null; then
    emit FAIL "Реестр host-ключей" "бот не читает ($(stat -c '%U:%G %a' "$KH"))"
elif ! runuser -u "$BOT_USER" -- test -w "$KH" 2>/dev/null; then
    emit FAIL "Реестр host-ключей" "бот не пишет ($(stat -c '%U:%G %a' "$KH")) — TOFU сломан"
else
    emit OK "Реестр host-ключей" "бот читает и пишет"
fi

# Фактический вход на каждый exit от имени бота. Права выше могут быть в
# порядке, а вход всё равно не пройдёт: сменился host-ключ после переустановки
# exit'а или пропал ключ бота в authorized_keys. Для бота это одинаково
# означает «управлять exit'ом не могу», и знать об этом надо ДО того, как
# понадобится что-то с ним сделать.
if [ -f "$STATE" ] && [ -f /etc/awg-cascade/ssh/id_ed25519 ]; then
    ssh_bad=""; ssh_ok=0
    while IFS= read -r row; do
        [ "$(jq -r .enabled <<<"$row")" = "true" ] || continue
        eip=$(jq -r .ip <<<"$row"); ename=$(jq -r .name <<<"$row")
        if runuser -u "$BOT_USER" -- ssh -F /dev/null \
                -i /etc/awg-cascade/ssh/id_ed25519 -o IdentitiesOnly=yes \
                -o IdentityAgent=none -o BatchMode=yes \
                -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" \
                -o ConnectTimeout=8 "root@$eip" true >/dev/null 2>&1; then
            ssh_ok=$((ssh_ok + 1))
        else
            ssh_bad="$ssh_bad $ename"
        fi
    done < <(jq -c '.exits[]' "$STATE" 2>/dev/null)
    if [ -n "$ssh_bad" ]; then
        emit FAIL "SSH бота → exits" "не заходит:$ssh_bad (управление ими недоступно)"
    elif [ "$ssh_ok" -gt 0 ]; then
        emit OK "SSH бота → exits" "$ssh_ok из $ssh_ok"
    fi
fi

# ─── Egress бота → Telegram (и ПУТЬ, а не только доступность) ────────────────
#
# Один только HTTP-код ничего не говорит о маршруте: при пустой таблице 100
# запрос бота уходит напрямую через WAN и точно так же возвращает 200. Проверка
# рапортовала «каскад жив» ровно в той аварии, которую должна была ловить.
# Поэтому отдельно сверяем ФАКТИЧЕСКИЙ внешний адрес с адресами exit'ов.
code=$(sudo -u "$BOT_USER" curl -s -o /dev/null -w '%{http_code}' --max-time 12 https://api.telegram.org 2>/dev/null)
if [ -n "$code" ] && [ "$code" != "000" ]; then
    seen=$(sudo -u "$BOT_USER" curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null)
    own=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    if [ -z "$seen" ]; then
        emit WARN "Egress бота" "Telegram HTTP $code, но внешний IP определить не удалось"
    elif echo "$own" | grep -qxF "$seen"; then
        emit FAIL "Egress бота" "выходит НАПРЯМУЮ ($seen — адрес самой ноды), мимо каскада"
    else
        emit OK "Egress бота" "Telegram HTTP $code, внешний IP $seen (не адрес ноды)"
    fi
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
