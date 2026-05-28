#!/bin/bash
# Удаляет peer из awg0. Вызывается ботом через sudo.
# argv: $1 = имя peer'а
set -e
. /etc/awg-cascade/config
WG_CONF=/etc/amnezia/amneziawg/awg0.conf
PEERS_DIR=/etc/awg-cascade/peers
PEERS_JSON=/etc/awg-cascade/peers.json

NAME="${1:-}"
[ -z "$NAME" ] && { echo '{"error":"empty name"}'; exit 1; }

PUBKEY=$(jq -r --arg n "$NAME" '.[] | select(.name==$n) | .pubkey' "$PEERS_JSON" 2>/dev/null)
[ -z "$PUBKEY" ] || [ "$PUBKEY" = "null" ] && { echo "{\"error\":\"peer $NAME not found\"}"; exit 1; }

# 1. Runtime: убрать peer из awg0
awg set awg0 peer "$PUBKEY" remove

# 2. Удалить блок [Peer] с этим PubKey из awg0.conf
python3 - "$WG_CONF" "$PUBKEY" <<'PYEOF'
import re, sys, os
path, target_pub = sys.argv[1], sys.argv[2]
text = open(path).read()
# Разбиваем по [Peer] заголовкам, оставляя [Interface] первым блоком
blocks = re.split(r"(?=^\[Peer\])", text, flags=re.MULTILINE)
kept = [b for b in blocks if target_pub not in b]
new = "".join(kept).rstrip() + "\n"
tmp = path + ".tmp"
open(tmp, "w").write(new)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PYEOF

# 3. Удалить .conf клиента
rm -f "$PEERS_DIR/${NAME}.conf"

# 4. peers.json
TMP=$(mktemp)
jq --arg n "$NAME" 'map(select(.name != $n))' "$PEERS_JSON" > "$TMP" && mv "$TMP" "$PEERS_JSON"
chown "$BOT_USER:$BOT_USER" "$PEERS_JSON"

echo "{\"ok\":true,\"name\":\"$NAME\",\"pubkey\":\"$PUBKEY\"}"
