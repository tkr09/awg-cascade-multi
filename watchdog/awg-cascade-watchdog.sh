#!/bin/bash
# =============================================================================
# AWG Cascade Multi — Watchdog
#
# Цикл каждые 5 сек:
#   1. Ping каждого enabled exit (ICMP → TCP fallback)
#   2. Handshake age
#   3. Hysteresis: 3 fail подряд → DOWN, 2 success подряд → UP
#   4. Если handshake > 180s → reconnect awgN
#   5. Atomic update state.json
#   6. ECMP route replace
#   7. Каждые 5 мин пересчёт весов (если разница > 20%)
#   8. ntfy alerts через --interface eth0 (emergency egress)
#
# Запускается из awg-cascade-watchdog.service (systemd)
# =============================================================================

set -u

# ─── Конфиг ───────────────────────────────────────────────────────────────────
. /etc/awg-cascade/config

STATE=/etc/awg-cascade/state.json
STATE_LOCK=/etc/awg-cascade/state.lock
LOG=/var/log/awg-cascade-watchdog.log

TICK_INTERVAL=5            # сек между тиками
RING_SIZE=20               # последние N точек пинга
DOWN_THRESHOLD=3           # 3 fail подряд → DOWN
UP_THRESHOLD=2             # 2 success подряд → UP
PING_TIMEOUT=2             # сек
HANDSHAKE_MAX=180          # сек, после этого reconnect
WEIGHT_RECALC_TICKS=60     # 60 тиков * 5с = 5 мин
WEIGHT_DIFF_PERCENT=20     # пересчёт весов только если разница > 20%

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

# Гарантируем что state.lock world-writable (иначе bot от awgbot не сможет
# открыть R/W когда root уже создал файл). Bash redirection в `200>"$STATE_LOCK"`
# создаёт файл с дефолтными правами 0644 если его не было.
touch "$STATE_LOCK" 2>/dev/null || true
chmod 666 "$STATE_LOCK" 2>/dev/null || true

# ─── Утилиты ──────────────────────────────────────────────────────────────────
log() { echo "$(date -Iseconds) $*"; }

# Atomic update of state.json
update_state() {
    local jq_filter=$1
    (
        flock -x 200
        local tmp
        tmp=$(mktemp)
        if jq "$jq_filter" "$STATE" > "$tmp" 2>/dev/null; then
            chown awgbot:awgbot "$tmp" 2>/dev/null
            chmod 644 "$tmp"
            mv "$tmp" "$STATE"
        else
            rm -f "$tmp"
            log "ERROR: update_state failed for filter: $jq_filter"
        fi
    ) 200>"$STATE_LOCK"
}

# Send ntfy via eth0 (emergency egress, bypasses cascade)
ntfy() {
    local title="$1" priority="${2:-default}" tags="${3:-}" body="${4:-}"
    [ -n "${NTFY_URL:-}" ] || return 0
    curl --interface eth0 -s --max-time 8 \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "$body" \
        "$NTFY_URL" >/dev/null 2>&1 || log "WARN: ntfy failed"
}

