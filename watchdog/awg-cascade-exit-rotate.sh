#!/bin/bash
# =============================================================================
# AWG Cascade Multi — Rotate exit tunnel (RU <-> Exit)
#
# Главный сценарий обхода ТСПУ: трафик RU→Exit может быть зафингерпринтен по
# H1-H4 / S1-S4 / I1. Регулярная ротация этих параметров (или ключей) =
# новая сигнатура для DPI.
#
# argv:
#   $1 = iface  (awg1, awg2, ...)
#   $2 = mode   (obfuscation | keys | all)
#       obfuscation — только H1-H4 + I1 (S1-S4 оставляем default; не меняем)
#       keys        — RU privkey + Exit privkey + PSK (обфускация не меняется)
#       all         — то и другое
#
# stdout: JSON {ok, iface, mode, changes:[fields], handshake_ok}
# =============================================================================

set -e
. /etc/awg-cascade/config

WG_DIR=/etc/amnezia/amneziawg
STATE=/etc/awg-cascade/state.json
SSH_KEY=/etc/awg-cascade/ssh/id_ed25519
FLOCK=/etc/awg-cascade/state.lock

IFACE="${1:-}"
MODE="${2:-obfuscation}"

[ -z "$IFACE" ] && { echo '{"ok":false,"error":"empty iface"}'; exit 1; }
[ "$IFACE" = "awg0" ] && { echo '{"ok":false,"error":"awg0 is not an exit tunnel"}'; exit 1; }
[ ! -f "$WG_DIR/${IFACE}.conf" ] && { echo "{\"ok\":false,\"error\":\"$IFACE.conf not found\"}"; exit 1; }
[[ "$MODE" =~ ^(obfuscation|keys|all)$ ]] || { echo '{"ok":false,"error":"mode must be obfuscation|keys|all"}'; exit 1; }

# Берём текущее состояние exit'а
EXIT_OBJ=$(jq --arg if "$IFACE" '.exits[] | select(.interface==$if)' "$STATE")
[ -z "$EXIT_OBJ" ] && { echo "{\"ok\":false,\"error\":\"exit $IFACE not found in state\"}"; exit 1; }

EXIT_IP=$(jq -r .ip <<<"$EXIT_OBJ")
EXIT_NAME=$(jq -r .name <<<"$EXIT_OBJ")
RU_TUNNEL_IP=$(jq -r .ru_tunnel_ip <<<"$EXIT_OBJ")
EXIT_TUNNEL_IP=$(jq -r .exit_tunnel_ip <<<"$EXIT_OBJ")
EXIT_PORT=$(jq -r .port <<<"$EXIT_OBJ")

CHANGES=()

# ─── Генерируем новые значения ───────────────────────────────────────────────

# Случайный uint32 в диапазоне [1, 2147483647]
gen_uint32() {
    od -An -N4 -tu4 /dev/urandom | tr -d ' \n' | awk '{printf "%d", $1 % 2147483646 + 1}'
}

if [[ "$MODE" == "obfuscation" || "$MODE" == "all" ]]; then
    NEW_H1=$(gen_uint32)
    NEW_H2=$(gen_uint32)
    NEW_H3=$(gen_uint32)
    NEW_H4=$(gen_uint32)
    CHANGES+=("H1-H4")
    # I1 пока не ротируем (если когда-нибудь добавим — для v2.0 будем менять CPS)
fi

if [[ "$MODE" == "keys" || "$MODE" == "all" ]]; then
    NEW_RU_PRIVKEY=$(awg genkey)
    NEW_RU_PUBKEY=$(echo "$NEW_RU_PRIVKEY" | awg pubkey)
    NEW_EXIT_PRIVKEY=$(awg genkey)
    NEW_EXIT_PUBKEY=$(echo "$NEW_EXIT_PRIVKEY" | awg pubkey)
    NEW_PSK=$(awg genpsk)
    CHANGES+=("keys+psk")
fi

# ─── Применяем на EXIT-стороне через SSH ─────────────────────────────────────

# Готовим скрипт для exit
EXIT_SCRIPT=$(mktemp)
cat > "$EXIT_SCRIPT" <<'EXITSH'
#!/bin/bash
set -e
WG=/etc/amnezia/amneziawg/awg-in.conf

# Параметры из переменных env
update_kv() {
    local key=$1 val=$2 file=$3
    if grep -q "^${key} =" "$file"; then
        sed -i "s|^${key} = .*|${key} = ${val}|" "$file"
    else
        sed -i "/^\[Interface\]/a ${key} = ${val}" "$file"
    fi
}

[ -n "${NEW_H1:-}" ] && update_kv H1 "$NEW_H1" "$WG"
[ -n "${NEW_H2:-}" ] && update_kv H2 "$NEW_H2" "$WG"
[ -n "${NEW_H3:-}" ] && update_kv H3 "$NEW_H3" "$WG"
[ -n "${NEW_H4:-}" ] && update_kv H4 "$NEW_H4" "$WG"

if [ -n "${NEW_EXIT_PRIVKEY:-}" ]; then
    update_kv PrivateKey "$NEW_EXIT_PRIVKEY" "$WG"
    # Удаляем все peer'ы, добавим заново
    awk '/^\[Peer\]/{exit} {print}' "$WG" > "${WG}.t"
    mv "${WG}.t" "$WG"
    cat >> "$WG" <<PEER

