#!/bin/bash
# =============================================================================
# AWG Cascade Multi — положить публичный ключ ДРУГОЙ RU на существующий exit
#
# ЗАЧЕМ. Exit после провижининга закрыт: вход по паролю выключает ssh-harden,
# и войти на него может только та RU, чей ключ уже лежит в authorized_keys.
# Поэтому подключить уже работающий exit к НОВОЙ RU невозможно её же силами —
# у неё нет доступа. Ключ должен положить кто-то, у кого доступ есть: RU, для
# которой этот exit уже свой. Ровно этот шаг раньше делался руками с машины
# владельца и был единственным местом, где без ручной работы не обойтись.
#
# Ключ читается со STDIN, а не из argv: он не секрет, но argv виден в ps всем
# пользователям ноды, и класть туда чужие идентификаторы незачем.
#
# Usage:
#   awg-cascade-exit-authkey.sh <iface|ip>        < key.pub
#   echo 'ssh-ed25519 AAAA... bot@ru2' | awg-cascade-exit-authkey.sh awg1
#
# Вывод: JSON. Код 0 — ключ на месте (добавлен или уже был), 1 — нет.
# =============================================================================
set -euo pipefail
umask 077

[ "$EUID" -eq 0 ] || { echo '{"error":"нужен root"}' >&2; exit 1; }

STATE=/etc/awg-cascade/state.json
SSH_DIR=/etc/awg-cascade/ssh
KNOWN_HOSTS="$SSH_DIR/known_hosts"
[ -f "$KNOWN_HOSTS" ] || KNOWN_HOSTS=/etc/awg-cascade/known_hosts

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo '{"error":"нужен интерфейс или IP exit-а"}' >&2; exit 1; }

# ─── Куда. Только известный exit ─────────────────────────────────────────────
#
# Адрес берём ИЗ state.json, а не из аргумента. Иначе helper становится
# универсальным «положи ключ на любой хост от root», а его вызывает бот —
# то есть сетевой ввод. Не нашли exit в состоянии — отказ.
EXIT_JSON=$(jq -c --arg t "$TARGET" \
    'first((.exits // [])[] | select(.interface == $t or .ip == $t))' "$STATE" 2>/dev/null || true)
[ -n "$EXIT_JSON" ] && [ "$EXIT_JSON" != "null" ] \
    || { printf '{"error":"exit %s не найден в state.json"}\n' "$TARGET" >&2; exit 1; }
EXIT_IP=$(printf '%s' "$EXIT_JSON" | jq -r '.ip')
EXIT_NAME=$(printf '%s' "$EXIT_JSON" | jq -r '.name')

# ─── Что. Ровно один настоящий публичный ключ ────────────────────────────────
#
# Проверок две, и они разные. Тип ключа первым полем отсекает строки с
# опциями (command=, from=, environment=) — их пускать нельзя: через них в
# authorized_keys заезжает чужое поведение, а не просто доступ. ssh-keygen -lf
# затем подтверждает, что base64 — действительно ключ, а не текст.
#
# Читаем ПЕРВУЮ непустую строку и требуем, чтобы других не было: вставка
# нескольких строк разом — это уже не «добавить ключ».
KEY=""
EXTRA=0
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "${line// /}" ] && continue
    if [ -z "$KEY" ]; then KEY="$line"; else EXTRA=1; fi
done
[ -n "$KEY" ] || { echo '{"error":"пустой ввод — ключ не получен"}' >&2; exit 1; }
[ "$EXTRA" = 0 ] || { echo '{"error":"во вводе больше одной строки — ожидается один ключ"}' >&2; exit 1; }

case "$KEY" in
    ssh-ed25519' '*|ssh-rsa' '*|ecdsa-sha2-nistp256' '*|ecdsa-sha2-nistp384' '*|ecdsa-sha2-nistp521' '*) ;;
    *) echo '{"error":"строка не начинается с типа ключа (опции в authorized_keys не принимаются)"}' >&2; exit 1 ;;
esac

TMPKEY=$(mktemp); trap 'rm -f "$TMPKEY"' EXIT
printf '%s\n' "$KEY" > "$TMPKEY"
FPR=$(ssh-keygen -lf "$TMPKEY" 2>/dev/null | awk '{print $2}') \
    || { echo '{"error":"ssh-keygen не признал это публичным ключом"}' >&2; exit 1; }
[ -n "$FPR" ] || { echo '{"error":"не удалось снять отпечаток ключа"}' >&2; exit 1; }

# ─── Кладём ──────────────────────────────────────────────────────────────────
SSH_OPTS="-F /dev/null -i $SSH_DIR/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none
          -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS
          -o ConnectTimeout=15"

# Перевод строки перед ключом обязателен: authorized_keys из образа хостера
# может не оканчиваться им, и тогда ключ приклеивается к комментарию соседней
# строки. Файл при этом выглядит правильным, а sshd видит на один ключ меньше.
RESULT=$(printf '%s\n' "$KEY" | ssh $SSH_OPTS "root@$EXIT_IP" '
    set -e
    umask 077
    IFS= read -r NEWKEY
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    if [ -s ~/.ssh/authorized_keys ] && [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then
        echo >> ~/.ssh/authorized_keys
    fi
    if grep -qxF "$NEWKEY" ~/.ssh/authorized_keys; then
        echo "already"
    else
        printf "%s\n" "$NEWKEY" >> ~/.ssh/authorized_keys
        echo "added"
    fi
    ssh-keygen -lf ~/.ssh/authorized_keys 2>/dev/null | awk "{print \$2}"
') || { printf '{"error":"SSH к exit %s (%s) не удался"}\n' "$EXIT_NAME" "$EXIT_IP" >&2; exit 1; }

ACTION=$(printf '%s' "$RESULT" | head -1)

# Проверяем по ОТПЕЧАТКУ, а не по тому, что запись прошла. Если ключ всё же
# склеился с соседней строкой, grep его найдёт, а sshd — нет; отпечаток видит
# ровно то же, что и sshd.
if ! printf '%s' "$RESULT" | tail -n +2 | grep -qxF "$FPR"; then
    printf '{"error":"ключ записан, но sshd его не видит — вероятно склеился со строкой рядом","fingerprint":"%s"}\n' "$FPR" >&2
    exit 1
fi

jq -n --arg n "$EXIT_NAME" --arg ip "$EXIT_IP" --arg f "$FPR" --arg a "$ACTION" \
      --argjson total "$(printf '%s' "$RESULT" | tail -n +2 | grep -c .)" \
   '{ok: true, exit: $n, ip: $ip, fingerprint: $f,
     added: ($a == "added"), keys_total: $total}'
