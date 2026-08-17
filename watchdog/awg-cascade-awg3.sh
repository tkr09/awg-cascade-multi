#!/bin/bash
# =============================================================================
# AWG Cascade Multi — включение AmneziaWG 3.0 на туннеле RU ↔ exit
#
# AWG 3.0 (вышел 24.07.2026) добавляет три независимые фичи поверх 2.0:
#   1. HeaderProtectionKey      — шифрование заголовков WireGuard (ChaCha20).
#                                 Убирает главную DPI-сигнатуру. Ключ СИММЕТРИЧНЫЙ.
#   2. ContentPaddingAddition   — набивка случайными байтами: маскирует
#                                 характерные размеры мелких пакетов.
#   3. Рандомизация 6 таймеров  — убирает «метрономность» handshake/keepalive.
#
# Скрипт правит конфиги ОБЕИХ сторон туннеля и применяет их через syncconf
# (без пересоздания интерфейса). Затрагивает ТОЛЬКО указанный туннель: на
# shared-exit сосед (другой RU на awg-in/awg-in-2) не трогается.
#
# ТРЕБОВАНИЯ:
#   • пакеты amneziawg >= 3.0 на обеих сторонах (иначе параметры отвергнутся);
#   • S1-S4 >= 12, иначе header protection МОЛЧА не включится — скрипт
#     проверяет и, с --fix-s, поднимает недостающие согласованно с обеих сторон.
#
# Usage:
#   awg-cascade-awg3.sh <awgN> on  [--fix-s]   — включить (--fix-s: поднять S<12)
#   awg-cascade-awg3.sh <awgN> off             — выключить, вернуть 2.0
#   awg-cascade-awg3.sh <awgN> reroll-s        — перегенерить S (свежая сигнатура)
#   awg-cascade-awg3.sh <awgN> status          — показать состояние обеих сторон
#   awg-cascade-awg3.sh all status             — по всем туннелям
#
# S-параметры генерятся СЛУЧАЙНО (S_MIN..S_MAX): одинаковое значение на разных
# туннелях само по себе стало бы сигнатурой для DPI.
# =============================================================================
set -u
. /etc/awg-cascade/config 2>/dev/null || true
STATE=/etc/awg-cascade/state.json
WG_DIR=/etc/amnezia/amneziawg
SSH_KEY=/etc/awg-cascade/ssh/id_ed25519
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"

: "${PAD_RANGE:=50-100}"
: "${REKEY_AFTER:=100-140}"
: "${REKEY_TIMEOUT:=4-7}"
: "${REJECT_AFTER:=170-200}"
: "${KEEPALIVE_TO:=8-13}"
: "${MAX_HS:=15-20}"
: "${S_MIN:=12}"
# S_NEW НЕ константа: одинаковое значение на нескольких туннелях само становится
# сигнатурой для DPI. Каждый вызов даёт свой случайный S в [S_MIN..S_MAX].
: "${S_MAX:=40}"
rand_s() { echo $(( S_MIN + RANDOM % (S_MAX - S_MIN + 1) )); }

IFACE="${1:-}"; ACTION="${2:-status}"; FIXS="${3:-}"
[ -z "$IFACE" ] && { sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 1; }

exit_info() {  # $1=iface → "ip exit_iface name"
    jq -r --arg i "$1" '.exits[] | select(.interface==$i) | "\(.ip) \(.exit_iface // "awg-in") \(.name)"' "$STATE" 2>/dev/null
}

# ─── status ───────────────────────────────────────────────────────────────────
show_status() {
    local i="$1" info ip eif nm
    info=$(exit_info "$i"); [ -z "$info" ] && { echo "  $i: нет в state.json"; return; }
    read -r ip eif nm <<<"$info"
    local s4 hpk pad rek hs age
    s4=$(awg showconf "$i" 2>/dev/null | grep -oP '^S4 = \K.*')
    hpk=$(awg showconf "$i" 2>/dev/null | grep -c '^HeaderProtectionKey')
    pad=$(awg showconf "$i" 2>/dev/null | grep -oP '^ContentPaddingAddition = \K.*')
    rek=$(awg showconf "$i" 2>/dev/null | grep -oP '^RekeyAfterTime = \K.*')
    hs=$(awg show "$i" latest-handshakes 2>/dev/null | awk '{print $2}')
    [ -n "${hs:-}" ] && [ "$hs" != "0" ] && age="$(( $(date +%s) - hs ))s" || age="НЕТ"
    local mode="2.0"
    [ "${hpk:-0}" -gt 0 ] && [ "${pad:-0}" != "0" ] && mode="3.0 (все)"
    [ "${hpk:-0}" -gt 0 ] && [ "${pad:-0}" = "0" ] && mode="3.0 (только header)"
    printf "  %-5s %-6s %-16s S4=%-3s hs=%-8s %s\n" "$i" "$nm" "$mode" "${s4:-?}" "$age" "$eif@$ip"
}

