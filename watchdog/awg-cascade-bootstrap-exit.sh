#!/bin/bash
# =============================================================================
# AWG Cascade Multi — CLI bootstrap первого exit (без живого бота)
#
# Решает chicken-and-egg на новом RU: бот не может выйти к Telegram пока нет
# ни одного exit (table 100 пуста), а exit через UI бота не добавить пока бот
# мёртв. Этот скрипт подключает exit напрямую через SSH из CLI.
#
# Работает и с fresh exit (поставит amneziawg), и с уже занятым другим RU
# (setup-exit.sh сам определит SHARED_MODE и создаст awg-in-<N>).
#
# Usage:
#   awg-cascade-bootstrap-exit.sh                  # интерактивно (спросит IP+пароль)
#   awg-cascade-bootstrap-exit.sh <IP> <NAME>      # IP+имя из argv, пароль спросит
#   EXIT_PASSWORD=... awg-cascade-bootstrap-exit.sh <IP> <NAME>  # всё из env
# =============================================================================
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $1" >&2; }
err()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1" >&2; }

# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
. /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config
STATE_FILE=/etc/awg-cascade/state.json
SSH_DIR=/etc/awg-cascade/ssh
BOT_SCRIPTS=/opt/awg-cascade-bot/scripts
WG_DIR=/etc/amnezia/amneziawg

command -v sshpass >/dev/null || err "sshpass не установлен (apt-get install sshpass)"
command -v jq >/dev/null || err "jq не установлен"

EXIT_IP="${1:-}"
EXIT_NAME="${2:-}"

if [ -z "$EXIT_IP" ]; then
    echo -en "${YELLOW}▶${NC} IP exit-сервера: " >&2; read -r EXIT_IP </dev/tty
fi
[ -z "$EXIT_IP" ] && { info "Пропущено (пустой IP)."; exit 0; }

if [ -z "$EXIT_NAME" ]; then
    echo -en "${YELLOW}▶${NC} Имя exit'а (например NL-1): " >&2; read -r EXIT_NAME </dev/tty
fi
EXIT_NAME=$(echo "$EXIT_NAME" | tr -cd 'a-zA-Z0-9._-' | head -c 32)
[ -z "$EXIT_NAME" ] && err "Имя exit'а обязательно"

# Общий с ботом реестр host-ключей. accept-new: незнакомый хост принимаем и
# запоминаем, изменившийся — отвергаем. Через этот же канал уезжают RU_PSK и
# приватный ключ туннеля, поэтому UserKnownHostsFile=/dev/null здесь нельзя.
KNOWN_HOSTS=/etc/awg-cascade/ssh/known_hosts
mkdir -p "$(dirname "$KNOWN_HOSTS")"

# ─── Способ подключения: сначала пробуем, потом спрашиваем ───────────────────
#
# Пароль годится только для СВЕЖЕГО сервера. На любом уже настроенном exit'е
# вход по паролю отключён нашим же ssh-harden — и раньше это делало невозможным
# главный сценарий: подключить существующий exit к НОВОЙ RU. Скрипт умел только
# пароль и упирался в собственную защиту.
#
# Порядок теперь такой: перебираем доступные ключи и МОЛЧА берём первый, которым
# вход получается. Многие хостинги раскладывают ключ владельца на все ноды сами,
# и в этом случае спрашивать вообще не о чем. Инструкция «добавь публичную часть»
# показывается только когда ни один ключ не подошёл — то есть на хостинге, где
# такой автоматики нет.
#
#   EXIT_AUTH=auto|key|password   (по умолчанию auto)
#   EXIT_SSH_KEY=<путь>           — проверить именно этот ключ первым
EXIT_AUTH="${EXIT_AUTH:-auto}"
[ -n "${EXIT_PASSWORD:-}" ] && [ "$EXIT_AUTH" = "auto" ] && EXIT_AUTH=password

SSH_OPTS_BASE="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=15"

# Кандидаты: явно заданный, собственный ключ этой RU, обычные ключи root.
# Ключ RU идёт раньше root-овых намеренно: он заведомо наш и не потребует
# держать на ноде приватный ключ владельца.
KEY_CANDIDATES="${EXIT_SSH_KEY:-} /etc/awg-cascade/ssh/id_ed25519 /root/.ssh/id_ed25519 /root/.ssh/id_rsa"

WORKING_KEY=""
if [ "$EXIT_AUTH" != "password" ]; then
    for _k in $KEY_CANDIDATES; do
        [ -n "$_k" ] && [ -f "$_k" ] || continue
        if ssh $SSH_OPTS_BASE -i "$_k" -o BatchMode=yes -o PasswordAuthentication=no \
               "root@$EXIT_IP" 'echo ok' >/dev/null 2>&1; then
            WORKING_KEY="$_k"
            ok "Вход по ключу $_k"
            break
        fi
    done
