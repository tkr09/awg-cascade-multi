#!/bin/bash
# AWG Cascade Multi — включить unattended-upgrades для security patches.
# Включается setup.sh / setup-exit.sh + можно запускать отдельно на существующих.
set -e
export DEBIAN_FRONTEND=noninteractive

if ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq unattended-upgrades apt-listchanges
fi

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
systemctl is-active --quiet unattended-upgrades && echo "unattended-upgrades: ACTIVE"

# Automatic-Reboot ЗДЕСЬ НЕ ТРОГАЕМ — им владеет awg-cascade-autoreboot.sh.
#
# Раньше тут стояло Automatic-Reboot "false" с комментарием «мы держим control
# plane». Это противоречило тому, как каскад реально работает: ноды ночью
# ребутятся сами, и именно так подхватываются обновления ядра, без которых DKMS
# собран под одну версию, а загружена другая. Sed срабатывал только на
# закомментированной строке, поэтому на настроенной ноде вреда не наносил — но
# стоило пакету переписать 50unattended-upgrades, и повторный запуск этого
# скрипта молча выключил бы ночное окно, а узнали бы мы об этом через месяцы.
#
# Окно у каждой ноды своё (AUTO_REBOOT_HOUR), иначе каскад перезагрузится разом
# и клиенты останутся без exit'ов — такое знание одному скрипту взять неоткуда.
if [ -x /usr/local/sbin/awg-cascade-autoreboot.sh ]; then
    /usr/local/sbin/awg-cascade-autoreboot.sh || true
fi
