#!/bin/bash
# AWG Cascade Multi — Postboot verify (одноразовый, через 90s после network-online)
# Проверяет что awg0, все awgN, ECMP и kill-switch — в норме.
# Если что-то не так — ntfy + попытка recovery.

set -u
. /etc/awg-cascade/config

STATE=/etc/awg-cascade/state.json
LOG=/var/log/awg-cascade-watchdog.log

log() { echo "$(date -Iseconds) POSTBOOT $*" >> "$LOG"; }

ntfy() {
    local title="$1" priority="${2:-default}" tags="${3:-}" body="${4:-}"
    [ -n "${NTFY_URL:-}" ] || return 0
    curl --interface eth0 -s --max-time 8 \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$body" "$NTFY_URL" >/dev/null 2>&1 || true
}

issues=()

# 1. awg0 поднят?
if ! awg show awg0 >/dev/null 2>&1; then
    issues+=("awg0 интерфейс не существует")
    log "FAIL: awg0 down — trying to bring up"
    awg-quick up awg0 >/dev/null 2>&1 || true
fi

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
