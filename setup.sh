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

# REPO_DIR — где лежат исходники (install.sh кладёт в /opt/awg-cascade-src).
# Определяется ЗДЕСЬ, а не в Phase 8b: version-stamp пишется раньше, в Phase 7,
# и с необъявленной переменной `git -C ""` падал, а стамп получался "unknown ?".
# Валидация содержимого (наличие watchdog/, bot/, systemd/) осталась в Phase 8b.
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"

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
# Прошлый config читаем разбором, а не source: он принадлежит боту.
if [ -f "$CONFIG_FILE" ]; then
    . "$REPO_DIR/watchdog/awg-cascade-cfg.sh" && awgc_load_config "$CONFIG_FILE" || . "$CONFIG_FILE"
fi

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

# Ждём освобождения ВСЕХ четырёх apt-локов. ВАЖНО: /var/cache/apt/archives/lock
# тоже надо проверять — иначе apt-get падает на нём даже когда остальные свободны
# (apt-daily-upgrade на first-boot держит именно archives/lock при скачивании).
# После grace-периода держателей убиваем принудительно (provisioning, сервер наш).
APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
wait_apt_lock() {
    local max=600 elapsed=0 grace=120
    while fuser $APT_LOCKS >/dev/null 2>&1; do
        if [ $elapsed -ge $max ]; then
            err "apt lock не освободился за 10 минут (что-то странное на сервере)"
        fi
        if [ $elapsed -ge $grace ]; then
            warn "apt lock держится >${grace}s — убиваю держателей принудительно"
            fuser -k $APT_LOCKS 2>/dev/null || true
            sleep 3
            dpkg --configure -a 2>/dev/null || true
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

# ─── Привести образ к актуальному состоянию ──────────────────────────────────
#
# ЗАЧЕМ. До v2.2.1 здесь был только `apt-get update` — обновление ИНДЕКСА, а не
# пакетов. Дальше ставились нужные пакеты, включался unattended-upgrades, и на
# этом всё. Нода рождалась ровно такой, каким был образ хостера, и такой
# оставалась: unattended-upgrades по умолчанию берёт только карманы
# <release> и <release>-security, а накопившиеся исправления из
# <release>-updates не подтягивает НИКОГДА. Замерено на четырёх живых нодах:
# по 20-37 пакетов, висящих с момента установки.
#
# ИМЕННО `upgrade`, А НЕ `dist-upgrade`. Разница здесь принципиальная, а не
# стилистическая: `upgrade` обновляет только уже установленные пакеты и НЕ
# ставит новые, поэтому новое ABI ядра (это всегда НОВЫЙ пакет
# linux-image-X.Y.Z) он не тянет. Проверено на RU-1: upgrade = 36 обновлённых,
# 0 новых; dist-upgrade = 38 обновлённых и 20 НОВЫХ, включая ядро.
#
# Почему новое ядро тут недопустимо: amneziawg-dkms собирается под `uname -r`,
# то есть под ЗАПУЩЕННОЕ ядро. Поставить новое ядро до сборки модуля значит
# получить ноду, которая после первой же перезагрузки поднимается без
# amneziawg. Ядро приедет позже штатным путём — через unattended-upgrades,
# который дособирает DKMS, и перезагрузку в окно awg-cascade-autoreboot.sh.
#
# --force-confold: без него apt на изменённом конфиге задаёт вопрос и ждёт
# ответа вечно. Для setup-exit.sh это не теория — его запускает бот по SSH без
# терминала, и зависший вопрос означал бы провижининг, висящий до таймаута.
#
# AWGC_SKIP_UPGRADE=1 — аварийный выход, если образ заведомо свежий и дорога
# каждая минута.
if [ "${AWGC_SKIP_UPGRADE:-0}" = "1" ]; then
    warn "apt upgrade пропущен (AWGC_SKIP_UPGRADE=1)"
else
    _pending=$(apt-get -s -q upgrade 2>/dev/null | grep -cE '^Inst ' || true)
    if [ "${_pending:-0}" -gt 0 ]; then
        info "Обновляю пакеты образа: $_pending шт. (может занять несколько минут)..."
        wait_apt_lock
        # NEEDRESTART_MODE=a: на Ubuntu 24.04 needrestart по умолчанию
        # интерактивен и спрашивает, какие сервисы перезапустить. В
        # провижининге по SSH без терминала этот вопрос означает зависание до
        # таймаута. Здесь нода ещё пустая, перезапускать безопасно.
        NEEDRESTART_MODE=a apt-get -y -qq \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            upgrade >/dev/null \
            && ok "Пакеты обновлены ($_pending)" \
            || warn "apt upgrade завершился с ошибкой — проверь: apt-get upgrade"
    else
        ok "Пакеты образа уже актуальны"
    fi
fi

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
# Авто-ребут настраивается ПОЗЖЕ (Phase 8b) через awg-cascade-autoreboot.sh —
# он идемпотентен, знает про уникальное окно AUTO_REBOOT_HOUR и переприменяется
# из sync.sh. Здесь только включаем сам сервис обновлений.
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

# Sudoers. Список сведён к тому, что бот действительно вызывает.
#
# Было четыре строки с awg-quick, wg-quick, systemctl, ip, iptables и ip6tables
# БЕЗ аргументов, то есть с любыми. Обоснование звучало как «это выделенный
# appliance с нашим доверенным кодом» — но sudoers защищает не от нашего кода, а
# от захвата процесса бота, и при таком наборе разница между awgbot и root
# исчезала: `sudo systemctl link` на подсунутый юнит — уже произвольный root.
#
# По коду бот зовёт через sudo ровно три вещи: helper-скрипты, `awg show` и
# SIGUSR1 watchdog'у. ip/iptables/awg-quick он не вызывает вообще — helper'ы
# сами работают от root, им sudo не нужен. Поэтому здесь остаётся только это.
#
# Важно: этот блок ДОЛЖЕН совпадать с каноном в awg-cascade-sync.sh — синк
# приводит файл к своему варианту и стирает всё лишнее.
cat > /etc/sudoers.d/$BOT_USER <<SUDOEOF
# AWG Cascade Multi — bot privileges
# Чтение состояния туннелей (awg show <iface> dump).
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/awg show *
# Разбудить watchdog после смены pin/веса.
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl kill -s SIGUSR1 awg-cascade-watchdog
# Helper'ы каскада. Wildcard по имени — чтобы не ловить рассинхрон при
# добавлении нового helper'а; аргументы проверяет сам helper.
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

# gai.conf: предпочитать IPv4. Каскад IPv4-only; если у домена есть AAAA, а
# рабочего IPv6 нет — getaddrinfo вернёт IPv6 первым, и бот/клиент уйдут в
# несуществующий IPv6-маршрут (таймаут). Префер IPv4 это снимает.
grep -q "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null \
    || echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
ok "gai.conf: предпочтение IPv4 (каскад IPv4-only)"

# Легаси ifupdown (networking.service/ifup@) конфликтует с netplan/networkd:
# двойное управление eth0 → failed-юниты + риск reflush ip rules при триггере.
# Если eth0 ведёт networkd (есть netplan) — маскируем ifupdown, чтобы сетью
# рулил ТОЛЬКО networkd. mask сеть не рестартит, текущий eth0 не трогается.
if systemctl is-active --quiet systemd-networkd && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    systemctl mask networking.service ifup@eth0.service >/dev/null 2>&1 || true
    systemctl reset-failed networking.service ifup@eth0.service >/dev/null 2>&1 || true
    ok "ifupdown замаскирован (eth0 под управлением networkd/netplan)"
fi

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

# Идемпотентность: повторный запуск setup.sh (или install.sh, который делает
# exec setup.sh) НЕ должен перегенерировать серверный ключ и переписать awg0.conf
# — иначе ВСЕ существующие клиенты разом отвалятся, а awg0.conf схлопнется до
# одного first-peer. Если awg0 уже настроен — пропускаем Phase 5 целиком.
# Обновление кода/конфига на живой ноде идёт через awg-cascade-sync.sh, не тут.
if [ -f "$WG_DIR/awg0.conf" ]; then
    warn "awg0.conf уже существует — Phase 5 пропущена (ключи/пиры/peers.json не трогаю)"
else

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
# Имя профиля мимикрии — только для диагностики: по самой строке I1 глазами
# понять, чем притворяется декой, трудно, а знать это нужно при разборе
# блокировок («какие установки пережили фильтр»).
I1_PROFILE='$I1_PROFILE'
EOF
    chmod 600 "$CONFIG_DIR/awg2_params"
    chown "$BOT_USER:$BOT_USER" "$CONFIG_DIR/awg2_params"
    ok "Сгенерированы v2.0 params: S=$S1/$S2/$S3/$S4  H1=$H1  I1-профиль=$I1_PROFILE"
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
# MTU=1280: двойная инкапсуляция (awg0 inside awgN inside eth0) + AWG 2.0 обфускация
# съедает payload; 1280 эмпирически стабильнее на PPPoE/4G (= IPv6 min-MTU, безопасный минимум).
# DisableCookies на клиентском интерфейсе.
#
# Флаг отключает ответ cookie-reply под нагрузкой. Смысл — защита от активного
# зондирования: цензор может послать на подозрительный UDP-порт поток
# handshake'ов и опознать сервер по тому, что тот ответил cookie'ом. С флагом
# хост молчит, а порт awg0 торчит в интернет и принимает клиентов откуда угодно.
#
# Плата: вместе с cookie в ядре отключается и rate limiter (это один блок под
# IsUnderLoad), то есть флудом handshake'ов сервер можно заставить считать
# криптографию. Для клиентского порта размен принят.
#
# В клиентские конфиги строка НЕ попадает: это поведение отвечающей стороны,
# клиент о нём не знает, и добавление сломало бы совместимость с 3.0.
#
# Подставляем пустую строку, если tools не умеют: на старых пакетах awg setconf
# упал бы на незнакомом ключе и интерфейс не поднялся бы вовсе.
DC_LINE=""
awg set --help 2>&1 | grep -q "disable-cookies" && DC_LINE="DisableCookies = on"

cat > $WG_DIR/awg0.conf <<EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $AWG0_PORT
MTU = 1280
$DC_LINE
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
MTU = 1280
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

fi  # ── конец гарда идемпотентности Phase 5 (awg0.conf не существовал) ──

# ═════════════════════════════════════════════════════════════════════════════
# Phase 6: iptables (kill-switch + MARK + MASQUERADE)
# ═════════════════════════════════════════════════════════════════════════════
header "6. iptables (kill-switch + MARK)"

# Detect main interface
MAIN_IFACE=$(ip route show default 0.0.0.0/0 | head -1 | awk '/dev/ {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE="eth0"
ok "Main interface: $MAIN_IFACE"

# Скрипт применения правил — обычный helper из репо (watchdog/awg-cascade-iptables.sh),
# а не heredoc здесь. До v2.2 он генерировался инлайном и из-за этого не попадал
# ни в sync.sh, ни в drift-guard: правка firewall доезжала до ноды только
# повторным запуском этого installer'а.
#
# Ставим прямо тут, до первого запуска: общий список helper'ов идёт позже, в
# Phase 8, а правила нужны уже сейчас. Повторная установка там безвредна.
install -m 755 "$REPO_DIR/watchdog/awg-cascade-cfg.sh"      /usr/local/sbin/
install -m 755 "$REPO_DIR/watchdog/awg-cascade-iptables.sh" /usr/local/sbin/
install -m 755 "$REPO_DIR/watchdog/awg-cascade-client3-fw.sh"  /usr/local/sbin/ 2>/dev/null || true
install -m 755 "$REPO_DIR/watchdog/awg-cascade-interclient.sh" /usr/local/sbin/ 2>/dev/null || true

# Запустим прямо сейчас
/usr/local/sbin/awg-cascade-iptables.sh
ok "iptables правила применены"

# ─── ip rule для policy routing ──────────────────────────────────────────────
# fwmark 0x1 (клиенты awg0) → table 100 (ECMP exits)
# uidrange awgbot → table 100 (бот'трафик к Telegram через NL)
# Всё остальное (включая ntfy через --interface $MAIN_IFACE) → main table

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

# Config-файл бота.
#
# ВНИМАНИЕ при правке этого блока. setup.sh запускают повторно — для обновления
# или после смены параметров. Раньше файл перезаписывался фиксированным набором
# полей, и повторный запуск СНОСИЛ всё, чего в шаблоне нет:
#   • CLIENT3_IFACE/PORT/NET/NET_PREFIX/SERVER_IP — второй клиентский интерфейс
#     продолжал работать, но helper'ы переставали о нём знать: firewall wgc3 без
#     правил, peer-add без нужных параметров;
#   • HC_PING_URL, пороги алертов, срок хранения трафика, час авто-ребута —
#     обнулялись до дефолтов.
# Защита двухслойная: (1) настраиваемые поля берутся из уже загруженного config
# через ${VAR:-default}; (2) ниже идёт merge-проход, возвращающий ЛЮБЫЕ ключи,
# которых в шаблоне нет вообще. Второй слой важнее первого: он не требует
# помнить про новое поле при его добавлении.
[ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$CONFIG_FILE.prev"
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

# ─── Alerting (A) ───
# HC_PING_URL: создай check на healthchecks.io → вставь ping-URL (dead-man). Пусто = выкл.
HC_PING_URL="${HC_PING_URL:-}"
DISK_ALERT_PCT=${DISK_ALERT_PCT:-90}
RAM_ALERT_PCT=${RAM_ALERT_PCT:-90}
LOAD_ALERT_MULT=${LOAD_ALERT_MULT:-2}
SSH_ALERT=${SSH_ALERT:-1}

# ─── Traffic graphs (D) ───
# Сколько суток хранить историю трафика per-peer (72 часа — минимум метаданных).
TRAFFIC_RETENTION_DAYS=${TRAFFIC_RETENTION_DAYS:-3}

# ─── Auto-reboot после unattended-upgrades ───
# Срабатывает ТОЛЬКО при /var/run/reboot-required (обновление ядра), не ежедневно.
# AUTO_REBOOT_HOUR (UTC) должен быть УНИКАЛЕН на каждой ноде каскада — иначе
# несколько exits перезагрузятся одновременно → пустая ECMP → kill-switch.
# Применяется через awg-cascade-autoreboot.sh (вызывается из sync.sh guards).
AUTO_REBOOT=${AUTO_REBOOT:-1}
AUTO_REBOOT_HOUR="${AUTO_REBOOT_HOUR:-03}"
EOF

# Merge-проход: возвращаем ключи, которых в шаблоне выше нет вообще.
# Пример из жизни — CLIENT3_*: их пишет awg-cascade-client3.sh, setup про них
# не знает, и без этого прохода повторная установка их теряла.
if [ -f "$CONFIG_FILE.prev" ]; then
    _restored=""
    while IFS= read -r _line; do
        case "$_line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        _key=${_line%%=*}
        # Пробелы/табы в начале ключа = не присваивание, пропускаем
        case "$_key" in *[!A-Za-z0-9_]*) continue ;; esac
        if ! grep -q "^${_key}=" "$CONFIG_FILE"; then
            printf '%s
' "$_line" >> "$CONFIG_FILE"
            _restored="$_restored $_key"
        fi
    done < "$CONFIG_FILE.prev"
    if [ -n "$_restored" ]; then
        ok "Сохранены поля из прошлого config:$_restored"
    fi
    # Прошлая версия остаётся рядом до следующего запуска setup — если merge
    # что-то не так понял, откатиться можно копированием .prev на место.
    chmod 600 "$CONFIG_FILE.prev"
    chown "$BOT_USER:$BOT_USER" "$CONFIG_FILE.prev"
fi

chmod 600 "$CONFIG_FILE"
chown "$BOT_USER:$BOT_USER" "$CONFIG_FILE"
ok "Config файл сохранён: $CONFIG_FILE"

# version-stamp — какой ref/commit развёрнут (для drift-guard и бота)
_VER=$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null || echo "unknown")
_COMMIT=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "?")
printf '%s %s %s\n' "$_VER" "$_COMMIT" "$(date -Iseconds)" > /etc/awg-cascade/version
ok "Version-stamp: $_VER ($_COMMIT)"

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

