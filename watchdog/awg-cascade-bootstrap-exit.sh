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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $1" >&2; }
err()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1" >&2; }

. /etc/awg-cascade/config
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

EXIT_PASSWORD="${EXIT_PASSWORD:-}"
if [ -z "$EXIT_PASSWORD" ]; then
    echo -en "${YELLOW}▶${NC} Root пароль exit-сервера: " >&2; read -rs EXIT_PASSWORD </dev/tty; echo >&2
fi
[ -z "$EXIT_PASSWORD" ] && err "Пароль обязателен"

# Первый контакт со свежим сервером — и по этому же каналу уезжают RU_PSK и
# приватный ключ туннеля. UserKnownHostsFile=/dev/null означало, что подмена
# сервера на сетевом пути не будет замечена НИКОГДА, даже на повторном запуске.
# accept-new: незнакомый хост принимаем и запоминаем в общий с ботом реестр,
# изменившийся — отвергаем.
KNOWN_HOSTS=/etc/awg-cascade/known_hosts
mkdir -p "$(dirname "$KNOWN_HOSTS")"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=15"
sshx() { sshpass -p "$EXIT_PASSWORD" ssh $SSH_OPTS "root@$EXIT_IP" "$@"; }
scpx() { sshpass -p "$EXIT_PASSWORD" scp $SSH_OPTS "$@"; }

info "Проверяю SSH к $EXIT_IP..."
sshx 'echo ok' >/dev/null 2>&1 || err "SSH не прошёл (проверь IP/пароль)"
ok "SSH OK"

# 1. Заливаем provisioning-скрипты на exit
info "Заливаю setup-exit.sh + awg2-params.sh + warp helper..."
scpx "$BOT_SCRIPTS/setup-exit.sh"               "root@$EXIT_IP:/root/setup-exit.sh" >/dev/null
scpx "$BOT_SCRIPTS/awg2-params.sh"              "root@$EXIT_IP:/tmp/awg2-params.sh" >/dev/null
scpx "$BOT_SCRIPTS/awg-cascade-exit-warp.sh"    "root@$EXIT_IP:/tmp/awg-cascade-exit-warp.sh" >/dev/null
[ -f "$BOT_SCRIPTS/awg-cascade-fail2ban.sh" ] && \
  scpx "$BOT_SCRIPTS/awg-cascade-fail2ban.sh"    "root@$EXIT_IP:/tmp/awg-cascade-fail2ban.sh" >/dev/null
[ -f "$BOT_SCRIPTS/awg-cascade-ssh-harden.sh" ] && \
  scpx "$BOT_SCRIPTS/awg-cascade-ssh-harden.sh" "root@$EXIT_IP:/tmp/awg-cascade-ssh-harden.sh" >/dev/null
ok "Скрипты залиты"

# 2. Генерим RU-ключи для этого туннеля
RU_PRIVKEY=$(awg genkey)
RU_PUBKEY=$(echo "$RU_PRIVKEY" | awg pubkey)
RU_PSK=$(awg genpsk)

# 3. EXIT_INDEX резервируем тем же механизмом, что и бот.
#
# Было `max(index)+1` из снимка state.json — без брони и без учёта того, что бот
# в этот момент может провижить свой exit. Два источника выдавали один индекс,
# и второй переписывал конфиг и ключи первого. Плюс max+1 оставлял дыры
# навсегда: после удаления exit'а 2 при живом 3 следующим снова становился 4.
RESERVE=$(/usr/local/sbin/awg-cascade-exit-reserve.sh acquire "cli:$EXIT_IP") \
    || err "не удалось зарезервировать индекс exit'а"
