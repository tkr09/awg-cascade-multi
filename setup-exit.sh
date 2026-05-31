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

# ─── SHARED_MODE detection ────────────────────────────────────────────────────
# Если на сервере уже стоит amneziawg и есть primary awg-in.conf — значит этот
# exit уже принадлежит другому RU. Тогда мы НЕ переустанавливаем пакеты, НЕ
# трогаем awg-in, а создаём дополнительный изолированный интерфейс awg-in-<N>
# с собственным портом 51920+N и tunnel 10.99.<100+N>.0/30.
SHARED_MODE=0
IFACE_NAME="awg-in"
if command -v awg >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg-in.conf ]; then
    SHARED_MODE=1
    # Найти свободный slot 2..99
    SHARED_N=2
    while [ -f "$WG_DIR/awg-in-$SHARED_N.conf" ] || ip link show "awg-in-$SHARED_N" &>/dev/null; do
        SHARED_N=$((SHARED_N + 1))
        [ $SHARED_N -gt 99 ] && err "Нет свободных awg-in-<N> slots (заняты 2..99)"
    done
    IFACE_NAME="awg-in-$SHARED_N"
    EXIT_PORT=$((51920 + SHARED_N))
    # Tunnel /30 octet. КЛЮЧЕВОЕ: октет ДОЛЖЕН быть уникален на стороне RU
    # (иначе у RU несколько awgN с одинаковым Address). Поэтому RU передаёт
    # предпочитаемый октет = 100 + его EXIT_INDEX (уникален среди интерфейсов RU).
    # На стороне exit сканируем вверх от предпочитаемого до первого свободного
    # (на случай если другой RU уже занял этот октет на этом же exit).
    TUNNEL_OCTET="${RU_TUNNEL_OCTET:-$((100 + SHARED_N))}"
    while ip -br addr show 2>/dev/null | grep -qE "[[:space:]]10\.99\.${TUNNEL_OCTET}\."; do
        TUNNEL_OCTET=$((TUNNEL_OCTET + 1))
        [ "$TUNNEL_OCTET" -gt 250 ] && err "Нет свободных tunnel-октетов 10.99.X на exit"
    done
    TUNNEL_NET="10.99.${TUNNEL_OCTET}.0/30"
    EXIT_TUNNEL_IP="10.99.${TUNNEL_OCTET}.1"
    RU_TUNNEL_IP="10.99.${TUNNEL_OCTET}.2"
    warn "SHARED MODE — exit уже занят другим RU."
    info "Создаю изолированный интерфейс $IFACE_NAME на порту $EXIT_PORT, tunnel $TUNNEL_NET"
fi

info "EXIT_INDEX=$EXIT_INDEX  iface=$IFACE_NAME  port=$EXIT_PORT  tunnel=$TUNNEL_NET  shared=$SHARED_MODE"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: пакеты (skip в SHARED_MODE — всё уже установлено primary RU)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$SHARED_MODE" = "1" ]; then
    ok "Skip Phase 2 (пакеты): amneziawg уже установлен"
else
header "Установка пакетов"

export DEBIAN_FRONTEND=noninteractive

# На fresh Ubuntu cloud-init запускает unattended-upgrades сразу после boot.
# Это держит /var/lib/dpkg/lock-frontend 5-10 минут и валит setup-exit.sh
# с "Could not get lock". Гасим apt-сервисы перед нашими apt-операциями.
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

# Восстановление после прерванной установки (например SSH-обрыв в прошлый раз):
# dpkg может застрять в half-configured. Идемпотентно, no-op если всё чисто.
dpkg --configure -a 2>/dev/null || true

apt-get update -qq

if ! command -v awg &>/dev/null; then
    wait_apt_lock
    apt-get install -y -qq software-properties-common >/dev/null
    wait_apt_lock
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
    wait_apt_lock
    apt-get update -qq
    wait_apt_lock
    apt-get install -y -qq linux-headers-$(uname -r) >/dev/null
    wait_apt_lock
    apt-get install -y -qq amneziawg amneziawg-dkms amneziawg-tools >/dev/null
fi

wait_apt_lock
apt-get install -y -qq iptables-persistent curl jq \
    unattended-upgrades apt-listchanges >/dev/null

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

modprobe amneziawg || err "Модуль amneziawg не загружается"
ok "amneziawg готов"
fi  # end Phase 2 (skip в SHARED_MODE)

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

# Per-interface файлы. В SHARED_MODE — суффикс по имени интерфейса, чтобы
# не затереть ключи/параметры primary awg-in (он принадлежит другому RU).
KEY_PRIV="$CONFIG_DIR/private.key"
KEY_PUB="$CONFIG_DIR/public.key"
PARAMS_FILE="$CONFIG_DIR/awg2_params"
if [ "$SHARED_MODE" = "1" ]; then
    KEY_PRIV="$CONFIG_DIR/private-$IFACE_NAME.key"
    KEY_PUB="$CONFIG_DIR/public-$IFACE_NAME.key"
    PARAMS_FILE="$CONFIG_DIR/awg2_params-$IFACE_NAME"
fi