# REPO_DIR задан в блоке констант (нужен уже в Phase 7 для version-stamp).
# Здесь только проверяем, что там действительно исходники репо.
[ -d "$REPO_DIR/watchdog" ] || err "Не найдена директория $REPO_DIR/watchdog. Запусти через install.sh или из корня репо."
[ -d "$REPO_DIR/bot" ]      || err "Не найдена директория $REPO_DIR/bot"
[ -d "$REPO_DIR/systemd" ]  || err "Не найдена директория $REPO_DIR/systemd"

# Копируем все helper-скрипты в /usr/local/sbin (перетирая stub'ы и старые версии)
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-cfg.sh               /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-iptables.sh          /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-watchdog.sh          /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-watchdog-postboot.sh /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-iprule.sh            /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-interclient.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-alert.sh             /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-ssh-alert.sh         /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-selftest.sh          /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-sync.sh             /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-traffic-sample.sh    /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-backup.sh            /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-autoreboot.sh        /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-fail2ban.sh         /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-awg3.sh              /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-kernel-check.sh      /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-ssh-harden.sh        /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-client3.sh           /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-client3-fw.sh        /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-peer-add.sh          /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-peer-remove.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-peer-rotate.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-exit-add-ru.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-exit-reserve.sh      /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-exit-remove.sh       /usr/local/sbin/
install -m 755 "$REPO_DIR"/watchdog/awg-cascade-bootstrap-exit.sh    /usr/local/sbin/
ok "Helper-скрипты установлены в /usr/local/sbin/"

