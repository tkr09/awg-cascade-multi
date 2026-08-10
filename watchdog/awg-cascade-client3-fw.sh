#!/bin/bash
# =============================================================================
# AWG Cascade Multi — firewall для второго клиентского интерфейса (3.0)
#
# Вызывается из awg-cascade-iptables.sh ПОСЛЕ базовых правил awg0 и ДО
# awg-cascade-interclient.sh. Порядок принципиален — см. ниже.
#
# No-op, если CLIENT3_IFACE не задан (то есть на нодах без второго интерфейса).
# =============================================================================
set -u
. /etc/awg-cascade/config 2>/dev/null || true

# ─── Самоустановка вызова в iptables.sh ──────────────────────────────────────
# awg-cascade-iptables.sh генерится setup.sh инлайном и потому НЕ синкается из
# репо — на живой ноде вызов нас в нём надо дописать один раз. Идемпотентно.
IPT=/usr/local/sbin/awg-cascade-iptables.sh
CALL='[ -x /usr/local/sbin/awg-cascade-client3-fw.sh ] && /usr/local/sbin/awg-cascade-client3-fw.sh || true'

case "${1:-}" in
--check-hook)
    grep -qF 'awg-cascade-client3-fw.sh' "$IPT" 2>/dev/null && exit 0 || exit 1 ;;
--hook)
    [ -f "$IPT" ] || { echo "  🔴 $IPT не найден"; exit 1; }
    grep -qF 'awg-cascade-client3-fw.sh' "$IPT" && { echo "  hook уже на месте"; exit 0; }
    # Строго ПЕРЕД interclient: тот вставляет свои исключения через -I 1, то
    # есть выше, а наши базовые правила должны лечь под ними.
    if grep -q 'awg-cascade-interclient\.sh' "$IPT"; then
        awk -v ins="$CALL" '/awg-cascade-interclient\.sh/ && !d {print ins; d=1} {print}' \
            "$IPT" > "$IPT.new"
    else
        cp "$IPT" "$IPT.new"; printf '%s\n' "$CALL" >> "$IPT.new"
    fi
    install -m 755 "$IPT.new" "$IPT" && rm -f "$IPT.new" && echo "  hook добавлен в $IPT"
    exit 0 ;;
esac

C3="${CLIENT3_IFACE:-}"
NET3="${CLIENT3_NET:-}"
[ -n "$C3" ] && [ -n "$NET3" ] || exit 0
ip link show "$C3" >/dev/null 2>&1 || exit 0

# ─── Изоляция между клиентскими интерфейсами ─────────────────────────────────
# ИДЁТ ПЕРВЫМ и это не стилистика: следующее правило разрешает "$C3 → awg+", а
# маска awg+ включает и сам awg0. Без явного DROP выше него клиент 3.0 получил
# бы прямой доступ к подсети клиентов 2.0 в обход изоляции.
#
# Обратное направление (awg0 → $C3) закрывает уже существующий kill-switch
# awg0 (`-i awg0 ! -o awg+ DROP`), добавленный выше нас: имя $C3 намеренно
# выбрано вне маски awg+, поэтому под `! -o awg+` оно попадает.
#
# Исключения для доверенных LAN-пар (в т.ч. кросс-интерфейсных) вставляет
# awg-cascade-interclient.sh через -I 1, то есть ВЫШЕ этих правил.
iptables -A FORWARD -i "$C3" -o awg0 -m comment --comment "awg-cascade-c3-iso" -j DROP

# ─── mangle: MARK → table 100 (ECMP exits), как у awg0 ───────────────────────
iptables -t mangle -A PREROUTING -i "$C3" -m comment --comment "awg-cascade-c3" -j MARK --set-mark 0x1

# ─── nat: подмена src на tunnel-IP при выходе на любой awgN ──────────────────
# Та же причина, что для awg0: exit принимает только src из AllowedIPs пира.
iptables -t nat -A POSTROUTING -s "$NET3" ! -o "$C3" -m comment --comment "awg-cascade-c3-masq" -j MASQUERADE

# ─── filter: выход ТОЛЬКО через exit-туннели ─────────────────────────────────
iptables -A FORWARD -i "$C3" -o awg+ -m comment --comment "awg-cascade-c3" -j ACCEPT
iptables -A FORWARD -i awg+ -o "$C3" -m comment --comment "awg-cascade-c3" -j ACCEPT
iptables -A FORWARD -i "$C3" ! -o awg+ -m comment --comment "awg-cascade-c3-killsw" -j DROP
