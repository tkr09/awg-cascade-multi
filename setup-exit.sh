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

# Persist the operation identity; retries reuse the original interface and keys.
exec 8>/run/awg-cascade-provision.lock
flock -w 30 -x 8 || err "На этом exit уже идёт другая операция провижининга"
OP_ID=$(printf '%s' "$RU_PUBLIC_IP:$RU_PUBKEY" | sha256sum | awk '{print $1}')
OP_DIR=/etc/awg-cascade-exit/operations
install -d -m 700 "$OP_DIR"
if [ -f "$OP_DIR/$OP_ID.done" ]; then cat "$OP_DIR/$OP_ID.done"; exit 0; fi

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
    while ip -br addr show 2>/dev/null | grep -qE "[[:space:]]10\.99\.${TUNNEL_OCTET}\." || \
        grep -Fq "10.99.${TUNNEL_OCTET}.0/30" <<<"${RU_USED_TUNNELS:-}"; do
        TUNNEL_OCTET=$((TUNNEL_OCTET + 1))
        [ "$TUNNEL_OCTET" -le 250 ] || err "Нет свободной подсети туннеля, общей для обеих сторон"
    done
    TUNNEL_NET="10.99.${TUNNEL_OCTET}.0/30"
    EXIT_TUNNEL_IP="10.99.${TUNNEL_OCTET}.1"
    RU_TUNNEL_IP="10.99.${TUNNEL_OCTET}.2"
    warn "SHARED MODE — exit уже занят другим RU."
    info "Создаю изолированный интерфейс $IFACE_NAME на порту $EXIT_PORT, tunnel $TUNNEL_NET"
fi

if [ -f "$OP_DIR/$OP_ID.plan" ]; then
    read -r IFACE_NAME EXIT_PORT TUNNEL_NET EXIT_TUNNEL_IP RU_TUNNEL_IP SHARED_MODE < "$OP_DIR/$OP_ID.plan"
else
    printf '%s %s %s %s %s %s\n' "$IFACE_NAME" "$EXIT_PORT" "$TUNNEL_NET" "$EXIT_TUNNEL_IP" "$RU_TUNNEL_IP" "$SHARED_MODE" > "$OP_DIR/$OP_ID.plan"
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

# Pause timers only; never kill dpkg/apt or stop an in-flight package job.
AWGC_APT_TIMERS=()
awgc_restore_apt() {
    local t
    for t in "${AWGC_APT_TIMERS[@]}"; do systemctl start "$t" || return 1; done
    AWGC_APT_TIMERS=()
}
awgc_install_exit() {
    local rc=$?
    trap - EXIT
    awgc_restore_apt || rc=1
    exit "$rc"
}
trap awgc_install_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
for t in apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-active --quiet "$t"; then
        AWGC_APT_TIMERS+=("$t")
        systemctl stop "$t" || err "Не удалось остановить таймер $t"
    fi