# Авто-ребут после unattended-upgrades (окно AUTO_REBOOT_HOUR из config).
# ВАЖНО: час должен быть уникален на каждой ноде каскада — см. комментарий в config.
/usr/local/sbin/awg-cascade-autoreboot.sh >/dev/null 2>&1 \
    && ok "Авто-ребут: $(/usr/local/sbin/awg-cascade-autoreboot.sh --show | awk -F= '/Reboot-Time/{print $2}')" \
    || warn "Авто-ребут не настроен (проверь: awg-cascade-autoreboot.sh --show)"

# fail2ban: не защита от подбора (вход по паролю отключён), а способ перестать
# тратить CPU и журнал на сканеров — их около 4 тысяч в сутки на ноду. Скрипт
# сам собирает ignoreip из живого состояния, чтобы бан RU-адреса на exit-е не
# отнял у бота управление этим exit-ом.
/usr/local/sbin/awg-cascade-fail2ban.sh >/dev/null 2>&1 \
    && ok "fail2ban настроен" \
    || warn "fail2ban не настроен (проверь: awg-cascade-fail2ban.sh)"

# SSH: отключаем вход по паролю — свежая нода иначе сразу тонет в брутфорсе.
# Скрипт сам пропустит шаг, если в authorized_keys нет ключей (чтобы не запереть).
/usr/local/sbin/awg-cascade-ssh-harden.sh 2>&1 | sed 's/^/  /'

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
# Комплект, который бот и bootstrap-exit.sh SCP-ят на новый exit. Список ДОЛЖЕН
# совпадать с одноимённым блоком в awg-cascade-sync.sh: он там уже расходился —
# fail2ban был в sync и отсутствовал здесь, поэтому свежепоставленная RU молча
# отдавала на новый exit комплект без fail2ban (передача условная, `[ -f ]`).
install -m 755 "$REPO_DIR/setup-exit.sh"                      "$BOT_DIR/scripts/setup-exit.sh"
install -m 755 "$REPO_DIR/awg2-params.sh"                     "$BOT_DIR/scripts/awg2-params.sh"
install -m 755 "$REPO_DIR/exit-side/awg-cascade-exit-warp.sh" "$BOT_DIR/scripts/awg-cascade-exit-warp.sh"
install -m 755 "$REPO_DIR/watchdog/awg-cascade-ssh-harden.sh" "$BOT_DIR/scripts/awg-cascade-ssh-harden.sh"
install -m 755 "$REPO_DIR/watchdog/awg-cascade-fail2ban.sh"   "$BOT_DIR/scripts/awg-cascade-fail2ban.sh"
# Комплект неполон -> новый exit получит не то, что задумано. Это не warn.
for _f in setup-exit.sh awg2-params.sh awg-cascade-exit-warp.sh           awg-cascade-ssh-harden.sh awg-cascade-fail2ban.sh; do
    [ -x "$BOT_DIR/scripts/$_f" ] || err "provisioning-комплект неполон: нет $_f"
