#!/bin/bash
# =============================================================================
# AWG Cascade Multi — атомарное резервирование индекса exit'а.
#
# ЗАЧЕМ. Индекс нового exit'а (awgN на RU, таблица 100+N, октет подсети 100+N)
# выбирался как «первый свободный в снимке state.json» — и выбирался ДО
# provisioning, который на свежем сервере занимает до десяти минут. Резервирования
# при этом не было никакого: два добавления, запущенные подряд, читали один и тот
# же снимок и оба получали один индекс. Дальше второе переписывало ключи и конфиг
# первого, опускало уже поднятый туннель и добавляло в state дубль interface/index.
# FSM бота очищается сразу после старта задачи, поэтому запустить второе
# добавление во время первого можно было обычными кнопками.
#
# Здесь индекс выдаётся под общей блокировкой и сразу записывается в
# state.json как бронь с токеном. Бронь учитывается при следующей выдаче, а
# awg-cascade-exit-add-ru.sh проверяет её принадлежность перед тем, как что-то
# менять на RU.
#
# Usage:
#   awg-cascade-exit-reserve.sh acquire <кто>  → stdout: "<index> <token>"
#   awg-cascade-exit-reserve.sh release <token>
#   awg-cascade-exit-reserve.sh list
# =============================================================================
set -u
# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || true
: "${BOT_USER:=awgbot}"

STATE=/etc/awg-cascade/state.json
FLOCK=/etc/awg-cascade/state.lock

# TTL брони. Provisioning свежего сервера — до 10 минут, берём с большим запасом.
# Протухшие брони чистятся при каждой выдаче: оборванное добавление не должно
# навсегда занимать индекс.
: "${RESERVE_TTL:=2700}"

# Верхняя граница индекса — 99, и это не произвол:
#   • таблица маршрутизации = 100 + index, то есть 101..199. 153/154/155 попали бы
#     в системные default/main/local, а стартовая уборка watchdog'а и так ходит
#     ровно по 101..199;
#   • октет shared-подсети = 100 + index, то есть 101..199 — влезает в байт;
#   • слоты awg-in-<N> на exit'е installer ограничивает теми же 2..99.
: "${MAX_INDEX:=99}"

_save() {  # <файл-с-новым-json>
    chown "$BOT_USER:$BOT_USER" "$1" 2>/dev/null || true
    chmod 644 "$1" 2>/dev/null || true
    mv "$1" "$STATE"
}

_gc() {  # чистка протухших броней; вызывать под lock
    local now tmp
    now=$(date +%s)
    tmp=$(mktemp)
    jq --argjson now "$now" --argjson ttl "$RESERVE_TTL" \
       '.exit_reservations = [ (.exit_reservations // [])[]
                               | select((.at // 0) > ($now - $ttl)) ]' \
       "$STATE" > "$tmp" && _save "$tmp" || rm -f "$tmp"
}

case "${1:-}" in
acquire)
    OWNER="${2:-unknown}"
    exec 200>"$FLOCK" || { echo "не открыть $FLOCK" >&2; exit 1; }
    # -w 30: без таймаута вызывающий (в т.ч. trap на выходе bootstrap) мог бы
    # ждать чужую блокировку бесконечно и выглядеть как зависание.
    flock -w 30 -x 200 || { echo "не взять блокировку state.lock за 30с" >&2; exit 1; }
    [ -f "$STATE" ] || { echo "нет $STATE" >&2; exit 1; }
    _gc
    IDX=$(jq -r --argjson max "$MAX_INDEX" '
        ( [ (.exits // [])[] | .index // empty ]
        + [ (.exit_reservations // [])[] | .index // empty ] ) as $used
        | ( [ range(1; $max + 1) ] - $used | first ) // empty' "$STATE")
    [ -n "$IDX" ] || { echo "нет свободных индексов exit (1..$MAX_INDEX)" >&2; exit 1; }
    TOKEN="$(hostname -s)-$$-$(date +%s)-${RANDOM}"
    TMP=$(mktemp)
    jq --argjson i "$IDX" --arg t "$TOKEN" --arg o "$OWNER" --argjson now "$(date +%s)" \
       '.exit_reservations = ((.exit_reservations // [])
                              + [{index: $i, token: $t, owner: $o, at: $now}])' \
       "$STATE" > "$TMP" || { rm -f "$TMP"; echo "jq не смог записать бронь" >&2; exit 1; }
    _save "$TMP"
    echo "$IDX $TOKEN"
    ;;
release)
    TOKEN="${2:-}"
    [ -n "$TOKEN" ] || { echo "нужен token" >&2; exit 1; }
    exec 200>"$FLOCK" || exit 1
    flock -w 30 -x 200 || { echo "не взять блокировку state.lock за 30с" >&2; exit 1; }
    TMP=$(mktemp)
    jq --arg t "$TOKEN" \
       '.exit_reservations = [ (.exit_reservations // [])[] | select(.token != $t) ]' \
       "$STATE" > "$TMP" && _save "$TMP" || rm -f "$TMP"
    ;;
list)
    jq -r '(.exit_reservations // [])[] | "\(.index)\t\(.owner)\t\(.token)"' "$STATE" 2>/dev/null
    ;;
*)
    echo "usage: $0 acquire <кто> | release <token> | list" >&2
    exit 1
    ;;
esac
