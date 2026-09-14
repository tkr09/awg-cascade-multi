#!/bin/bash
# =============================================================================
# AWG Cascade Multi — alert helper
# ntfy через --interface $MAIN_IFACE (emergency egress, работает даже когда каскад
# или Telegram лежит) + дедуп/cooldown, чтобы не спамить один и тот же алерт.
#
# Usage:
#   awg-cascade-alert.sh <key> <cooldown_sec> <title> <priority> <tags> <body>
#   awg-cascade-alert.sh --clear <key>      # сбросить cooldown (на recovery)
#
# cooldown=0 → слать всегда (для transition-алертов, где состояние трекает
# вызывающий). cooldown>0 → не повторять тот же <key> чаще раза в N сек
# (для level-алертов: disk/RAM/SSH).
# =============================================================================
set -u
# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || true

# Интерфейс аварийного egress: раньше литерал eth0, из-за чего на ноде с ens3
# алерты молча не уходили (ошибка curl подавлена). Фолбэк = прежнее поведение.
: "${MAIN_IFACE:=eth0}"
ip link show "$MAIN_IFACE" >/dev/null 2>&1 || MAIN_IFACE=$(
    ip route show default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
: "${MAIN_IFACE:=eth0}"

ADIR=/run/awg-cascade/alerts
mkdir -p "$ADIR" 2>/dev/null || true

if [ "${1:-}" = "--clear" ]; then
    rm -f "$ADIR/${2:-__none}" 2>/dev/null || true
    exit 0
fi

KEY="${1:?key required}"
COOLDOWN="${2:-1800}"
TITLE="${3:-AWG Cascade}"
PRIO="${4:-default}"
TAGS="${5:-}"
BODY="${6:-}"

# safe key (без слешей)
KEY_SAFE=$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '_')
STAMP="$ADIR/$KEY_SAFE"
now=$(date +%s)

if [ "$COOLDOWN" -gt 0 ] && [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    [ "$((now - last))" -lt "$COOLDOWN" ] && exit 0   # в окне cooldown → молчим
fi

[ -n "${NTFY_URL:-}" ] || exit 0
: "${NTFY_TIMEOUT:=15}"
: "${NTFY_RETRIES:=3}"

# Stamp пишем ТОЛЬКО после успешной доставки — иначе упавший curl «съест» весь
# cooldown и алерт промолчит N часов, ни разу не дойдя.
#
# Ретраи по той же причине, что и в watchdog'е: замерено, что запрос к ntfy.sh
# обычно идёт 0.37 с, но иногда затягивается до 5.4 с, а одной попытки с
# коротким таймаутом хватало, чтобы алерт потерялся. Здесь это ещё чувствительнее:
# сюда приходят диск, RAM, SSH-входы и упавшие юниты — то, что дедуплицируется
# длинным cooldown'ом и потому повторится не скоро.
for _attempt in $(seq 1 "$NTFY_RETRIES"); do
    # --fail обязателен: без него curl считает успехом ЛЮБОЙ HTTP-ответ, в том
    # числе 429 (rate limit ntfy) и 5xx. Тогда stamp писался как при доставке, и
    # алерт замолкал на весь cooldown, ни разу не дойдя. С --fail такой ответ —
    # ошибка, а значит отрабатывает тот же retry с нарастающей паузой.
    if curl --interface "$MAIN_IFACE" -s --fail --max-time "$NTFY_TIMEOUT" \
        -H "Title: $TITLE" \
        -H "Priority: $PRIO" \
        -H "Tags: $TAGS" \
        -d "$(printf '%s\nHost: %s' "$BODY" "$(hostname)")" \
        "$NTFY_URL" >/dev/null 2>&1; then
        echo "$now" > "$STAMP" 2>/dev/null || true
        exit 0
    fi
    [ "$_attempt" -lt "$NTFY_RETRIES" ] && sleep $(( _attempt * 3 ))
done
exit 1
