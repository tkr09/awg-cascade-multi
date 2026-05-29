#!/bin/bash
# =============================================================================
# AWG Cascade Multi — Setup на RU (entry)
#
# Архитектура:
#   Клиент ──AmneziaWG──> RU (awg0) ──ECMP──> awg1/awg2/.../awgN ──> exits
#
# Ставит на RU:
#   • amneziawg (host-native, без docker)
#   • awg0 для клиентов + первый peer
#   • iptables kill-switch + MASQUERADE + MARK
#   • sysctl (ip_forward, fib_multipath_hash_policy)
#   • systemd units: killswitch, watchdog, postboot, bot
#   • Telegram бот (Python aiogram)
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/tkr09/awg-cascade-multi/main/setup.sh -o setup.sh
#   sudo bash setup.sh
# =============================================================================

set -e
sed -i 's/\r//' "$0" 2>/dev/null || true

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
err()    { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}\n"; }
prompt() { echo -e -n "${YELLOW}▶${NC} $1"; }
read_tty() {
    # Если есть /dev/tty — читаем оттуда. Иначе из stdin (для non-interactive)
    if [ -r /dev/tty ] && [ -z "$BATCH" ]; then
        IFS= read -r "$1" </dev/tty
    else
        IFS= read -r "$1" || true
    fi
    printf -v "$1" '%s' "${!1%$'\r'}"
}

[ "$EUID" -ne 0 ] && err "Запусти от root"
[ -f /etc/os-release ] && . /etc/os-release
[ "$ID" != "ubuntu" ] && warn "Скрипт тестирован на Ubuntu 24.04. У тебя: $PRETTY_NAME"

# ─── Константы ────────────────────────────────────────────────────────────────
CONFIG_DIR=/etc/awg-cascade
PEERS_DIR=$CONFIG_DIR/peers
EXITS_DIR=$CONFIG_DIR/exits
SSH_DIR=$CONFIG_DIR/ssh
WG_DIR=/etc/amnezia/amneziawg
BOT_DIR=/opt/awg-cascade-bot
STATE_FILE=$CONFIG_DIR/state.json
CONFIG_FILE=$CONFIG_DIR/config
LOG_FILE=/var/log/awg-cascade.log
BOT_USER=awgbot

# AmneziaWG v2.0 параметры — генерируем через awg2-params.sh (sourced ниже).
# Каждая установка получает уникальные H-ranges + случайные S1-S4.
# Совместимо с amnezia-client v2.0 (формат idential to реальному client config).

# ─── Баннер ───────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
    ╔══════════════════════════════════════════════════════════╗
    ║       AWG Cascade Multi — RU (entry) Setup               ║
    ║                                                          ║
    ║  Клиент ──AWG──> RU ──ECMP──> awg1/awg2/...awgN ──> exits║
    ║                                                          ║
    ║  Kill-switch by design + Watchdog + Telegram bot         ║
    ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 0: cleanup (если есть остатки docker/amnezia)
# ═════════════════════════════════════════════════════════════════════════════
header "0. Очистка предыдущих установок"

if command -v docker &>/dev/null; then
    info "Найден docker, удаляю amnezia-контейнеры..."
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i amnezia | while read n; do
        docker stop "$n" 2>/dev/null || true
        docker rm -f "$n" 2>/dev/null || true
    done
fi

if [ -d /opt/amnezia ]; then
    rm -rf /opt/amnezia
    ok "/opt/amnezia удалён"
fi

# Не сносим docker автоматически — это решение юзера
ok "Старые amnezia-контейнеры удалены"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 1: параметры
# ═════════════════════════════════════════════════════════════════════════════
header "1. Параметры установки"