if [ "$IFACE" = "all" ]; then
    echo "=== AWG 3.0: состояние туннелей ==="
    for i in $(jq -r '.exits[].interface' "$STATE" 2>/dev/null); do show_status "$i"; done
    exit 0
fi

CONF="$WG_DIR/$IFACE.conf"
[ -f "$CONF" ] || { echo "🔴 $CONF не найден"; exit 1; }
INFO=$(exit_info "$IFACE")
[ -z "$INFO" ] && { echo "🔴 $IFACE нет в state.json"; exit 1; }
read -r EXIT_IP EXIT_IF EXIT_NAME <<<"$INFO"

case "$ACTION" in
status) echo "=== $IFACE ($EXIT_NAME) ==="; show_status "$IFACE"; exit 0 ;;
on|off|reroll-s) ;;
*) echo "🔴 действие: on | off | status | reroll-s"; exit 1 ;;
esac

# ─── версия tools на обеих сторонах ──────────────────────────────────────────
LOCAL_V=$(awg --version 2>/dev/null | awk '{print $2}')
REMOTE_V=$(ssh $SSH_OPTS "root@$EXIT_IP" "awg --version 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
echo "→ $IFACE ↔ $EXIT_NAME ($EXIT_IF@$EXIT_IP)"
echo "  tools: RU=$LOCAL_V  exit=${REMOTE_V:-НЕДОСТУПЕН}"
[ -z "$REMOTE_V" ] && { echo "🔴 нет SSH к exit — прерываю"; exit 1; }
if [ "$ACTION" = "on" ]; then
    case "$LOCAL_V$REMOTE_V" in
        *v3.*v3.*) ;;
        *) echo "🔴 нужен amneziawg 3.x на ОБЕИХ сторонах (сначала обнови пакеты)"; exit 1 ;;
    esac
fi

# ─── remote-хелпер: правит конфиг exit-стороны и применяет ───────────────────
run_remote() {  # $1 = shell-код
    local tmp; tmp=$(mktemp)
    printf '%s\n' "$1" > "$tmp"
    scp $SSH_OPTS "$tmp" "root@$EXIT_IP:/tmp/.awg3-op.sh" >/dev/null 2>&1
    ssh $SSH_OPTS "root@$EXIT_IP" 'bash /tmp/.awg3-op.sh; rm -f /tmp/.awg3-op.sh' 2>/dev/null
    rm -f "$tmp"
}

# umask 077 в субшелле: `awg-quick strip` печатает конфиг ВМЕСТЕ с приватным
# ключом интерфейса, а /tmp доступен на чтение всем — при root-umask 022 файл
# создавался с правами 0644 и ключ был читаем всем на время операции.
sync_local()  { ( umask 077; awg-quick strip "$IFACE" > /tmp/.awg3-l.conf 2>/dev/null ) && awg syncconf "$IFACE" /tmp/.awg3-l.conf; rm -f /tmp/.awg3-l.conf; }

if [ "$ACTION" = "reroll-s" ]; then
    # Перегенерация S-параметров на живом туннеле: свежая уникальная сигнатура
    # без смены ключей. Полезно если S были выставлены одинаково/предсказуемо.
    echo "  → перегенерирую S1-S4 (случайно, $S_MIN..$S_MAX) на обеих сторонах"
    RSED=""
    for k in S1 S2 S3 S4; do
        old=$(grep -oP "^$k = \K.*" "$CONF")
        # S1-S3 обычно уже широкие и уникальные — трогаем только те, что <S_MIN
        # или равны дефолту-заглушке; S4 перегенерируем всегда (его мы правили).
        if [ "$k" = "S4" ] || [ "${old:-0}" -lt "$S_MIN" ]; then
            v=$(rand_s)
            echo "    $k: $old → $v"
            sed -i "s|^$k = .*|$k = $v|" "$CONF"
            RSED="$RSED sed -i 's|^$k = .*|$k = $v|' $WG_DIR/$EXIT_IF.conf;"
        fi
    done
    [ -z "$RSED" ] && { echo "    нечего менять"; exit 0; }
    run_remote "$RSED
