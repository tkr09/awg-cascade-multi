#!/bin/bash
# =============================================================================
# AWG Cascade Multi — alert helper
# ntfy через --interface eth0 (emergency egress, работает даже когда каскад
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
. /etc/awg-cascade/config 2>/dev/null || true

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
# Stamp пишем ТОЛЬКО после успешной доставки — иначе упавший curl «съест» весь
# cooldown и алерт промолчит N часов, ни разу не дойдя.
if curl --interface eth0 -s --max-time 8 \
    -H "Title: $TITLE" \
    -H "Priority: $PRIO" \
    -H "Tags: $TAGS" \
    -d "$(printf '%s\nHost: %s' "$BODY" "$(hostname)")" \
    "$NTFY_URL" >/dev/null 2>&1; then
    echo "$now" > "$STAMP" 2>/dev/null || true
fi