# Загружаем предыдущие если есть
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Public IP (для endpoint в клиентских конфигах)
DETECTED_IP=$(curl -fsS --max-time 5 -4 https://ifconfig.me 2>/dev/null || curl -fsS --max-time 5 -4 https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
RU_PUBLIC_IP="${RU_PUBLIC_IP:-$DETECTED_IP}"
prompt "Публичный IP этого RU [${RU_PUBLIC_IP}]: "; read_tty inp; [ -n "$inp" ] && RU_PUBLIC_IP="$inp"
[ -z "$RU_PUBLIC_IP" ] && err "Публичный IP обязателен"

# UDP-порт awg0
AWG0_PORT="${AWG0_PORT:-32762}"
prompt "UDP-порт awg0 [${AWG0_PORT}]: "; read_tty inp; [ -n "$inp" ] && AWG0_PORT="$inp"

# Подсеть клиентов
CLIENT_NET="${CLIENT_NET:-10.222.122.0/24}"
CLIENT_NET_PREFIX=$(echo "$CLIENT_NET" | sed 's|0/24$||')
SERVER_IP=$(echo "$CLIENT_NET" | sed 's|0/24$|1|')
prompt "Подсеть клиентов [${CLIENT_NET}]: "; read_tty inp; [ -n "$inp" ] && {
    CLIENT_NET="$inp"
    CLIENT_NET_PREFIX=$(echo "$CLIENT_NET" | sed 's|0/24$||')
    SERVER_IP=$(echo "$CLIENT_NET" | sed 's|0/24$|1|')
}

# Telegram
if [ -z "$TG_TOKEN" ]; then
    prompt "Telegram bot token (от @BotFather): "; read_tty TG_TOKEN
fi
[ -z "$TG_TOKEN" ] && err "Token обязателен (можно env: TG_TOKEN=... bash setup.sh)"

if [ -z "$TG_CHAT_ID" ]; then
    prompt "Telegram chat_id (твой ID, узнать у @userinfobot): "; read_tty TG_CHAT_ID
fi
[ -z "$TG_CHAT_ID" ] && err "Chat ID обязателен"

# ntfy
if [ -z "$NTFY_TOPIC" ]; then
    prompt "ntfy.sh topic (для emergency alerts, можно создать любое имя): "; read_tty NTFY_TOPIC
fi
[ -z "$NTFY_TOPIC" ] && err "ntfy topic обязателен"
NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"

info "Параметры:"
echo "  RU IP:         ${BOLD}$RU_PUBLIC_IP:$AWG0_PORT/udp${NC}"
echo "  Клиенты:       ${BOLD}$CLIENT_NET${NC} (server $SERVER_IP)"
echo "  Telegram chat: ${BOLD}$TG_CHAT_ID${NC}"
echo "  ntfy:          ${BOLD}$NTFY_URL${NC}"
echo ""
prompt "Всё верно? [Y/n]: "; read_tty inp
[[ "$inp" =~ ^[Nn] ]] && err "Прервано пользователем"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: установка пакетов
# ═════════════════════════════════════════════════════════════════════════════
header "2. Установка пакетов"

export DEBIAN_FRONTEND=noninteractive

info "apt update..."
apt-get update -qq

info "Базовые утилиты..."
apt-get install -y -qq software-properties-common curl jq qrencode iptables-persistent \
    python3 python3-venv python3-pip git ca-certificates dnsutils \
    unattended-upgrades apt-listchanges >/dev/null
ok "Базовые пакеты"

# Включаем unattended-upgrades для security patches
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
sed -i 's|//Unattended-Upgrade::Automatic-Reboot ".*";|Unattended-Upgrade::Automatic-Reboot "false";|' \
    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades включён"

# AmneziaWG PPA + kernel module + tools
if ! command -v awg &>/dev/null; then
    info "Добавляю Amnezia PPA..."
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
    apt-get update -qq
    info "Устанавливаю amneziawg + amneziawg-dkms (компиляция модуля)..."
    apt-get install -y -qq linux-headers-$(uname -r) >/dev/null
    apt-get install -y -qq amneziawg amneziawg-dkms >/dev/null
fi

if ! command -v awg &>/dev/null; then
    err "amneziawg не установился"
fi
ok "amneziawg: $(awg --version | head -1)"

# Проверим что модуль ядра загружается
if ! modprobe amneziawg 2>/dev/null; then
    warn "Модуль amneziawg не загрузился — пробую пересобрать dkms..."
    dkms autoinstall || true
    modprobe amneziawg || err "Не удалось загрузить модуль amneziawg"
fi
ok "Модуль amneziawg загружен"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: пользователь awgbot + sudoers
# ═════════════════════════════════════════════════════════════════════════════
header "3. Пользователь $BOT_USER"

if ! id "$BOT_USER" &>/dev/null; then
    useradd -r -s /bin/bash -d "$BOT_DIR" -m "$BOT_USER"
    ok "Создан пользователь $BOT_USER"
else
    ok "Пользователь $BOT_USER уже существует"
fi

# Sudoers: ограниченный набор команд
cat > /etc/sudoers.d/$BOT_USER <<SUDOEOF
# AWG Cascade Multi — bot privileges
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/awg, /usr/bin/awg-quick, /usr/bin/wg-quick
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart awg-quick@*
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart awg-cascade-watchdog
$BOT_USER ALL=(root) NOPASSWD: /sbin/ip route, /sbin/ip rule, /sbin/ip link
$BOT_USER ALL=(root) NOPASSWD: /sbin/iptables, /sbin/ip6tables
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-route.sh
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-exit-add.sh
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-exit-remove.sh
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-peer-add.sh
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-peer-remove.sh
SUDOEOF
chmod 440 /etc/sudoers.d/$BOT_USER
visudo -c -f /etc/sudoers.d/$BOT_USER >/dev/null || err "sudoers syntax error"
ok "Sudoers настроен"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 4: sysctl + директории
# ═════════════════════════════════════════════════════════════════════════════
header "4. sysctl + директории"

cat > /etc/sysctl.d/99-awg-cascade.conf <<EOF
# AWG Cascade Multi
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.fib_multipath_hash_policy = 1
net.ipv4.fib_multipath_use_neigh = 1
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
EOF
sysctl --system -q >/dev/null 2>&1 || true
ok "sysctl применён (ip_forward, fib_multipath_hash_policy=1 для L4 ECMP)"

mkdir -p "$CONFIG_DIR" "$PEERS_DIR" "$EXITS_DIR" "$SSH_DIR" "$WG_DIR"
chown -R "$BOT_USER:$BOT_USER" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" "$PEERS_DIR" "$EXITS_DIR" "$SSH_DIR"
ok "Директории созданы"

# SSH key пары для бота (для коннекта к exits)
if [ ! -f "$SSH_DIR/id_ed25519" ]; then
    sudo -u "$BOT_USER" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -C "awg-cascade-bot@$(hostname)" >/dev/null
    ok "SSH ключ бота создан: $SSH_DIR/id_ed25519"
else
    ok "SSH ключ бота уже есть"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Phase 5: awg0 (серверный интерфейс) + первый peer
# ═════════════════════════════════════════════════════════════════════════════
header "5. AmneziaWG awg0 + первый peer"

# Генерируем v2.0 параметры (S1-S4 random + H1-H4 ranged monotonic + I1)
SERVER_PRIVKEY=$(awg genkey)
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | awg pubkey)