done
APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
wait_apt_lock() {
    local elapsed=0
    while fuser $APT_LOCKS >/dev/null 2>&1; do
        [ "$elapsed" -lt 600 ] || err "apt занят дольше 600 с — пакетные процессы оставлены работать"
        sleep 5; elapsed=$((elapsed + 5))
    done
}
wait_apt_lock
dpkg --configure -a || err "dpkg --configure -a не отработал"
[ -z "$(dpkg --audit)" ] || err "dpkg --audit нашёл недонастроенные пакеты"

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
# ЧТО ИМЕННО ОБНОВЛЯЕМ — зависит от того, чистая нода или действующая.
#
# ЧИСТАЯ — `dist-upgrade`, вместе с ядром. Образы хостеров отстают не на
# проценты: HOSTKEY отдаёт Ubuntu 24.04 с ядром 6.8.0-36 при 6.8.0-139 в apt,
# то есть сотня ABI-ревизий и все накопившиеся в них дыры. `upgrade` не закроет
# это никогда — он принципиально не ставит НОВЫЕ пакеты, а ядро всегда приходит
# новым пакетом linux-image-X.Y.Z. Замерено на RU-1: upgrade = 36 обновлённых и
# 0 новых, dist-upgrade = 38 обновлённых и 20 новых, включая ядро.
#
# ДЕЙСТВУЮЩАЯ — только `upgrade`. Там смена ядра это не установка, а операция с
# окном и перезагрузкой: за ней следит awg-cascade-kernel-check.sh, и делать её
# молча, внутри обновления пакетов, на ноде с живыми клиентами нельзя.
#
# ПОЧЕМУ ЯДРО БЫЛО ЗАПРЕЩЕНО ЗДЕСЬ И ПОЧЕМУ РАЗРЕШЕНО ТЕПЕРЬ. amneziawg-dkms
# собирает модуль под ЗАПУЩЕННОЕ ядро. Поставить новое ядро раньше сборки
# модуля значило получить ноду, которая после первой же перезагрузки
# поднимается без amneziawg. Это по-прежнему так — ровно до тех пор, пока
# модуль собирают под одно ядро. Теперь ставятся заголовки под ВСЕ
# установленные ядра, модуль собирается под каждое (awgc_dkms_all_kernels
# ниже), а перезагрузка в новое ядро происходит в конце установки, когда
# модуль под него уже готов. Запрет снят не потому, что опасность выдумали,
# а потому что её устранили.
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
    # Чистая нода — та, где нашего каскада нет ни в одной из двух ролей.
    #
    # Признак снимается ЗДЕСЬ и живёт до конца скрипта. Ниже установка сама
    # создаст /etc/awg-cascade/version, и повторная проверка в конце сочла бы
    # ноду действующей. От признака зависит не только режим apt, но и право на
    # автоматическую перезагрузку в конце: на действующей ноде её быть не должно.
    AWGC_FRESH=1
    if [ -f /etc/awg-cascade/version ] || [ -f /etc/awg-cascade-exit/info.json ]; then AWGC_FRESH=0; fi
    if [ "$AWGC_FRESH" = 0 ]; then
        _upg_mode="upgrade";      _upg_what="пакеты образа (нода действующая — ядро не трогаю)"
    else
        _upg_mode="dist-upgrade"; _upg_what="пакеты образа вместе с ядром"
    fi
    # needrestart на Ubuntu 24.04 интерактивен по умолчанию, и NEEDRESTART_MODE=a
    # снимает только вопрос «какие сервисы перезапустить». ОТДЕЛЬНО от него есть
    # экран «Pending kernel upgrade», который показывается при установке нового
    # ядра и ждёт Enter — то есть ровно в том случае, ради которого мы сюда и
    # шли. Через env его не закрыть, только конфигом. В провижининге по SSH без
    # терминала этот экран означал бы зависание до таймаута.
    #
    # Файл остаётся на ноде намеренно: он же спасает от зависания
    # unattended-upgrades. reboot-required при этом продолжает выставляться,
    # и awg-cascade-autoreboot.sh его видит — гасится диалог, а не сигнал.
    mkdir -p /etc/needrestart/conf.d
    cat > /etc/needrestart/conf.d/99-awg-cascade.conf <<'NRCONF'
# Ставит установщик awg-cascade: провижининг идёт без терминала,
# любой интерактивный экран здесь — это зависание до таймаута.
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
NRCONF

    _pending=$(apt-get -s -q "$_upg_mode" 2>/dev/null | grep -cE '^Inst ' || true)
    if [ "${_pending:-0}" -gt 0 ]; then
        info "Обновляю $_upg_what: $_pending шт. (может занять несколько минут)..."
        wait_apt_lock
        # NEEDRESTART_MODE=a: на Ubuntu 24.04 needrestart по умолчанию
        # интерактивен и спрашивает, какие сервисы перезапустить. В
        # провижининге по SSH без терминала этот вопрос означает зависание до
        # таймаута. Здесь нода ещё пустая, перезапускать безопасно.
        if NEEDRESTART_MODE=a apt-get -y -qq \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                "$_upg_mode" >/dev/null; then
            ok "Обновлено пакетов: $_pending"
        else
            # Ненулевой код здесь ЧАЩЕ ВСЕГО не означает сломанный apt.
            # Постинсталл-скрипты пытаются ЗАПУСТИТЬ сервисы, и часть из них
            # на виртуалке не стартует в принципе: fwupd — демон обновления
            # прошивок, а прошивок у VPS нет. Пакет при этом распакован и
            # настроен. Валить из-за этого установку нельзя, но и молча
            # считать успехом тоже.
            warn "apt upgrade вернул ошибку — до-настраиваю пакеты"
            dpkg --configure -a || err "dpkg --configure -a не отработал при восстановлении"
            [ -z "$(dpkg --audit)" ] || err "dpkg --audit нашёл недонастроенные пакеты после восстановления"
            if apt-get -s -q -y check >/dev/null 2>&1; then
                warn "Зависимости пакетов целы, но upgrade не прошёл — нужен повтор"
                exit 1
            else
                err "apt остался в нерабочем состоянии. Почини вручную и повтори:
     apt-get -f install; dpkg --configure -a"
            fi
        fi
    else
        ok "Пакеты образа уже актуальны"
    fi
