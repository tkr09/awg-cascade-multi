#!/bin/bash
# =============================================================================
# AWG Cascade Multi — второй КЛИЕНТСКИЙ интерфейс на AmneziaWG 3.0
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ИНТЕРФЕЙС, а не апгрейд awg0:
# HeaderProtectionKey — параметр ИНТЕРФЕЙСА, а не пира (см. `awg set`: он стоит
# до ключевого слова `peer`). Включить его на awg0 = разом отрубить всех, кто
# ещё на клиенте 2.0. Поэтому 3.0 живёт на своём интерфейсе/порту/подсети, а
# awg0 остаётся нетронутым; клиенты переезжают по одному, когда готовы.
#
# ⚠️ ИМЯ ИНТЕРФЕЙСА НЕ ДОЛЖНО НАЧИНАТЬСЯ НА "awg".
# Kill-switch каскада написан через маску awg+ ("любой exit-туннель"):
#     FORWARD -i awg0 ! -o awg+ -j DROP
# Имя вида awgc3 попало бы в эту маску, и правило перестало бы дропать
# awg0 → новый интерфейс, то есть клиенты двух подсетей увидели бы друг друга
# в обход изоляции. С именем вне маски (wgc3) изоляция одной стороны получается
# сама собой; обратную сторону закрывает awg-cascade-client3-fw.sh.
#
# Usage:
#   awg-cascade-client3.sh up      [iface]  — создать и поднять (по умолч. wgc3)
#   awg-cascade-client3.sh down            — снести (только если нет пиров)
#   awg-cascade-client3.sh status          — показать состояние
# =============================================================================
set -u
CFG=/etc/awg-cascade/config
WG_DIR=/etc/amnezia/amneziawg
PEERS_JSON=/etc/awg-cascade/peers.json
PARAMS=/opt/awg-cascade-bot/scripts/awg2-params.sh

. "$CFG" 2>/dev/null || true
: "${CLIENT3_IFACE:=}"
: "${CLIENT_NET:=}"
: "${AWG0_PORT:=}"

# 3.0-блок: те же диапазоны, что на туннелях RU↔exit (awg-cascade-awg3.sh)
: "${PAD_RANGE:=50-100}"
: "${REKEY_AFTER:=100-140}"
: "${REKEY_TIMEOUT:=4-7}"
: "${REJECT_AFTER:=170-200}"
: "${KEEPALIVE_TO:=8-13}"
: "${MAX_HS:=15-20}"

ACTION="${1:-status}"

# ─── status ──────────────────────────────────────────────────────────────────
show_status() {
    if [ -z "$CLIENT3_IFACE" ]; then
        echo "  второй клиентский интерфейс не настроен (CLIENT3_IFACE пуст)"
        return 0
    fi
    local i="$CLIENT3_IFACE" hpk pad n
    if ! ip link show "$i" >/dev/null 2>&1; then
        echo "  $i: в config есть, но интерфейс НЕ ПОДНЯТ"
        return 0
    fi
    hpk=$(awg showconf "$i" 2>/dev/null | grep -c '^HeaderProtectionKey')
    pad=$(awg showconf "$i" 2>/dev/null | grep -oP '^ContentPaddingAddition = \K.*')
    n=$(awg show "$i" peers 2>/dev/null | grep -c .)
    echo "  интерфейс:  $i  (порт ${CLIENT3_PORT:-?}/udp, сеть ${CLIENT3_NET:-?})"
    echo "  режим:      $([ "${hpk:-0}" -gt 0 ] && echo "3.0 (header protection + padding=${pad:-?})" || echo "🔴 2.0 — HeaderProtectionKey НЕ применился")"
    echo "  пиров:      $n"
}

[ "$ACTION" = "status" ] && { echo "=== второй клиентский интерфейс ==="; show_status; exit 0; }

# ─── down ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "down" ]; then
    [ -z "$CLIENT3_IFACE" ] && { echo "  нечего сносить"; exit 0; }
    n=$(jq -r --arg i "$CLIENT3_IFACE" '[.[] | select((.iface // "awg0") == $i)] | length' "$PEERS_JSON" 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then
        echo "🔴 на $CLIENT3_IFACE ещё $n пир(ов) — сначала удали их, иначе останутся висеть в peers.json"
        exit 1
    fi
    systemctl disable --now "awg-quick@$CLIENT3_IFACE" >/dev/null 2>&1 || true
    rm -f "$WG_DIR/$CLIENT3_IFACE.conf"
    sed -i '/^# ─── Второй клиентский интерфейс/d;/^CLIENT3_/d' "$CFG"
    /usr/local/sbin/awg-cascade-iptables.sh >/dev/null 2>&1 || true
    echo "  ✅ $CLIENT3_IFACE снесён, config почищен, firewall пересобран"
    exit 0
fi

[ "$ACTION" = "up" ] || { echo "🔴 действие: up | down | status"; exit 1; }

# ─── up ──────────────────────────────────────────────────────────────────────
IFACE="${2:-${CLIENT3_IFACE:-wgc3}}"

# Имя вне маски awg+ — иначе ломается kill-switch (см. шапку)
case "$IFACE" in
    awg*) echo "🔴 имя '$IFACE' начинается на 'awg' — попадёт в маску awg+ kill-switch'а."
          echo "   Возьми имя вне маски, например wgc3."; exit 1 ;;