( umask 077; awg-quick strip $EXIT_IF > /tmp/.c 2>/dev/null ) && awg syncconf $EXIT_IF /tmp/.c && echo '  exit: применено'; rm -f /tmp/.c"
    sync_local && echo "  RU: применено"
    sleep 6
    show_status "$IFACE"
    exit 0
fi

if [ "$ACTION" = "off" ]; then
    echo "  → выключаю 3.0 (возврат к 2.0)"
    sed -i '/^HeaderProtectionKey/d;/^ContentPaddingAddition/d;/^RekeyAfterTime/d;/^RekeyTimeout/d;/^RejectAfterTime/d;/^KeepaliveTimeout/d;/^MaxHandshakeAttempts/d' "$CONF"
    run_remote "sed -i '/^HeaderProtectionKey/d;/^ContentPaddingAddition/d;/^RekeyAfterTime/d;/^RekeyTimeout/d;/^RejectAfterTime/d;/^KeepaliveTimeout/d;/^MaxHandshakeAttempts/d' $WG_DIR/$EXIT_IF.conf
awg-quick down $EXIT_IF >/dev/null 2>&1; awg-quick up $EXIT_IF >/dev/null 2>&1 && echo '  exit: перезапущен'"
    awg-quick down "$IFACE" >/dev/null 2>&1; awg-quick up "$IFACE" >/dev/null 2>&1
    echo "  ✅ выключено (нужен полный down/up — syncconf не снимает параметры)"
    sleep 5; show_status "$IFACE"
    exit 0
fi

# ─── on ───────────────────────────────────────────────────────────────────────
# 1. проверка S1-S4 >= S_MIN
LOW=$(grep -E '^S[1-4] ' "$CONF" | awk -v m="$S_MIN" '$3 < m {printf "%s ", $1}')
if [ -n "$LOW" ]; then
    if [ "$FIXS" = "--fix-s" ]; then
        for k in $LOW; do
            v=$(rand_s)   # свой рандом на каждый параметр и туннель, не константа
            echo "  ⚠ $k < $S_MIN → $v (случайно) на обеих сторонах"
            sed -i "s|^$k = .*|$k = $v|" "$CONF"
            run_remote "sed -i 's|^$k = .*|$k = $v|' $WG_DIR/$EXIT_IF.conf" >/dev/null
        done
    else
        echo "  🔴 S-параметры ниже $S_MIN: ${LOW}— header protection НЕ включится."
        echo "     Повтори с --fix-s (поднимет до случайного $S_MIN..$S_MAX с обеих сторон)."
        exit 1
    fi
fi

# 2. общий ключ + блок параметров
KEY=$(openssl rand -base64 32)
BLOCK="HeaderProtectionKey = $KEY
ContentPaddingAddition = $PAD_RANGE
RekeyAfterTime = $REKEY_AFTER
RekeyTimeout = $REKEY_TIMEOUT
RejectAfterTime = $REJECT_AFTER
KeepaliveTimeout = $KEEPALIVE_TO
MaxHandshakeAttempts = $MAX_HS"

apply_block() {  # вставить/заменить блок в конфиге (локально)
    local c="$1"
    sed -i '/^HeaderProtectionKey/d;/^ContentPaddingAddition/d;/^RekeyAfterTime/d;/^RekeyTimeout/d;/^RejectAfterTime/d;/^KeepaliveTimeout/d;/^MaxHandshakeAttempts/d' "$c"
    awk -v blk="$BLOCK" '{print} /^PrivateKey/ && !d {print blk; d=1}' "$c" > "$c.new" && mv "$c.new" "$c"
    chmod 600 "$c"
}

echo "  → пишу конфиги (ключ ${KEY:0:12}…)"
apply_block "$CONF"
run_remote "$(declare -f apply_block); BLOCK='$BLOCK'; apply_block $WG_DIR/$EXIT_IF.conf
( umask 077; awg-quick strip $EXIT_IF > /tmp/.c 2>/dev/null ) && awg syncconf $EXIT_IF /tmp/.c && echo '  exit: применено'; rm -f /tmp/.c"
sync_local && echo "  RU: применено"

sleep 6
echo ""
show_status "$IFACE"
HS=$(awg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
if [ -n "${HS:-}" ] && [ "$HS" != "0" ] && [ $(( $(date +%s) - HS )) -lt 200 ]; then
    echo "  ✅ туннель жив на AWG 3.0"
else
    echo "  ⚠ handshake ещё не обновился — подожди ~1 мин и проверь: $0 $IFACE status"
    echo "     откат при необходимости: $0 $IFACE off"
fi