[Peer]
PublicKey = ${NEW_RU_PUBKEY}
PresharedKey = ${NEW_PSK}
AllowedIPs = ${RU_TUNNEL_IP}/32
PEER
    chmod 600 "$WG"
fi

# Если только обфускация — peer не трогаем, только перезапуск
awg-quick down awg-in 2>/dev/null || true
awg-quick up awg-in >/dev/null
EXITSH
chmod +x "$EXIT_SCRIPT"

# Залить на exit и выполнить
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$EXIT_SCRIPT" "root@${EXIT_IP}:/tmp/exit-rotate.sh" >/dev/null
ENV_VARS=""
[[ "$MODE" == "obfuscation" || "$MODE" == "all" ]] && ENV_VARS+="NEW_H1=$NEW_H1 NEW_H2=$NEW_H2 NEW_H3=$NEW_H3 NEW_H4=$NEW_H4 "
if [[ "$MODE" == "keys" || "$MODE" == "all" ]]; then
    ENV_VARS+="NEW_EXIT_PRIVKEY=$NEW_EXIT_PRIVKEY NEW_RU_PUBKEY=$NEW_RU_PUBKEY NEW_PSK=$NEW_PSK RU_TUNNEL_IP=$RU_TUNNEL_IP "
fi
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@${EXIT_IP}" "$ENV_VARS bash /tmp/exit-rotate.sh && rm /tmp/exit-rotate.sh" >&2
rm -f "$EXIT_SCRIPT"

# ─── Применяем на RU-стороне ──────────────────────────────────────────────────

(
    flock -x 200

    WG_LOCAL=$WG_DIR/${IFACE}.conf

    # Используем те же помощники
    update_kv_local() {
        local key=$1 val=$2 file=$3
        if grep -q "^${key} =" "$file"; then
            sed -i "s|^${key} = .*|${key} = ${val}|" "$file"
        else
            sed -i "/^\[Interface\]/a ${key} = ${val}" "$file"
        fi
    }

    if [[ "$MODE" == "obfuscation" || "$MODE" == "all" ]]; then
        update_kv_local H1 "$NEW_H1" "$WG_LOCAL"
        update_kv_local H2 "$NEW_H2" "$WG_LOCAL"
        update_kv_local H3 "$NEW_H3" "$WG_LOCAL"
        update_kv_local H4 "$NEW_H4" "$WG_LOCAL"
    fi

    if [[ "$MODE" == "keys" || "$MODE" == "all" ]]; then
        update_kv_local PrivateKey "$NEW_RU_PRIVKEY" "$WG_LOCAL"
        # Заменить [Peer] блок
        awk '/^\[Peer\]/{exit} {print}' "$WG_LOCAL" > "${WG_LOCAL}.t"
        mv "${WG_LOCAL}.t" "$WG_LOCAL"
        cat >> "$WG_LOCAL" <<PEER

[Peer]
PublicKey = ${NEW_EXIT_PUBKEY}
PresharedKey = ${NEW_PSK}
Endpoint = ${EXIT_IP}:${EXIT_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
PEER
        chmod 600 "$WG_LOCAL"

        # Сохраняем новые ключи в /etc/awg-cascade/exits/
        cat > "/etc/awg-cascade/exits/${IFACE}.keys" <<EOF
RU_PRIVKEY=$NEW_RU_PRIVKEY
RU_PUBKEY=$NEW_RU_PUBKEY
RU_PSK=$NEW_PSK
EOF
        chmod 600 "/etc/awg-cascade/exits/${IFACE}.keys"
    fi

    # Перезапускаем awg<N>
    awg-quick down "$IFACE" 2>/dev/null || true
    awg-quick up "$IFACE" >/dev/null

    # Обновляем state.json
    TMP=$(mktemp)
    if [[ "$MODE" == "keys" || "$MODE" == "all" ]]; then
        jq --arg if "$IFACE" --arg pub "$NEW_EXIT_PUBKEY" --arg t "$(date -Iseconds)" \
           '(.exits[] | select(.interface==$if)) |= (.exit_pubkey = $pub | .rotated_at = $t)' \
           "$STATE" > "$TMP"
    else
        jq --arg if "$IFACE" --arg t "$(date -Iseconds)" \
           '(.exits[] | select(.interface==$if)) |= (.rotated_at = $t)' \
           "$STATE" > "$TMP"
    fi
    mv "$TMP" "$STATE"
    chown "$BOT_USER:$BOT_USER" "$STATE"

) 200>"$FLOCK"

# ─── Проверяем handshake ─────────────────────────────────────────────────────

sleep 5
HS_OK=false
HS=$(awg show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
if [ -n "$HS" ] && [ "$HS" != "0" ]; then
    AGE=$(( $(date +%s) - HS ))
    [ "$AGE" -lt 30 ] && HS_OK=true
fi

CHANGES_JSON=$(printf '%s\n' "${CHANGES[@]}" | jq -R . | jq -s .)

jq -n \
    --arg if "$IFACE" --arg n "$EXIT_NAME" --arg m "$MODE" \
    --argjson changes "$CHANGES_JSON" --argjson hsok "$HS_OK" \
    '{ok:true, iface:$if, name:$n, mode:$m, changes:$changes, handshake_ok:$hsok}'
