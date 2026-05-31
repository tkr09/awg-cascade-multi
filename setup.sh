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

# На fresh Ubuntu cloud-init запускает unattended-upgrades сразу после boot.
# Это держит /var/lib/dpkg/lock-frontend 5-10 минут и валит setup.sh
# с "Could not get lock". Гасим apt-сервисы перед нашими apt-операциями.
info "Останавливаю cloud-init apt-сервисы (если работают)..."
systemctl stop unattended-upgrades.service \
               apt-daily.service apt-daily-upgrade.service \
               apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -9 unattended-upgr 2>/dev/null || true

# Ждём пока ВСЕ apt-локи освободятся (если что-то ещё держит после kill)
wait_apt_lock() {
    local max=600 elapsed=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock >/dev/null 2>&1; do
        if [ $elapsed -ge $max ]; then
            err "apt lock не освободился за 10 минут (что-то странное на сервере)"
        fi
        [ $((elapsed % 30)) -eq 0 ] && info "apt lock занят, жду... (${elapsed}s/$max)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
}
wait_apt_lock

# Восстановление после прерванной установки (dpkg half-configured). Идемпотентно.
dpkg --configure -a 2>/dev/null || true

info "apt update..."
apt-get update -qq

info "Базовые утилиты..."
wait_apt_lock
apt-get install -y -qq software-properties-common curl jq qrencode iptables-persistent \
    python3 python3-venv python3-pip git ca-certificates dnsutils sshpass \
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

# logrotate для watchdog.log — иначе залогируется до сотен МБ
cat > /etc/logrotate.d/awg-cascade <<EOF
/var/log/awg-cascade-watchdog.log {
    weekly
    rotate 4
    compress
    delaycompress
    notifempty
    missingok
    create 0644 root root
    copytruncate
}
EOF
ok "logrotate для awg-cascade-watchdog.log (weekly, 4 weeks)"

# AmneziaWG PPA + kernel module + tools
if ! command -v awg &>/dev/null; then
    wait_apt_lock
    info "Добавляю Amnezia PPA..."
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
    wait_apt_lock
    apt-get update -qq
    info "Устанавливаю amneziawg + amneziawg-dkms (компиляция модуля)..."
    wait_apt_lock
    apt-get install -y -qq linux-headers-$(uname -r) >/dev/null
    wait_apt_lock
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

# Sudoers. Wildcard на awg-cascade-*.sh — чтобы не ловить рассинхрон имён
# (бот зовёт exit-add-ru.sh / exit-rotate.sh / peer-rotate.sh — их легко забыть
# перечислить поимённо). Это выделенный appliance с нашим доверенным кодом бота,
# поэтому даём широкий systemctl/ip — бот и так управляет WG/iptables/routing.
# Команда без аргументов в sudoers = разрешён любой набор аргументов.
cat > /etc/sudoers.d/$BOT_USER <<SUDOEOF
# AWG Cascade Multi — bot privileges
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/awg, /usr/bin/awg-quick, /usr/bin/wg-quick
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl
$BOT_USER ALL=(root) NOPASSWD: /sbin/ip, /sbin/iptables, /sbin/ip6tables
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-*.sh
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

# MASQUERADE для tunnel-side трафика (RU bot + любой локальный с src=10.99.*.*).
# Зачем: Linux ECMP per-flow hash меняет out-interface, но source IP всегда
# берётся с первого nexthop. Если ECMP кинул на awg2 а src остался =10.99.1.2 —
# exit отвергает (AllowedIPs=10.99.<N>.2/32). MASQUERADE подменяет src на
# IP актуального out-interface, exit принимает.
iptables -t nat -A POSTROUTING -s 10.99.0.0/16 -o awg+ -m comment --comment "awg-cascade-tunnel-masq" -j MASQUERADE

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
# Idempotent: удаляем по priority (все правила в этих "слотах"), потом ставим.
BOT_UID=\$(id -u $BOT_USER 2>/dev/null || echo 999)
for prio in 998 1000 1001; do
    while ip rule show priority \$prio 2>/dev/null | grep -q "^\$prio:"; do
        ip rule del priority \$prio 2>/dev/null || break
    done
done
ip rule add ipproto tcp dport 22 uidrange \$BOT_UID-\$BOT_UID lookup main priority 998
ip rule add fwmark 0x1 lookup 100 priority 1000
ip rule add uidrange \$BOT_UID-\$BOT_UID lookup 100 priority 1001
RULEEOF
chmod +x /usr/local/sbin/awg-cascade-iprule.sh

# systemd-юнит — применяет ip rules после network-online (иначе они теряются после ребута)
cat > /etc/systemd/system/awg-cascade-iprule.service <<EOF
[Unit]
Description=AWG Cascade ip rules (fwmark + uidrange policy routing)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/awg-cascade-iprule.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable awg-cascade-iprule.service >/dev/null 2>&1
ok "ip rule: SSH→eth0 (998), clients→ECMP (1000), bot→ECMP (1001) + systemd persist"

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

