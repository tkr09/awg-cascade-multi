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

# ─── Снимок под общей блокировкой ───────────────────────────────────────────
# Раньше tar читал peers.json, ключи и конфиги интерфейсов без блокировки, и,
# попав на add/remove/rotate, мог взять файлы РАЗНЫХ поколений: peers.json уже
# новый, awg0.conf ещё старый — или наоборот. Проверка gzip -t такой архив
# пропускает: сжатие-то целое. Узнаёшь об этом при восстановлении.
#
# Тот же state.lock, что берут peer-add/remove/rotate и exit-add/remove.
# Ждём ограниченно: бэкап, не состоявшийся из-за чужого зависшего lock, хуже
# слегка несогласованного. Поэтому по таймауту снимаем всё равно, но помечаем
# архив и говорим об этом вслух.
FLOCK=/etc/awg-cascade/state.lock
CONSISTENT=yes
# Без `2>/dev/null` здесь намеренно: exec без команды применяет перенаправления
# к САМОМУ шеллу, и такой глушитель заодно отключил бы весь вывод об ошибках
# ниже — включая сообщения tar, ради которых их перестали прятать.
exec 200>"$FLOCK" || CONSISTENT=no
if ! flock -w 120 -x 200 2>/dev/null; then
    CONSISTENT=no
    echo "⚠️  state.lock не взят за 120с — снимаю бэкап без блокировки" >&2
fi

# Манифест: без него архив не отвечает на вопрос «от какой это версии и полон ли
# он». Пишется внутрь архива, поэтому создаётся до tar.
MANIFEST=/etc/awg-cascade/backup-manifest.json
{
    printf '{\n'
    printf '  "hostname": "%s",\n'   "$(hostname -s)"
    printf '  "created": "%s",\n'    "$(date -Iseconds)"
    printf '  "version": "%s",\n'    "$(cat /etc/awg-cascade/version 2>/dev/null | tr -d '\n' || echo unknown)"
    printf '  "consistent": "%s",\n' "$CONSISTENT"
    printf '  "peers": %s,\n'        "$(jq 'length' /etc/awg-cascade/peers.json 2>/dev/null || echo 0)"
    printf '  "exits": %s\n'         "$(jq '.exits | length' /etc/awg-cascade/state.json 2>/dev/null || echo 0)"
    printf '}\n'
} > "$MANIFEST"
chmod 600 "$MANIFEST"

# Ошибки tar больше не прячем в /dev/null: «файл изменился при чтении» и
# «отказано в доступе» — это ровно то, что делает бэкап неполным, и это
# единственный момент, когда о них можно узнать.
TAR_ERR=$(mktemp)
tar czf "$DST" \
    --exclude='/etc/awg-cascade/state.lock' \
    /etc/awg-cascade/ \
    /etc/amnezia/amneziawg/ \
    /etc/iptables/rules.v4 \
    2>"$TAR_ERR" || {
        echo "🔴 tar завершился с ошибкой:" >&2
        sed 's/^/    /' "$TAR_ERR" >&2
        rm -f "$TAR_ERR" "$DST"
        exit 1
    }
if [ -s "$TAR_ERR" ]; then
    echo "⚠️  tar с замечаниями:" >&2
    sed 's/^/    /' "$TAR_ERR" >&2
fi
rm -f "$TAR_ERR"

flock -u 200 2>/dev/null || true

chmod 600 "$DST"

# Проверяем архив сразу, а не при скачивании: битый бэкап, о котором узнаёшь в
# момент восстановления, хуже отсутствующего — на него рассчитывают.
if ! gzip -t "$DST" 2>/dev/null; then
    echo "🔴 архив не проходит gzip -t, удаляю: $DST" >&2
    rm -f "$DST"
    exit 1
fi

# gzip -t проверяет только целостность СЖАТИЯ. Отдельно убеждаемся, что внутри
# лежит то, ради чего бэкап делается: без этих файлов восстанавливать нечего.
for _must in etc/awg-cascade/peers.json etc/awg-cascade/state.json \
             etc/awg-cascade/config etc/awg-cascade/backup-manifest.json; do
    if ! tar tzf "$DST" 2>/dev/null | grep -qx "$_must"; then
        echo "🔴 в архиве нет $_must — бэкап бесполезен, удаляю: $DST" >&2
        rm -f "$DST"
        exit 1
    fi
done

# Соответствие runtime и архива: каждый pubkey из peers.json должен встречаться
# в конфиге своего интерфейса. Расхождение = взяли файлы разных поколений.
_mismatch=$(tar xzf "$DST" -O etc/awg-cascade/peers.json 2>/dev/null \
    | jq -r '.[] | "\(.pubkey) \(.iface // "awg0")"' 2>/dev/null \
    | while read -r _pk _if; do
        [ -n "$_pk" ] || continue
        tar xzf "$DST" -O "etc/amnezia/amneziawg/${_if}.conf" 2>/dev/null \
            | grep -qF "$_pk" || echo "$_pk"
      done | wc -l)
if [ "${_mismatch:-0}" -gt 0 ]; then
    echo "⚠️  в архиве $_mismatch peer(ов) есть в peers.json, но нет в конфиге интерфейса" >&2
    echo "    (снимок неконсистентен: consistent=$CONSISTENT)" >&2
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