# H1-H4 + S1-S4 + I1 уникальные для этой установки. Если уже сохранены — берём
# те же (чтобы peer-конфиги остались валидными между переустановками setup.sh).
if [ ! -f "$CONFIG_DIR/awg2_params" ]; then
    . "$(dirname "$0")/awg2-params.sh"
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
    chown "$BOT_USER:$BOT_USER" "$CONFIG_DIR/awg2_params"
    ok "Сгенерированы v2.0 params: S=$S1/$S2/$S3/$S4  H1=$H1"
else
    . "$CONFIG_DIR/awg2_params"
    ok "v2.0 params подгружены из $CONFIG_DIR/awg2_params"
fi
JC_VAL=5; JMIN_VAL=10; JMAX_VAL=50

# Первый peer
if [ -z "$FIRST_PEER" ]; then
    prompt "Имя первого peer'а (например 'phone'): "; read_tty FIRST_PEER
fi
[ -z "$FIRST_PEER" ] && FIRST_PEER="phone"
FIRST_PEER=$(echo "$FIRST_PEER" | tr -cd 'a-zA-Z0-9._-')

PEER_PRIVKEY=$(awg genkey)
PEER_PUBKEY=$(echo "$PEER_PRIVKEY" | awg pubkey)
PEER_PSK=$(awg genpsk)
PEER_IP="${CLIENT_NET_PREFIX}2"

