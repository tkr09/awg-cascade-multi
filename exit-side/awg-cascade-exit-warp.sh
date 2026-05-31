#!/bin/bash
# =============================================================================
# AWG Cascade Exit — WARP manager (interface-aware, multi-RU safe)
#
# Cloudflare WARP toggle для exit-сервера. Когда WARP включён для конкретного
# cascade-интерфейса (awg-in / awg-in-2 / ...), трафик приходящий из этого
# интерфейса уходит наружу через warp0 (Cloudflare), а не через eth0.
#
# Один exit может обслуживать НЕСКОЛЬКО RU (awg-in для RU-1, awg-in-2 для RU-2).
# WARP управляется НЕЗАВИСИМО для каждого: своя fwmark + ip rule. warp0 общий
# (один wgcf-аккаунт на сервер): поднимается на первом 'on', опускается на
# последнем 'off'. Так RU-2 не ломает WARP у RU-1 и наоборот.
#
# Команды (вызываются ботом по SSH):  <cmd> [iface]
#   install   — wgcf + warp0.conf (shared) + mark-rule для iface
#   on        — поднять warp0 (если ещё не поднят) + routing для iface
#   off       — убрать routing для iface; warp0 down если больше никто не юзает
#   status    — JSON статус для iface
#   rekey     — пересоздать WARP-аккаунт (новый exit IP) — влияет на все iface
#   uninstall — убрать routing для iface; полный снос если iface не осталось
#
# iface по умолчанию = awg-in (обратная совместимость со старым ботом).
# Stdout всегда JSON.
# =============================================================================

set -u
WGCF_VERSION=2.2.27
WGCF_BIN=/usr/local/bin/wgcf
WARP_DIR=/etc/awg-cascade-exit
WARP_CONF=/etc/amnezia/amneziawg/warp0.conf
WARP_LOG=$WARP_DIR/warp.log
TABLE=200          # общая table → warp0 (все марки сюда)

mkdir -p $WARP_DIR

log() { echo "$(date -Iseconds) [${IFACE:-?}] $*" >> $WARP_LOG; }

die() {
    log "ERROR: $1"
    jq -n --arg e "$1" '{ok:false, error:$e}'
    exit 1
}

# ─── iface → mark / priority ──────────────────────────────────────────────────
# awg-in → idx 1 → mark 0x10, prio 990
# awg-in-2 → idx 2 → mark 0x11, prio 991
# awg-in-N → idx N → mark 0x(0f+N), prio 989+N
IFACE="${2:-awg-in}"
case "$IFACE" in
    awg-in)   IDX=1 ;;
    awg-in-*) IDX="${IFACE##*-}" ;;
    *) die "bad iface: $IFACE (ожидается awg-in или awg-in-N)" ;;
esac
[[ "$IDX" =~ ^[0-9]+$ ]] || die "bad iface index: $IFACE"
MARK=$(printf '0x%x' $((0x10 + IDX - 1)))
RULE_PRIO=$((990 + IDX - 1))
WARP_STATE="$WARP_DIR/warp-$IFACE.state"

# Сколько cascade-интерфейсов сейчас маркируются в warp (т.е. WARP on)
count_active_marks() {
    iptables -t mangle -S PREROUTING 2>/dev/null \
        | grep -cE '\-i awg-in(-[0-9]+)? .*MARK' || true
}

# Получаем внешний IP через warp0
detect_warp_ip() {
    local ip
    ip=$(timeout 8 curl -s --interface warp0 --max-time 6 \
         https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
         | awk -F= '/^ip=/{print $2}')
    [ -z "$ip" ] && ip=$(timeout 8 curl -s --interface warp0 --max-time 6 \
         -4 https://api.ipify.org 2>/dev/null)
    echo "${ip:-}"
}

# ─── install (shared warp0 + per-iface mark rule) ─────────────────────────────

cmd_install() {
    log "INSTALL begin"

    # 1. wgcf (если ещё нет) — shared
    if [ ! -x "$WGCF_BIN" ]; then
        local arch wa
        arch=$(uname -m)
        case "$arch" in
            x86_64)  wa="amd64" ;;
            aarch64) wa="arm64" ;;
            armv7l)  wa="armv7" ;;
            *) die "unsupported arch $arch" ;;
        esac
        curl -fsSL -o "$WGCF_BIN" \
            "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wa}" \
            || die "download wgcf failed"
        chmod +x "$WGCF_BIN"
        log "  wgcf $WGCF_VERSION installed"
    fi

    # 2-5. warp0.conf — создаём только если ещё нет (shared между всеми iface)
    if [ ! -f "$WARP_CONF" ]; then
        cd $WARP_DIR
        if [ ! -f wgcf-account.toml ]; then
            log "  registering WARP account..."
            yes | $WGCF_BIN register >/dev/null 2>&1 || die "wgcf register failed"
        fi
        [ -f wgcf-account.toml ] || die "wgcf-account.toml missing"
        $WGCF_BIN generate >/dev/null 2>&1 || die "wgcf generate failed"
        [ -f wgcf-profile.conf ] || die "wgcf-profile.conf not generated"

        local endpoint_ip privkey pubkey address
        endpoint_ip=$(getent ahostsv4 engage.cloudflareclient.com 2>/dev/null | awk 'NR==1{print $1}')
        [ -z "$endpoint_ip" ] && endpoint_ip="162.159.193.10"
        privkey=$(awk -F' = ' '/^PrivateKey/{print $2}' wgcf-profile.conf)
        pubkey=$(awk  -F' = ' '/^PublicKey/{print $2}'  wgcf-profile.conf)
        address=$(awk -F' = ' '/^Address/{print $2}'    wgcf-profile.conf | head -1)

        cat > "$WARP_CONF" <<EOF
