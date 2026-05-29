#!/bin/bash
# AWG Cascade Multi — backup всего критичного state в один tar.gz.
#
# Что бэкапится (всё что нельзя восстановить если RU сдохнет):
#   /etc/awg-cascade/        — peers.json, state.json, config, ssh-keys, exits/*.keys
#   /etc/amnezia/amneziawg/  — awg0.conf + awg<N>.conf (приватные ключи)
#   /etc/iptables/rules.v4   — кастомные правила
#
# Использование:
#   sudo /usr/local/sbin/awg-cascade-backup.sh
#       — создаёт /root/awg-cascade-backup-YYYYMMDD-HHMM.tar.gz
#
#   sudo /usr/local/sbin/awg-cascade-backup.sh /tmp/mybackup.tar.gz
#       — кастомное имя/путь
#
# Восстановление на новой машине:
#   1. Установи нормально (curl ... setup.sh)
#   2. Останови сервисы: systemctl stop awg-cascade-{bot,watchdog} awg-quick@awg*
#   3. tar xzf backup.tar.gz -C /
#   4. Запусти awg-quick up на каждый awg<N>
#   5. systemctl start ...

set -e

DST="${1:-/root/awg-cascade-backup-$(date +%Y%m%d-%H%M).tar.gz}"

mkdir -p "$(dirname "$DST")"

tar czf "$DST" \
    --exclude='/etc/awg-cascade/state.lock' \
    /etc/awg-cascade/ \
    /etc/amnezia/amneziawg/ \
    /etc/iptables/rules.v4 \
    2>/dev/null

chmod 600 "$DST"
echo "Backup: $DST ($(du -h "$DST" | cut -f1))"
echo
echo "Скопируй на безопасное место:"
echo "  scp root@$(hostname -I | awk '{print $1}'):$DST ./"
