#!/bin/bash
# =============================================================================
# AWG Cascade Multi — fail2ban для SSH.
#
# ЗАЧЕМ. Вход по паролю отключён (passwordauthentication no), подобрать пароль
# нельзя в принципе. Смысл не в защите от подбора, а в том, чтобы перестать
# тратить CPU и записи журнала на сканеров: замерено 3853 неудачные попытки за
# сутки на одной ноде. Они же маскируют настоящие события — SSH-алерт через
# pam_exec тонет в этом шуме.
#
# ГЛАВНОЕ, РАДИ ЧЕГО НУЖЕН СВОЙ КОНФИГ. Бот ходит с RU на exit'ы по SSH. Бан
# RU-адреса на exit'е отнял бы у бота управление этим exit'ом — то есть защита
# от сканеров сама создала бы аварию. Поэтому адреса каскада всегда в ignoreip,
# и собираются они ИЗ ЖИВОГО СОСТОЯНИЯ, а не из списка в коде:
#   • на RU  — из state.json (адреса exit'ов);
#   • на exit — из endpoint'ов пиров (адреса RU, которые к нему подключены).
# Захардкоженный список в этом проекте протухал дважды.
#
# Идемпотентен: можно вызывать повторно, в том числе после добавления exit'а.
# =============================================================================
set -u
# Config читаем строгим разбором, а не source: файл принадлежит боту, и
# source превращал бы любую его правку в выполнение кода от root.
# Фолбэк на source — на время раскатки, пока cfg.sh есть не на всех нодах.
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || . /etc/awg-cascade/config 2>/dev/null || true

CONF=/etc/fail2ban/jail.d/awg-cascade.conf

if ! command -v fail2ban-client >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq fail2ban >/dev/null 2>&1 || {
        echo "fail2ban: установить не удалось" >&2; exit 1; }
fi

# ─── Сбор адресов, которые нельзя банить ────────────────────────────────────
add_ip() {
    case " $IGNORE " in
        *" $1 "*) : ;;                      # уже есть
        *) [ -n "$1" ] && IGNORE="$IGNORE $1" ;;
    esac
}

IGNORE="127.0.0.1/8 ::1"

# Адреса, которые нельзя вывести из живого состояния. Два источника:
#
#   EXTRA_IGNOREIP — передаётся вызывающим. Главный случай: setup-exit.sh знает
#   RU_PUBLIC_IP нового RU, но на момент его запуска туннель ещё не поднят с той
#   стороны, peer создан без Endpoint — и прочитать этот адрес из awg show
#   физически неоткуда. Без явной передачи новый RU в ignoreip не попадал вообще.
#
#   Файл $EXTRA_FILE — то же самое, но сохранённое. Скрипт идемпотентный и
#   запускается повторно (после добавления exit'а, из sync, руками), поэтому
#   переданное однажды должно пережить запуск без аргументов. Сюда же оператор
#   дописывает свои адреса — их мы не теряем.
EXTRA_FILE=/etc/awg-cascade/fail2ban-extra
mkdir -p "$(dirname "$EXTRA_FILE")" 2>/dev/null || true

if [ -n "${EXTRA_IGNOREIP:-}" ]; then
    for _a in $EXTRA_IGNOREIP; do
        grep -qxF "$_a" "$EXTRA_FILE" 2>/dev/null || echo "$_a" >> "$EXTRA_FILE"
    done
fi
if [ -f "$EXTRA_FILE" ]; then
    while IFS= read -r _a; do
        case "$_a" in ''|'#'*) continue ;; esac
        add_ip "$_a"
    done < "$EXTRA_FILE"
fi

# Собственные ПУБЛИЧНЫЕ адреса ноды. Внутренние адреса туннелей отбрасываем:
# в ignoreip они бесполезны (по ним никто не ломится в SSH) и только зашумляют
# список, из-за чего в нём труднее заметить лишнее.
for _a in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    case "$_a" in
        10.*|192.168.*|127.*) continue ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
    esac
    add_ip "$_a"
done

# Роль RU: адреса exit'ов знает state.json.
if [ -f /etc/awg-cascade/state.json ] && command -v jq >/dev/null 2>&1; then
    for _a in $(jq -r '.exits[]?.ip // empty' /etc/awg-cascade/state.json 2>/dev/null); do
        add_ip "$_a"
    done
fi

# Роль exit: адреса RU видны как endpoint'ы пиров, но ТОЛЬКО на интерфейсах
# awg-in*. Это важно и было ошибкой в первой версии: на RU пиры интерфейса awg0
# — это КЛИЕНТЫ, и сбор endpoint'ов «со всех интерфейсов» затащил в ignoreip
# шесть домашних IP пользователей. Такой список и бессмыслен (никто оттуда не
# ломится в SSH), и растёт без границ, и записывает адреса людей в конфиг.
for _if in $(awg show interfaces 2>/dev/null); do
    case "$_if" in awg-in*) ;; *) continue ;; esac
    for _a in $(awg show "$_if" endpoints 2>/dev/null | awk '{print $2}' \
                | cut -d: -f1 | grep -E '^[0-9]+(\.[0-9]+){3}$'); do
        add_ip "$_a"
    done
done

# Обратная сторона: RU-ноды между собой не общаются, поэтому у одной RU нет
# живого источника, откуда узнать адрес другой. И не нужно — по SSH к RU ходит
# только оператор, а бот ходит с RU на exit'ы, не наоборот.

# ─── Конфиг ──────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# Генерируется awg-cascade-fail2ban.sh — правки руками затрутся.
[DEFAULT]
# Адреса каскада НИКОГДА не банить: бот ходит с RU на exit'ы по SSH, и бан
# RU-адреса на exit'е отнял бы у бота управление этим exit'ом.
ignoreip = $IGNORE
# Бан на час, а не навсегда: ошибка в правилах должна залечиваться сама.
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
# В Ubuntu 24.04 юнит называется ssh.service, а не sshd.service. Дефолтный
# journalmatch всё же срабатывает — через альтернативу _COMM=sshd, — но здесь
# условие записано явно, чтобы работа jail не зависела от имени процесса.
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd
EOF
chmod 644 "$CONF"

systemctl enable fail2ban >/dev/null 2>&1 || true
if systemctl is-active --quiet fail2ban; then
    systemctl reload-or-restart fail2ban >/dev/null 2>&1 || true
else
    systemctl start fail2ban >/dev/null 2>&1 || true
fi

sleep 2

# Результат проверяем, а не декларируем.
#
# Раньше ошибки start/reload гасились в /dev/null, а последней командой скрипта
# был pipeline с grep — он возвращает 0 даже когда jail не поднялся, и вызывающая
# сторона печатала «fail2ban настроен» при неработающем fail2ban. Это ровно тот
# случай, когда молчание в логе неотличимо от защиты.
RC=0
if ! systemctl is-active --quiet fail2ban; then
    echo "🔴 fail2ban не запущен (systemctl status fail2ban)" >&2
    RC=1
elif ! fail2ban-client status sshd >/dev/null 2>&1; then
    echo "🔴 fail2ban работает, но jail sshd не поднялся" >&2
    RC=1
fi
echo "fail2ban: $(systemctl is-active fail2ban), в исключениях $(echo $IGNORE | wc -w) адресов"
fail2ban-client status sshd 2>/dev/null | grep -E "Currently banned|Total banned" | tr -s ' ' || true
exit $RC