done
ok "Exit-provisioning комплект в $BOT_DIR/scripts/ (5 скриптов, проверен)"

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

# Ставим ВСЁ из systemd/ глобом, как это делает sync.sh, а не поимённым списком.
# Поимённый список пропускал awg-cascade-backup.service и .timer: юниты лежали в
# репо, setup их не ставил, и свежая нода до первого sync жила вообще без
# ежедневного бэкапа — при этом выглядела установленной.
for _u in "$REPO_DIR"/systemd/awg-cascade-*.service "$REPO_DIR"/systemd/awg-cascade-*.timer; do
    [ -e "$_u" ] || continue
    install -m 644 "$_u" /etc/systemd/system/
done
ok "systemd-юниты установлены: $(ls -1 "$REPO_DIR"/systemd/awg-cascade-*.service "$REPO_DIR"/systemd/awg-cascade-*.timer 2>/dev/null | wc -l)"

# SSH-логин алерт (pam_exec hook). optional = вход не блокируется если скрипт
# отсутствует/упал. Только интерактив (pts), дедуп per user@host.
if ! grep -q "awg-cascade-ssh-alert" /etc/pam.d/sshd 2>/dev/null; then
    echo "session    optional   pam_exec.so /usr/local/sbin/awg-cascade-ssh-alert.sh" >> /etc/pam.d/sshd
    ok "SSH-login алерт добавлен в /etc/pam.d/sshd"