# Lock-файл должен быть world-writable — и bot (awgbot uid 999) и helper
# скрипты (root) должны мочь его открыть R/W для flock. Если кто-то первым
# создаст root-owned 644 — другой пользователь не сможет open() и получит
# PermissionError. Pre-создаём 0666 owned by awgbot.
touch "$CONFIG_DIR/state.lock"
chown "$BOT_USER:$BOT_USER" "$CONFIG_DIR/state.lock"
chmod 666 "$CONFIG_DIR/state.lock"
ok "state.lock pre-created с 0666 (shared между bot и root)"

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

# ═════════════════════════════════════════════════════════════════════════════
# Phase 8b: deploy watchdog + helper scripts
# ═════════════════════════════════════════════════════════════════════════════
header "8b. Deploy watchdog + helper-скрипты"

# REPO_DIR — куда install.sh положил исходники. Если setup.sh запустили
# напрямую (не через install.sh) — берём dirname текущего скрипта.
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
[ -d "$REPO_DIR/watchdog" ] || err "Не найдена директория $REPO_DIR/watchdog. Запусти через install.sh или из корня репо."
[ -d "$REPO_DIR/bot" ]      || err "Не найдена директория $REPO_DIR/bot"
[ -d "$REPO_DIR/systemd" ]  || err "Не найдена директория $REPO_DIR/systemd"

# Копируем все helper-скрипты в /usr/local/sbin (перетирая stub'ы и старые версии)
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-watchdog.sh          /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-watchdog-postboot.sh /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-iprule.sh            /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-peer-add.sh          /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-peer-remove.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-peer-rotate.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-exit-add-ru.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-exit-remove.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-exit-rotate.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-bootstrap-exit.sh    /usr/local/sbin/
ok "Helper-скрипты установлены в /usr/local/sbin/"

# Заодно положим setup-exit.sh — пригодится когда будем поднимать новый exit
install -m 755 "$REPO_DIR/setup-exit.sh" /usr/local/sbin/awg-cascade-setup-exit.sh
ok "setup-exit.sh доступен как /usr/local/sbin/awg-cascade-setup-exit.sh"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 8c: deploy Telegram bot + venv
# ═════════════════════════════════════════════════════════════════════════════
header "8c. Telegram бот (Python aiogram)"

mkdir -p "$BOT_DIR" "$BOT_DIR/scripts"
cp -r "$REPO_DIR/bot/." "$BOT_DIR/"
# Сносим __pycache__ на случай если он попал из репо
find "$BOT_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
ok "Bot файлы скопированы в $BOT_DIR"

# Bot при провижне exit'а SCP-ит эти 3 скрипта на новый сервер. Без них
# add-exit не работает.
install -m 755 "$REPO_DIR/setup-exit.sh"                  "$BOT_DIR/scripts/setup-exit.sh"
install -m 755 "$REPO_DIR/awg2-params.sh"                 "$BOT_DIR/scripts/awg2-params.sh"
install -m 755 "$REPO_DIR/exit-side/awg-cascade-exit-warp.sh" "$BOT_DIR/scripts/awg-cascade-exit-warp.sh"
ok "Exit-provisioning скрипты в $BOT_DIR/scripts/ (setup-exit, awg2-params, warp)"

chown -R "$BOT_USER:$BOT_USER" "$BOT_DIR"

# Python venv + зависимости
if [ ! -d "$BOT_DIR/venv" ]; then
    info "Создаю venv и ставлю зависимости (aiogram, asyncssh, qrcode)..."
    sudo -u "$BOT_USER" python3 -m venv "$BOT_DIR/venv"
    sudo -u "$BOT_USER" "$BOT_DIR/venv/bin/pip" install --quiet --upgrade pip
    sudo -u "$BOT_USER" "$BOT_DIR/venv/bin/pip" install --quiet -r "$BOT_DIR/requirements.txt"
    ok "venv готов: $BOT_DIR/venv"
else
    info "venv уже есть, обновляю зависимости..."
    sudo -u "$BOT_USER" "$BOT_DIR/venv/bin/pip" install --quiet --upgrade -r "$BOT_DIR/requirements.txt"
    ok "venv обновлён"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Phase 8d: systemd units (watchdog, postboot, bot) + старт
# ═════════════════════════════════════════════════════════════════════════════
header "8d. systemd units + запуск"

install -m 644 "$REPO_DIR/systemd/awg-cascade-watchdog.service" /etc/systemd/system/
install -m 644 "$REPO_DIR/systemd/awg-cascade-postboot.service" /etc/systemd/system/
install -m 644 "$REPO_DIR/systemd/awg-cascade-bot.service"      /etc/systemd/system/

# Logrotate (мог быть уже создан inline в Phase 2 — перетрём shipped версией если есть)
if [ -f "$REPO_DIR/systemd/awg-cascade.logrotate" ]; then
    install -m 644 "$REPO_DIR/systemd/awg-cascade.logrotate" /etc/logrotate.d/awg-cascade