fi

# ─── Ядро: модуль нужен под то ядро, которое ЗАПУСТИТСЯ ──────────────────────
#
# dist-upgrade выше мог поставить новое ядро. Работать оно начнёт только после
# перезагрузки, а до неё `uname -r` показывает старое — и сборка «под uname -r»
# дала бы ноду, которая после ребута грузится без amneziawg. Ровно этот сценарий
# и был причиной запрета на dist-upgrade.
#
# Отсюда два правила ниже: заголовки ставим под ВСЕ установленные ядра, модуль
# собираем под каждое. Проверка идёт по НОВЕЙШЕМУ ядру — именно оно запустится.
AWGC_KERNEL_RUNNING="$(uname -r)"
AWGC_KERNEL_NEWEST="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)"
[ -z "$AWGC_KERNEL_NEWEST" ] && AWGC_KERNEL_NEWEST="$AWGC_KERNEL_RUNNING"

# Собрать модуль под все установленные ядра. Вызывается сразу после установки
# amneziawg-dkms: к этому моменту исходники модуля на месте.
awgc_kernel_ready() {
    local k="$1" module
    module=$(modinfo -k "$k" -n amneziawg 2>/dev/null) || return 1
    [ -f "$module" ] || return 1
    if command -v dkms >/dev/null 2>&1 && dkms status -m amneziawg -k "$k" 2>/dev/null | grep -q .; then
        dkms status -m amneziawg -k "$k" 2>/dev/null | awk -F', ' -v k="$k" '
            $2 == k && $3 ~ /: installed$/ {ok=1} END {exit !ok}' || return 1
    fi
}
awgc_dkms_all_kernels() {
    local k built=""
    for k in $(ls -1 /lib/modules | sort -V); do
        [ -e "/boot/vmlinuz-$k" ] || continue
        if ! awgc_kernel_ready "$k"; then
            command -v dkms >/dev/null 2>&1 || { warn "Для ядра $k нет ни модуля, ни dkms"; return 1; }
            if [ ! -d "/lib/modules/$k/build" ]; then
                wait_apt_lock
                apt-get install -y -qq "linux-headers-$k" >/dev/null || return 1
            fi
            dkms autoinstall -k "$k" || return 1
            awgc_kernel_ready "$k" || { warn "Модуль не установлен для ядра $k"; return 1; }
        fi
        built="$built $k"
    done
    awgc_kernel_ready "$AWGC_KERNEL_RUNNING" || return 1
    echo "${built# }"
}

if [ "$AWGC_KERNEL_NEWEST" != "$AWGC_KERNEL_RUNNING" ]; then
    warn "Новое ядро: $AWGC_KERNEL_RUNNING → $AWGC_KERNEL_NEWEST"
    info "Модуль соберу под оба; перезагрузка в новое ядро — в конце установки"
fi


