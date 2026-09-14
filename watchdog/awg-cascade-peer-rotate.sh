#!/bin/bash
# =============================================================================
# AWG Cascade Multi — Rotate ONE peer
#
# Перевыпускает ключи для одного конкретного peer'а:
#   - новый peer privkey + pubkey
#   - новый PSK
# Остальные peer'ы и server-side ключи не трогаются.
#
# argv: $1 = peer name
# stdout: JSON {ok, name, ip, conf}
# =============================================================================

set -e
# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
. /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config

PEERS_DIR=/etc/awg-cascade/peers
PEERS_JSON=/etc/awg-cascade/peers.json
FLOCK=/etc/awg-cascade/state.lock

NAME="${1:-}"
[ -z "$NAME" ] && { echo '{"ok":false,"error":"empty name"}'; exit 1; }

# Новые ключи peer'а генерим ДО lock: это чистая энтропия, ни от чего не зависит
# и держать под блокировкой её незачем.
NEW_PRIVKEY=$(awg genkey)
NEW_PUBKEY=$(echo "$NEW_PRIVKEY" | awg pubkey)
NEW_PSK=$(awg genpsk)

# ─── Всё остальное — под общим lock ─────────────────────────────────────────
# Состояние peer'а читается ВНУТРИ блокировки, непосредственно перед изменением.
#
# Раньше OLD_PUBKEY, IP и интерфейс читались снаружи. Две ротации одного клиента
# успевали прочитать один и тот же OLD, потом по очереди войти в lock: первая
# меняла OLD на NEW_A, вторая снова удаляла уже отсутствующий OLD, не трогала
# NEW_A и добавляла NEW_B. В конфиге оставались ДВА [Peer] с одним AllowedIPs.
# Пересечение с удалением давало ещё хуже: ротация возвращала в runtime и в
# конфиг клиента, которого в peers.json уже нет.
#
# Блокировка берётся на весь остаток скрипта (fd 200 живёт до выхода), поэтому
# отдельный субшелл с flock ниже больше не нужен.
exec 200>"$FLOCK"
flock -x 200

# Текущий peer
PEER=$(jq --arg n "$NAME" '.[] | select(.name==$n)' "$PEERS_JSON")
[ -z "$PEER" ] && { echo "{\"ok\":false,\"error\":\"peer $NAME not found\"}"; exit 1; }

OLD_PUBKEY=$(jq -r .pubkey <<<"$PEER")
PEER_IP=$(jq -r .ip <<<"$PEER")
# Интерфейс пира: awg0 (2.0) или CLIENT3_IFACE (3.0). Старые записи без поля — awg0.
IFACE=$(jq -r '.iface // "awg0"' <<<"$PEER")
WG_CONF="/etc/amnezia/amneziawg/${IFACE}.conf"
if [ "$IFACE" = "awg0" ]; then
    PORT="$AWG0_PORT"
else
    PORT="${CLIENT3_PORT:-$AWG0_PORT}"
fi

# Server-side params (берём из существующего конфига интерфейса — не меняем)
SERVER_PUB=$(awg show "$IFACE" public-key)

# Obfuscation params интерфейса (для клиентского конфига)
cfg() { grep "^$1 " "$WG_CONF" | head -1 | awk -F' = ' '{print $2}'; }
JC=$(cfg Jc);     JMIN=$(cfg Jmin); JMAX=$(cfg Jmax)
S1=$(cfg S1); S2=$(cfg S2); S3=$(cfg S3); S4=$(cfg S4)
H1=$(cfg H1); H2=$(cfg H2); H3=$(cfg H3); H4=$(cfg H4)
I1=$(cfg I1)

# AWG 3.0-блок для клиента (см. пояснение в awg-cascade-peer-add.sh):
# HeaderProtectionKey общий на интерфейс + padding + пять таймеров.
HPK=$(cfg HeaderProtectionKey)
PAD=$(cfg ContentPaddingAddition)
AWG3_BLOCK=""
if [ -n "$HPK" ]; then
    AWG3_BLOCK="HeaderProtectionKey = $HPK"
    [ -n "$PAD" ] && [ "$PAD" != "0" ] && AWG3_BLOCK="$AWG3_BLOCK
