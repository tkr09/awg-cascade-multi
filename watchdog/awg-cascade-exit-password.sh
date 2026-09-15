#!/bin/bash
# =============================================================================
# AWG Cascade Multi — временно вернуть вход по паролю на exit
#
# ЗАЧЕМ. Новая RU не может добавить уже работающий exit: вход по паролю там
# выключен, а её ключа в authorized_keys нет. Обмен ключами требует прочитать
# публичный ключ в консоли новой ноды — а её бот в этот момент нем, потому что
# без exit'а у него нет пути к Telegram.
#
# Окно с паролем разрывает этот круг: владелец открывает его из бота РАБОЧЕЙ
# RU (та ходит на exit по ключу), после чего провижининг с новой ноды проходит
# по паролю и сам же выключает его обратно — ssh-harden отрабатывает в конце.
#
# ОКНО ЗАКРЫВАЕТСЯ САМО, и закрытий два.
#
# Первое — таймер на абсолютное время: истёк срок, окно закрылось.
#
# Второе — тот же юнит, включённый в multi-user.target, то есть на ЗАГРУЗКУ.
# Он нужен потому, что одного таймера мало: перезагрузка внутри окна убивает
# отсчёт, и пароль остался бы включённым навсегда, а закрывать его было бы
# некому. Понадеяться на Persistent=true здесь нельзя — проверено на живом
# exit'е: он догоняет только запуски, пропущенные ПОСЛЕ последнего
# записанного, а stamp-файл создаётся уже при первом включении таймера, и
# просроченный OnCalendar не срабатывает вовсе.
#
# Побочный эффект принят сознательно: перезагрузка exit'а закрывает окно
# досрочно. Окно короткое и открывается под присмотром — переоткрыть дешевле,
# чем однажды оставить пароль включённым и не заметить.
#
# Имя drop-in'а начинается с 00 намеренно: sshd читает sshd_config.d по
# алфавиту и берёт ПЕРВОЕ значение. Наш hardening лежит в 99-, cloud-init в
# 50-, так что перебить их может только файл, стоящий раньше обоих.
#
# Usage:
#   awg-cascade-exit-password.sh <iface|ip> on [минуты]   # по умолчанию 30
#   awg-cascade-exit-password.sh <iface|ip> off
#   awg-cascade-exit-password.sh <iface|ip> status
# =============================================================================
set -euo pipefail
umask 077

[ "$EUID" -eq 0 ] || { echo '{"error":"нужен root"}' >&2; exit 1; }

STATE=/etc/awg-cascade/state.json
SSH_DIR=/etc/awg-cascade/ssh
KNOWN_HOSTS="$SSH_DIR/known_hosts"
[ -f "$KNOWN_HOSTS" ] || KNOWN_HOSTS=/etc/awg-cascade/known_hosts
DROPIN=/etc/ssh/sshd_config.d/00-awg-temp-password.conf
UNIT=awg-temp-password-off

TARGET="${1:-}"; ACTION="${2:-status}"; MINUTES="${3:-30}"
[ -n "$TARGET" ] || { echo '{"error":"нужен интерфейс или IP exit-а"}' >&2; exit 1; }
case "$ACTION" in on|off|status) ;; *) echo '{"error":"действие: on | off | status"}' >&2; exit 1 ;; esac
case "$MINUTES" in ''|*[!0-9]*) echo '{"error":"минуты — целое число"}' >&2; exit 1 ;; esac
[ "$MINUTES" -ge 5 ] && [ "$MINUTES" -le 120 ] \
    || { echo '{"error":"окно допустимо от 5 до 120 минут"}' >&2; exit 1; }

# Адрес берём ИЗ state.json, а не из аргумента: helper вызывает бот, то есть
# сетевой ввод, и «включи пароль на любом хосте» он предлагать не должен.
EXIT_JSON=$(jq -c --arg t "$TARGET" \
    'first((.exits // [])[] | select(.interface == $t or .ip == $t))' "$STATE" 2>/dev/null || true)
[ -n "$EXIT_JSON" ] && [ "$EXIT_JSON" != "null" ] \
    || { printf '{"error":"exit %s не найден в state.json"}\n' "$TARGET" >&2; exit 1; }
EXIT_IP=$(printf '%s' "$EXIT_JSON" | jq -r '.ip')
EXIT_NAME=$(printf '%s' "$EXIT_JSON" | jq -r '.name')

SSH_OPTS="-F /dev/null -i $SSH_DIR/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none
          -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS
          -o ConnectTimeout=15"

