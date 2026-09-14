#!/bin/bash
# Удаляет exit с RU: down интерфейс + удаляет conf + убирает из state.json.
# Вызывается ботом через sudo. argv: $1 = interface (awg<N>).
set -e
. /etc/awg-cascade/config
STATE=/etc/awg-cascade/state.json
PEERS_JSON=/etc/awg-cascade/peers.json
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
# Убираем из state.json И снимаем pin'ы на этот интерфейс в peers.json.
#
# Второе обязательно, и это не косметика: имена интерфейсов переиспользуются.
# Удалили awg2 — индекс 2 освободился, следующий добавленный exit займёт то же
# имя, и пир, у которого в peers.json остался "pinned_exit": "awg2", молча
# приедет на НОВЫЙ exit в другой стране. Ни бот, ни watchdog этого не заметят:
# с их точки зрения pin валиден, интерфейс существует.
#
# Оба файла меняем под ОДНИМ замком (тем же, что берут peer-add/-remove и бот):
# иначе между правкой state.json и peers.json влезает чужая запись.
FLOCK=/etc/awg-cascade/state.lock
UNPIN_F="/run/awg-cascade-unpinned.$$"
(
    flock -x 200
    TMP=$(mktemp)
    jq --arg if "$IFACE" \
       '.exits |= map(select(.interface != $if)) | .last_update = (now|todate)' \
       "$STATE" > "$TMP"
    mv "$TMP" "$STATE"
    chown "$BOT_USER:$BOT_USER" "$STATE"
    chmod 644 "$STATE"

    cnt=0
    if [ -f "$PEERS_JSON" ]; then
        cnt=$(jq --arg if "$IFACE" '[.[] | select(.pinned_exit == $if)] | length' "$PEERS_JSON")
        if [ "${cnt:-0}" -gt 0 ]; then
            TMP2=$(mktemp)
            jq --arg if "$IFACE" \
               'map(if .pinned_exit == $if then .pinned_exit = null else . end)' \
               "$PEERS_JSON" > "$TMP2"
            mv "$TMP2" "$PEERS_JSON"
            chown "$BOT_USER:$BOT_USER" "$PEERS_JSON"
            chmod 644 "$PEERS_JSON"
        fi
    fi
    printf '%s' "${cnt:-0}" > "$UNPIN_F"
) 200>"$FLOCK"

# Счётчик забираем через файл: переменная, присвоенная внутри субшелла, наружу
# не доедет.
UNPINNED=$(cat "$UNPIN_F" 2>/dev/null || echo 0)
rm -f "$UNPIN_F"

# Триггерим watchdog: пересобрать peer-routing (снять pinned-правила на удалённый
# exit). ECMP пересобирается каждый тик сам (apply_route увидит, что iface исчез).
systemctl kill -s SIGUSR1 awg-cascade-watchdog 2>/dev/null || true

echo "{\"ok\":true,\"interface\":\"$IFACE\",\"unpinned\":${UNPINNED:-0}}"

# Список доверенных адресов fail2ban на RU строится из state.json и потому
# является снимком на момент запуска: добавили/удалили exit — он протух.
# Пересобираем здесь же, чтобы бан нового exit-адреса не отнял управление им.
/usr/local/sbin/awg-cascade-fail2ban.sh >/dev/null 2>&1 || true
