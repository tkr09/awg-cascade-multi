#!/bin/bash
# =============================================================================
# AWG Cascade Exit — WARP manager
#
# Cloudflare WARP toggle для exit-сервера. Когда WARP включён, весь трафик
# приходящий из cascade через awg-in уходит наружу через warp0 (Cloudflare),
# а не через eth0.
#
# Команды (вызываются ботом по SSH):
#   install   — скачать wgcf, зарегистрировать WARP-аккаунт, создать конфиг
#               (вызывается автоматически при первом 'on' если не установлен)
#   on        — поднять warp0 + добавить policy routing
#   off       — опустить warp0 + убрать policy routing
#   status    — JSON: {installed, running, exit_ip}
#   rekey     — пересоздать WARP-аккаунт (новый ключ + новый exit IP)
#   uninstall — снести всё
#
# Stdout всегда JSON для надёжного парсинга ботом.
# =============================================================================

set -u
WGCF_VERSION=2.2.27
WGCF_BIN=/usr/local/bin/wgcf
WARP_DIR=/etc/awg-cascade-exit
WARP_CONF=/etc/amnezia/amneziawg/warp0.conf
WARP_STATE=$WARP_DIR/warp.state
WARP_LOG=$WARP_DIR/warp.log
MARK=0x10
TABLE=200
RULE_PRIO=990

mkdir -p $WARP_DIR

log() { echo "$(date -Iseconds) $*" >> $WARP_LOG; }

die() {
    log "ERROR: $1"
    jq -n --arg e "$1" '{ok:false, error:$e}'
    exit 1
}

# Получаем внешний IP через интерфейс warp0
detect_warp_ip() {
    local ip
    ip=$(timeout 8 curl -s --interface warp0 --max-time 6 \
         https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
         | awk -F= '/^ip=/{print $2}')
    [ -z "$ip" ] && ip=$(timeout 8 curl -s --interface warp0 --max-time 6 \
         -4 https://api.ipify.org 2>/dev/null)
    echo "${ip:-}"
}

# ─── install ─────────────────────────────────────────────────────────────────

cmd_install() {
    log "INSTALL begin"

    # 1. Скачиваем wgcf (если ещё нет)
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

    # 2. Регистрируем WARP аккаунт
    cd $WARP_DIR
    if [ ! -f wgcf-account.toml ]; then
        log "  registering WARP account..."
        yes | $WGCF_BIN register >/dev/null 2>&1 || die "wgcf register failed"
    fi
    [ -f wgcf-account.toml ] || die "wgcf-account.toml missing"

    # 3. Генерируем профиль
    $WGCF_BIN generate >/dev/null 2>&1 || die "wgcf generate failed"
    [ -f wgcf-profile.conf ] || die "wgcf-profile.conf not generated"

    # 4. Резолвим endpoint
    local endpoint_ip
    endpoint_ip=$(getent ahostsv4 engage.cloudflareclient.com 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$endpoint_ip" ] && endpoint_ip="162.159.193.10"

    # 5. Собираем warp0.conf (в /etc/amnezia/amneziawg/ т.к. awg-quick его ищет там)
    local privkey pubkey address
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

    # 6. Постоянные iptables (idempotent)
    iptables -t mangle -C PREROUTING -i awg-in -j MARK --set-mark $MARK 2>/dev/null \
        || iptables -t mangle -A PREROUTING -i awg-in -j MARK --set-mark $MARK
    iptables -t nat -C POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o warp0 -j MASQUERADE
    iptables -t mangle -C FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # 7. State
    jq -n --arg t "$(date -Iseconds)" \
        '{installed:true, running:false, installed_at:$t}' > $WARP_STATE

    log "INSTALL OK"
    jq -n '{ok:true, installed:true}'
}

# ─── on ──────────────────────────────────────────────────────────────────────

cmd_on() {
    # Lazy install
    if [ ! -f "$WARP_CONF" ]; then
        log "ON: not installed yet, running install..."
        cmd_install >/dev/null
    fi

    # Поднимаем warp0 (через awg-quick, который понимает стандартный WG)
    awg-quick down warp0 2>/dev/null || true
    awg-quick up warp0 >/dev/null 2>&1 || die "awg-quick up warp0 failed"

    # Policy routing: cascade-incoming с MARK 0x10 → table 200 → dev warp0
    ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
    ip rule add fwmark $MARK lookup $TABLE priority $RULE_PRIO
    ip route replace default dev warp0 table $TABLE

    # Ждём handshake и пробуем определить exit IP
    sleep 2
    local exit_ip
    exit_ip=$(detect_warp_ip)

    # State
    jq -n --arg ip "$exit_ip" --arg t "$(date -Iseconds)" \
        '{installed:true, running:true, exit_ip:$ip, on_at:$t}' > $WARP_STATE

    log "ON exit_ip=$exit_ip"
    jq -n --arg ip "$exit_ip" \
        '{ok:true, warp_state:"on", exit_ip:$ip}'
}

# ─── off ─────────────────────────────────────────────────────────────────────

cmd_off() {
    # Убираем policy routing
    ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
    ip route flush table $TABLE 2>/dev/null || true

    # Опускаем warp0
    awg-quick down warp0 2>/dev/null || true

    # State
    jq -n --arg t "$(date -Iseconds)" \
        '{installed:true, running:false, off_at:$t}' > $WARP_STATE

    log "OFF"
    jq -n '{ok:true, warp_state:"off"}'
}

# ─── status ──────────────────────────────────────────────────────────────────

cmd_status() {
    local installed=false running=false exit_ip=""
    [ -f "$WARP_CONF" ] && installed=true
    ip link show warp0 >/dev/null 2>&1 && running=true
    if [ "$running" = "true" ]; then
        exit_ip=$(detect_warp_ip)
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --arg ip "$exit_ip" \
        '{ok:true, installed:$i, running:$r, exit_ip:$ip, warp_state: (if $r then "on" else "off" end)}'
}

# ─── rekey ───────────────────────────────────────────────────────────────────

cmd_rekey() {
    local was_running=false
    ip link show warp0 >/dev/null 2>&1 && was_running=true
    cmd_off >/dev/null

    rm -f $WARP_DIR/wgcf-account.toml $WARP_DIR/wgcf-profile.conf "$WARP_CONF"
    log "REKEY: account deleted, re-installing..."
    cmd_install >/dev/null

    if $was_running; then
        cmd_on
    else
        cmd_status
    fi
}

# ─── uninstall ───────────────────────────────────────────────────────────────

cmd_uninstall() {
    cmd_off >/dev/null
    iptables -t mangle -D PREROUTING -i awg-in -j MARK --set-mark $MARK 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -D FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    rm -f $WARP_CONF $WARP_DIR/wgcf-account.toml $WARP_DIR/wgcf-profile.conf $WARP_STATE
    log "UNINSTALL"
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