# Переменные уезжают в командной строке ssh: заданные локально перед вызовом
# функции до удалённой оболочки не доходят, и окно молча становилось бы всегда
# тридцатиминутным.
remote() { ssh $SSH_OPTS "root@$EXIT_IP" "DROPIN=$DROPIN UNIT=$UNIT MINUTES=$MINUTES bash -s" ; }

case "$ACTION" in
status)
    OUT=$(remote <<'REMOTE'
        echo "eff=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
        echo "dropin=$([ -f "$DROPIN" ] && echo yes || echo no)"
        echo "timer=$(systemctl is-active "$UNIT.timer" 2>/dev/null)"
        echo "until=$(systemctl show "$UNIT.timer" -p NextElapseUSecRealtime --value 2>/dev/null)"
REMOTE
) || { printf '{"error":"SSH к %s не удался"}\n' "$EXIT_NAME" >&2; exit 1; }
    ;;
on)
    # Сначала пишем drop-in, ПОТОМ проверяем конфиг и только затем перечитываем
    # sshd. Битый конфиг не должен доехать до работающего демона.
    OUT=$(remote <<'REMOTE'
        set -e
        DEADLINE=$(date -u -d "+${MINUTES:-30} minutes" '+%Y-%m-%d %H:%M:%S UTC')
        printf '# Временное окно, ставит awg-cascade-exit-password.sh\nPasswordAuthentication yes\n' > "$DROPIN"
        chmod 644 "$DROPIN"
        if ! sshd -t 2>/dev/null; then rm -f "$DROPIN"; echo "err=конфиг sshd не прошёл проверку"; exit 1; fi
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
        cat > "/etc/systemd/system/$UNIT.service" <<UNITEOF
[Unit]
Description=Закрыть временное окно входа по паролю (awg-cascade)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rm -f $DROPIN; (sshd -t && (systemctl reload ssh || systemctl reload sshd)) || true; systemctl disable --now $UNIT.timer; systemctl disable $UNIT.service'
[Install]
WantedBy=multi-user.target
UNITEOF
        cat > "/etc/systemd/system/$UNIT.timer" <<UNITEOF
[Unit]
Description=Таймер закрытия окна входа по паролю (awg-cascade)
[Timer]
OnCalendar=$DEADLINE
Persistent=true
AccuracySec=10s
[Install]
WantedBy=timers.target
UNITEOF
        systemctl daemon-reload
        # Таймер закроет окно по сроку, сервис в multi-user.target — на загрузке.
        systemctl enable --now "$UNIT.timer" >/dev/null 2>&1
        systemctl enable "$UNIT.service" >/dev/null 2>&1
        echo "eff=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
        echo "deadline=$DEADLINE"
        echo "timer=$(systemctl is-active "$UNIT.timer" 2>/dev/null)"
REMOTE
) || { printf '{"error":"не удалось открыть окно на %s"}\n' "$EXIT_NAME" >&2; exit 1; }
    ;;
off)
    OUT=$(remote <<'REMOTE'
        rm -f "$DROPIN"
        (sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd)) || true
        systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
        systemctl disable "$UNIT.service" >/dev/null 2>&1 || true
        echo "eff=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
        echo "timer=$(systemctl is-active "$UNIT.timer" 2>/dev/null)"
REMOTE
) || { printf '{"error":"не удалось закрыть окно на %s"}\n' "$EXIT_NAME" >&2; exit 1; }
    ;;
esac

# Отвечаем ПО ФАКТИЧЕСКОМУ значению sshd -T, а не по тому, что команда не
# упала: записать файл и перечитать конфиг — не то же самое, что включить вход.
EFF=$(printf '%s' "$OUT" | grep -m1 '^eff=' | cut -d= -f2-)
ERR=$(printf '%s' "$OUT" | grep -m1 '^err=' | cut -d= -f2- || true)
[ -z "$ERR" ] || { printf '{"error":"%s"}\n' "$ERR" >&2; exit 1; }

case "$ACTION:$EFF" in
    on:yes|off:no|status:*) ;;
    *) printf '{"error":"sshd сообщает passwordauthentication=%s — не то, что просили"}\n' "${EFF:-?}" >&2; exit 1 ;;
esac

jq -n --arg n "$EXIT_NAME" --arg ip "$EXIT_IP" --arg a "$ACTION" --arg eff "${EFF:-?}" \
      --arg dl "$(printf '%s' "$OUT" | grep -m1 '^deadline=' | cut -d= -f2- || true)" \
      --arg tm "$(printf '%s' "$OUT" | grep -m1 '^timer=' | cut -d= -f2- || true)" \
   '{ok: true, exit: $n, ip: $ip, action: $a, password_auth: $eff,
     deadline: (if $dl == "" then null else $dl end),
     timer: (if $tm == "" then null else $tm end)}'