fi

if [ -n "$WORKING_KEY" ]; then
    EXIT_AUTH=key
    SSH_OPTS="$SSH_OPTS_BASE -i $WORKING_KEY -o BatchMode=yes -o PasswordAuthentication=no"
elif [ "$EXIT_AUTH" = "key" ]; then
    _pub=$(cat /etc/awg-cascade/ssh/id_ed25519.pub 2>/dev/null || echo "<ключа нет>")
    echo "" >&2
    err "Ни один ключ не подошёл к $EXIT_IP. Проверены: $(echo $KEY_CANDIDATES | tr ' ' ',')

     Если хостинг не раскладывает ключи сам, добавь публичную часть ЭТОЙ ноды
     с машины, у которой доступ к exit'у уже есть:

       ssh root@$EXIT_IP \"printf '\\n%s\\n' '$_pub' >> ~/.ssh/authorized_keys\"

     Либо укажи другой ключ: EXIT_SSH_KEY=<путь> $0 $EXIT_IP $EXIT_NAME"
else
    # auto без подошедшего ключа, либо явный password
    if [ -z "${EXIT_PASSWORD:-}" ]; then
        [ "$EXIT_AUTH" = "auto" ] && info "Ключом войти не удалось — спрашиваю пароль"
        echo -en "${YELLOW}▶${NC} Root пароль exit-сервера: " >&2
        read -rs EXIT_PASSWORD </dev/tty; echo >&2
    fi
    [ -z "$EXIT_PASSWORD" ] && err "Пароль обязателен"
    command -v sshpass >/dev/null 2>&1 || err "нет sshpass — поставь его или дай доступ по ключу"
    EXIT_AUTH=password
    SSH_OPTS="$SSH_OPTS_BASE"
fi

if [ "$EXIT_AUTH" = "key" ]; then
    sshx() { ssh $SSH_OPTS "root@$EXIT_IP" "$@"; }
    scpx() { scp $SSH_OPTS "$@"; }
else
    sshx() { sshpass -d 7 ssh $SSH_OPTS "root@$EXIT_IP" "$@" 7<<<"$EXIT_PASSWORD"; }
    scpx() { sshpass -d 7 scp $SSH_OPTS "$@" 7<<<"$EXIT_PASSWORD"; }
fi


# Для ключа соединение уже проверено перебором выше — здесь остаётся пароль.
if [ "$EXIT_AUTH" = "password" ]; then
    info "Проверяю SSH к $EXIT_IP по паролю..."
    sshx 'echo ok' >/dev/null 2>&1 || err "SSH по паролю не прошёл. Если exit уже настроен,
     вход по паролю на нём закрыт — дай доступ по ключу (EXIT_AUTH=key)."
fi
ok "SSH OK ($EXIT_AUTH)"