NEXT_IDX=$(echo "$RESERVE" | awk '{print $1}')
RESERVE_TOKEN=$(echo "$RESERVE" | awk '{print $2}')
[ -n "$NEXT_IDX" ] || err "бронь вернула пустой индекс"
# Оборвались на provisioning — бронь не должна держать индекс до TTL.
trap '[ -n "${RESERVE_TOKEN:-}" ] && /usr/local/sbin/awg-cascade-exit-reserve.sh release "$RESERVE_TOKEN" >/dev/null 2>&1 || true' EXIT
info "Локальный интерфейс будет awg${NEXT_IDX} (бронь взята)"

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
    sshx "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
        grep -qxF '$BOT_PUB' ~/.ssh/authorized_keys 2>/dev/null || \
        echo '$BOT_PUB' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" \
        >/dev/null 2>&1 || err "не удалось добавить ключ бота на exit"

    ssh -i "$SSH_DIR/id_ed25519" $SSH_OPTS -o BatchMode=yes -o PasswordAuthentication=no \
        "root@$EXIT_IP" 'echo ok' >/dev/null 2>&1 \
        || err "ключ бота добавлен, но вход по нему не работает — прерываю ДО отключения пароля"
    ok "Ключ бота добавлен и проверен"
else
    warn "$SSH_DIR/id_ed25519.pub не найден — бот не сможет управлять этим exit'ом"
fi

# 5. Запускаем setup-exit.sh на exit. Он сам определит fresh/SHARED и вернёт JSON.
info "Провижу exit (это может занять до 10 мин на свежем сервере)..."
EXIT_RAW=$(sshx "chmod +x /root/setup-exit.sh && \
    BATCH=1 TERM=xterm EXIT_INDEX=$NEXT_IDX RU_TUNNEL_OCTET=$((100 + NEXT_IDX)) \
    RU_PUBLIC_IP='$RU_PUBLIC_IP' RU_PUBKEY='$RU_PUBKEY' RU_PSK='$RU_PSK' \
    bash /root/setup-exit.sh") || err "setup-exit.sh упал на exit (см. вывод выше)"

# 6. Извлекаем JSON-блок (stdout = только JSON, но подстрахуемся sed'ом)
EXIT_JSON=$(echo "$EXIT_RAW" | sed -n '/^{/,/^}/p')
echo "$EXIT_JSON" | jq -e . >/dev/null 2>&1 || {
    echo "$EXIT_RAW" >&2
    err "Не удалось распарсить JSON от setup-exit.sh"
}
EXIT_IFACE=$(echo "$EXIT_JSON" | jq -r '.exit_iface // "awg-in"')
EXIT_PORT=$(echo "$EXIT_JSON" | jq -r '.exit_port')
SHARED=$(echo "$EXIT_JSON" | jq -r '.shared_mode // 0')
ok "Exit provisioned: iface=$EXIT_IFACE port=$EXIT_PORT shared=$SHARED"

# 7. Собираем args для awg-cascade-exit-add-ru.sh и создаём awg<N> на RU
# Приватный ключ и PSK берём через $ENV, а не через --arg: аргументы jq
# попадают в /proc/<pid>/cmdline, который читается любым локальным
# пользователем. Переменные окружения процесса — только владельцем и root.
ADD_ARGS=$(RU_PRIVKEY="$RU_PRIVKEY" RU_PSK="$RU_PSK" jq -n \
    --argjson idx "$NEXT_IDX" \
    --arg name    "$EXIT_NAME" \
    --arg pub     "$RU_PUBKEY" \
    --argjson info "$EXIT_JSON" \
    --arg tok     "$RESERVE_TOKEN" \
    '{exit_index: $idx, reserve_token: $tok, name: $name,
      ru_privkey: $ENV.RU_PRIVKEY, ru_pubkey: $pub, ru_psk: $ENV.RU_PSK,
      exit_info: $info}')

info "Создаю awg${NEXT_IDX} на RU + добавляю в state.json..."
# ADD_ARGS содержит приватный ключ и PSK — через stdin, не через argv.
RESULT=$(printf '%s' "$ADD_ARGS" | /usr/local/sbin/awg-cascade-exit-add-ru.sh -)     || err "awg-cascade-exit-add-ru.sh упал"
echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1 || err "exit-add-ru вернул ошибку: $RESULT"
ok "awg${NEXT_IDX} ($EXIT_NAME) поднят и добавлен в каскад"
# Бронь уже снята внутри exit-add-ru.sh той же записью, что добавила exit.
# Обнуляем токен, чтобы trap на выходе не отпустил чужую бронь.
RESERVE_TOKEN=""

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