# Возвращает handshake age в секундах (9999 если нет handshake)
hs_age() {
    local iface=$1
    local hs
    hs=$(awg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    if [ -z "$hs" ] || [ "$hs" = "0" ]; then
        echo "9999"
    else
        echo $(( $(date +%s) - hs ))
    fi
}

# Smart ping через интерфейс. Echo "ms" или "-1" на fail.
smart_ping() {
    local iface=$1
    local target=${2:-1.1.1.1}
    local ms
    # 1. ICMP
    ms=$(ping -I "$iface" -c 1 -W "$PING_TIMEOUT" "$target" 2>/dev/null \
         | grep -oP 'time=\K[0-9.]+' | head -1)
    if [ -n "$ms" ]; then
        echo "${ms%.*}"  # int часть
        return 0
    fi
    # 2. TCP fallback (curl https)
    local start end
    start=$(date +%s%N)
    if timeout "$PING_TIMEOUT" curl --interface "$iface" -s -o /dev/null \
            -m "$PING_TIMEOUT" --connect-timeout "$PING_TIMEOUT" \
            "https://${target}/" 2>/dev/null; then
        end=$(date +%s%N)
        echo $(( (end - start) / 1000000 ))
        return 0
    fi
    echo "-1"
    return 1
}

# Down + Up интерфейса
reconnect_iface() {
    local iface=$1
    log "RECONNECT $iface (handshake stale)"
    awg-quick down "$iface" >/dev/null 2>&1 || true
    sleep 1
    awg-quick up   "$iface" >/dev/null 2>&1 || true
}

# Применить per-peer routing rules: pinned peers → их exit (table 100+idx),
# остальные (auto) — через fwmark→table 100 (ECMP).
apply_peer_routing() {
    local PEERS_JSON=/etc/awg-cascade/peers.json
    [ -f "$PEERS_JSON" ] || return 0

    # 1. Удаляем все наши per-peer rules (priority 999, from <ip>/32)
    while ip rule show priority 999 2>/dev/null | grep -q "^999:"; do
        ip rule del priority 999 2>/dev/null || break
    done

    # 2. Чистим персональные таблицы 101..199
    for tid in $(seq 101 199); do
        if ip route show table $tid 2>/dev/null | grep -q .; then
            ip route flush table $tid 2>/dev/null
        fi
    done

    # 3. Для каждого pinned peer'а:
    #    - table = 100 + exit_index
    #    - в табле: default dev awgN (single)
    #    - ip rule: from peer_ip/32 lookup table priority 999
    while IFS= read -r peer; do
        local peer_ip pinned
        peer_ip=$(jq -r .ip            <<<"$peer")
        pinned=$(jq -r '.pinned_exit // empty' <<<"$peer")
        [ -z "$pinned" ] || [ "$pinned" = "null" ] && continue

        # pinned = interface name (awg1, awg2, ...)
        if ! ip link show "$pinned" >/dev/null 2>&1; then
            log "PIN $peer_ip → $pinned: интерфейс down, пропускаем"
            continue
        fi

        local idx tid
        idx=$(echo "$pinned" | sed 's/awg//')
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        tid=$((100 + idx))

        ip route replace default dev "$pinned" table "$tid"
        ip rule add from "${peer_ip}/32" lookup "$tid" priority 999 2>/dev/null
    done < <(jq -c '.[]' "$PEERS_JSON" 2>/dev/null)
}

# Применить ECMP route в table 100 на основе текущего state
apply_route() {
    local nexthops=""
    local active=()
    while IFS= read -r row; do
        local iface enabled status weight
        iface=$(jq -r .interface <<<"$row")
        enabled=$(jq -r .enabled   <<<"$row")
        status=$(jq -r .status     <<<"$row")
        weight=$(jq -r .weight     <<<"$row")
        if [ "$enabled" = "true" ] && [ "$status" = "up" ]; then
            # Проверяем что интерфейс реально существует
            if ip link show "$iface" >/dev/null 2>&1; then
                nexthops="$nexthops nexthop dev $iface weight $weight"
                active+=("\"$iface\"")
            fi
        fi
    done < <(jq -c '.exits[]' "$STATE")

    if [ -n "$nexthops" ]; then
        # shellcheck disable=SC2086
        ip route replace default table 100 $nexthops 2>&1 \
            || log "ERROR: ip route replace failed (nexthops=$nexthops)"
    else
        ip route flush table 100 2>/dev/null
        log "ECMP empty — table 100 flushed (kill-switch ACTIVE)"
    fi

    # Обновляем state
    local active_json
    if [ ${#active[@]} -eq 0 ]; then
        active_json="[]"
    else
        active_json="[$(IFS=,; echo "${active[*]}")]"
    fi
    local kill_switch
    [ -z "$nexthops" ] && kill_switch=true || kill_switch=false
    update_state ".active_default_route = $active_json | .kill_switch_active = $kill_switch"
}

# Пересчёт весов: weight = round(min_ping_alive / this_ping * 10), min 1
recompute_weights() {
    local pings=()
    local ifaces=()
    while IFS= read -r row; do
        local iface enabled status avg
        iface=$(jq -r .interface  <<<"$row")
        enabled=$(jq -r .enabled  <<<"$row")
        status=$(jq -r .status    <<<"$row")
        avg=$(jq -r '.ping_avg // empty' <<<"$row")
        if [ "$enabled" = "true" ] && [ "$status" = "up" ] && [ -n "$avg" ]; then
            pings+=("$avg")
            ifaces+=("$iface")
        fi
    done < <(jq -c '.exits[]' "$STATE")

    local n=${#pings[@]}
    [ "$n" -lt 1 ] && return

    # Минимальный пинг среди живых
    local min_ping=999999
    for p in "${pings[@]}"; do
        # int сравнение через bc если float
        local pi=${p%.*}
        [ "$pi" -lt "$min_ping" ] && min_ping=$pi
    done
    [ "$min_ping" -lt 1 ] && min_ping=1

    # Считаем новые веса
    local need_apply=false
    for i in "${!ifaces[@]}"; do
        local iface=${ifaces[$i]}
        local p=${pings[$i]%.*}
        [ "$p" -lt 1 ] && p=1
        local new_weight=$(( (min_ping * 10 + p / 2) / p ))
        [ "$new_weight" -lt 1 ] && new_weight=1
        [ "$new_weight" -gt 10 ] && new_weight=10

        local cur_weight
        cur_weight=$(jq -r ".exits[] | select(.interface==\"$iface\") | .weight" "$STATE")

        # Применять только если разница > WEIGHT_DIFF_PERCENT
        local diff_pct=0
        if [ "$cur_weight" -gt 0 ]; then
            diff_pct=$(( (new_weight > cur_weight ? new_weight - cur_weight : cur_weight - new_weight) * 100 / cur_weight ))
        fi
        if [ "$diff_pct" -ge "$WEIGHT_DIFF_PERCENT" ]; then
            update_state "(.exits[] | select(.interface==\"$iface\")) |= (.weight = $new_weight)"
            log "WEIGHT $iface: $cur_weight → $new_weight (ping=${p}ms, min=${min_ping}ms)"
            need_apply=true
        fi
    done

    $need_apply && apply_route
}

# Postboot verify (вызывается один раз при старте)
postboot_check() {
    sleep 3
    log "Postboot verify"
    local fails=""
    while IFS= read -r row; do
        local iface name
        iface=$(jq -r .interface <<<"$row")
        name=$(jq  -r .name      <<<"$row")
        if ! awg show "$iface" >/dev/null 2>&1; then
            fails="$fails $name"
            log "POSTBOOT FAIL: $name ($iface) interface down"
            # Попытка поднять
            awg-quick up "$iface" >/dev/null 2>&1 || true
        fi
    done < <(jq -c '.exits[]' "$STATE")

    if [ -n "$fails" ]; then
        ntfy "⚠️ Postboot fails" "high" "warning" "Интерфейсы не подняты:$fails"
    else
        log "Postboot OK"
    fi
}

# ─── Per-interface state (in memory) ─────────────────────────────────────────
declare -A FAIL_COUNT
declare -A SUCC_COUNT
declare -A PREV_STATUS
TICK_COUNT=0

process_exit() {
    local row=$1
    local iface name enabled cur_status
    iface=$(jq -r .interface   <<<"$row")
    name=$(jq  -r .name        <<<"$row")
    enabled=$(jq -r .enabled   <<<"$row")
    cur_status=$(jq -r .status <<<"$row")

    [ "$enabled" != "true" ] && return

    local ping_ms hs
    ping_ms=$(smart_ping "$iface")
    hs=$(hs_age "$iface")

    if [ "$ping_ms" = "-1" ]; then
        FAIL_COUNT[$iface]=$(( ${FAIL_COUNT[$iface]:-0} + 1 ))
        SUCC_COUNT[$iface]=0
    else
        SUCC_COUNT[$iface]=$(( ${SUCC_COUNT[$iface]:-0} + 1 ))
        FAIL_COUNT[$iface]=0
    fi

    # Hysteresis transitions
    local new_status=$cur_status
    if [ "$cur_status" = "up" ] && [ "${FAIL_COUNT[$iface]:-0}" -ge "$DOWN_THRESHOLD" ]; then
        new_status="down"
        log "FLIP $name → DOWN (fails=${FAIL_COUNT[$iface]})"
        ntfy "🔴 Exit DOWN: $name" "urgent" "rotating_light" \
            "$name ($iface): $DOWN_THRESHOLD ping fails подряд.\nУбираю из ECMP.\nHost: $(hostname)"
    elif [ "$cur_status" = "down" ] && [ "${SUCC_COUNT[$iface]:-0}" -ge "$UP_THRESHOLD" ]; then
        new_status="up"
        log "FLIP $name → UP (successes=${SUCC_COUNT[$iface]}, ping=${ping_ms}ms)"
        ntfy "🟢 Exit UP: $name" "high" "white_check_mark" \
            "$name ($iface): вернулся в строй (ping=${ping_ms}ms).\nДобавлен в ECMP."
    fi

    # Reconnect если handshake состарился
    if [ "$hs" -gt "$HANDSHAKE_MAX" ]; then
        reconnect_iface "$iface"
    fi

    # Записываем в state: ping_ring, status, last_ping, handshake_age, ping_avg, ping_loss
    update_state "
        (.exits[] | select(.interface == \"$iface\")) |= (
            .ping_ring = ((.ping_ring + [$ping_ms]) | if length > $RING_SIZE then .[length-$RING_SIZE:] else . end)
            | .last_ping = $ping_ms
            | .handshake_age = $hs
            | .status = \"$new_status\"
            | .ping_avg = ([.ping_ring[] | select(. > 0)] | if length > 0 then (add / length | (. * 10 | round) / 10) else null end)
            | .ping_loss = (
                if (.ping_ring | length) > 0
                then ([.ping_ring[] | select(. < 0)] | length) * 100 / (.ping_ring | length)
                else 0 end
            )
        )
    "

    PREV_STATUS[$iface]=$new_status
}

# ─── Main loop ───────────────────────────────────────────────────────────────
trap 'log "watchdog stopping"; exit 0' SIGTERM SIGINT

log "================================="
log "watchdog starting (host=$(hostname), pid=$$)"
ntfy "🚀 Watchdog started" "low" "rocket" "Host: $(hostname)\nTick: ${TICK_INTERVAL}s"

# Применить fwmark rules (если потерялись после ребута)
[ -x /usr/local/sbin/awg-cascade-iprule.sh ] && /usr/local/sbin/awg-cascade-iprule.sh

postboot_check
apply_route
apply_peer_routing

# SIGUSR1 = немедленно пересобрать peer-routing (когда бот меняет pin)
trap 'apply_peer_routing; log "SIGUSR1: peer routing reapplied"' SIGUSR1

while true; do
    TICK_COUNT=$(( TICK_COUNT + 1 ))

    # Status flips счётчик для apply_route
    status_changed=false
    while IFS= read -r row; do
        iface_x=$(jq -r .interface  <<<"$row")
        old_status=$(jq -r .status  <<<"$row")
        process_exit "$row"
        # PREV_STATUS[$iface_x] выставлен в process_exit = новый статус
        if [ "${PREV_STATUS[$iface_x]:-}" != "$old_status" ]; then
            status_changed=true
        fi
    done < <(jq -c '.exits[]' "$STATE")

    # apply_route в каждом тике (а не только при status change) — это
    # копеечно (ip route replace идемпотентен) и защищает от случаев когда
    # таблица 100 опустела из-за restart awg-quick@awgN или ручного down/up.
    apply_route

    # Применяем per-peer pinned маршруты (раз в тик — копеечно)
    apply_peer_routing

    # Пересчёт весов раз в 5 мин
    if [ $(( TICK_COUNT % WEIGHT_RECALC_TICKS )) -eq 0 ]; then
        recompute_weights
    fi

    # Last update timestamp
    update_state ".last_update = \"$(date -Iseconds)\""

    sleep "$TICK_INTERVAL"
done
