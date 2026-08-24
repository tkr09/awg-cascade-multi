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
#   7. Каждые 5 мин пересчёт весов (пороги + гистерезис + выдержка, см. ниже)
#   8. ntfy alerts через --interface $MAIN_IFACE (emergency egress, мимо каскада)
#
# Запускается из awg-cascade-watchdog.service (systemd)
# =============================================================================

set -u

# ─── Конфиг ───────────────────────────────────────────────────────────────────
. /etc/awg-cascade/config

STATE=/etc/awg-cascade/state.json
STATE_LOCK=/etc/awg-cascade/state.lock
LOG=/var/log/awg-cascade-watchdog.log

TICK_INTERVAL=10           # сек между тиками (1-ядерные VPS: меньше пробуждений)
RING_SIZE=20               # последние N точек пинга
DOWN_THRESHOLD=3           # 3 fail подряд → DOWN
UP_THRESHOLD=2             # 2 success подряд → UP
PING_TIMEOUT=2             # сек
HANDSHAKE_MAX=180          # сек, после этого reconnect

# ─── Backoff переподключения ──────────────────────────────────────────────────
# Без него зависший handshake давал `awg-quick down/up` КАЖДЫЙ тик, то есть раз
# в 10 секунд без конца. В инциденте 22.08.2026, когда с RU-1 разом пропали все
# четыре туннеля, это дало 35 переподключений подряд: вылечить они ничего не
# могли (проблема была вне ноды), а каждое down/up рвало то, что ещё жило, и
# сбрасывало счётчики. Теперь интервал удваивается до потолка и сбрасывается,
# как только handshake снова свежий.
: "${RECONNECT_BACKOFF_MIN:=30}"    # сек до первой повторной попытки
: "${RECONNECT_BACKOFF_MAX:=600}"   # потолок интервала (10 мин)
WEIGHT_RECALC_TICKS=30     # 30 тиков * 10с = 5 мин

# ─── Веса ECMP ────────────────────────────────────────────────────────────────
# ВАЖНО, почему тут пороги, а не формула от min_ping (как было до v2.1.6):
# `ip route replace` на multipath-маршруте НЕ бесплатен. При
# fib_multipath_hash_policy=1 nexthop выбирается по хешу L4-кортежа на каждый
# пакет, привязки потока к маршруту в Linux нет. Смена весов двигает границы
# бакетов → часть ЖИВЫХ соединений переезжает на другой exit → там другой
# MASQUERADE и другой внешний IP → установленные TCP/TLS-сессии рвутся.
#
# Старая формула weight = min_ping_alive/this_ping*10 меняла веса 110-145 раз
# в сутки (замер по логам обеих RU), то есть практически каждый пересчёт рвал
# кому-то соединения. Две причины: min_ping — ПОДВИЖНАЯ точка отсчёта (джиттер
# на самом быстром exit'е пересчитывал веса сразу всем), а порог в 20%
# сравнивался на целых 1..10, где шаг ±1 это 10-50% и проходил почти всегда.
#
# Теперь: фиксированные пороги пинга (ни от кого не зависят) + гистерезис на
# границе + минимальная выдержка между сменами + медиана вместо среднего.
WEIGHT_TIERS="30:10 45:8 65:6 90:4 130:2"   # <ping_ms>:<вес>, свыше последнего → 1
: "${WEIGHT_HYST_PCT:=15}"      # на сколько % надо перевалить границу, чтобы УХУДШИТЬ вес
: "${WEIGHT_MIN_DWELL:=1800}"   # сек: не менять вес одного iface чаще, чем раз в 30 мин
: "${WEIGHT_URGENT_DELTA:=6}"   # обвал на 3+ ступени (напр. 8→2) — деградация, выдержку игнорируем

# ─── Alerting (A) — значения можно переопределить в /etc/awg-cascade/config ──
: "${BOT_USER:=awgbot}"
: "${HC_PING_URL:=}"               # healthchecks.io ping URL (dead-man); пусто = выкл
: "${DISK_ALERT_PCT:=90}"          # алерт если занято / >= N%
: "${RAM_ALERT_PCT:=90}"           # алерт если RAM >= N%
: "${LOAD_ALERT_MULT:=2}"          # алерт если load1 > MULT * nproc
: "${RES_COOLDOWN:=21600}"         # 6ч между повторами level-алертов (disk/ram/load)
: "${EGRESS_CHECK_URL:=https://api.telegram.org}"
ALERT=/usr/local/sbin/awg-cascade-alert.sh
NPROC=$(nproc 2>/dev/null || echo 1)

