#!/bin/bash
# =============================================================================
# AWG Cascade Multi — обновление УЖЕ РАБОТАЮЩЕГО exit'а.
#
# ЗАЧЕМ. Пути обновления для exit'а в проекте не было вообще. Exit получал свои
# скрипты ровно один раз — при заведении, по SCP из $BOT_DIR/scripts, — и дальше
# застывал навсегда. awg-cascade-sync.sh здесь не помощник: он обслуживает
# только RU и клонирует репозиторий на себя, а на exit'е нет ни git, ни желания
# пускать его за репозиторием наружу.
#
# Из-за этого правки exit-стороны молча не доезжали. Пример, на котором это и
# всплыло: восстановление WARP после перезагрузки (v2.2.0) лежало и в репо, и на
# RU в $BOT_DIR/scripts, а на PL-1 продолжал работать прежний скрипт без него —
# и diagnose честно продолжал показывать «WARP не переживёт перезагрузку».
#
# ЧТО ДЕЛАЕТ: заливает exit-side скрипты из $BOT_DIR/scripts и переприменяет то,
# что идемпотентно (fail2ban, restore-юнит WARP). По флагу — пакеты ОС.
#
# ЧЕГО НЕ ДЕЛАЕТ НИКОГДА: не трогает awg-in*, ключи, конфиги интерфейсов и
# sshd_config. Один exit может обслуживать несколько RU, и обновление не должно
# ронять туннель соседа.
#
# Usage:
#   awg-cascade-exit-update.sh <awgN|IP|all> [--check] [--os]
#     --check  только показать расхождение, ничего не менять
#     --os     дополнительно apt-get upgrade на exit'е (без перезапуска сервисов)
# =============================================================================
set -u
# Config читаем строгим разбором, а не source (см. awg-cascade-cfg.sh).
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || . /etc/awg-cascade/config 2>/dev/null || true
: "${BOT_USER:=awgbot}"

STATE=/etc/awg-cascade/state.json
BOT_SCRIPTS="/opt/awg-cascade-bot/scripts"
SSH_KEY=/etc/awg-cascade/ssh/id_ed25519
KNOWN_HOSTS=/etc/awg-cascade/known_hosts
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=15 -o BatchMode=yes"

TARGET="${1:-}"
[ -z "$TARGET" ] && { echo "usage: $0 <awgN|IP|all> [--check] [--os]" >&2; exit 1; }
shift

CHECK=0
DO_OS=0
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        --os)    DO_OS=1 ;;
        *) echo "неизвестный аргумент: $a" >&2; exit 1 ;;
    esac
done

# Комплект, который живёт на exit'е. setup-exit.sh и awg2-params.sh нужны только
# при заведении, но кладём и их: тогда добавление ещё одного shared-слота на этом
# же сервере пойдёт актуальным кодом, а не тем, что приехал год назад.
BUNDLE="awg-cascade-exit-warp.sh awg-cascade-fail2ban.sh awg-cascade-ssh-harden.sh setup-exit.sh awg2-params.sh"

VER=$(cut -d' ' -f1 /etc/awg-cascade/version 2>/dev/null || echo unknown)
COMMIT=$(cut -d' ' -f2 /etc/awg-cascade/version 2>/dev/null || echo "?")

# ─── список целей ────────────────────────────────────────────────────────────
if [ "$TARGET" = "all" ]; then
    targets=$(jq -r '.exits[]? | select(.enabled) | "\(.interface)|\(.ip)|\(.name)|\(.exit_iface // "awg-in")"' "$STATE" 2>/dev/null)
else
    targets=$(jq -r --arg t "$TARGET" \
        '.exits[]? | select(.interface == $t or .ip == $t) | "\(.interface)|\(.ip)|\(.name)|\(.exit_iface // "awg-in")"' \
        "$STATE" 2>/dev/null)
fi
[ -z "$targets" ] && { echo "🔴 не нашёл exit '$TARGET' в $STATE" >&2; exit 1; }

rc_total=0

