#!/bin/bash
# One-time migration and repeated enforcement of the privileged file boundary.
set -euo pipefail
[ "$EUID" -eq 0 ] || exit 1
. /usr/local/sbin/awg-cascade-cfg.sh
awgc_load_config
[[ "$BOT_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$BOT_USER" != root ]] || exit 1
BASE=/etc/awg-cascade
BOT=/opt/awg-cascade-bot
for dir in "$BASE" "$BASE/peers" "$BASE/exits" "$BASE/ssh" "$BOT" "$BOT/scripts"; do
    [ ! -L "$dir" ] || { echo "Отказ: каталог $dir — симлинк" >&2; exit 1; }
done
install -d -m 750 -o root -g "$BOT_USER" "$BASE" "$BASE/peers"
install -d -m 700 -o root -g root "$BASE/exits"
install -d -m 700 -o "$BOT_USER" -g "$BOT_USER" "$BASE/ssh"
if [ -f "$BASE/known_hosts" ] && [ ! -e "$BASE/ssh/known_hosts" ]; then
    install -m 600 -o "$BOT_USER" -g "$BOT_USER" "$BASE/known_hosts" "$BASE/ssh/known_hosts"
fi
# Реестр host-ключей принадлежит БОТУ: он его и читает, и дописывает при TOFU.
#
# Миграция выше срабатывает только когда целевого файла ещё нет, а владельца
# существующего не проверял никто. Между тем файл создаёт ssh, запущенный от
# root: bootstrap-exit.sh вызывается из setup.sh во время установки. Нода
# рождалась с root:root 600 в каталоге бота — и бот терял ВСЕ операции с
# exit'ами по SSH разом: статус, WARP, удаление, обновление, добавление
# нового exit'а. Снаружи это выглядело как зависший экран в Telegram, а
# selftest горел зелёным, потому что проверяет egress через curl.
[ ! -L "$BASE/ssh/known_hosts" ] || { echo "Отказ: ssh/known_hosts — симлинк" >&2; exit 1; }
if [ -f "$BASE/ssh/known_hosts" ]; then
    chown "$BOT_USER:$BOT_USER" "$BASE/ssh/known_hosts"
    chmod 600 "$BASE/ssh/known_hosts"
fi
for file in config state.json peers.json awg2_params version installed-version active-version activation-pending; do
    [ ! -L "$BASE/$file" ] || { echo "Отказ: $file — симлинк" >&2; exit 1; }
    if [ -f "$BASE/$file" ]; then
        chown "root:$BOT_USER" "$BASE/$file"
        chmod 640 "$BASE/$file"
    fi
done
for file in "$BASE/peers/"*.conf; do
    [ -e "$file" ] || continue
    [ ! -L "$file" ] || exit 1
    chown "root:$BOT_USER" "$file"; chmod 640 "$file"
done
[ ! -L "$BASE/state.lock" ] || exit 1
touch "$BASE/state.lock"; chown root:root "$BASE/state.lock"; chmod 600 "$BASE/state.lock"
if [ -d "$BOT" ]; then
    # A writable parent could replace an otherwise root-owned provisioning script.
    chown root:root "$BOT"; chmod 755 "$BOT"
    for dir in "$BOT/scripts" "$BOT/handlers"; do
        [ ! -L "$dir" ] || exit 1
        if [ -d "$dir" ]; then
            [ -z "$(find "$dir" -type l -print -quit)" ] || exit 1
            chown -R root:root "$dir"
            find "$dir" -type d -exec chmod 755 {} +
            find "$dir" -type f -exec chmod 644 {} +
            # В scripts/ лежит комплект провижининга, и он весь исполняемый.
            # Возврат 755 только для *.sh оставлял awg-cascade-reboot.py с 644:
            # проверка комплекта в setup.sh требует -x, а sync на каждой свежей
            # ноде вечно показывал дрейф прав.
            [ "$dir" != "$BOT/scripts" ] || \
                find "$dir" \( -name '*.sh' -o -name '*.py' \) -exec chmod 755 {} +
        fi
    done
    for file in "$BOT/"*.py "$BOT/"*.txt; do
        [ -f "$file" ] || continue
        [ ! -L "$file" ] || exit 1
        chown root:root "$file"; chmod 644 "$file"
    done
fi