# Интерфейс для аварийного egress (ntfy/healthchecks идут МИМО каскада, чтобы
# алертить даже когда туннели лежат). Раньше здесь был литерал eth0 — на ноде с
# ens3/enp1s0 весь алертинг молча умирал бы, потому что ошибки curl подавляются.
# Берём из config (setup.sh его определяет), с фолбэком на eth0 = прежнее поведение.
: "${MAIN_IFACE:=eth0}"
# Если NIC переименовался после апгрейда ядра, config устарел: молчащий алертинг
# хуже неточного, поэтому подстраховываемся текущим default-route.
ip link show "$MAIN_IFACE" >/dev/null 2>&1 || MAIN_IFACE=$(
    ip route show default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
: "${MAIN_IFACE:=eth0}"
EGRESS_FAILS=0
EGRESS_STATE=up

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
    curl --interface "$MAIN_IFACE" -s --max-time 8 \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "$body" \
        "$NTFY_URL" >/dev/null 2>&1 || log "WARN: ntfy failed (iface=$MAIN_IFACE)"
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

# Down + Up интерфейса. $2 — текущий интервал backoff, только для лога.
reconnect_iface() {
    local iface=$1 wait_s=${2:-}
    log "RECONNECT $iface (handshake stale${wait_s:+, следующая попытка не раньше чем через ${wait_s}s})"
    awg-quick down "$iface" >/dev/null 2>&1 || true
    sleep 1
    awg-quick up   "$iface" >/dev/null 2>&1 || true
}

# Отпечаток желаемого состояния peer-routing: пары «ip>интерфейс» плюс живость
# каждого задействованного интерфейса. Меняется ровно тогда, когда правила надо
# перестраивать, — и не меняется от тика к тику при спокойном каскаде.
PEERS_JSON=/etc/awg-cascade/peers.json
PEER_ROUTING_SIG=""
PEER_TABLES_APPLIED=""

peer_routing_signature() {
    [ -f "$PEERS_JSON" ] || { echo "-"; return; }
    local pairs iface up=""
    pairs=$(jq -r '[.[] | select(.pinned_exit != null) | "\(.ip)>\(.pinned_exit)"]
                   | sort | join(",")' "$PEERS_JSON" 2>/dev/null)
    for iface in $(jq -r '[.[] | .pinned_exit // empty] | unique | .[]?' "$PEERS_JSON" 2>/dev/null); do
        ip link show "$iface" >/dev/null 2>&1 && up="$up$iface:1," || up="$up$iface:0,"
    done
    echo "$pairs|$up"
}

# Применить per-peer routing rules: pinned peers → их exit (table 100+idx),
# остальные (auto) — через fwmark→table 100 (ECMP).
#
# ВЫЗЫВАТЬ ТОЛЬКО ПРИ ИЗМЕНЕНИИ (см. peer_routing_signature). До v2.1.6 эта
# функция бежала КАЖДЫЙ тик, то есть раз в 10 секунд сносила правила priority
# 999 и заново их ставила. В окне между `ip rule del` и `ip rule add` pinned-пир
# проваливался на общее правило fwmark → table 100 и уезжал в ECMP на чужой
# exit — то есть его соединения рвались каждые 10 секунд. Плюс `seq 101 199`
# давал 99 вызовов `ip route show` на тик впустую.
apply_peer_routing() {
    [ -f "$PEERS_JSON" ] || return 0

    # 1. Удаляем все наши per-peer rules (priority 999, from <ip>/32)
    while ip rule show priority 999 2>/dev/null | grep -q "^999:"; do
        ip rule del priority 999 2>/dev/null || break
    done

    # 2. Чистим только те персональные таблицы, которые сами же и наполняли в
    #    прошлый раз. Слепой проход по 101..199 не нужен: чужого там быть не
    #    может, а свои мы помним.
    local tid
    for tid in $PEER_TABLES_APPLIED; do
        ip route flush table "$tid" 2>/dev/null
    done
    PEER_TABLES_APPLIED=""

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

        local idx ptid
        idx=$(echo "$pinned" | sed 's/awg//')
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        ptid=$((100 + idx))

        ip route replace default dev "$pinned" table "$ptid"
        ip rule add from "${peer_ip}/32" lookup "$ptid" priority 999 2>/dev/null
        case " $PEER_TABLES_APPLIED " in
            *" $ptid "*) ;;
            *) PEER_TABLES_APPLIED="$PEER_TABLES_APPLIED $ptid" ;;
        esac
    done < <(jq -c '.[]' "$PEERS_JSON" 2>/dev/null)
}

