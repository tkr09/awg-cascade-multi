#!/bin/bash
# AWG Cascade Multi — Postboot verify (одноразовый, через 90s после network-online)
# Проверяет что awg0, все awgN, ECMP и kill-switch — в норме.
# Если что-то не так — ntfy + попытка recovery.

set -u
. /etc/awg-cascade/config

STATE=/etc/awg-cascade/state.json
LOG=/var/log/awg-cascade-watchdog.log

# Интерфейс аварийного egress: см. пояснение в awg-cascade-watchdog.sh.
# Фолбэк на eth0 сохраняет прежнее поведение там, где MAIN_IFACE не задан.
: "${MAIN_IFACE:=eth0}"
ip link show "$MAIN_IFACE" >/dev/null 2>&1 || MAIN_IFACE=$(
    ip route show default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
: "${MAIN_IFACE:=eth0}"

log() { echo "$(date -Iseconds) POSTBOOT $*" >> "$LOG"; }

# С ретраями — см. пояснение в awg-cascade-watchdog.sh. Здесь это особенно
# важно: сообщение отправляется сразу после загрузки, когда сеть только встаёт
# и первая попытка проваливается охотнее обычного, а второго шанса у postboot
# нет — юнит oneshot и больше не запустится.
ntfy() {
    local title="$1" priority="${2:-default}" tags="${3:-}" body="${4:-}"
    [ -n "${NTFY_URL:-}" ] || return 0
    : "${NTFY_TIMEOUT:=15}"
    : "${NTFY_RETRIES:=3}"
    local attempt
    for attempt in $(seq 1 "$NTFY_RETRIES"); do
        curl --interface "$MAIN_IFACE" -s --fail --max-time "$NTFY_TIMEOUT" \
            -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
            -d "$body" "$NTFY_URL" >/dev/null 2>&1 && return 0
        [ "$attempt" -lt "$NTFY_RETRIES" ] && sleep $(( attempt * 3 ))
    done
    log "WARN: ntfy НЕ доставлен за $NTFY_RETRIES попыток"
    return 1
}

issues=()

# 1. Клиентские интерфейсы подняты? (awg0 всегда, второй — если настроен)
for _cif in awg0 ${CLIENT3_IFACE:-}; do
    if ! awg show "$_cif" >/dev/null 2>&1; then
        issues+=("$_cif интерфейс не существует")
        log "FAIL: $_cif down — trying to bring up"
        awg-quick up "$_cif" >/dev/null 2>&1 || true
    fi
done

# 2. Все awgN из state.json поднят и с handshake?
if [ -f "$STATE" ]; then
    while IFS= read -r row; do
        iface=$(jq -r .interface <<<"$row")
        name=$(jq -r .name <<<"$row")
        enabled=$(jq -r .enabled <<<"$row")
        [ "$enabled" != "true" ] && continue

        if ! awg show "$iface" >/dev/null 2>&1; then
            issues+=("$name ($iface) интерфейс не поднят")
            log "FAIL: $iface — trying to bring up"
            awg-quick up "$iface" >/dev/null 2>&1 || true
            continue
        fi

        hs=$(awg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        if [ -z "$hs" ] || [ "$hs" = "0" ]; then
            issues+=("$name ($iface) нет handshake")
            log "WARN: $iface no handshake yet (may handshake in next 30s)"
        else
            age=$(( $(date +%s) - hs ))
            if [ "$age" -gt 300 ]; then
                issues+=("$name ($iface) handshake устарел: ${age}s")
                log "FAIL: $iface handshake stale ${age}s"
            fi
        fi
    done < <(jq -c '.exits[]' "$STATE")
fi

# 3. ECMP route в table 100 существует?
if ! ip route show table 100 2>/dev/null | grep -q default; then
    issues+=("ECMP-таблица 100 пустая")
    log "FAIL: table 100 empty"
fi

# 4. Kill-switch правило на FORWARD?
if ! iptables -L FORWARD -n 2>/dev/null | grep -q "awg-cascade-killsw"; then
    issues+=("kill-switch правило отсутствует в FORWARD")
    log "FAIL: kill-switch rule missing"
    [ -x /usr/local/sbin/awg-cascade-iptables.sh ] && /usr/local/sbin/awg-cascade-iptables.sh
fi

# 5. ip rule fwmark → table 100?
if ! ip rule show | grep -q "fwmark 0x1 lookup 100"; then
    issues+=("ip rule fwmark 0x1 → table 100 отсутствует")
    log "FAIL: ip rule missing"
    [ -x /usr/local/sbin/awg-cascade-iprule.sh ] && /usr/local/sbin/awg-cascade-iprule.sh
fi

# 5b. Firewall второго клиентского интерфейса на месте?
#     Отдельная проверка, а не часть п.4: тот смотрит на kill-switch awg0, а он
#     присутствует всегда — даже когда правила $CLIENT3_IFACE не применились
#     совсем. Ровно так wgc3 и оставался без MARK/MASQUERADE после загрузки,
#     а postboot рапортовал OK.
if [ -n "${CLIENT3_IFACE:-}" ] && ip link show "$CLIENT3_IFACE" >/dev/null 2>&1; then
    if [ "$(iptables-save -t mangle 2>/dev/null | grep -c awg-cascade-c3)" -eq 0 ]; then
        issues+=("$CLIENT3_IFACE без firewall-правил (нет MARK -> трафик мимо table 100)")
        log "FAIL: $CLIENT3_IFACE c3-rules missing - reapplying"
        [ -x /usr/local/sbin/awg-cascade-client3-fw.sh ] && /usr/local/sbin/awg-cascade-client3-fw.sh >/dev/null 2>&1 || true
    fi
fi

# 6. per-peer inter-client LAN-доступ (идемпотентно переприменяем после буста)
[ -x /usr/local/sbin/awg-cascade-interclient.sh ] && /usr/local/sbin/awg-cascade-interclient.sh || true

# Финальный отчёт
if [ ${#issues[@]} -eq 0 ]; then
    log "OK — all checks passed"
    ntfy "✅ Postboot OK" "low" "white_check_mark" \
        "Каскад поднялся.\nHost: $(hostname)"
else
    log "FAILS: ${#issues[@]} issues found"
    body="Найдено проблем: ${#issues[@]}"$'\n\n'
    for issue in "${issues[@]}"; do
        body="${body}• ${issue}"$'\n'
    done
    body="${body}"$'\n'"Host: $(hostname)"
    ntfy "⚠️ Postboot: проблемы" "high" "warning" "$body"
fi

# Перезапустим watchdog чтобы он подтянул возможные изменения
systemctl restart awg-cascade-watchdog 2>/dev/null || true