# Цикл читает со СВОЕГО дескриптора 3, а не со stdin.
#
# Иначе первый же `ssh` внутри тела съедает остаток списка, и обновляется ровно
# одна нода из всех — молча, с кодом 0. В этом проекте на том же самом уже
# спотыкались (`ssh-keygen -lf -` в цикле по authorized_keys), так что ловушка
# известная: любая команда в теле цикла, читающая stdin, ворует вход у read.
while IFS='|' read -r IFACE IP NAME EIFACE <&3; do
    [ -n "$IP" ] || continue
    echo "═══ $NAME ($IP, локально $IFACE, на exit'е $EIFACE) ═══"

    if ! ssh $SSH_OPTS "root@$IP" 'echo ok' >/dev/null 2>&1; then
        echo "  🔴 SSH недоступен — пропускаю"
        rc_total=1
        continue
    fi

    # ─── что расходится ──────────────────────────────────────────────────────
    changed=""
    for f in $BUNDLE; do
        [ -f "$BOT_SCRIPTS/$f" ] || continue
        lsum=$(sha256sum "$BOT_SCRIPTS/$f" | cut -d' ' -f1)
        rsum=$(ssh $SSH_OPTS "root@$IP" "sha256sum /usr/local/sbin/$f 2>/dev/null | cut -d' ' -f1")
        [ "$lsum" = "$rsum" ] || changed="$changed $f"
    done
    remote_ver=$(ssh $SSH_OPTS "root@$IP" "cut -d' ' -f1 /etc/awg-cascade/version 2>/dev/null")

    if [ -z "$changed" ] && [ "$remote_ver" = "$VER" ]; then
        echo "  ✅ уже на $VER, расхождений нет"
    else
        echo "  версия на exit'е: ${remote_ver:-нет штампа} → $VER"
        [ -n "$changed" ] && echo "  расходятся:$changed"
    fi

    if [ "$CHECK" = "1" ]; then
        [ -n "$changed" ] && rc_total=2
        continue
    fi

    # ─── заливка ─────────────────────────────────────────────────────────────
    for f in $changed; do
        if ! scp $SSH_OPTS "$BOT_SCRIPTS/$f" "root@$IP:/tmp/.upd-$f" >/dev/null 2>&1; then
            echo "  🔴 не передался $f"
            rc_total=1
            continue
        fi
        if ssh $SSH_OPTS "root@$IP" "install -m 755 -o root -g root /tmp/.upd-$f /usr/local/sbin/$f && rm -f /tmp/.upd-$f"; then
            echo "  обновлён: $f"
        else
            echo "  🔴 не установился $f"
            rc_total=1
        fi
    done

    # ─── переприменение идемпотентного ───────────────────────────────────────
    # fail2ban пересобирает ignoreip из живых endpoint'ов. Адрес ЭТОЙ RU
    # передаём явно: на exit'е он читается из endpoint'ов пиров, а если наш
    # туннель в этот момент молчит, прочитать его неоткуда (пункт 11 аудита).
    if ssh $SSH_OPTS "root@$IP" "EXTRA_IGNOREIP='${RU_PUBLIC_IP:-}' /usr/local/sbin/awg-cascade-fail2ban.sh >/dev/null 2>&1"; then
        echo "  fail2ban переприменён"
    else
        echo "  ⚠️ fail2ban вернул ошибку — проверь на exit'е"
        rc_total=1
    fi

    # WARP: restore сам разбирается, включён он здесь или нет. Включён —
    # переприменит маршруты и поставит юнит восстановления после перезагрузки.
    # Не заводился — state-файлов нет, и это честный no-op.
    warp_out=$(ssh $SSH_OPTS "root@$IP" "[ -x /usr/local/sbin/awg-cascade-exit-warp.sh ] && /usr/local/sbin/awg-cascade-exit-warp.sh restore 2>/dev/null")
    if [ -n "$warp_out" ]; then
        restored=$(echo "$warp_out" | jq -r '.restored // 0' 2>/dev/null)
        failed=$(echo "$warp_out" | jq -r '.failed // 0' 2>/dev/null)
        if [ "${failed:-0}" -gt 0 ]; then
            echo "  🔴 WARP: восстановлено ${restored:-0}, не удалось $failed"
            rc_total=1
        elif [ "${restored:-0}" -gt 0 ]; then
            echo "  WARP: переприменён на $restored интерфейсе(ах), юнит восстановления установлен"
        else
            echo "  WARP: на этом exit'е не используется"
        fi
    fi

    # ─── пакеты ОС (только по явному --os) ───────────────────────────────────
    if [ "$DO_OS" = "1" ]; then
        echo "  обновляю пакеты ОС..."
        # NEEDRESTART_MODE=l — список, БЕЗ перезапуска сервисов. На работающем
        # exit'е перезапуск демонов и есть вся дисруптивность, а обновления
        # здесь несекьюрные и вполне ждут штатной перезагрузки.
        os_out=$(ssh $SSH_OPTS "root@$IP" 'n=$(apt-get -s -q upgrade 2>/dev/null | grep -cE "^Inst "); if [ "${n:-0}" -eq 0 ]; then echo "уже актуальны"; else DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null 2>&1 && echo "обновлено пакетов: $n" || echo "ОШИБКА apt upgrade"; fi; [ -f /var/run/reboot-required ] && echo "требуется перезагрузка (сработает в своё окно)"; exit 0')
        echo "$os_out" | sed 's/^/    /'
        echo "$os_out" | grep -q "ОШИБКА" && rc_total=1
    fi

    # ─── штамп версии ────────────────────────────────────────────────────────
    # Без него exit в сводке каскада значится с пустой версией, и понять, какой
    # на нём код, можно было только сравнением файлов руками. Путь тот же, что
    # у RU (/etc/awg-cascade/version) — его и читает диагностика.
    if ssh $SSH_OPTS "root@$IP" "mkdir -p /etc/awg-cascade && printf '%s %s %s\n' '$VER' '$COMMIT' \"\$(date -Iseconds)\" > /etc/awg-cascade/version"; then
        echo "  version-stamp: $VER ($COMMIT)"
    else
        echo "  ⚠️ не удалось записать version-stamp"
        rc_total=1
    fi

    # ─── проверка, что ничего не уронили ─────────────────────────────────────
    hs=$(ssh $SSH_OPTS "root@$IP" "awg show $EIFACE latest-handshakes 2>/dev/null | awk '{print \$2}' | sort -rn | head -1")
    if [ -n "${hs:-}" ] && [ "$hs" != "0" ]; then
        age=$(( $(date +%s) - hs ))
        echo "  проверка: $EIFACE handshake ${age}s назад"
        if [ "$age" -gt 300 ]; then
            echo "  🔴 handshake старше 5 минут — посмотри туннель"
            rc_total=1
        fi
    else
        echo "  🔴 проверка: у $EIFACE нет handshake"
        rc_total=1
    fi
done 3<<TARGETS
$targets
TARGETS

exit $rc_total