# Записываем awg0.conf
# MTU=1340: двойная инкапсуляция (awg0 inside awg1 inside eth0). 1500 - 80 - 80 = 1340.
cat > $WG_DIR/awg0.conf <<EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $AWG0_PORT
MTU = 1340
PrivateKey = $SERVER_PRIVKEY
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

[Peer]
# $FIRST_PEER
PublicKey = $PEER_PUBKEY
PresharedKey = $PEER_PSK
AllowedIPs = $PEER_IP/32
EOF
chmod 600 $WG_DIR/awg0.conf
ok "$WG_DIR/awg0.conf создан"

# Клиентский конфиг
CLIENT_CONF="$PEERS_DIR/${FIRST_PEER}.conf"
cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $PEER_PRIVKEY
Address = $PEER_IP/32
MTU = 1340
DNS = 1.1.1.1, 8.8.8.8
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

[Peer]
PublicKey = $SERVER_PUBKEY
PresharedKey = $PEER_PSK
Endpoint = $RU_PUBLIC_IP:$AWG0_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chown "$BOT_USER:$BOT_USER" "$CLIENT_CONF"
chmod 600 "$CLIENT_CONF"

# Регистрация peer'а в state
PEERS_JSON="$CONFIG_DIR/peers.json"
if [ ! -f "$PEERS_JSON" ]; then
    echo "[]" > "$PEERS_JSON"
fi
jq --arg n "$FIRST_PEER" --arg ip "$PEER_IP" --arg pk "$PEER_PUBKEY" \
   '. + [{name: $n, ip: $ip, pubkey: $pk, created: now|todate, note: ""}]' \
   "$PEERS_JSON" > "$PEERS_JSON.tmp" && mv "$PEERS_JSON.tmp" "$PEERS_JSON"
chown "$BOT_USER:$BOT_USER" "$PEERS_JSON"
ok "Peer '$FIRST_PEER' (IP $PEER_IP) добавлен"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 6: iptables (kill-switch + MARK + MASQUERADE)
# ═════════════════════════════════════════════════════════════════════════════
header "6. iptables (kill-switch + MARK)"

