#!/bin/bash
# =============================================================================
# Регрессия R04 аудита v2.8.5: WARP off отличает «правил нет» от «прочитать
# не удалось» и не опускает общий warp0 при неизвестном числе пользователей.
#
# Исполняет НАСТОЯЩИЕ cmd_off и функции наблюдения из exit-warp.sh на настоящих
# ip/iptables, но в отдельном network namespace — правила хоста отсюда не
# видны. Отказы чтения подставляются поверх настоящих команд.
#
# Всё, что трогало бы хост, заменено заглушками, а единственный абсолютный путь
# в cmd_off (сохранение rules.v4) переписывается на временный каталог. Перед
# исполнением проверяется, что в извлечённом коде не осталось ни одного /etc.
#
# Запуск (root, Linux):
#   ip netns add warp-t
#   ip netns exec warp-t bash tests/exit_warp_off.sh exit-side/awg-cascade-exit-warp.sh
#   ip netns del warp-t
#
# Код выхода — число проваленных сценариев. Против кода до R04 сценарии 3 и 4
# проваливаются: отказ чтения там выдавал себя за отсутствие правил.
# =============================================================================
set -u
SRC="${1:?путь к awg-cascade-exit-warp.sh}"
TABLE=200
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

[ "$(ip netns identify 2>/dev/null)" != "" ] \
    || { echo "ОТКАЗ: запускать только внутри отдельного network namespace"; exit 99; }

extract() {
    # Новый код держит наблюдение отдельным блоком; у старого есть только
    # count_active_marks — берём, что есть, чтобы тест годился для сравнения.
    if grep -q '^# ─── Наблюдение за селекторами WARP' "$SRC"; then
        sed -n '/^# ─── Наблюдение за селекторами WARP/,/^# ─── конец наблюдения/p' "$SRC"
    else
        sed -n '/^count_active_marks() {/,/^}/p' "$SRC"
    fi
    sed -n '/^cmd_off() {/,/^}/p' "$SRC" | sed "s#/etc/iptables/rules.v4#$SCRATCH/rules.v4#g"
}
CODE=$(extract)
if printf '%s' "$CODE" | grep -q '/etc/'; then echo "ОТКАЗ: в извлечённом коде остался путь /etc"; exit 99; fi

setup_iface() {  # как в скрипте: awg-in → 0x10/990, awg-in-N → 0x(0f+N)/989+N
    IFACE="$1"
    case "$IFACE" in awg-in) IDX=1 ;; *) IDX="${IFACE##*-}" ;; esac
    MARK=$(printf '0x%x' $((0x10 + IDX - 1)))
    RULE_PRIO=$((990 + IDX - 1))
    WARP_STATE="$SCRATCH/warp-$IFACE.state"
}
reset_net() {
    command iptables -w 30 -t mangle -F PREROUTING
    for p in 990 991; do while command ip rule del priority $p 2>/dev/null; do :; done; done
    rm -f "$SCRATCH"/*.state "$SCRATCH/calls"
}
add_user() {  # add_user <iface> <копий маркировки>; одинаковые ip rule ядро не принимает
    local i; setup_iface "$1"
    for i in $(seq "$2"); do
        command iptables -w 30 -t mangle -A PREROUTING -i "$1" -j MARK --set-mark "$MARK"
    done
    command ip rule add fwmark "$MARK" lookup $TABLE priority "$RULE_PRIO"
}
marks() { command iptables -w 30 -t mangle -S PREROUTING | grep -c -- '-j MARK'; }
rules() { command ip -j rule show | jq -c '[.[] | select(.table == "200") | .priority]'; }

# ─── заглушки: всё, что трогало бы хост ──────────────────────────────────────
log() { :; }
die() { jq -cn --arg e "$1" '{ok:false, error:$e}'; exit 1; }
warp_guard()     { echo guard     >> "$SCRATCH/calls"; }
warp_unguard()   { echo unguard   >> "$SCRATCH/calls"; }
warp_unprotect() { echo unprotect >> "$SCRATCH/calls"; }
persist_warp()   { echo persist   >> "$SCRATCH/calls"; }
awg-quick()      { echo "down"    >> "$SCRATCH/calls"; }
eval "$CODE"

FAIL=""
ip() {
    # И новый (`ip -j rule show`), и старый (`ip rule show`) способ чтения.
    if [ "$FAIL" = rule-read ]; then case " $* " in *" rule show"*) return 2 ;; esac; fi
    command ip "$@"
}
iptables() {
    case "$FAIL" in
        # Старый код читал через -C, новый через -S: отказываем обоим.
        mangle-read) for a in "$@"; do case "$a" in -S|-C) return 4 ;; esac; done ;;
        mangle-noop) for a in "$@"; do [ "$a" = -D ] && return 0; done ;;
    esac
    command iptables "$@"
}

failures=0
# check <название> <FAIL> <iface> <код> <state yes|no> <down yes|no> <unguard yes|no> <marks> <rules>
check() {
    local title="$1" out rc state down ung got want
    FAIL="$2"; setup_iface "$3"
    out=$( (cmd_off) 2>&1 ); rc=$?
    FAIL=""
    state=$([ -f "$WARP_STATE" ] && echo yes || echo no)
    down=$(grep -qx down "$SCRATCH/calls" 2>/dev/null && echo yes || echo no)
    ung=$(grep -qx unguard "$SCRATCH/calls" 2>/dev/null && echo yes || echo no)
    got="код=$rc state=$state down=$down unguard=$ung marks=$(marks) rules=$(rules)"
    want="код=$4 state=$5 down=$6 unguard=$7 marks=$8 rules=$9"
    if [ "$got" = "$want" ]; then
        echo "PASS  $title"
    else
        failures=$((failures + 1))
        echo "FAIL  $title"
        echo "      ожидалось: $want"
        echo "      получено:  $got"
        echo "      ответ:     $(printf '%s' "$out" | tail -1 | cut -c1-120)"
    fi
}

reset_net; add_user awg-in 2; add_user awg-in-2 1
check "1. общий exit: снимаем awg-in с дубликатом маркировки, awg-in-2 остаётся" \
      "" awg-in 0 yes no yes 1 '[991]'
reset_net; add_user awg-in 1
check "2. последний пользователь — warp0 опускается" \
      "" awg-in 0 yes yes yes 0 '[]'
reset_net; add_user awg-in 1; add_user awg-in-2 1
check "3. ip rule не читается — отказ, guard и состояние на месте" \
      rule-read awg-in 1 no no no 1 '[990,991]'
reset_net; add_user awg-in 1; add_user awg-in-2 1
check "4. маркировки не читаются — warp0 другой RU не трогаем" \
      mangle-read awg-in 1 no no no 2 '[991]'
reset_net; add_user awg-in 1
check "5. iptables -D «успешен», но ничего не удаляет — ограниченный повтор и отказ" \
      mangle-noop awg-in 1 no no no 1 '[]'
reset_net
echo "провалено: $failures из 5"
exit "$failures"