# ─── fwupd на виртуалке ──────────────────────────────────────────────────────
#
# fwupd — демон обновления ПРОШИВОК. У виртуальной машины прошивок нет, и он
# падает при каждом запуске: сначала в постинсталле apt (это видно как
# «Job for fwupd.service failed»), потом висит в systemctl --failed навсегда.
# Это не наша поломка, но она создаёт ровно тот шум, из-за которого перестают
# читать список упавших юнитов — а там могут оказаться наши.
#
# Маскируем ТОЛЬКО на виртуалке и только сам fwupd: на железе он осмыслен.
if systemd-detect-virt --quiet 2>/dev/null; then
    if systemctl list-unit-files fwupd.service >/dev/null 2>&1; then
        systemctl stop fwupd.service >/dev/null 2>&1 || true
        systemctl mask fwupd.service fwupd-refresh.service >/dev/null 2>&1 || true
        systemctl reset-failed fwupd.service >/dev/null 2>&1 || true
        ok "fwupd замаскирован (виртуалка: $(systemd-detect-virt 2>/dev/null), прошивок нет)"
    fi
fi

# ─── Двойное управление сетью в образе хостера ───────────────────────────────
#
# Наблюдалось на HOSTKEY: SolusVM кладёт в /etc/network/interfaces статику для
# eth0, а cloud-init — netplan с DHCP. Адрес выдаёт networkd, после чего
# ifupdown пытается присвоить тот же адрес второй раз и падает с «Address
# already assigned». Каждую загрузку в systemctl --failed висят
# networking.service и ifup@<iface>. Сеть при этом работает.
#
# Чиним по той же причине, что и fwupd выше: постоянный красный список — это
# то, из-за чего перестают замечать настоящие аварии.
#
# Трогаем ТОЛЬКО когда доказано, что ifupdown здесь лишний:
#   • интерфейс сейчас настроен systemd-networkd из netplan-файла;
#   • маршрут по умолчанию идёт через него и получен по DHCP, то есть не от
#     ifupdown;
#   • юнит ifupdown для этого интерфейса действительно в failed.
# Не совпало хоть одно — не делаем НИЧЕГО. Остаться с красным юнитом лучше,
# чем с недоступной нодой, до которой ехать через консоль хостера.
#
# disable недостаточно: ifup@<iface> запускает udev при появлении интерфейса,
# поэтому именно mask. Проверено перезагрузкой: после disable юнит вернулся в
# failed, после mask — нет.
_net_if=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "${_net_if:-}" ] \
   && command -v networkctl >/dev/null 2>&1 \
   && networkctl status "$_net_if" 2>/dev/null | grep -q '/run/systemd/network/.*netplan' \
   && ip route show default 2>/dev/null | grep -q 'proto dhcp' \
   && systemctl is-failed --quiet "ifup@${_net_if}.service" 2>/dev/null; then
    [ -f /etc/network/interfaces ] && cp -a /etc/network/interfaces /etc/network/interfaces.bak-awgc
    systemctl mask "ifup@${_net_if}.service" >/dev/null 2>&1 || true
    systemctl disable --now networking.service >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
    ok "Сеть: снят конфликт ifupdown/netplan на $_net_if (адрес держит networkd)"
fi

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

# ─── Модуль под ВСЕ установленные ядра ───────────────────────────────────────
#
# Загрузка модуля доказывает только то, что он есть под ТЕКУЩЕЕ ядро. Если выше
# приехало новое, после перезагрузки нода поднимется без amneziawg — то есть без
# каскада вообще, и чинить это придётся с консоли хостера. Поэтому собираем под
# каждое установленное ядро и ОТДЕЛЬНО проверяем новейшее: именно оно стартует.
_dkms_built="$(awgc_dkms_all_kernels)" || err "Проверка модуля ядра не прошла — перезагрузка запрещена"
ok "Модуль amneziawg собран под ядра: ${_dkms_built:-—}"
if ! awgc_kernel_ready "$AWGC_KERNEL_NEWEST"; then
    err "нет модуля amneziawg под ядро $AWGC_KERNEL_NEWEST, а именно оно запустится
     после перезагрузки. Собрать вручную и повторить установку:
       apt-get install -y linux-headers-$AWGC_KERNEL_NEWEST
       dkms autoinstall -k $AWGC_KERNEL_NEWEST"
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
# No unattended reboot from a provisioning side effect. A later maintenance
# operation must verify the actual GRUB target and all attached RU owners.
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/99-awg-cascade-reboot

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

