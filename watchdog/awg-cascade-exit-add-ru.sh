#!/bin/bash
# Создаёт awg<N>.conf на RU + поднимает интерфейс + добавляет в state.json.
# Вызывается ботом через sudo. argv: $1 = JSON со всеми параметрами.
#
# JSON формат:
# {
#   "exit_index": 2,
#   "name": "DE-1",
#   "ru_privkey": "...",
#   "ru_pubkey":  "...",
#   "ru_psk":     "...",
#   "exit_info":  { ... } // вывод setup-exit.sh JSON
# }
set -e
. /etc/awg-cascade/config
STATE=/etc/awg-cascade/state.json
WG_DIR=/etc/amnezia/amneziawg

ARGS="${1:-}"
[ -z "$ARGS" ] && { echo '{"error":"empty args"}'; exit 1; }

EXIT_INDEX=$(echo "$ARGS" | jq -r .exit_index)
NAME=$(echo "$ARGS" | jq -r .name)
RU_PRIVKEY=$(echo "$ARGS" | jq -r .ru_privkey)
RU_PUBKEY=$(echo "$ARGS" | jq -r .ru_pubkey)
RU_PSK=$(echo "$ARGS" | jq -r .ru_psk)
EXIT_PUBKEY=$(echo "$ARGS" | jq -r .exit_info.exit_pubkey)
EXIT_IP=$(echo "$ARGS"     | jq -r .exit_info.exit_public_ip)
EXIT_PORT=$(echo "$ARGS"   | jq -r .exit_info.exit_port)
EXIT_TUNNEL_IP=$(echo "$ARGS" | jq -r .exit_info.exit_tunnel_ip)
RU_TUNNEL_IP=$(echo "$ARGS"   | jq -r .exit_info.ru_tunnel_ip)
H1=$(echo "$ARGS" | jq -r .exit_info.h_params.H1)
H2=$(echo "$ARGS" | jq -r .exit_info.h_params.H2)
H3=$(echo "$ARGS" | jq -r .exit_info.h_params.H3)
H4=$(echo "$ARGS" | jq -r .exit_info.h_params.H4)
# v2.0 (schema 2): берём S1-S4 и I1 от exit-стороны. Если поля отсутствуют
# (старый exit на schema 1) — fallback на v1.5 defaults.
S1=$(echo "$ARGS" | jq -r '.exit_info.s_params.S1 // 68')
S2=$(echo "$ARGS" | jq -r '.exit_info.s_params.S2 // 140')
S3=$(echo "$ARGS" | jq -r '.exit_info.s_params.S3 // 14')
S4=$(echo "$ARGS" | jq -r '.exit_info.s_params.S4 // 9')
I1=$(echo "$ARGS" | jq -r '.exit_info.i_params.I1 // "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"')
WARP_STATE=$(echo "$ARGS" | jq -r '.exit_info.warp_state // "off"')
# Имя интерфейса НА EXIT'е (awg-in для fresh, awg-in-N для shared). Нужно боту
# для interface-aware WARP-тоггла, чтобы не задеть чужой RU на shared-exit.
EXIT_IFACE=$(echo "$ARGS" | jq -r '.exit_info.exit_iface // "awg-in"')

IFACE="awg${EXIT_INDEX}"

# Сохраняем RU-ключи
mkdir -p /etc/awg-cascade/exits
cat > "/etc/awg-cascade/exits/${IFACE}.keys" <<EOF
RU_PRIVKEY=$RU_PRIVKEY
RU_PUBKEY=$RU_PUBKEY
RU_PSK=$RU_PSK
EOF
chmod 600 "/etc/awg-cascade/exits/${IFACE}.keys"

# Записываем awg<N>.conf
cat > "$WG_DIR/${IFACE}.conf" <<EOF
[Interface]
Address = $RU_TUNNEL_IP/30
PrivateKey = $RU_PRIVKEY
Table = off
MTU = 1420
Jc = 5
Jmin = 10
Jmax = 50
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
PublicKey = $EXIT_PUBKEY
PresharedKey = $RU_PSK
Endpoint = $EXIT_IP:$EXIT_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$WG_DIR/${IFACE}.conf"

# Поднимаем
awg-quick down "$IFACE" 2>/dev/null || true
awg-quick up "$IFACE"

# Enable в systemd
systemctl enable "awg-quick@${IFACE}" >/dev/null 2>&1 || true

# Добавляем в state.json (atomic)
FLOCK=/etc/awg-cascade/state.lock
(
    flock -x 200
    TMP=$(mktemp)
    EXIT_OBJ=$(jq -n \
        --arg name        "$NAME" \
        --argjson idx     "$EXIT_INDEX" \
        --arg ip          "$EXIT_IP" \
        --argjson port    "$EXIT_PORT" \
        --arg pub         "$EXIT_PUBKEY" \
        --arg tip         "$EXIT_TUNNEL_IP" \
        --arg rtip        "$RU_TUNNEL_IP" \
        --arg iface       "$IFACE" \
        --arg eiface      "$EXIT_IFACE" \
        --arg warp        "$WARP_STATE" \
        '{
            name: $name, index: $idx, ip: $ip, port: $port,
            exit_pubkey: $pub, exit_tunnel_ip: $tip, ru_tunnel_ip: $rtip,
            interface: $iface, exit_iface: $eiface, enabled: true, status: "up",
            ping_avg: null, ping_loss: null, ping_ring: [],
            weight: 10, warp_state: $warp, note: "",
            added_at: now|todate
        }')
    jq --argjson e "$EXIT_OBJ" '.exits += [$e] | .last_update = (now|todate)' "$STATE" > "$TMP"
    mv "$TMP" "$STATE"
    chown "$BOT_USER:$BOT_USER" "$STATE"
    chmod 644 "$STATE"
) 200>"$FLOCK"

# Сохраняем SSH-доступ — копируем bot pubkey на exit (для будущих операций)
# (бот уже имеет ssh-доступ к exit на этом этапе — наш ключ положен setup-exit.sh'ом
#  через RU_PUBKEY... хотя нет, RU_PUBKEY это AWG-ключ, не SSH.
#  setup-exit.sh не добавляет наш SSH ключ. Это надо сделать отдельно.)
# Бот добавит свой SSH-ключ через ssh_copy_id перед вызовом этого скрипта.

# Триггерим watchdog чтобы пересобрал ECMP
systemctl kill -s SIGUSR1 awg-cascade-watchdog 2>/dev/null || true
/usr/local/sbin/awg-cascade-route.sh 2>/dev/null || true

echo "{\"ok\":true,\"interface\":\"$IFACE\",\"name\":\"$NAME\"}"
