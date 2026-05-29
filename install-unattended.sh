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

# Опционально автоматический перезапуск сервисов после patch'а
# (но без auto-reboot — мы держим control plane)
sed -i 's|//Unattended-Upgrade::Automatic-Reboot ".*";|Unattended-Upgrade::Automatic-Reboot "false";|' \
    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
sed -i 's|//Unattended-Upgrade::Remove-Unused-Dependencies ".*";|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' \
    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
systemctl is-active --quiet unattended-upgrades && echo "unattended-upgrades: ACTIVE"