# v2.0 параметры (S1-S4 random, H1-H4 monotonic ranges, I1 — случайный
# профиль мимикрии из каталога в awg2-params.sh).
# Если уже сохранены для этого интерфейса — берём существующие (постоянство).
if [ ! -f "$PARAMS_FILE" ]; then
    # Ищем awg2-params.sh в /tmp (положил бот) или рядом со setup-exit.sh
    AWG2_PARAMS_FILE="$(dirname "$0")/awg2-params.sh"
    [ -f "$AWG2_PARAMS_FILE" ] || err "awg2-params.sh missing from operation directory"

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
I1_PROFILE='$I1_PROFILE'
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

# MTU: по той же арифметике, что на RU-стороне (см. awg-cascade-exit-add-ru.sh).
# Раньше строки MTU здесь не было вовсе, то есть awg-quick брал дефолтные 1420 —
# а это направление как раз несёт крупные пакеты (download к клиентам, средний
# размер ~1317 байт), поэтому именно оно и упиралось в path MTU 1500.
TUNNEL_MTU=$(( 1500 - 60 - S4 - 100 ))
# ...но не больше клиентского MTU. Клиенты сидят на awg0/wgc3 с MTU 1280, и всё,
# что приходит с exit'а крупнее, RU обязан отбить ICMP'ом «нужна фрагментация» —
# замерено 16 таких пакетов в минуту, ровно столько же исходящих ICMP. Ломаться
# от этого ничего не ломается (PMTU discovery работает), но лишние 30-40 байт
# MTU туннеля клиентам всё равно не достаются, а работу создают.
[ "$TUNNEL_MTU" -gt 1280 ] && TUNNEL_MTU=1280

cat > $WG_DIR/$IFACE_NAME.conf <<EOF
[Interface]
Address = $EXIT_TUNNEL_IP/30
MTU = $TUNNEL_MTU
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

# DisableCookies на слушающем интерфейсе exit'а.
#
# Флаг отключает ответ cookie-reply под нагрузкой. Смысл не в экономии, а в
# защите от активного зондирования: цензор может послать на подозрительный UDP
# порт поток handshake'ов и опознать сервер по тому, что тот ответил cookie'ом.
# С флагом хост молчит. Именно порты exit'ов и стали бы зондировать в первую
# очередь — они торчат в интернет из чужой страны.
#
# Плата честная: вместе с cookie в ядре отключается и rate limiter (в
# amneziawg-go это один и тот же блок под IsUnderLoad), то есть флудом
# handshake'ов с подменённым адресом сервер можно заставить считать
# криптографию. Для exit'а размен принят; на исходящей стороне RU (awgN) флаг
# намеренно НЕ ставим — там собеседник ровно один и известен, и защита от
# флуда там полезнее.
#
# Ставим, только если tools реально умеют: на старых пакетах awg setconf
# упал бы на незнакомом ключе и интерфейс не поднялся бы вовсе.
if awg set --help 2>&1 | grep -q "disable-cookies"; then
    if ! grep -q '^DisableCookies' "$WG_DIR/$IFACE_NAME.conf"; then
        sed -i "0,/^\[Peer\]/s//DisableCookies = on\n\n[Peer]/" "$WG_DIR/$IFACE_NAME.conf"
    fi
    ok "DisableCookies включён для $IFACE_NAME"
else
    warn "amneziawg-tools без поддержки disable-cookies — флаг не выставлен"
fi

ok "$WG_DIR/$IFACE_NAME.conf создан"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 6: systemd up
# ═════════════════════════════════════════════════════════════════════════════
header "WARP helper-скрипт"

# Кладём awg-cascade-exit-warp.sh (бот вызывает через sudo)
# Сам скрипт скачивается из репо или подкладывается setup'ом.
# Если он залит в /tmp перед запуском — копируем; иначе пользователь должен
# залить руками (или скачать с github).
# Provisioning carries the reboot guard and its config parser on first install.
for helper in awg-cascade-cfg.sh awg-cascade-autoreboot.sh awg-cascade-reboot.py; do
    if [ -f "$(dirname "$0")/$helper" ]; then
        install -m 755 -o root -g root "$(dirname "$0")/$helper" /usr/local/sbin/
    fi