[Interface]
PrivateKey = $privkey
Address = $address
MTU = 1280
Table = off

[Peer]
PublicKey = $pubkey
AllowedIPs = 0.0.0.0/0
Endpoint = ${endpoint_ip}:2408
PersistentKeepalive = 25
EOF
        chmod 600 "$WARP_CONF"
        log "  warp0.conf created"
    fi

    # 6. iptables: mark per-iface + nat/MSS shared (idempotent)
    iptables -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null \
        || iptables -t mangle -A PREROUTING -i "$IFACE" -j MARK --set-mark $MARK
    iptables -t nat -C POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o warp0 -j MASQUERADE
    iptables -t mangle -C FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    jq -n --arg t "$(date -Iseconds)" \
        '{installed:true, running:false, installed_at:$t}' > $WARP_STATE
    log "INSTALL OK"
    jq -n '{ok:true, installed:true}'
}

# ─── on ───────────────────────────────────────────────────────────────────────

cmd_on() {
    [ -f "$WARP_CONF" ] || { log "ON: not installed, installing"; cmd_install >/dev/null; }

    # warp0 общий: поднимаем только если ещё не поднят (не трогаем чужой WARP)
    if ! ip link show warp0 >/dev/null 2>&1; then
        awg-quick up warp0 >/dev/null 2>&1 || die "awg-quick up warp0 failed"
        log "  warp0 brought up"
    else
        log "  warp0 already up (другой iface уже использует)"
    fi
    ip route replace default dev warp0 table $TABLE

    # mark-rule для этого iface (idempotent)
    iptables -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null \
        || iptables -t mangle -A PREROUTING -i "$IFACE" -j MARK --set-mark $MARK

    # ip rule: fwmark → table 200 (per-iface priority)
    ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
    ip rule add fwmark $MARK lookup $TABLE priority $RULE_PRIO

    sleep 2
    local exit_ip
    exit_ip=$(detect_warp_ip)
    jq -n --arg ip "$exit_ip" --arg t "$(date -Iseconds)" \
        '{installed:true, running:true, exit_ip:$ip, on_at:$t}' > $WARP_STATE
    log "ON exit_ip=$exit_ip mark=$MARK prio=$RULE_PRIO"
    jq -n --arg ip "$exit_ip" '{ok:true, warp_state:"on", exit_ip:$ip}'
}

# ─── off ──────────────────────────────────────────────────────────────────────

cmd_off() {
    # Убираем routing ТОЛЬКО для этого iface
    ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null || true

    # Если больше НИ ОДИН iface не маркируется — опускаем общий warp0
    local remain
    remain=$(count_active_marks)
    if [ "${remain:-0}" -eq 0 ]; then
        awg-quick down warp0 2>/dev/null || true
        ip route flush table $TABLE 2>/dev/null || true
        log "OFF — warp0 down (никто больше не использует)"
    else
        log "OFF — warp0 оставлен (ещё $remain iface используют WARP)"
    fi

    jq -n --arg t "$(date -Iseconds)" \
        '{installed:true, running:false, off_at:$t}' > $WARP_STATE
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    jq -n '{ok:true, warp_state:"off"}'
}

# ─── status ──────────────────────────────────────────────────────────────────

cmd_status() {
    local installed=false running=false exit_ip=""
    [ -f "$WARP_CONF" ] && installed=true
    # running ДЛЯ ЭТОГО iface = warp0 поднят И есть mark-rule этого iface
    if ip link show warp0 >/dev/null 2>&1 && \
       iptables -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null; then
        running=true
        exit_ip=$(detect_warp_ip)
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --arg ip "$exit_ip" \
        '{ok:true, installed:$i, running:$r, exit_ip:$ip, warp_state: (if $r then "on" else "off" end)}'
}

# ─── rekey (влияет на общий warp0 → меняет exit IP для ВСЕХ iface) ────────────

cmd_rekey() {
    local was_up=false
    ip link show warp0 >/dev/null 2>&1 && was_up=true
    awg-quick down warp0 2>/dev/null || true
    rm -f $WARP_DIR/wgcf-account.toml $WARP_DIR/wgcf-profile.conf "$WARP_CONF"
    log "REKEY: account deleted, re-installing shared warp0..."
    cmd_install >/dev/null
    if $was_up; then
        awg-quick up warp0 >/dev/null 2>&1 || true
        ip route replace default dev warp0 table $TABLE
    fi
    cmd_status
}

# ─── uninstall (per-iface; полный снос если iface не осталось) ─────────────────

cmd_uninstall() {
    ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null || true
    rm -f "$WARP_STATE"

    local remain
    remain=$(count_active_marks)
    if [ "${remain:-0}" -eq 0 ]; then
        awg-quick down warp0 2>/dev/null || true
        ip route flush table $TABLE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null || true
        iptables -t mangle -D FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
                 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        rm -f $WARP_CONF $WARP_DIR/wgcf-account.toml $WARP_DIR/wgcf-profile.conf
        log "UNINSTALL — полный снос (последний iface)"
    else
        log "UNINSTALL — убран только $IFACE (ещё $remain используют warp0)"
    fi
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    jq -n '{ok:true}'
}

# ─── dispatch ────────────────────────────────────────────────────────────────

case "${1:-status}" in
    install)   cmd_install ;;
    on)        cmd_on ;;
    off)       cmd_off ;;
    status)    cmd_status ;;
    rekey)     cmd_rekey ;;
    uninstall) cmd_uninstall ;;
    *) jq -n --arg cmd "${1:-}" '{ok:false, error: "unknown command: " + $cmd}'; exit 1 ;;
esac