# Перестроить peer-routing, только если желаемое состояние изменилось.
sync_peer_routing() {
    local sig
    sig=$(peer_routing_signature)
    [ "$sig" = "$PEER_ROUTING_SIG" ] && return 0
    apply_peer_routing
    PEER_ROUTING_SIG="$sig"
}

# Разовая уборка на старте. Инкрементальная чистка выше помнит только таблицы,
# которые наполнил ЭТОТ процесс, поэтому после рестарта watchdog'а таблицы от
# прошлого запуска остались бы висеть. Сами по себе они безвредны (правил на них
# нет, значит в маршрутизации не участвуют), но пусть не копятся. Проход по
# 101..199 стоит дорого только когда он на каждом тике — раз при старте не жалко.
peer_routing_initial_cleanup() {
    local tid
    for tid in $(seq 101 199); do
        ip route show table "$tid" 2>/dev/null | grep -q . \
            && ip route flush table "$tid" 2>/dev/null
    done
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

# Вес по пингу: фиксированные пороги + гистерезис на границе.
# $1 = пинг (целое, мс), $2 = текущий вес. Печатает новый вес.
#
# Гистерезис асимметричный и это намеренно: УЛУЧШЕНИЕ применяется сразу, а
# чтобы ухудшить вес, пинг должен перевалить границу с запасом. Иначе пинг,
# болтающийся ровно на пороге, гонял бы вес туда-сюда — ровно то, от чего
# уходим. Расширяем только ту границу, на которой стоим сейчас.
weight_for_ping() {
    local p=$1 cur=${2:-0} tier bound w
    for tier in $WEIGHT_TIERS; do
        bound=${tier%%:*}
        w=${tier##*:}
        [ "$w" = "$cur" ] && bound=$(( bound * (100 + WEIGHT_HYST_PCT) / 100 ))
        if [ "$p" -lt "$bound" ]; then echo "$w"; return; fi
    done
    echo 1
}

# Пересчёт весов ECMP. Осторожно: каждая смена веса перетасовывает живые потоки
# между exit'ами (см. блок WEIGHT_TIERS выше), поэтому здесь три независимых
# тормоза — пороги, гистерезис и выдержка.
recompute_weights() {
    local now need_apply=false
    now=$(date +%s)

    while IFS= read -r row; do
        local iface enabled status med cur_weight changed_at new_weight
        iface=$(jq -r .interface <<<"$row")
        enabled=$(jq -r .enabled <<<"$row")
        status=$(jq -r .status   <<<"$row")
        [ "$enabled" = "true" ] && [ "$status" = "up" ] || continue

        # Медиана ring'а, а не среднее: одиночный выброс (наблюдали 30→114 мс на
        # PL) сдвигает среднее настолько, что вес прыгал 6→2 и обратно.
        med=$(jq -r '[.ping_ring[] | select(. > 0)] | sort
                     | if length == 0 then empty else .[(length/2)|floor] end' <<<"$row")
        [ -n "$med" ] || continue
        med=${med%.*}
        [ "$med" -lt 1 ] && med=1

        cur_weight=$(jq -r '.weight // 0'            <<<"$row")
        changed_at=$(jq -r '.weight_changed_at // 0' <<<"$row")
        case "$changed_at" in ''|*[!0-9]*) changed_at=0 ;; esac

        new_weight=$(weight_for_ping "$med" "$cur_weight")
        [ "$new_weight" = "$cur_weight" ] && continue

        # Выдержка. Обходим её ТОЛЬКО при резком ухудшении: держать трафик
        # полчаса на обвалившемся exit'е хуже, чем разово перетасовать потоки.
        # Восстановление выдержку не обходит — оно не срочное (трафик и так
        # идёт по живым exit'ам), а спешка тут превратила бы пару
        # «просадка + возврат» в две перетасовки подряд.
        local urgent=0
        if [ "$new_weight" -lt "$cur_weight" ] \
           && [ $(( cur_weight - new_weight )) -ge "$WEIGHT_URGENT_DELTA" ]; then
            urgent=1
        fi
        if [ "$urgent" = "0" ] && [ $(( now - changed_at )) -lt "$WEIGHT_MIN_DWELL" ]; then
            continue
        fi

        update_state "(.exits[] | select(.interface==\"$iface\"))
                      |= (.weight = $new_weight | .weight_changed_at = $now)"
        # changed_at=0 = поля ещё не было (первая смена после апгрейда), и
        # разница с нулём печаталась бы как эпоха целиком.
        local since
        [ "$changed_at" -gt 0 ] && since="$(( now - changed_at ))s" || since="первая"
        log "WEIGHT $iface: $cur_weight → $new_weight (медиана=${med}ms, выдержка=$since)"
        need_apply=true
    done < <(jq -c '.exits[]' "$STATE")

    $need_apply && apply_route
}

# ─── Alerting (A): bot egress / ресурсы / healthchecks dead-man ──────────────
# Bot egress к Telegram через каскад (transition-алерт: state в памяти).
check_bot_egress() {
    local code
    code=$(sudo -u "$BOT_USER" curl -s -o /dev/null -w '%{http_code}' \
           --max-time 12 "$EGRESS_CHECK_URL" 2>/dev/null)
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        EGRESS_FAILS=$(( EGRESS_FAILS + 1 ))
        if [ "$EGRESS_FAILS" -ge 3 ] && [ "$EGRESS_STATE" = "up" ]; then
            EGRESS_STATE=down
            log "EGRESS DOWN (bot→Telegram, fails=$EGRESS_FAILS)"
            "$ALERT" egress-down 0 "🔴 Бот не видит Telegram" urgent rotating_light \
                "curl $EGRESS_CHECK_URL = ${code:-timeout} (через каскад). Смотри ip rules / exits / egress."
        fi
    else
        if [ "$EGRESS_STATE" = "down" ]; then
            EGRESS_STATE=up
            log "EGRESS UP (bot→Telegram restored, code=$code)"
            "$ALERT" egress-up 0 "🟢 Egress восстановлен" high white_check_mark \
                "Бот снова видит Telegram (HTTP $code)."
        fi
        EGRESS_FAILS=0
    fi
}

# Disk / RAM / load — level-алерты с cooldown.
check_resources() {
    local disk ram load1
    disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
    ram=$(free 2>/dev/null | awk '/^Mem:/{printf "%d", $3*100/$2}')
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    [ -n "$disk" ] && [ "$disk" -ge "$DISK_ALERT_PCT" ] && \
        "$ALERT" disk-high "$RES_COOLDOWN" "⚠️ Диск ${disk}%" high warning \
            "Занято ${disk}% на / (порог ${DISK_ALERT_PCT}%)."
    [ -n "$ram" ] && [ "$ram" -ge "$RAM_ALERT_PCT" ] && \
        "$ALERT" ram-high "$RES_COOLDOWN" "⚠️ RAM ${ram}%" high warning \
            "Память ${ram}% (порог ${RAM_ALERT_PCT}%)."
    if [ -n "$load1" ] && awk -v l="$load1" -v t="$(( LOAD_ALERT_MULT * NPROC ))" 'BEGIN{exit !(l>t)}'; then
        "$ALERT" load-high "$RES_COOLDOWN" "⚠️ Load ${load1}" high warning \
            "load1=${load1} > ${LOAD_ALERT_MULT}×${NPROC} ядер."
    fi
}

# Dead-man: пинг healthchecks.io через eth0. Пропал пинг → их сервис алертит.
healthcheck_ping() {
    [ -n "$HC_PING_URL" ] || return 0
    curl --interface "$MAIN_IFACE" -fsS -m 10 "$HC_PING_URL" >/dev/null 2>&1 \
        || log "WARN: healthcheck ping failed (iface=$MAIN_IFACE)"
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
declare -A RECONNECT_NEXT   # iface → epoch, раньше которого не переподключаемся
declare -A RECONNECT_WAIT   # iface → текущий интервал backoff в секундах
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
    # Reconnect если handshake состарился — но не чаще, чем позволяет backoff.
    if [ "$hs" -gt "$HANDSHAKE_MAX" ]; then
        local now_ts wait_s
        now_ts=$(date +%s)
        if [ "$now_ts" -ge "${RECONNECT_NEXT[$iface]:-0}" ]; then
            wait_s=${RECONNECT_WAIT[$iface]:-$RECONNECT_BACKOFF_MIN}
            reconnect_iface "$iface" "$wait_s"
            RECONNECT_NEXT[$iface]=$(( now_ts + wait_s ))
            wait_s=$(( wait_s * 2 ))
            [ "$wait_s" -gt "$RECONNECT_BACKOFF_MAX" ] && wait_s=$RECONNECT_BACKOFF_MAX
            RECONNECT_WAIT[$iface]=$wait_s
        fi
    else
        # Handshake свежий — цепочка неудач прервана, начинаем счёт заново.
        if [ -n "${RECONNECT_NEXT[$iface]:-}" ] && [ "${RECONNECT_NEXT[$iface]}" != "0" ]; then
            log "RECONNECT $iface: handshake восстановлен, backoff сброшен"
        fi
        RECONNECT_NEXT[$iface]=0
        RECONNECT_WAIT[$iface]=$RECONNECT_BACKOFF_MIN
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
peer_routing_initial_cleanup
sync_peer_routing   # первый прогон заодно инициализирует отпечаток

# SIGUSR1 = немедленно пересобрать peer-routing (когда бот меняет pin).
# Строим безусловно и обновляем отпечаток: бот шлёт сигнал именно потому, что
# уже изменил peers.json, а ждать следующего тика незачем.
trap 'apply_peer_routing; PEER_ROUTING_SIG=$(peer_routing_signature); log "SIGUSR1: peer routing reapplied"' SIGUSR1

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

    # Per-peer pinned маршруты: сверяем отпечаток и трогаем правила ТОЛЬКО если
    # что-то реально изменилось (сменился pin или упал/поднялся его интерфейс).
    # Безусловная перестройка каждый тик рвала соединения pinned-пиров.
    sync_peer_routing

    # Страховка ip rules: policy-routing (uidrange/fwmark → table 100) может
    # быть стёрт переконфигурацией сети В РАНТАЙМЕ (netplan/networkd при
    # apt-upgrade флашит ip rules; table 100 при этом остаётся). Без них
    # трафик бота (uid) и клиентов (fwmark) уходит МИМО каскада напрямую →
    # блокировки ТСПУ → бот «висит». iprule.service применяет только на boot,
    # поэтому проверяем и в цикле.
    if ! ip rule show | grep -q "fwmark 0x1 lookup 100"; then
        log "FAIL: ip rules каскада пропали — переприменяю iprule.sh"
        [ -x /usr/local/sbin/awg-cascade-iprule.sh ] && /usr/local/sbin/awg-cascade-iprule.sh
        ntfy "⚠️ ip rules восстановлены" "high" "warning" \
            "policy-routing (→ table 100) пропадал и был переприменён.\nХост: $(hostname)"
    fi

    # A: алертинг. Bot-egress + healthchecks dead-man раз в ~60с (6 тиков),
    # ресурсы раз в ~5 мин (30 тиков).
    if [ $(( TICK_COUNT % 6 )) -eq 0 ]; then
        check_bot_egress
        healthcheck_ping
    fi
    if [ $(( TICK_COUNT % 30 )) -eq 0 ]; then
        check_resources
        # D: сэмплируем счётчики трафика per-peer в CSV (для графиков в боте)
        [ -x /usr/local/sbin/awg-cascade-traffic-sample.sh ] \
            && /usr/local/sbin/awg-cascade-traffic-sample.sh
        # Kernel drift: unattended-upgrades не тянет новые ядра (приходят новыми
        # пакетами) — предупреждаем, чтобы не отставать месяцами. Внутри скрипта
        # суточный stamp, поэтому реально бегает раз в день.
        [ -x /usr/local/sbin/awg-cascade-kernel-check.sh ] \
            && /usr/local/sbin/awg-cascade-kernel-check.sh >/dev/null 2>&1 &
    fi

    # Пересчёт весов раз в 5 мин
    if [ $(( TICK_COUNT % WEIGHT_RECALC_TICKS )) -eq 0 ]; then
        recompute_weights
    fi

    # Last update timestamp
    update_state ".last_update = \"$(date -Iseconds)\""

    sleep "$TICK_INTERVAL"
done