fi

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

# Таймеры. Файл на месте, а таймер выключен — самый тихий способ остаться без
# бэкапов: ошибок нет, drift нет, архивов нет.
for _t in "$REPO_DIR"/systemd/awg-cascade-*.timer; do
    [ -e "$_t" ] || continue
    _tb=$(basename "$_t")
    if systemctl enable --now "$_tb" >/dev/null 2>&1 && systemctl is-active --quiet "$_tb"; then
        ok "таймер активен: $_tb"
    else
        warn "таймер НЕ включился: $_tb (проверь: systemctl status $_tb)"
    fi
done

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

# При повторном запуске Phase 5 пропущена гардом идемпотентности, поэтому
# FIRST_PEER/PEER_IP/CLIENT_CONF/SERVER_PUBKEY не заданы. Раньше здесь безусловно
# выполнялось `qrencode < "$CLIENT_CONF"` с пустым именем файла — редирект падал,
# а из-за `set -e` скрипт обрывался ДО Phase 10 (bootstrap первого exit) и до
# финальных инструкций. То есть повторный запуск, который README называет
# безопасным, всегда заканчивался ошибкой.
if [ -n "${CLIENT_CONF:-}" ] && [ -f "${CLIENT_CONF:-}" ]; then
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
else
    info "Phase 5 была пропущена (нода уже настроена) — QR первого peer'а не выводим."
    echo "  Конфиги существующих пиров: ${BOLD}ls $PEERS_DIR/${NC}"
    echo "  Или через бота: 👤 Peers → выбрать пира → 📱 QR / 📄 Конфиг"
    echo ""
fi

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

Обновление живой ноды — ТОЛЬКО через drift-guard, не повторным setup.sh:
  ${BOLD}awg-cascade-sync.sh --check${NC}          показать дрейф от репо
  ${BOLD}awg-cascade-sync.sh${NC}                  привести ноду к последнему тегу
NEXT

echo ""
ok "Setup завершён. Файлы в $CONFIG_DIR/"