# 4. Ключ бота ставим ДО provisioning — и проверяем, что он работает.
#
# Порядок был обратный: setup-exit.sh в конце вызывает ssh-harden, который
# отключает вход по паролю, и только ПОСЛЕ этого bootstrap добавлял ключ бота —
# новой парольной сессией. Если на сервере уже лежал чей-то ключ, hardening
# срабатывал, парольная сессия переставала подключаться, и добавление ключа
# падало. Ошибка была помечена «не критично», хотя означала ровно одно: бот не
# может управлять этим exit'ом. Если же ключей не было вовсе, hardening
# пропускался, а повторно после добавления ключа не запускался — сервер
# оставался с включённым паролем.
#
# Теперь: сначала ключ, потом проверка входа ИМЕННО этим ключом, и только затем
# provisioning с hardening. Не прошла проверка — останавливаемся до того, как
# что-то отключено.
if [ -f "$SSH_DIR/id_ed25519.pub" ]; then
    BOT_PUB=$(cat "$SSH_DIR/id_ed25519.pub")

    # ─── Дописывать в authorized_keys можно ТОЛЬКО с гарантией перевода строки ──
    #
    # Образ хостера вправе оставить authorized_keys без завершающего \n — так
    # делает, например, HOSTKEY. Тогда `echo key >> file` приклеивает наш ключ
    # к КОММЕНТАРИЮ предыдущей строки:
    #
    #   ssh-ed25519 AAAA...  awg-admin@tkr-20260824ssh-ed25519 AAAA... bot@ru.srv
    #
    # Файл при этом выглядит правильным, права правильные, ключ «на месте» —
    # а sshd видит на один ключ меньше и отвечает «Permission denied
    # (publickey)». Диагноз неочевиден настолько, что этот шаг обрывал установку
    # дважды подряд, и оба раза на полностью исправном ключе.
    #
    # Поэтому: последний байт не \n — сначала добавляем его, и только потом ключ.
    # Проверка через `[ -n "$(tail -c1 …)" ]`: подстановка съедает завершающие
    # переводы строки, значит пусто ⇔ файл уже кончается переводом строки.
    _ak_out=$(sshx "set -e
        umask 077
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        if [ -s ~/.ssh/authorized_keys ] && [ -n \"\$(tail -c1 ~/.ssh/authorized_keys)\" ]; then
            echo >> ~/.ssh/authorized_keys
        fi
        grep -qxF '$BOT_PUB' ~/.ssh/authorized_keys || printf '%s\n' '$BOT_PUB' >> ~/.ssh/authorized_keys
        echo \"ключей в authorized_keys: \$(ssh-keygen -lf ~/.ssh/authorized_keys 2>/dev/null | wc -l)\"" 2>&1) \
        || err "не удалось добавить ключ бота на exit: $_ak_out"
    info "$(echo "$_ak_out" | tail -1)"

    # Проверка входа ИМЕННО этим ключом, до отключения пароля. С ретраями и с
    # ВИДИМЫМ выводом ssh.
    #
    # Прежний вариант делал одну попытку и прятал вывод в /dev/null. При сбое
    # оператор получал «вход по нему не работает» и ноль сведений о причине, а
    # запуск обрывался — при том что ключ мог быть на месте и рабочим. Ровно та
    # болезнь, за которую аудит цеплял другие места: диагностика, которая молчит
    # именно тогда, когда нужна.
    _kv_out=""
    _kv_ok=0
    for _try in 1 2 3; do
        if _kv_out=$(ssh -F /dev/null -i "$SSH_DIR/id_ed25519" $SSH_OPTS_BASE \
                -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o PasswordAuthentication=no \
                "root@$EXIT_IP" 'echo ok' 2>&1); then
            _kv_ok=1
            break
        fi
        [ "$_try" -lt 3 ] && { info "вход по ключу с попытки $_try не прошёл, повтор через 3с"; sleep 3; }
    done
    if [ "$_kv_ok" != "1" ]; then
        echo "" >&2
        echo "  Вывод ssh:" >&2
        printf '%s\n' "$_kv_out" | tail -5 | sed 's/^/    /' >&2
        # Диагностику даём по ОТПЕЧАТКУ, а не по grep'у строки: если ключ снова
        # склеился с соседним, grep его найдёт, а sshd — нет, и подсказка соврёт.
        err "ключ бота добавлен, но вход по нему не работает — прерываю ДО отключения пароля.
     Проверить на exit'е (с машины, где доступ есть), ищем СВОЙ отпечаток:
       ssh-keygen -lf /root/.ssh/authorized_keys
       наш: $(ssh-keygen -lf "$SSH_DIR/id_ed25519.pub" 2>/dev/null | awk '{print $2}')
     Нет его в списке при наличии ключа в файле — строка склеена с соседней."
    fi
    ok "Ключ бота добавлен и проверен"
else
    warn "$SSH_DIR/id_ed25519.pub не найден — бот не сможет управлять этим exit'ом"
fi

# Общий с ботом движок провижининга; вход по ключу проверен выше.
#
# Код возврата 2 — особый: exit настроен, добавлен и работает, не подтвердилась
# только его перезагрузка в новое ядро. Повторять провижининг в этом случае
# нельзя — он уже сделан, и повтор пошёл бы по чужому индексу.
_prov_rc=0
_prov_out=$(/usr/local/sbin/awg-cascade-provision.sh "$EXIT_IP" "$EXIT_NAME") || _prov_rc=$?
_prov_reboot=$(printf %s "$_prov_out" | jq -r '.reboot // "-"' 2>/dev/null || echo "-")
case "$_prov_rc" in
    0) ok "Exit провижинен (перезагрузка: $_prov_reboot)" ;;
    2) warn "Exit добавлен и работает, но перезагрузка не подтверждена:"
       warn "  $_prov_reboot"
       warn "  Провижининг НЕ повторять. Проверь сам exit: uptime, awg show" ;;
    *) err "Провижининг не завершён — повтори с тем же IP и именем" ;;
esac

# 8. Перезапускаем бота — теперь у него есть egress через этот exit
info "Перезапускаю бота (теперь будет egress через $EXIT_NAME)..."
systemctl restart awg-cascade-bot 2>/dev/null || true
sleep 3
if systemctl is-active --quiet awg-cascade-bot; then
    ok "Бот перезапущен"
else
    warn "Бот не активен — проверь: journalctl -u awg-cascade-bot -n 30"
fi

echo "" >&2
ok "Готово! Exit '$EXIT_NAME' подключён. Watchdog подхватит в ECMP за ~5 сек."
ok "Проверь бота в Telegram (/start) — он должен отвечать через $EXIT_NAME."