# Если уже есть ключ для этого интерфейса — не перетираем
if [ -f "$KEY_PRIV" ]; then
    EXIT_PRIVKEY=$(cat "$KEY_PRIV")
    EXIT_PUBKEY=$(echo "$EXIT_PRIVKEY" | awg pubkey)
    ok "Используем существующие ключи для $IFACE_NAME"
else
    EXIT_PRIVKEY=$(awg genkey)
    EXIT_PUBKEY=$(echo "$EXIT_PRIVKEY" | awg pubkey)
    echo "$EXIT_PRIVKEY" > "$KEY_PRIV"
    echo "$EXIT_PUBKEY"  > "$KEY_PUB"
    chmod 600 "$KEY_PRIV"
    ok "Сгенерированы новые ключи для $IFACE_NAME"
fi

# v2.0 параметры (S1-S4 random, H1-H4 monotonic ranges, I1 DNS-iCloud).
# Если уже сохранены для этого интерфейса — берём существующие (постоянство).
if [ ! -f "$PARAMS_FILE" ]; then
    # Ищем awg2-params.sh в /tmp (положил бот) или рядом со setup-exit.sh
    AWG2_PARAMS_FILE=""
    for cand in /tmp/awg2-params.sh "$(dirname "$0")/awg2-params.sh"; do
        [ -f "$cand" ] && AWG2_PARAMS_FILE="$cand" && break
    done
    [ -z "$AWG2_PARAMS_FILE" ] && err "awg2-params.sh не найден (положи в /tmp/ или рядом с setup-exit.sh)"

    . "$AWG2_PARAMS_FILE"
    cat > "$PARAMS_FILE" <<EOF
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
    chmod 600 "$PARAMS_FILE"
fi
. "$PARAMS_FILE"

MAIN_IFACE=$(ip route show default 0.0.0.0/0 | head -1 | awk '/dev/ {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE="eth0"

# awg-in.conf — приём от RU
PSK_LINE=""
[ -n "$RU_PSK" ] && PSK_LINE="PresharedKey = $RU_PSK"

# MASQUERADE: в shared-режиме скопируем по source tunnel-net (не blanket),
# чтобы не дублировать blanket-правило primary awg-in.
if [ "$SHARED_MODE" = "1" ]; then
    MASQ_UP="iptables -t nat -A POSTROUTING -s $TUNNEL_NET -o $MAIN_IFACE -j MASQUERADE"
    MASQ_DOWN="iptables -t nat -D POSTROUTING -s $TUNNEL_NET -o $MAIN_IFACE -j MASQUERADE"
else
    MASQ_UP="iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE"
    MASQ_DOWN="iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE"
fi

cat > $WG_DIR/$IFACE_NAME.conf <<EOF
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
PostUp   = $MASQ_UP
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = $MASQ_DOWN
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

[Peer]
# RU entry server
PublicKey = $RU_PUBKEY
$PSK_LINE
AllowedIPs = $RU_TUNNEL_IP/32
PersistentKeepalive = 25
EOF
chmod 600 $WG_DIR/$IFACE_NAME.conf
ok "$WG_DIR/$IFACE_NAME.conf создан"

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

header "Запуск awg-quick@$IFACE_NAME"

systemctl enable "awg-quick@$IFACE_NAME" >/dev/null 2>&1
systemctl restart "awg-quick@$IFACE_NAME"
sleep 1
systemctl is-active --quiet "awg-quick@$IFACE_NAME" || {
    journalctl -u "awg-quick@$IFACE_NAME" -n 20 --no-pager >&2
    err "awg-quick@$IFACE_NAME не запустился"
}
ok "$IFACE_NAME активен на $EXIT_PORT/udp"

# Persist iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════════
# Phase 7: info JSON (для бота / RU-стороны)
# ═════════════════════════════════════════════════════════════════════════════

# В SHARED_MODE пишем info в per-interface файл, чтобы не затереть primary info.json
[ "$SHARED_MODE" = "1" ] && STATE_FILE="$CONFIG_DIR/info-$IFACE_NAME.json"

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
    --arg exitiface  "$IFACE_NAME" \
    --argjson shared "$SHARED_MODE" \
    --arg h1         "$H1" --arg h2 "$H2" --arg h3 "$H3" --arg h4 "$H4" \
    --argjson s1     "$S1" --argjson s2 "$S2" --argjson s3 "$S3" --argjson s4 "$S4" \
    --arg i1         "$I1" \
    --arg t          "$(date -Iseconds)" \
    '{
        schema: 2,
        exit_index: $idx, exit_public_ip: $pip, exit_pubkey: $pub, exit_port: $port,
        exit_tunnel_ip: $etip, ru_tunnel_ip: $rtip, tunnel_net: $net, main_iface: $iface,
        exit_iface: $exitiface, shared_mode: $shared,
        h_params: {H1: $h1, H2: $h2, H3: $h3, H4: $h4},
        s_params: {S1: $s1, S2: $s2, S3: $s3, S4: $s4},
        i_params: {I1: $i1},
        warp_state: "off", installed_at: $t
    }' > "$STATE_FILE"
chmod 644 "$STATE_FILE"

# Вывод JSON на stdout (бот парсит)
header "Готово. JSON для RU:"
cat "$STATE_FILE"