# Detect main interface
MAIN_IFACE=$(ip route show default 0.0.0.0/0 | head -1 | awk '/dev/ {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE="eth0"
ok "Main interface: $MAIN_IFACE"

# Скрипт применения правил (вызывается systemd и при ручном перезапуске)
cat > /usr/local/sbin/awg-cascade-iptables.sh <<IPTEOF
#!/bin/bash
# AWG Cascade — apply iptables rules (idempotent)
set -e

# Очистка наших правил (по комментарию)
flush_our_rules() {
    iptables-save 2>/dev/null | grep -v 'awg-cascade' | iptables-restore 2>/dev/null || true
    iptables -t mangle -F PREROUTING 2>/dev/null || true
    iptables -t mangle -F OUTPUT 2>/dev/null || true
}

# --- mangle: MARK клиентского трафика для ECMP routing ---
# 0x1 = трафик клиентов awg0 → table 100 (ECMP exits)
iptables -t mangle -A PREROUTING -i awg0 -m comment --comment "awg-cascade" -j MARK --set-mark 0x1
# Для бота используется НЕ mangle MARK (он не триггерит re-route), а ip rule uidrange — см. ниже

# --- nat: MASQUERADE клиентского трафика на исходе из awg1..awgN ---
# Зачем: внутренний пакет от клиента имеет src=10.222.122.X. Exit-нода видит
# inner packet с этим src — но peer AllowedIPs у неё = 10.99.N.2/32 (наш tunnel IP).
# Wireguard на exit'е отвергает пакеты с src НЕ из AllowedIPs. Решение: на RU
# подменяем src клиентских пакетов на наш tunnel IP (через MASQUERADE на awg1).
# Условие ! -o awg0 = масквардим всё что уходит НЕ к клиенту (то есть на любой awgN).
iptables -t nat -A POSTROUTING -s $CLIENT_NET ! -o awg0 -m comment --comment "awg-cascade-masq" -j MASQUERADE

# --- filter FORWARD: kill-switch ---
# Клиентский трафик может выйти ТОЛЬКО через awg+ (awg1..awgN)
# Если ECMP-таблица пуста (все exits down) → нет nexthop'а → drop
# Дополнительно: явный DROP если awg0 → не-awg
iptables -A FORWARD -i awg0 -o awg+ -m comment --comment "awg-cascade" -j ACCEPT
iptables -A FORWARD -i awg+ -o awg0 -m comment --comment "awg-cascade" -j ACCEPT
iptables -A FORWARD -i awg0 ! -o awg+ -m comment --comment "awg-cascade-killsw" -j DROP

# --- mangle FORWARD: MSS clamp для TCP (двойная инкапсуляция → нужно PMTU) ---
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "awg-cascade-mss" -j TCPMSS --clamp-mss-to-pmtu

# Persist
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
IPTEOF
chmod +x /usr/local/sbin/awg-cascade-iptables.sh

# Запустим прямо сейчас
/usr/local/sbin/awg-cascade-iptables.sh
ok "iptables правила применены"

# ─── ip rule для policy routing ──────────────────────────────────────────────
# fwmark 0x1 (клиенты awg0) → table 100 (ECMP exits)
# uidrange awgbot → table 100 (бот'трафик к Telegram через NL)
# Всё остальное (включая ntfy через --interface eth0) → main table (eth0)

BOT_UID=$(id -u $BOT_USER)
ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip rule del fwmark 0x2 lookup 100 2>/dev/null || true
ip rule del uidrange $BOT_UID-$BOT_UID 2>/dev/null || true
ip rule del ipproto tcp dport 22 uidrange $BOT_UID-$BOT_UID 2>/dev/null || true
# 998: бот SSH-outbound → eth0 (в обход cascade, на случай если exit-hoster блокирует :22)
ip rule add ipproto tcp dport 22 uidrange $BOT_UID-$BOT_UID lookup main priority 998
# 1000: клиенты awg0 → ECMP table 100
ip rule add fwmark 0x1 lookup 100 priority 1000
# 1001: бот (остальной outbound) → table 100 (Telegram через NL)
ip rule add uidrange $BOT_UID-$BOT_UID lookup 100 priority 1001

# Скрипт чтобы это пережило ребут
cat > /usr/local/sbin/awg-cascade-iprule.sh <<RULEEOF
#!/bin/bash
BOT_UID=\$(id -u $BOT_USER 2>/dev/null || echo 999)
ip rule del fwmark 0x1 lookup 100 2>/dev/null
ip rule del fwmark 0x2 lookup 100 2>/dev/null
ip rule del uidrange \$BOT_UID-\$BOT_UID 2>/dev/null
ip rule del ipproto tcp dport 22 uidrange \$BOT_UID-\$BOT_UID 2>/dev/null
ip rule add ipproto tcp dport 22 uidrange \$BOT_UID-\$BOT_UID lookup main priority 998
ip rule add fwmark 0x1 lookup 100 priority 1000
ip rule add uidrange \$BOT_UID-\$BOT_UID lookup 100 priority 1001
RULEEOF
chmod +x /usr/local/sbin/awg-cascade-iprule.sh
ok "ip rule: SSH→eth0 (998), clients→ECMP (1000), bot→ECMP (1001)"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 7: state.json + helper-скрипты
# ═════════════════════════════════════════════════════════════════════════════
header "7. State и helper-скрипты"

# Начальный state.json
if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<EOF
{
  "schema": 1,
  "ru_public_ip": "$RU_PUBLIC_IP",
  "ru_main_iface": "$MAIN_IFACE",
  "exits": [],
  "active_default_route": [],
  "kill_switch_active": true,
  "last_update": "$(date -Iseconds)"
}
EOF
    chown "$BOT_USER:$BOT_USER" "$STATE_FILE"
    chmod 644 "$STATE_FILE"
    ok "state.json создан (пустой, без exits)"
fi

# Config-файл бота
cat > "$CONFIG_FILE" <<EOF
# AWG Cascade Multi — config (загружается ботом и скриптами)
RU_PUBLIC_IP="$RU_PUBLIC_IP"
AWG0_PORT="$AWG0_PORT"
CLIENT_NET="$CLIENT_NET"
CLIENT_NET_PREFIX="$CLIENT_NET_PREFIX"
SERVER_IP="$SERVER_IP"
MAIN_IFACE="$MAIN_IFACE"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
NTFY_URL="$NTFY_URL"
NTFY_TOPIC="$NTFY_TOPIC"
BOT_USER="$BOT_USER"
EOF
chmod 600 "$CONFIG_FILE"
chown "$BOT_USER:$BOT_USER" "$CONFIG_FILE"
ok "Config файл сохранён: $CONFIG_FILE"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 8: systemd units
# ═════════════════════════════════════════════════════════════════════════════
header "8. systemd"

# awg-quick@awg0
systemctl enable awg-quick@awg0 >/dev/null 2>&1
systemctl restart awg-quick@awg0
sleep 1
if ! awg show awg0 >/dev/null 2>&1; then
    err "awg0 не поднялся. Логи: journalctl -u awg-quick@awg0 -n 30"
fi
ok "awg-quick@awg0 запущен"

# iptables persistence service (применяет наши правила при загрузке)
cat > /etc/systemd/system/awg-cascade-iptables.service <<EOF
[Unit]
Description=AWG Cascade iptables rules
After=network-pre.target
Before=awg-quick@awg0.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/awg-cascade-iptables.sh
ExecStart=/usr/local/sbin/awg-cascade-iprule.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable awg-cascade-iptables.service >/dev/null
ok "awg-cascade-iptables.service зарегистрирован"

# Watchdog/postboot/bot units — заглушки (наполним когда напишем сами скрипты/бот)
# Пока просто создаём пустые stub'ы чтобы было видно что они есть
touch /usr/local/sbin/awg-cascade-watchdog.sh
chmod +x /usr/local/sbin/awg-cascade-watchdog.sh

# ═════════════════════════════════════════════════════════════════════════════
# Phase 9: финал — выводим QR первого peer'а
# ═════════════════════════════════════════════════════════════════════════════
header "9. Готово! QR первого peer'а"

echo ""
echo -e "${BOLD}Peer: ${GREEN}$FIRST_PEER${NC}  IP: ${BOLD}$PEER_IP${NC}"
echo -e "Конфиг: ${BOLD}$CLIENT_CONF${NC}"
echo ""

# QR в терминал
qrencode -t ANSIUTF8 < "$CLIENT_CONF"

echo ""
info "Импорт в amnezia-client:"
echo "  Mobile: открой app → '+' → 'Импорт конфига' → 'Сканировать QR-код' → сканируй ↑"
echo "  Desktop: открой app → 'Импорт конфига' → 'Из файла' → загрузи $CLIENT_CONF"
echo ""
info "Endpoint: ${BOLD}$RU_PUBLIC_IP:$AWG0_PORT${NC}"
info "Server pubkey: ${BOLD}$SERVER_PUBKEY${NC}"
echo ""

header "Что дальше"

cat << NEXT
${GREEN}awg0 запущен${NC} — подключайся первым peer'ом ($FIRST_PEER).

${YELLOW}Бот и watchdog ещё не активны${NC} — будут установлены отдельными скриптами:
  • Watchdog: будет мониторить exits и управлять ECMP-маршрутом
  • Telegram бот: для добавления exits, peers, WARP управления
  • Postboot verify: проверка после ребута

Сейчас работает только клиент↔RU. ${RED}Без exits трафик кейс выйти не может (kill-switch активен).${NC}
Чтобы клиенты получили доступ в интернет — нужно добавить хотя бы один exit.

Полезные команды:
  ${BOLD}awg show${NC}                      статус awg0
  ${BOLD}cat $STATE_FILE${NC}     state каскада
  ${BOLD}journalctl -u awg-quick@awg0${NC}  логи awg0
  ${BOLD}iptables -L FORWARD -v -n${NC}     правила kill-switch
NEXT

echo ""
ok "Setup завершён. Файлы в $CONFIG_DIR/"
