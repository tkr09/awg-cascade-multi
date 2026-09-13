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
. /etc/awg-cascade/config 2>/dev/null || true

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

# Собственные адреса ноды.
for _a in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    add_ip "$_a"
done

# Роль RU: адреса exit'ов знает state.json.
if [ -f /etc/awg-cascade/state.json ] && command -v jq >/dev/null 2>&1; then
    for _a in $(jq -r '.exits[]?.ip // empty' /etc/awg-cascade/state.json 2>/dev/null); do
        add_ip "$_a"
    done
fi

# Роль exit: адреса RU видны как endpoint'ы пиров. Тот же цикл на RU добавит
# адреса exit'ов ещё раз — add_ip это отсеет.
for _a in $(awg show all endpoints 2>/dev/null | awk '{print $3}' \
            | cut -d: -f1 | grep -E '^[0-9]+(\.[0-9]+){3}$'); do
    add_ip "$_a"
done

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
echo "fail2ban: $(systemctl is-active fail2ban), в исключениях $(echo $IGNORE | wc -w) адресов"
fail2ban-client status sshd 2>/dev/null | grep -E "Currently banned|Total banned" | tr -s ' '
