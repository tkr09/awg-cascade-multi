#!/bin/bash
# Создаёт нового peer'а в awg0. Вызывается ботом через sudo.
# stdin: пусто. argv: $1 = имя.
# stdout: JSON с информацией о созданном peer + клиентский конфиг (key 'client_conf')
set -e
. /etc/awg-cascade/config
WG_CONF=/etc/amnezia/amneziawg/awg0.conf
PEERS_DIR=/etc/awg-cascade/peers
PEERS_JSON=/etc/awg-cascade/peers.json

NAME="${1:-}"
[ -z "$NAME" ] && { echo '{"error":"empty name"}'; exit 1; }
[ -n "$(echo "$NAME" | tr -cd 'a-zA-Z0-9._-')" ] || { echo '{"error":"invalid name"}'; exit 1; }
NAME=$(echo "$NAME" | tr -cd 'a-zA-Z0-9._-')

# Не дублируем
if [ -f "$PEERS_JSON" ] && jq -e --arg n "$NAME" 'map(.name) | index($n)' "$PEERS_JSON" >/dev/null 2>&1; then
    echo "{\"error\":\"peer $NAME already exists\"}"; exit 1
fi

# Подбираем свободный IP в client_net
PREFIX="$CLIENT_NET_PREFIX"
TAKEN=$(jq -r '.[].ip' "$PEERS_JSON" 2>/dev/null || echo "")
TAKEN="$TAKEN $SERVER_IP"

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

SERVER_PUB=$(awg show awg0 public-key)

# Все obfuscation params из awg0.conf — чтобы клиент получил ТОЧНО ТЕ ЖЕ
# значения что у сервера (иначе handshake не пройдёт в v2.0).
JC=$(grep   "^Jc "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
JMIN=$(grep "^Jmin " "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
JMAX=$(grep "^Jmax " "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
S1=$(grep   "^S1 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
S2=$(grep   "^S2 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
S3=$(grep   "^S3 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
S4=$(grep   "^S4 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
H1=$(grep   "^H1 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
H2=$(grep   "^H2 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
H3=$(grep   "^H3 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
H4=$(grep   "^H4 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')
I1=$(grep   "^I1 "   "$WG_CONF" | head -1 | awk -F' = ' '{print $2}')

# 1. Добавить peer в runtime через awg set (PSK через временный файл, /dev/stdin не работает в sudo)
PSK_FILE=$(mktemp)
echo -n "$PSK" > "$PSK_FILE"
chmod 600 "$PSK_FILE"
trap "rm -f $PSK_FILE" EXIT

awg set awg0 peer "$PUBKEY" preshared-key "$PSK_FILE" allowed-ips "${PEER_IP}/32"

# 2. Дописать peer в awg0.conf (для persistence)
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
MTU = 1340
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
I1 = $I1

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
Endpoint = ${RU_PUBLIC_IP}:${AWG0_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"
chown "$BOT_USER:$BOT_USER" "$CLIENT_CONF"

# 4. peers.json
[ -f "$PEERS_JSON" ] || echo "[]" > "$PEERS_JSON"
TMP=$(mktemp)
jq --arg n "$NAME" --arg ip "$PEER_IP" --arg pk "$PUBKEY" \
   '. + [{name: $n, ip: $ip, pubkey: $pk, created: now|todate, note: "", pinned_exit: null}]' \
   "$PEERS_JSON" > "$TMP" && mv "$TMP" "$PEERS_JSON"
chown "$BOT_USER:$BOT_USER" "$PEERS_JSON"
chmod 644 "$PEERS_JSON"

# 5. Output JSON для бота
jq -n \
    --arg name    "$NAME" \
    --arg ip      "$PEER_IP" \
    --arg pubkey  "$PUBKEY" \
    --arg conf    "$(cat "$CLIENT_CONF")" \
    '{ok: true, name: $name, ip: $ip, pubkey: $pubkey, client_conf: $conf}'