ContentPaddingAddition = $PAD"
    for _k in RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts; do
        _v=$(cfg "$_k")
        [ -n "$_v" ] && [ "$_v" != "0" ] && AWG3_BLOCK="$AWG3_BLOCK
$_k = $_v"
    done
fi

(
    # 1. Удаляем старого peer'а из runtime
    awg set "$IFACE" peer "$OLD_PUBKEY" remove

    # 2. Добавляем нового
    PSK_FILE=$(mktemp)
    echo -n "$NEW_PSK" > "$PSK_FILE"
    chmod 600 "$PSK_FILE"
    awg set "$IFACE" peer "$NEW_PUBKEY" preshared-key "$PSK_FILE" allowed-ips "${PEER_IP}/32"
    rm -f "$PSK_FILE"

    # 3. Пересобираем конфиг интерфейса — удаляем старый [Peer] блок, добавляем новый
    NEW_WG_TMP=$(mktemp)
    # Используем python для корректного парсинга — bash sed на блоках хрупкий
    # PSK передаём переменной окружения, а не аргументом.
    #
    # /proc/<pid>/cmdline читается любым локальным пользователем, поэтому PSK в
    # argv виден в обычном `ps` и попадает в process accounting. /proc/<pid>/environ
    # доступен только владельцу процесса и root — это не идеальная изоляция
    # (stdin занят самим текстом скрипта), но принципиально другой уровень
    # доступности.
    AWGC_NEW_PSK="$NEW_PSK"     python3 - "$WG_CONF" "$OLD_PUBKEY" "$NEW_PUBKEY" "$PEER_IP" "$NAME" "$NEW_WG_TMP" <<'PYEOF'
import os, re, sys
path, old_pub, new_pub, peer_ip, name, out_path = sys.argv[1:]
new_psk = os.environ["AWGC_NEW_PSK"]
text = open(path).read()
# Разбиваем по [Peer]
blocks = re.split(r'(?=^\[Peer\])', text, flags=re.MULTILINE)
# Удаляем блок старого peer'а
kept = [b for b in blocks if old_pub not in b]
# Добавляем новый
new_peer = f"\n[Peer]\n# {name}\nPublicKey = {new_pub}\nPresharedKey = {new_psk}\nAllowedIPs = {peer_ip}/32\n"
kept.append(new_peer)
open(out_path, 'w').write("".join(kept).rstrip() + "\n")
PYEOF
    chmod 600 "$NEW_WG_TMP"
    mv "$NEW_WG_TMP" "$WG_CONF"

    # 4. Перезаписываем клиентский conf
    CLIENT_CONF="$PEERS_DIR/${NAME}.conf"
    cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $NEW_PRIVKEY
Address = ${PEER_IP}/32
MTU = 1280
DNS = 1.1.1.1, 8.8.8.8
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1${AWG3_BLOCK:+
$AWG3_BLOCK}

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $NEW_PSK
Endpoint = ${RU_PUBLIC_IP}:${PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    chmod 600 "$CLIENT_CONF"
    chown "$BOT_USER:$BOT_USER" "$CLIENT_CONF"

    # 5. Обновляем peers.json — новый pubkey
    TMP=$(mktemp)
    jq --arg n "$NAME" --arg pk "$NEW_PUBKEY" --arg t "$(date -Iseconds)" \
       'map(if .name == $n then .pubkey = $pk | .rotated_at = $t else . end)' \
       "$PEERS_JSON" > "$TMP"
    mv "$TMP" "$PEERS_JSON"
    chown "$BOT_USER:$BOT_USER" "$PEERS_JSON"
    chmod 644 "$PEERS_JSON"

    # Output
    jq -n --arg n "$NAME" --arg ip "$PEER_IP" --rawfile conf "$CLIENT_CONF" \
        '{ok:true, name:$n, ip:$ip, conf:$conf}'
)