esac
echo "$IFACE" | grep -qE '^[a-z][a-z0-9_-]{1,14}$' || { echo "🔴 недопустимое имя интерфейса"; exit 1; }

[ -f "$WG_DIR/$IFACE.conf" ] && { echo "🔴 $WG_DIR/$IFACE.conf уже существует — сначала down"; exit 1; }
[ -n "$CLIENT_NET" ] || { echo "🔴 CLIENT_NET не задан в $CFG"; exit 1; }
[ -f "$PARAMS" ] || { echo "🔴 $PARAMS не найден (нужен для генерации 2.0-параметров)"; exit 1; }

# amneziawg 3.x обязателен: без него HeaderProtectionKey молча не применится
TOOLS_V=$(awg --version 2>/dev/null | awk '{print $2}')
case "$TOOLS_V" in
    v3.*) ;;
    *) echo "🔴 нужен amneziawg-tools 3.x (сейчас: ${TOOLS_V:-нет}). Обнови пакеты."; exit 1 ;;
esac
MOD_V=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2}')
case "$MOD_V" in
    3.*) ;;
    *) echo "🔴 ядерный модуль amneziawg не 3.x (сейчас: ${MOD_V:-нет})"; exit 1 ;;
esac

# Порт: соседний с awg0. Проверяем, что реально свободен.
PORT="${CLIENT3_PORT:-$(( AWG0_PORT + 1 ))}"
if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${PORT}\$"; then
    echo "🔴 порт $PORT уже занят"; exit 1
fi

# Подсеть: инкремент второго октета клиентской сети.
# 10.122.222.0/24 (RU-2) → 10.123.222.0/24;  10.222.122.0/24 (RU-1) → 10.223.122.0/24.
if [ -n "${CLIENT3_NET:-}" ]; then
    NET3="$CLIENT3_NET"
else
    IFS='./' read -r _a _b _c _d _m <<EOF
$CLIENT_NET
EOF
    [ "${_b:-0}" -ge 255 ] && _b2=$(( _b - 1 )) || _b2=$(( _b + 1 ))
    NET3="$_a.$_b2.$_c.0/24"
fi
PREFIX3="${NET3%0/24}"          # "10.123.222."
SRV3="${PREFIX3}1"

ip route show | grep -q "^${NET3%/24}/24 " && { echo "🔴 подсеть $NET3 уже маршрутизируется — выбери другую"; exit 1; }

echo "→ Создаю $IFACE: порт $PORT/udp, сеть $NET3, сервер $SRV3"

# Свои 2.0-параметры, НЕ копия awg0: одинаковые Jc/S/H/I на двух портах одного
# IP сами по себе стали бы связывающей сигнатурой для DPI.
# shellcheck disable=SC1090
. "$PARAMS"

PRIVKEY=$(awg genkey)
PUBKEY=$(echo "$PRIVKEY" | awg pubkey)
HPK=$(openssl rand -base64 32)

umask 077
cat > "$WG_DIR/$IFACE.conf" <<EOF
[Interface]
Address = $SRV3/24
ListenPort = $PORT
MTU = 1280
PrivateKey = $PRIVKEY
$(emit_v2_params_block)
HeaderProtectionKey = $HPK
ContentPaddingAddition = $PAD_RANGE
RekeyAfterTime = $REKEY_AFTER
RekeyTimeout = $REKEY_TIMEOUT
RejectAfterTime = $REJECT_AFTER
KeepaliveTimeout = $KEEPALIVE_TO
MaxHandshakeAttempts = $MAX_HS
EOF
chmod 600 "$WG_DIR/$IFACE.conf"

# config: пока переменных нет, весь новый код (peer-add, firewall, бот, бэкап)
# остаётся no-op — поэтому пишем их только после успешного создания конфига.
sed -i '/^# ─── Второй клиентский интерфейс/d;/^CLIENT3_/d' "$CFG"
cat >> "$CFG" <<EOF
# ─── Второй клиентский интерфейс (AmneziaWG 3.0, header protection) ───
CLIENT3_IFACE="$IFACE"
CLIENT3_PORT="$PORT"
CLIENT3_NET="$NET3"
CLIENT3_NET_PREFIX="$PREFIX3"
CLIENT3_SERVER_IP="$SRV3"
EOF

systemctl enable "awg-quick@$IFACE" >/dev/null 2>&1
if ! systemctl restart "awg-quick@$IFACE"; then
    echo "🔴 $IFACE не поднялся. Логи: journalctl -u awg-quick@$IFACE -n 30"
    exit 1
fi

# Header protection применяется молча: если S1-S4 < 12, ключ игнорируется
# ядром и интерфейс поднимется как обычный 2.0. Проверяем по факту.
if [ "$(awg showconf "$IFACE" 2>/dev/null | grep -c '^HeaderProtectionKey')" -eq 0 ]; then
    echo "🔴 HeaderProtectionKey не применился (проверь S1-S4 >= 12 в $WG_DIR/$IFACE.conf)"
    exit 1
fi

# Firewall: MARK → ECMP, MASQUERADE, kill-switch, изоляция от awg0
/usr/local/sbin/awg-cascade-iptables.sh >/dev/null 2>&1 || true

echo ""
. "$CFG"
show_status
echo ""
echo "  ✅ готово. Добавить пира: awg-cascade-peer-add.sh <имя> $IFACE"