done
# SSH hardening: к этому моменту ключ бота уже в authorized_keys (его кладёт
# ssh_copy_id до запуска этого скрипта), поэтому пароли можно закрывать —
# сам helper всё равно перепроверит наличие ключей и откажется, если их нет.
if [ -f "$(dirname "$0")/awg-cascade-ssh-harden.sh" ]; then
    install -m 755 -o root -g root "$(dirname "$0")/awg-cascade-ssh-harden.sh" \
        /usr/local/sbin/awg-cascade-ssh-harden.sh
    /usr/local/sbin/awg-cascade-ssh-harden.sh 2>&1 | sed 's/^/  /' >&2
else
    warn "ssh-harden не найден в /tmp — вход по паролю останется ВКЛЮЧЁН (брутфорс!)"
fi

if [ -f "$(dirname "$0")/awg-cascade-fail2ban.sh" ]; then
    install -m 755 -o root -g root "$(dirname "$0")/awg-cascade-fail2ban.sh" \
        /usr/local/sbin/awg-cascade-fail2ban.sh
fi

if [ -f "$(dirname "$0")/awg-cascade-exit-warp.sh" ]; then
    install -m 755 -o root -g root "$(dirname "$0")/awg-cascade-exit-warp.sh" \
        /usr/local/sbin/awg-cascade-exit-warp.sh
    ok "WARP helper установлен (/usr/local/sbin/awg-cascade-exit-warp.sh)"
else
    warn "WARP helper не найден в $(dirname "$0")/awg-cascade-exit-warp.sh"
    warn "(скачай руками с https://github.com/tkr09/awg-cascade-multi/blob/main/exit-side/awg-cascade-exit-warp.sh)"
fi

mkdir -p $CONFIG_DIR
chown $BOT_USER:$BOT_USER $CONFIG_DIR
# 750, а не 755: внутри метаданные exit'а (info*.json) и публичные ключи.
# Приватные и так 600, но каталог нараспашку означает, что любой локальный
# процесс видит состав каскада — имена интерфейсов, какие RU подключены.
chmod 750 $CONFIG_DIR

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
# 640: info.json описывает состав каскада — какие RU подключены, через какие
# интерфейсы. Читает его только root (бот ходит сюда по SSH под root).
chmod 640 "$STATE_FILE"


# ─── Вернуть остановленные apt-таймеры ───────────────────────────────────────
#
# В начале установки они останавливаются, чтобы не драться за apt-lock. Обратно
# их никто не включал: `systemctl enable --now unattended-upgrades` — это ДРУГОЙ
# юнит, а периодический запуск даёт именно apt-daily-upgrade.timer. На ноде,
# которая после установки долго не перезагружается, автоматические обновления
# так и оставались выключенными — то есть ровно то, ради чего они и ставились,
# молча не работало.
if declare -F awgc_restore_apt >/dev/null; then awgc_restore_apt || err "Не удалось вернуть apt-таймеры на место"; fi

# Вывод JSON на stdout (бот парсит)
header "Готово. JSON для RU:"
install -m 600 "$STATE_FILE" "$OP_DIR/$OP_ID.done"
cat "$STATE_FILE"

# fail2ban на exit-е. Ставится последним: скрипту нужны поднятые интерфейсы —
# он собирает адреса RU из endpoint-ов пиров, чтобы никогда их не забанить,
# иначе бот потерял бы управление этим exit-ом.
if [ -x /usr/local/sbin/awg-cascade-fail2ban.sh ]; then
    # RU_PUBLIC_IP передаём ЯВНО. Скрипт собирает доверенные адреса из живых
    # endpoint-ов awg-in*, но сейчас туннель с той стороны ещё не поднят и peer
    # создан без Endpoint — прочитать адрес нового RU неоткуда. Без этого он в
    # ignoreip не попадал, и правило «бот никогда не банит свой RU» держалось на
    # том, что RU успеет подключиться раньше, чем наберёт 5 неудачных входов.
    EXTRA_IGNOREIP="$RU_PUBLIC_IP" /usr/local/sbin/awg-cascade-fail2ban.sh >/dev/null 2>&1 \
        && ok "fail2ban настроен (RU $RU_PUBLIC_IP в исключениях)" \
        || warn "fail2ban не настроен — проверь: awg-cascade-fail2ban.sh"
fi