fi

systemctl daemon-reload

# Watchdog — постоянный сервис
systemctl enable --now awg-cascade-watchdog.service >/dev/null 2>&1
sleep 1
if systemctl is-active --quiet awg-cascade-watchdog.service; then
    ok "awg-cascade-watchdog.service запущен"
else
    warn "Watchdog не стартанул, проверь: journalctl -u awg-cascade-watchdog -n 30"
fi

# Postboot — oneshot, сработает на следующем reboot (сейчас не запускаем)
systemctl enable awg-cascade-postboot.service >/dev/null 2>&1
ok "awg-cascade-postboot.service зарегистрирован (oneshot на boot)"

# Bot — постоянный сервис
systemctl enable --now awg-cascade-bot.service >/dev/null 2>&1
sleep 2
if systemctl is-active --quiet awg-cascade-bot.service; then
    ok "awg-cascade-bot.service запущен"
else
    warn "Bot не стартанул, проверь: journalctl -u awg-cascade-bot -n 30"
fi

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

# ═════════════════════════════════════════════════════════════════════════════
# Phase 10: bootstrap первого exit (опционально, интерактивно)
# ═════════════════════════════════════════════════════════════════════════════
# Нужно чтобы разорвать chicken-and-egg: бот в РФ не может выйти к Telegram пока
# нет ни одного exit. Подключаем первый exit прямо из CLI (бот сейчас может быть
# недоступен). Дальше остальные exits добавляются уже через UI бота.
header "10. Подключить первый exit (опционально)"

cat <<INTRO
Сейчас kill-switch активен — клиенты без интернета, и ${BOLD}бот может не отвечать${NC}
в Telegram (если этот RU в сети где Telegram заблокирован, egress идёт через exit).

Если у тебя уже есть рабочий exit (свежий Ubuntu ИЛИ exit от другого RU —
скрипт сам определит и создаст изолированный интерфейс) — подключи его сейчас.

Пропустить (добавить позже через бота) — просто нажми Enter.
INTRO
echo ""

prompt "IP первого exit-сервера (Enter — пропустить): "; read_tty BOOTSTRAP_EXIT_IP
if [ -n "$BOOTSTRAP_EXIT_IP" ]; then
    prompt "Имя exit'а (например NL-1): "; read_tty BOOTSTRAP_EXIT_NAME
    prompt "Root пароль exit-сервера: "
    if [ -r /dev/tty ] && [ -z "$BATCH" ]; then
        read -rs BOOTSTRAP_EXIT_PASS </dev/tty; echo ""
    else
        read -r BOOTSTRAP_EXIT_PASS || true
    fi

    if [ -n "$BOOTSTRAP_EXIT_NAME" ] && [ -n "$BOOTSTRAP_EXIT_PASS" ]; then
        EXIT_PASSWORD="$BOOTSTRAP_EXIT_PASS" \
            /usr/local/sbin/awg-cascade-bootstrap-exit.sh \
            "$BOOTSTRAP_EXIT_IP" "$BOOTSTRAP_EXIT_NAME" \
            || warn "Bootstrap exit'а не удался — добавишь позже через бота или повтори: awg-cascade-bootstrap-exit.sh"
    else
        warn "Имя или пароль пустые — пропускаю bootstrap exit'а"
    fi
else
    info "Exit не подключён. Добавь позже: ${BOLD}awg-cascade-bootstrap-exit.sh${NC} или через бота."
fi

header "Что дальше"

cat << NEXT
${GREEN}awg0 запущен${NC} — подключайся первым peer'ом ($FIRST_PEER).
${GREEN}Watchdog активен${NC} — мониторит handshake/ping exits и держит ECMP.
${GREEN}Telegram бот активен${NC} — напиши ему /start в Telegram чтобы открыть меню.

${YELLOW}ВАЖНО:${NC} если exit ещё не подключён — ${RED}kill-switch активен${NC}, клиенты без
интернета. Подключи exit одним из способов:
  • CLI (если бот недоступен): ${BOLD}awg-cascade-bootstrap-exit.sh${NC}
  • бот → 🌐 Exits → ➕ Add exit (IP + root пароль; fresh Ubuntu ИЛИ exit от другого RU).

Полезные команды на RU:
  ${BOLD}awg show${NC}                              статус awg0
  ${BOLD}cat $STATE_FILE${NC}             state каскада (JSON)
  ${BOLD}systemctl status awg-cascade-bot${NC}      бот
  ${BOLD}systemctl status awg-cascade-watchdog${NC} watchdog
  ${BOLD}journalctl -u awg-cascade-bot -f${NC}      логи бота вживую
  ${BOLD}tail -f /var/log/awg-cascade-watchdog.log${NC} логи watchdog'а

Обновление до новой версии репо:
  ${BOLD}cd /opt/awg-cascade-src && git pull && bash setup.sh${NC}
NEXT

echo ""
ok "Setup завершён. Файлы в $CONFIG_DIR/"
