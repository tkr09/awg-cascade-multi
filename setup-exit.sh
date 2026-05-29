#!/bin/bash
# =============================================================================
# AWG Cascade Multi — Exit-side setup
#
# Ставится на каждом exit-сервере (NL/DE/PL/...).
# Создаёт awg-in (AmneziaWG) которое принимает один peer = RU entry-сервер.
# Настраивает MASQUERADE для выхода в инет.
#
# Использование:
#   1. Вручную (тестовая установка):
#        sudo bash setup-exit.sh
#      Скрипт спросит индекс exit'а (1/2/3/...) и публичный IP RU.
#
#   2. Через бота (автоматически, по SSH):
#        sudo EXIT_INDEX=1 RU_PUBLIC_IP=1.2.3.4 RU_PUBKEY=... bash setup-exit.sh
#      Скрипт вернёт JSON c {pubkey, port, allowed_ip, tunnel_ip} для записи на RU.
# =============================================================================

set -e
sed -i 's/\r//' "$0" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}[✓]${NC} $1" >&2; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" >&2; }
err()    { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $1" >&2; }
header() { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}\n" >&2; }
prompt() { echo -e -n "${YELLOW}▶${NC} $1" >&2; }
read_tty() {
    if [ -r /dev/tty ] && [ -z "$BATCH" ]; then
        IFS= read -r "$1" </dev/tty
    else
        IFS= read -r "$1" || true
    fi
    printf -v "$1" '%s' "${!1%$'\r'}"
}

[ "$EUID" -ne 0 ] && err "Запусти от root"

# ─── Константы ────────────────────────────────────────────────────────────────
WG_DIR=/etc/amnezia/amneziawg
CONFIG_DIR=/etc/awg-cascade-exit
STATE_FILE=$CONFIG_DIR/info.json
BOT_USER=awgbot

# AmneziaWG v2.0 params generator (S1-S4 random, H1-H4 monotonic ranges, I1 fixed)
# Загружается ниже из /tmp/awg2-params.sh который бот залил вместе с setup-exit.sh.
JC_VAL=5; JMIN_VAL=10; JMAX_VAL=50

# ═════════════════════════════════════════════════════════════════════════════
# Phase 1: параметры
# ═════════════════════════════════════════════════════════════════════════════

# EXIT_INDEX — номер этого exit'а у RU. Определяет:
#   - имя интерфейса awg-in (всегда awg-in на exit)
#   - на RU соответствующий awg<EXIT_INDEX> (awg1, awg2, ...)
#   - UDP-порт (51820 + EXIT_INDEX) — чтобы exits не конфликтовали если их много за одним NAT
#   - tunnel-подсеть 10.99.<EXIT_INDEX>.0/30 (point-to-point /30: .1 = exit, .2 = RU)

[ -z "$EXIT_INDEX" ] && {
    prompt "Индекс exit'а (1..255, должен совпадать с awg<N> на RU): "
    read_tty EXIT_INDEX
}
[[ ! "$EXIT_INDEX" =~ ^[0-9]+$ ]] && err "EXIT_INDEX должен быть числом 1..255"
[ "$EXIT_INDEX" -lt 1 ] || [ "$EXIT_INDEX" -gt 255 ] && err "EXIT_INDEX вне диапазона 1..255"

EXIT_PORT=$((51820 + EXIT_INDEX))
TUNNEL_NET="10.99.${EXIT_INDEX}.0/30"
EXIT_TUNNEL_IP="10.99.${EXIT_INDEX}.1"
RU_TUNNEL_IP="10.99.${EXIT_INDEX}.2"

[ -z "$RU_PUBLIC_IP" ] && {
    prompt "Публичный IP RU-сервера (entry): "
    read_tty RU_PUBLIC_IP
}
[ -z "$RU_PUBLIC_IP" ] && err "RU_PUBLIC_IP обязателен"

[ -z "$RU_PUBKEY" ] && {
    prompt "Публичный ключ awg<${EXIT_INDEX}> с RU (на RU будет генериться при создании туннеля): "
    read_tty RU_PUBKEY
}
[ -z "$RU_PUBKEY" ] && err "RU_PUBKEY обязателен"

[ -z "$RU_PSK" ] && {
    prompt "Pre-shared key (опционально, Enter — пропустить): "
    read_tty RU_PSK
}

# WARP опционально
WARP_ENABLE="${WARP_ENABLE:-0}"

info "EXIT_INDEX=$EXIT_INDEX  port=$EXIT_PORT  tunnel=$TUNNEL_NET"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: пакеты
# ═════════════════════════════════════════════════════════════════════════════
header "Установка пакетов"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

if ! command -v awg &>/dev/null; then
    apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
    apt-get update -qq
    apt-get install -y -qq linux-headers-$(uname -r) >/dev/null
    apt-get install -y -qq amneziawg amneziawg-dkms amneziawg-tools >/dev/null
fi

apt-get install -y -qq iptables-persistent curl jq >/dev/null

modprobe amneziawg || err "Модуль amneziawg не загружается"
ok "amneziawg готов"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: awgbot user (только если бот будет SSH'ить сюда)
# ═════════════════════════════════════════════════════════════════════════════
header "Пользователь $BOT_USER"

if ! id "$BOT_USER" &>/dev/null; then
    useradd -r -s /bin/bash -d /var/lib/$BOT_USER -m "$BOT_USER"
fi

cat > /etc/sudoers.d/$BOT_USER <<EOF
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/awg, /usr/bin/awg-quick, /usr/bin/wg
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart awg-quick@*
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start awg-quick@*
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl stop awg-quick@*
$BOT_USER ALL=(root) NOPASSWD: /sbin/iptables, /sbin/ip6tables
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-exit-warp.sh
EOF
chmod 440 /etc/sudoers.d/$BOT_USER
visudo -c -f /etc/sudoers.d/$BOT_USER >/dev/null
ok "Sudoers ОК"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 4: sysctl
# ═════════════════════════════════════════════════════════════════════════════
header "sysctl"

cat > /etc/sysctl.d/99-awg-cascade-exit.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
EOF
sysctl --system -q >/dev/null 2>&1 || true
ok "sysctl применён"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 5: ключи + awg-in.conf
# ═════════════════════════════════════════════════════════════════════════════
header "AmneziaWG awg-in"

mkdir -p "$CONFIG_DIR" "$WG_DIR"
chmod 700 "$CONFIG_DIR" "$WG_DIR"

# Если уже есть конфиг — не перетираем
if [ -f "$CONFIG_DIR/private.key" ]; then
    EXIT_PRIVKEY=$(cat "$CONFIG_DIR/private.key")
    EXIT_PUBKEY=$(echo "$EXIT_PRIVKEY" | awg pubkey)
    ok "Используем существующие ключи exit'а"
else
    EXIT_PRIVKEY=$(awg genkey)
    EXIT_PUBKEY=$(echo "$EXIT_PRIVKEY" | awg pubkey)
    echo "$EXIT_PRIVKEY" > "$CONFIG_DIR/private.key"
    echo "$EXIT_PUBKEY"  > "$CONFIG_DIR/public.key"
    chmod 600 "$CONFIG_DIR/private.key"
    ok "Сгенерированы новые ключи exit'а"
fi

# v2.0 параметры (S1-S4 random, H1-H4 monotonic ranges, I1 DNS-iCloud).
# Если уже сохранены — берём существующие (постоянство при reinstall).
if [ ! -f "$CONFIG_DIR/awg2_params" ]; then
    # Ищем awg2-params.sh в /tmp (положил бот) или рядом со setup-exit.sh
    AWG2_PARAMS_FILE=""
    for cand in /tmp/awg2-params.sh "$(dirname "$0")/awg2-params.sh"; do
        [ -f "$cand" ] && AWG2_PARAMS_FILE="$cand" && break
    done
    [ -z "$AWG2_PARAMS_FILE" ] && err "awg2-params.sh не найден (положи в /tmp/ или рядом с setup-exit.sh)"

    . "$AWG2_PARAMS_FILE"
    cat > "$CONFIG_DIR/awg2_params" <<EOF
S1=$S1
S2=$S2
S3=$S3
S4=$S4
H1='$H1'
H2='$H2'
H3='$H3'
H4='$H4'
I1='$I1'
EOF
    chmod 600 "$CONFIG_DIR/awg2_params"
fi
. "$CONFIG_DIR/awg2_params"

MAIN_IFACE=$(ip route show default 0.0.0.0/0 | head -1 | awk '/dev/ {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE="eth0"

# awg-in.conf — приём от RU
PSK_LINE=""
[ -n "$RU_PSK" ] && PSK_LINE="PresharedKey = $RU_PSK"

cat > $WG_DIR/awg-in.conf <<EOF
[Interface]
Address = $EXIT_TUNNEL_IP/30
ListenPort = $EXIT_PORT
PrivateKey = $EXIT_PRIVKEY
Jc = $JC_VAL
Jmin = $JMIN_VAL
Jmax = $JMAX_VAL
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1

# Forwarding rules — MASQUERADE на main interface
PostUp   = iptables -A FORWARD -i %i -j ACCEPT
PostUp   = iptables -A FORWARD -o %i -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

[Peer]
# RU entry server
PublicKey = $RU_PUBKEY
$PSK_LINE
AllowedIPs = $RU_TUNNEL_IP/32
PersistentKeepalive = 25
EOF
chmod 600 $WG_DIR/awg-in.conf
ok "$WG_DIR/awg-in.conf создан"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 6: systemd up
# ═════════════════════════════════════════════════════════════════════════════
header "WARP helper-скрипт"

# Кладём awg-cascade-exit-warp.sh (бот вызывает через sudo)
# Сам скрипт скачивается из репо или подкладывается setup'ом.
# Если он залит в /tmp перед запуском — копируем; иначе пользователь должен
# залить руками (или скачать с github).
if [ -f /tmp/awg-cascade-exit-warp.sh ]; then
    install -m 755 -o root -g root /tmp/awg-cascade-exit-warp.sh \
        /usr/local/sbin/awg-cascade-exit-warp.sh
    ok "WARP helper установлен (/usr/local/sbin/awg-cascade-exit-warp.sh)"
else
    warn "WARP helper не найден в /tmp/awg-cascade-exit-warp.sh"
    warn "(скачай руками с https://github.com/tkr09/awg-cascade-multi/blob/main/exit-side/awg-cascade-exit-warp.sh)"
fi

mkdir -p $CONFIG_DIR
chown $BOT_USER:$BOT_USER $CONFIG_DIR
chmod 755 $CONFIG_DIR

header "Запуск awg-quick@awg-in"

systemctl enable awg-quick@awg-in >/dev/null 2>&1
systemctl restart awg-quick@awg-in
sleep 1
systemctl is-active --quiet awg-quick@awg-in || {
    journalctl -u awg-quick@awg-in -n 20 --no-pager >&2
    err "awg-quick@awg-in не запустился"
}
ok "awg-in активен на $EXIT_PORT/udp"

# Persist iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════════
# Phase 7: info JSON (для бота / RU-стороны)
# ═════════════════════════════════════════════════════════════════════════════

# H1-H4 теперь строки-диапазоны ("min-max"), а S1-S4 и I1 — отдельно.
# Schema 2 = v2.0 AmneziaWG (ranged headers + random padding).
PUBLIC_IP=$(curl -fsS --max-time 5 -4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

jq -n \
    --argjson idx    "$EXIT_INDEX" \
    --arg pip        "$PUBLIC_IP" \
    --arg pub        "$EXIT_PUBKEY" \
    --argjson port   "$EXIT_PORT" \
    --arg etip       "$EXIT_TUNNEL_IP" \
    --arg rtip       "$RU_TUNNEL_IP" \
    --arg net        "$TUNNEL_NET" \
    --arg iface      "$MAIN_IFACE" \
    --arg h1         "$H1" --arg h2 "$H2" --arg h3 "$H3" --arg h4 "$H4" \
    --argjson s1     "$S1" --argjson s2 "$S2" --argjson s3 "$S3" --argjson s4 "$S4" \
    --arg i1         "$I1" \
    --arg t          "$(date -Iseconds)" \
    '{
        schema: 2,
        exit_index: $idx, exit_public_ip: $pip, exit_pubkey: $pub, exit_port: $port,
        exit_tunnel_ip: $etip, ru_tunnel_ip: $rtip, tunnel_net: $net, main_iface: $iface,
        h_params: {H1: $h1, H2: $h2, H3: $h3, H4: $h4},
        s_params: {S1: $s1, S2: $s2, S3: $s3, S4: $s4},
        i_params: {I1: $i1},
        warp_state: "off", installed_at: $t
    }' > "$STATE_FILE"
chmod 644 "$STATE_FILE"

# Вывод JSON на stdout (бот парсит)
header "Готово. JSON для RU:"
cat "$STATE_FILE"
