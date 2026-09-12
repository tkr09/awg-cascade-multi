#!/bin/bash
# AWG Cascade Multi — backup всего критичного state в один tar.gz.
#
# Что бэкапится (всё что нельзя восстановить если RU сдохнет):
#   /etc/awg-cascade/        — peers.json, state.json, config, ssh-keys, exits/*.keys
#   /etc/amnezia/amneziawg/  — awg0.conf + awg<N>.conf + второй клиентский
#                              интерфейс 3.0, если поднят (приватные ключи)
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

# Имя включает hostname: каскад multi-RU, и без него бэкапы с двух RU, снятые в
# одну минуту, дают одинаковое имя. При сборе в одну папку второй молча
# перезаписывает первый — так уже терялся бэкап RU-1.
DST="${1:-/root/awg-cascade-backup-$(hostname -s)-$(date +%Y%m%d-%H%M).tar.gz}"

mkdir -p "$(dirname "$DST")"

# umask ДО создания архива: внутри приватные ключи сервера, клиентов и бота, а
# chmod 600 ниже срабатывает уже после записи — файл успевал полежать с 0644.
umask 077

tar czf "$DST" \
    --exclude='/etc/awg-cascade/state.lock' \
    /etc/awg-cascade/ \
    /etc/amnezia/amneziawg/ \
    /etc/iptables/rules.v4 \
    2>/dev/null

chmod 600 "$DST"

# Проверяем архив сразу, а не при скачивании: битый бэкап, о котором узнаёшь в
# момент восстановления, хуже отсутствующего — на него рассчитывают.
if ! gzip -t "$DST" 2>/dev/null; then
    echo "🔴 архив не проходит gzip -t, удаляю: $DST" >&2
    rm -f "$DST"
    exit 1
fi

# Ротация. Нужна с появлением таймера: без неё ежедневный бэкап растёт без
# границ. Считаем только автоимена в /root — файлы с явным путём (аргумент $1)
# не наши, их не трогаем.
: "${BACKUP_KEEP:=14}"
if [ -z "${1:-}" ]; then
    ls -1t /root/awg-cascade-backup-*.tar.gz 2>/dev/null         | tail -n +$((BACKUP_KEEP + 1))         | while IFS= read -r old; do rm -f "$old"; echo "ротация: удалён $old"; done
fi

echo "Backup: $DST ($(du -h "$DST" | cut -f1))"
echo
echo "Скопируй на безопасное место:"
echo "  scp root@$(hostname -I | awk '{print $1}'):$DST ./"
