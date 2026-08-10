#!/bin/bash
# Создаёт нового peer'а. Вызывается ботом через sudo.
# argv: $1 = имя, $2 = интерфейс (необяз.: awg0 по умолчанию, либо CLIENT3_IFACE)
# stdout: JSON с информацией о созданном peer + клиентский конфиг (key 'client_conf')
#
# Два клиентских интерфейса: awg0 (AmneziaWG 2.0, совместим со всеми клиентами)
# и опциональный CLIENT3_IFACE (3.0 — header protection + padding, требует
# клиента 3.x). Параметры обфускации у них РАЗНЫЕ, поэтому всё, что попадает в
# клиентский конфиг, читается из конфига именно того интерфейса.
set -e
. /etc/awg-cascade/config
PEERS_DIR=/etc/awg-cascade/peers
PEERS_JSON=/etc/awg-cascade/peers.json

NAME="${1:-}"
IFACE="${2:-awg0}"
[ -z "$NAME" ] && { echo '{"error":"empty name"}'; exit 1; }
[ -n "$(echo "$NAME" | tr -cd 'a-zA-Z0-9._-')" ] || { echo '{"error":"invalid name"}'; exit 1; }
NAME=$(echo "$NAME" | tr -cd 'a-zA-Z0-9._-')

# ─── Выбор интерфейса ────────────────────────────────────────────────────────
if [ "$IFACE" = "awg0" ]; then
    PREFIX="$CLIENT_NET_PREFIX"
    OWN_IP="$SERVER_IP"
    PORT="$AWG0_PORT"
elif [ -n "${CLIENT3_IFACE:-}" ] && [ "$IFACE" = "$CLIENT3_IFACE" ]; then
    PREFIX="$CLIENT3_NET_PREFIX"
    OWN_IP="$CLIENT3_SERVER_IP"
    PORT="$CLIENT3_PORT"
else
    echo "{\"error\":\"unknown iface $IFACE\"}"; exit 1
fi
WG_CONF="/etc/amnezia/amneziawg/${IFACE}.conf"
[ -f "$WG_CONF" ] || { echo "{\"error\":\"$WG_CONF not found\"}"; exit 1; }

# Не дублируем (имена глобальны — по обоим интерфейсам)
if [ -f "$PEERS_JSON" ] && jq -e --arg n "$NAME" 'map(.name) | index($n)' "$PEERS_JSON" >/dev/null 2>&1; then
    echo "{\"error\":\"peer $NAME already exists\"}"; exit 1
fi

# Подбираем свободный IP в подсети ЭТОГО интерфейса (у интерфейсов разные /24,
# поэтому сравнение полных адресов из общего peers.json корректно)
TAKEN=$(jq -r '.[].ip' "$PEERS_JSON" 2>/dev/null || echo "")
TAKEN="$TAKEN $OWN_IP"

PEER_IP=""
for OCT in $(seq 2 254); do
    CAND="${PREFIX}${OCT}"
    if ! echo "$TAKEN" | tr ' ' '\n' | grep -qx "$CAND"; then
        PEER_IP="$CAND"; break
    fi
done
[ -z "$PEER_IP" ] && { echo '{"error":"no free IP"}'; exit 1; }

PRIVKEY=$(awg genkey)
PUBKEY=$(echo "$PRIVKEY" | awg pubkey)
PSK=$(awg genpsk)

SERVER_PUB=$(awg show "$IFACE" public-key)

# Все obfuscation params из конфига интерфейса — чтобы клиент получил ТОЧНО ТЕ
# ЖЕ значения что у сервера (иначе handshake не пройдёт).
cfg() { grep "^$1 " "$WG_CONF" | head -1 | awk -F' = ' '{print $2}'; }
JC=$(cfg Jc);     JMIN=$(cfg Jmin); JMAX=$(cfg Jmax)
S1=$(cfg S1); S2=$(cfg S2); S3=$(cfg S3); S4=$(cfg S4)
H1=$(cfg H1); H2=$(cfg H2); H3=$(cfg H3); H4=$(cfg H4)
I1=$(cfg I1)

# AWG 3.0: HeaderProtectionKey симметричный и общий для всего интерфейса —
# у всех его клиентов он один и тот же, это свойство фичи (ключ шифрует
# заголовки, а не аутентифицирует пира). ContentPaddingAddition кладём тоже:
# без него клиент не будет набивать СВОИ пакеты, набивка была бы односторонней.
#
# Пять таймеров тоже отдаём клиенту. Они управляют локальным поведением своей
# стороны, и рандомизация нужна именно на клиенте: наблюдателя интересует
# трафик клиент→сервер, а фиксированные интервалы rekey/keepalive — это
# «метрономность», по которой туннель узнаётся независимо от обфускации.
#
# ⚠️ На awg0 (2.0) этих строк в конфиге нет — блок остаётся пустым, и клиенты
# 2.0 получают конфиг ровно как раньше.
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

# 1. Добавить peer в runtime через awg set (PSK через временный файл, /dev/stdin не работает в sudo)
PSK_FILE=$(mktemp)
echo -n "$PSK" > "$PSK_FILE"
chmod 600 "$PSK_FILE"
trap "rm -f $PSK_FILE" EXIT

awg set "$IFACE" peer "$PUBKEY" preshared-key "$PSK_FILE" allowed-ips "${PEER_IP}/32"

# 2. Дописать peer в конфиг интерфейса (для persistence)
cat >> "$WG_CONF" <<EOF

[Peer]
# $NAME
PublicKey = $PUBKEY
PresharedKey = $PSK
AllowedIPs = ${PEER_IP}/32
EOF
chmod 600 "$WG_CONF"

# 3. Записать клиентский конфиг
mkdir -p "$PEERS_DIR"
CLIENT_CONF="$PEERS_DIR/${NAME}.conf"
cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $PRIVKEY
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
PresharedKey = $PSK
Endpoint = ${RU_PUBLIC_IP}:${PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"
chown "$BOT_USER:$BOT_USER" "$CLIENT_CONF"

# 4. peers.json
[ -f "$PEERS_JSON" ] || echo "[]" > "$PEERS_JSON"
TMP=$(mktemp)
jq --arg n "$NAME" --arg ip "$PEER_IP" --arg pk "$PUBKEY" --arg if "$IFACE" \
   '. + [{name: $n, ip: $ip, pubkey: $pk, iface: $if, created: now|todate, note: "", pinned_exit: null}]' \
   "$PEERS_JSON" > "$TMP" && mv "$TMP" "$PEERS_JSON"
chown "$BOT_USER:$BOT_USER" "$PEERS_JSON"
chmod 644 "$PEERS_JSON"

# 5. Output JSON для бота
jq -n \
    --arg name    "$NAME" \
    --arg ip      "$PEER_IP" \
    --arg pubkey  "$PUBKEY" \
    --arg iface   "$IFACE" \
    --arg conf    "$(cat "$CLIENT_CONF")" \
    '{ok: true, name: $name, ip: $ip, pubkey: $pubkey, iface: $iface, client_conf: $conf}'
