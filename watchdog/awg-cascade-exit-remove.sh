#!/bin/bash
# Удаляет exit с RU: down интерфейс + удаляет conf + убирает из state.json.
# Вызывается ботом через sudo. argv: $1 = interface (awg<N>).
set -e
. /etc/awg-cascade/config
STATE=/etc/awg-cascade/state.json
WG_DIR=/etc/amnezia/amneziawg
IFACE="${1:-}"

[ -z "$IFACE" ] && { echo '{"error":"empty interface"}'; exit 1; }
[ "$IFACE" = "awg0" ] && { echo '{"error":"cannot remove awg0"}'; exit 1; }

# Опускаем интерфейс
awg-quick down "$IFACE" 2>/dev/null || true
systemctl disable "awg-quick@${IFACE}" >/dev/null 2>&1 || true

# Удаляем conf и ключи
rm -f "$WG_DIR/${IFACE}.conf"
rm -f "/etc/awg-cascade/exits/${IFACE}.keys"

# Убираем из state.json
FLOCK=/etc/awg-cascade/state.lock
(
    flock -x 200
    TMP=$(mktemp)
    jq --arg if "$IFACE" \
       '.exits |= map(select(.interface != $if)) | .last_update = (now|todate)' \
       "$STATE" > "$TMP"
    mv "$TMP" "$STATE"
    chown "$BOT_USER:$BOT_USER" "$STATE"
    chmod 644 "$STATE"
) 200>"$FLOCK"

# Пересобираем ECMP
/usr/local/sbin/awg-cascade-route.sh 2>/dev/null || true

echo "{\"ok\":true,\"interface\":\"$IFACE\"}"
