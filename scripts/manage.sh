#!/bin/sh
#
# hysteria-keenetic — Selective VPN routing for Keenetic routers
# Usage: hysteria-keenetic {start|stop|restart|update|upgrade|status}
#
# Components: sing-box (redirect+tproxy+Hysteria2+SOCKS5) + dnscrypt-proxy (DNS via VPS)
#            + dnsmasq (DNS->ipset) + iptables (REDIRECT for TCP, TPROXY for UDP)
#

PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BASE_DIR="/opt/etc/hysteria-keenetic"
CONFIG="$BASE_DIR/config"
IPSET_NAME="unblock"
DNSMASQ_PID_FILE="/tmp/hysteria-dnsmasq.pid"

# Load config
[ -f "$CONFIG" ] || { echo "Error: $CONFIG not found"; exit 1; }
. "$CONFIG"

# Defaults for optional config values
DNSMASQ_PORT="${DNSMASQ_PORT:-5300}"
LAN_IF="${LAN_IF:-br0}"
FWMARK="${FWMARK:-2}"
ROUTE_TABLE="${ROUTE_TABLE:-101}"
FORCE_DNS="${FORCE_DNS:-1}"
ROUTE_MODE="${ROUTE_MODE:-selective}"

SINGBOX_BIN="/opt/bin/sing-box"
SINGBOX_CONF="$BASE_DIR/sing-box.json"
SINGBOX_MARK=200
REDIRECT_PORT=2500
TPROXY_PORT=2501
DNS_TPROXY_PORT=5302

DNSMASQ_CONF="$BASE_DIR/dnsmasq.conf"
DNSCRYPT_BIN="/opt/sbin/dnscrypt-proxy"
DNSCRYPT_CONF="/opt/etc/dnscrypt-proxy.toml"
DNSCRYPT_PORT=5301
UPDATE_SCRIPT="$BASE_DIR/scripts/update-domains.sh"

log() { logger -s -t "hysteria-keenetic" "$1"; }

# ── Config validation ─────────────────────────────────────────────

validate_config() {
    errors=0

    if [ -z "$HY_SERVER" ] || [ "$HY_SERVER" = "your-server.com:443" ]; then
        log "Error: HY_SERVER is not configured in $CONFIG"
        errors=$((errors + 1))
    fi

    if [ -z "$HY_PASSWORD" ] || [ "$HY_PASSWORD" = "your-password-here" ]; then
        log "Error: HY_PASSWORD is not configured in $CONFIG"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        log ""
        log "Edit your config: vi $CONFIG"
        log "Set HY_SERVER to your Hysteria 2 server address (e.g., mydomain.com:443)"
        log "Set HY_PASSWORD to your server password"
        return 1
    fi
    return 0
}

# ── Load TPROXY kernel modules ────────────────────────────────────

load_tproxy_modules() {
    for mod in xt_socket xt_TPROXY; do
        f="/lib/modules/$(uname -r)/${mod}.ko"
        if [ -f "$f" ]; then
            insmod "$f" 2>/dev/null
        fi
    done
}

# Add RETURN rules for private/reserved IP ranges to an iptables chain
_add_private_ip_rules() {
    _table=$1; _chain=$2
    for _range in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
                  172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t "$_table" -A "$_chain" -d "$_range" -j RETURN
    done
}

# Resolve VPN server IP (for ROUTE_MODE=all to avoid routing loops)
_get_server_ip() {
    _host=$(echo "$HY_SERVER" | sed 's/:[0-9]*$//')
    # If already an IP, return as-is
    echo "$_host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && echo "$_host" && return
    # Resolve hostname
    if command -v dig >/dev/null 2>&1; then
        dig +short "$_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$_host" 2>/dev/null | grep -A1 'Name:' | grep 'Address' | awk '{print $2}' | head -1
    fi
}

# ── iptables setup (used by start and netfilter.d hook) ──────────

setup_iptables() {
    # === TCP: REDIRECT to sing-box (nat PREROUTING) ===
    iptables -t nat -N HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -F HYSTERIA_REDIRECT

    # VPN server RETURN (prevent routing loops in "all" mode)
    if [ "$ROUTE_MODE" = "all" ]; then
        _server_ip=$(_get_server_ip)
        if [ -n "$_server_ip" ]; then
            iptables -t nat -A HYSTERIA_REDIRECT -d "$_server_ip" -j RETURN
        fi
    fi

    _add_private_ip_rules nat HYSTERIA_REDIRECT

    iptables -t nat -A HYSTERIA_REDIRECT -p tcp -j REDIRECT --to-ports "$REDIRECT_PORT"

    # Remove both selective and all variants before inserting
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -j HYSTERIA_REDIRECT 2>/dev/null

    if [ "$ROUTE_MODE" = "all" ]; then
        iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -p tcp -j HYSTERIA_REDIRECT
    else
        iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_REDIRECT
    fi

    # === UDP: TPROXY to sing-box (mangle PREROUTING) ===
    load_tproxy_modules
    iptables -t mangle -N HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -F HYSTERIA_TPROXY

    # VPN server RETURN (prevent routing loops in "all" mode)
    if [ "$ROUTE_MODE" = "all" ]; then
        _server_ip=${_server_ip:-$(_get_server_ip)}
        if [ -n "$_server_ip" ]; then
            iptables -t mangle -A HYSTERIA_TPROXY -d "$_server_ip" -j RETURN
        fi
    fi

    _add_private_ip_rules mangle HYSTERIA_TPROXY

    iptables -t mangle -A HYSTERIA_TPROXY -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "0x$FWMARK/0x$FWMARK"

    # Remove both selective and all variants before inserting
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -j HYSTERIA_TPROXY 2>/dev/null

    if [ "$ROUTE_MODE" = "all" ]; then
        iptables -t mangle -I PREROUTING 1 -i "$LAN_IF" -p udp -j HYSTERIA_TPROXY
    else
        iptables -t mangle -I PREROUTING 1 -i "$LAN_IF" -p udp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_TPROXY
    fi

    # Policy routing for TPROXY
    ip rule del fwmark "0x$FWMARK" table "$ROUTE_TABLE" 2>/dev/null
    ip rule add fwmark "0x$FWMARK" table "$ROUTE_TABLE"
    ip route replace local default dev lo table "$ROUTE_TABLE"

    # === DNS: intercept LAN DNS queries ===
    # UDP DNS: use TPROXY to sing-box (works for any destination IP; nat REDIRECT
    # is broken for UDP to non-local IPs on Keenetic NDM kernel 4.9)
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j TPROXY --on-port "$DNS_TPROXY_PORT" --tproxy-mark "0x$FWMARK/0x$FWMARK" 2>/dev/null
    iptables -t mangle -I PREROUTING 1 -i "$LAN_IF" -p udp --dport 53 -j TPROXY --on-port "$DNS_TPROXY_PORT" --tproxy-mark "0x$FWMARK/0x$FWMARK"
    # TCP DNS: nat REDIRECT works fine for TCP
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"
    # Legacy: remove old UDP REDIRECT if present
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null

    # === Force DNS (block DoH/DoT) ===
    if [ "$FORCE_DNS" = "1" ]; then
        ipset create force_dns hash:ip 2>/dev/null
        ipset flush force_dns 2>/dev/null
        for ip in \
            8.8.8.8 8.8.4.4 \
            1.1.1.1 1.0.0.1 \
            9.9.9.9 149.112.112.112 \
            208.67.222.222 208.67.220.220 \
            94.140.14.14 94.140.15.15 \
            185.228.168.9 185.228.169.9; do
            ipset add force_dns "$ip" 2>/dev/null
        done

        iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p udp --dport 853 -j REJECT 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 853 -j DROP 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p udp --dport 853 -j DROP 2>/dev/null
        iptables -I FORWARD 1 -i "$LAN_IF" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
        iptables -I FORWARD 2 -i "$LAN_IF" -p udp --dport 853 -j REJECT

        iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j REJECT --reject-with tcp-reset 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j REJECT 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
        iptables -I FORWARD 3 -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j REJECT --reject-with tcp-reset
        iptables -I FORWARD 4 -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j REJECT
    fi
}

# ── Start ────────────────────────────────────────────────────────

do_start() {
    if ! _start_internal; then
        log "Start failed, rolling back..."
        do_stop
        return 1
    fi
}

_start_internal() {
    log "Starting hysteria-keenetic..."

    # Validate config first
    validate_config || return 1

    # Check binaries
    if [ ! -x "$SINGBOX_BIN" ]; then
        log "Error: sing-box not found at $SINGBOX_BIN"
        log "Install with: opkg install sing-box-go"
        return 1
    fi
    for bin in dnsmasq ipset iptables; do
        command -v "$bin" >/dev/null 2>&1 || { log "Error: $bin not found. Run install.sh"; return 1; }
    done

    # Load TPROXY modules (needed for UDP)
    load_tproxy_modules

    # ── 1. Generate sing-box config ──
    _generate_singbox_config

    # Validate config
    if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONF" 2>/dev/null; then
        log "Error: sing-box config validation failed"
        "$SINGBOX_BIN" check -c "$SINGBOX_CONF" 2>&1 | while read -r line; do log "  $line"; done
        return 1
    fi

    # ── 2. Start sing-box (redirect + tproxy + SOCKS5 + Hysteria2) ──
    if pidof sing-box >/dev/null 2>&1; then
        log "  sing-box: already running"
    else
        "$SINGBOX_BIN" run -c "$SINGBOX_CONF" >/dev/null 2>&1 &
        sleep 3
        if pidof sing-box >/dev/null 2>&1; then
            log "  sing-box: started (redirect :$REDIRECT_PORT, tproxy :$TPROXY_PORT, SOCKS5 :1080)"
        else
            log "  sing-box: FAILED to start"
            return 1
        fi
    fi

    # ── 2a. dnscrypt-proxy (DNS via VPS SOCKS5) ──
    # DNS resolution through VPS ensures CDN IPs are optimal for VPS location
    if [ -x "$DNSCRYPT_BIN" ]; then
        if pidof dnscrypt-proxy >/dev/null 2>&1; then
            log "  dnscrypt-proxy: already running"
        else
            "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" >/dev/null 2>&1 &
            sleep 3
            if pidof dnscrypt-proxy >/dev/null 2>&1; then
                log "  dnscrypt-proxy: started (port $DNSCRYPT_PORT via SOCKS5)"
            else
                log "  dnscrypt-proxy: FAILED to start, falling back to direct DNS"
            fi
        fi
    else
        log "  dnscrypt-proxy: not installed (using direct DNS)"
    fi

    # ── 3. IPSet ──
    ipset create "$IPSET_NAME" hash:net maxelem 131072 2>/dev/null
    log "  ipset: created"

    # ── 3a. Load static CIDRs into ipset ──
    LOADED=0
    if [ -f "$BASE_DIR/static-ips.lst" ] && [ -s "$BASE_DIR/static-ips.lst" ]; then
        COUNT_BEFORE=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
        sed '/^$/d; /^#/d' "$BASE_DIR/static-ips.lst" | awk "{print \"add $IPSET_NAME \" \$0}" | ipset restore -exist 2>/dev/null
        COUNT_AFTER=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
        LOADED=$((COUNT_AFTER - COUNT_BEFORE))
    fi
    [ "$LOADED" -gt 0 ] && log "  ipset: pre-loaded $LOADED static IPs/CIDRs"

    # ── 4. Update domains (downloads lists, generates dnsmasq config) ──
    if [ ! -f "$BASE_DIR/dnsmasq-ipset.conf" ] || [ ! -s "$BASE_DIR/dnsmasq-ipset.conf" ]; then
        log "  domains: downloading..."
        sh "$UPDATE_SCRIPT"
    else
        log "  domains: using cached list ($(wc -l < "$BASE_DIR/dnsmasq-ipset.conf") rules)"
    fi

    # ── 5. dnsmasq ──
    # Safety: /tmp is a RAM-backed tmpfs on Keenetic. A leftover debug edit
    # (log-queries + log-facility=/tmp/...) makes dnsmasq log every query to RAM
    # unbounded → fills tmpfs → OOMs the router. Strip it before every start.
    if grep -qE '^[[:space:]]*(log-queries|log-facility=)' "$DNSMASQ_CONF" 2>/dev/null; then
        sed -i '/^[[:space:]]*log-queries/d; /^[[:space:]]*log-facility=/d' "$DNSMASQ_CONF"
        rm -f /tmp/dnsmasq-debug.log
        log "  dnsmasq: stripped debug logging to prevent tmpfs OOM"
    fi

    DNSMASQ_PID=$(cat "$DNSMASQ_PID_FILE" 2>/dev/null)
    if [ -n "$DNSMASQ_PID" ] && [ -d "/proc/$DNSMASQ_PID" ]; then
        log "  dnsmasq: already running"
    else
        if ! dnsmasq --test --conf-file="$DNSMASQ_CONF" 2>/dev/null; then
            log "  dnsmasq: WARNING — ipset may not be supported, testing..."
            if ! dnsmasq --test --port="$DNSMASQ_PORT" --no-resolv --server=8.8.8.8 2>/dev/null; then
                log "  dnsmasq: FAILED config test"
                return 1
            fi
        fi
        dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID_FILE"
        sleep 1
        if [ -f "$DNSMASQ_PID_FILE" ]; then
            log "  dnsmasq: started on port $DNSMASQ_PORT"
        else
            log "  dnsmasq: FAILED to start"
            return 1
        fi
    fi

    # ── 6. iptables (TCP REDIRECT + UDP TPROXY + DNS + DoH/DoT) ──
    setup_iptables
    log "  iptables: TCP REDIRECT to :$REDIRECT_PORT"
    log "  iptables: UDP TPROXY to :$TPROXY_PORT (fwmark 0x$FWMARK)"
    log "  iptables: DNS TPROXY to :$DNS_TPROXY_PORT (UDP), REDIRECT to :$DNSMASQ_PORT (TCP)"
    [ "$FORCE_DNS" = "1" ] && log "  iptables: DoH/DoT blocking enabled"

    # ── 8. Flush conntrack ──
    if command -v conntrack >/dev/null 2>&1; then
        conntrack -F 2>/dev/null
        log "  conntrack: flushed"
    fi

    # ── 9. DNS warm-up ──
    if command -v dig >/dev/null 2>&1; then
        for domain in youtube.com www.youtube.com googlevideo.com \
                      www.google.com google.com play.google.com \
                      i.ytimg.com yt3.ggpht.com \
                      facebook.com www.facebook.com \
                      twitter.com x.com \
                      instagram.com www.instagram.com \
                      discord.com gateway.discord.gg \
                      api.openai.com t.me; do
            dig "$domain" @127.0.0.1 -p "$DNSMASQ_PORT" +short +time=5 +tries=1 >/dev/null 2>&1
        done
        IPCOUNT=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
        log "  DNS warm-up: $IPCOUNT IPs in ipset"
    fi

    IPCOUNT=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
    if [ "$ROUTE_MODE" = "all" ]; then
        log "Started. Mode: ALL traffic through VPN. TCP via REDIRECT, UDP via TPROXY."
    else
        log "Started. Mode: selective. $IPCOUNT IPs in ipset. TCP via REDIRECT, UDP via TPROXY."
    fi
}

# ── Generate sing-box config ─────────────────────────────────────

_generate_singbox_config() {
    # Parse server address (host:port)
    HY_HOST=$(echo "$HY_SERVER" | sed 's/:[0-9]*$//')
    HY_PORT=$(echo "$HY_SERVER" | grep -o '[0-9]*$')
    [ -z "$HY_PORT" ] && HY_PORT=443

    # TLS insecure
    TLS_INSECURE="false"
    [ "$HY_TLS_INSECURE" = "1" ] && TLS_INSECURE="true"

    # Obfuscation block
    OBFS_BLOCK=""
    if [ -n "$HY_OBFS_PASSWORD" ]; then
        OBFS_BLOCK="\"obfs\": { \"type\": \"salamander\", \"password\": \"$HY_OBFS_PASSWORD\" },"
    fi

    # Bandwidth (only include if non-zero)
    BW_BLOCK=""
    BW_UP=$(echo "$HY_BW_UP" | grep -oE '[0-9]+')
    BW_DOWN=$(echo "$HY_BW_DOWN" | grep -oE '[0-9]+')
    if [ -n "$BW_UP" ] && [ "$BW_UP" != "0" ] && [ -n "$BW_DOWN" ] && [ "$BW_DOWN" != "0" ]; then
        BW_BLOCK="\"up_mbps\": $BW_UP, \"down_mbps\": $BW_DOWN,"
    fi

    cat > "$SINGBOX_CONF" << SINGBOX_EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dnsmasq",
        "address": "udp://127.0.0.1:$DNSMASQ_PORT",
        "detour": "direct"
      }
    ],
    "final": "dnsmasq"
  },
  "inbounds": [
    {
      "type": "redirect",
      "tag": "redirect-in",
      "listen": "0.0.0.0",
      "listen_port": $REDIRECT_PORT
    },
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": $TPROXY_PORT,
      "network": "udp"
    },
    {
      "type": "tproxy",
      "tag": "dns-in",
      "listen": "0.0.0.0",
      "listen_port": $DNS_TPROXY_PORT,
      "network": "udp",
      "sniff": true
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": "$HY_HOST",
      "server_port": $HY_PORT,
      "password": "$HY_PASSWORD",
      $OBFS_BLOCK
      $BW_BLOCK
      "tls": {
        "enabled": true,
        "insecure": $TLS_INSECURE
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_mark": $SINGBOX_MARK,
    "rules": [
      {
        "inbound": "dns-in",
        "outbound": "dns-out"
      },
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "inbound": "socks-in",
        "outbound": "hy2-out"
      }
    ],
    "final": "hy2-out"
  }
}
SINGBOX_EOF
}

# ── Stop ─────────────────────────────────────────────────────────

do_stop() {
    log "Stopping hysteria-keenetic..."

    # TCP REDIRECT cleanup (nat table) — both selective and all variants
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -F HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -X HYSTERIA_REDIRECT 2>/dev/null

    # UDP TPROXY cleanup (mangle table) — both selective and all variants
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -F HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -X HYSTERIA_TPROXY 2>/dev/null

    # Policy routing cleanup (for TPROXY)
    ip rule del fwmark "0x$FWMARK" table "$ROUTE_TABLE" 2>/dev/null
    ip route del local default dev lo table "$ROUTE_TABLE" 2>/dev/null

    # Legacy TUN cleanup (from previous version)
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -m set --match-set "$IPSET_NAME" dst -j HYSTERIA 2>/dev/null
    iptables -t mangle -F HYSTERIA 2>/dev/null
    iptables -t mangle -X HYSTERIA 2>/dev/null
    iptables -t nat -D POSTROUTING -o tun0 -j RETURN 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -o tun0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i tun0 -o "$LAN_IF" -j ACCEPT 2>/dev/null
    ip route del default dev tun0 table "$ROUTE_TABLE" 2>/dev/null

    # Legacy old TPROXY cleanup (from Hysteria version)
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null

    log "  iptables: redirect/tproxy cleaned"

    # DoH/DoT blocking cleanup (both REJECT and legacy DROP variants)
    iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 853 -j REJECT 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 853 -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 853 -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j REJECT --reject-with tcp-reset 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j REJECT 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
    ipset destroy force_dns 2>/dev/null

    # DNS intercept cleanup
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j TPROXY --on-port "$DNS_TPROXY_PORT" --tproxy-mark "0x$FWMARK/0x$FWMARK" 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    # Legacy: old UDP REDIRECT
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null

    # Legacy redsocks cleanup (from older versions)
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j REDSOCKS 2>/dev/null
    iptables -t nat -F REDSOCKS 2>/dev/null
    iptables -t nat -X REDSOCKS 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -j DROP 2>/dev/null

    log "  iptables: cleaned"

    # dnsmasq
    if [ -f "$DNSMASQ_PID_FILE" ]; then
        kill "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null
        rm -f "$DNSMASQ_PID_FILE"
    fi
    log "  dnsmasq: stopped"

    # ipset (must be after iptables cleanup)
    ipset destroy "$IPSET_NAME" 2>/dev/null
    log "  ipset: destroyed"

    # dnscrypt-proxy
    killall dnscrypt-proxy 2>/dev/null
    log "  dnscrypt-proxy: stopped"

    # Legacy cleanup
    killall redsocks 2>/dev/null
    killall hysteria 2>/dev/null

    # sing-box
    killall sing-box 2>/dev/null
    sleep 1
    log "  sing-box: stopped"

    log "Stopped."
}

# ── Update ───────────────────────────────────────────────────────

do_update() {
    log "Updating domain lists..."
    sh "$UPDATE_SCRIPT"
}

# ── Upgrade ───────────────────────────────────────────────────────

do_upgrade() {
    log "Checking for sing-box updates..."

    CURRENT_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    log "Current version: v$CURRENT_VER"

    log "Updating via opkg..."
    opkg update >/dev/null 2>&1
    AVAIL_VER=$(opkg info sing-box-go 2>/dev/null | grep '^Version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    if [ -z "$AVAIL_VER" ]; then
        log "Error: Could not check latest version"
        return 1
    fi

    log "Available version: v$AVAIL_VER"

    if [ "$CURRENT_VER" = "$AVAIL_VER" ]; then
        log "Already up to date."
        return 0
    fi

    opkg upgrade sing-box-go 2>&1 | while read -r line; do log "  $line"; done

    NEW_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    log "Upgraded to v$NEW_VER"
    log "Restart hysteria-keenetic to use new version"
}

# ── Self-update ──────────────────────────────────────────────────

do_self_update() {
    log "Self-update: updating everything..."

    REPO_URL="https://github.com/DenisNikonov/hysteria-keenetic/archive/main.tar.gz"
    TMP_DIR="/tmp/hysteria-keenetic-update"

    # 1. Download latest scripts from GitHub
    log "  Downloading latest version..."
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    if ! curl -fsSL -o "$TMP_DIR/main.tar.gz" "$REPO_URL"; then
        log "Error: Failed to download from GitHub"
        rm -rf "$TMP_DIR"
        return 1
    fi

    tar xzf "$TMP_DIR/main.tar.gz" -C "$TMP_DIR" 2>/dev/null
    SRC_DIR="$TMP_DIR/hysteria-keenetic-main"
    if [ ! -d "$SRC_DIR" ]; then
        log "Error: Failed to extract archive"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # 2. Update scripts (preserve config and custom-domains.txt)
    log "  Updating scripts..."
    for f in scripts/manage.sh scripts/update-domains.sh scripts/netfilter-hook.sh uninstall.sh install.sh; do
        if [ -f "$SRC_DIR/$f" ]; then
            cp "$SRC_DIR/$f" "$BASE_DIR/$f" 2>/dev/null && log "    updated $f" || true
        fi
    done
    # Update config.example (for reference, not the active config)
    [ -f "$SRC_DIR/config.example" ] && cp "$SRC_DIR/config.example" "$BASE_DIR/config.example" 2>/dev/null

    # Update netfilter hook
    if [ -f "$SRC_DIR/scripts/netfilter-hook.sh" ]; then
        cp "$SRC_DIR/scripts/netfilter-hook.sh" /opt/etc/ndm/netfilter.d/100-hysteria-keenetic.sh 2>/dev/null
        chmod +x /opt/etc/ndm/netfilter.d/100-hysteria-keenetic.sh 2>/dev/null
    fi

    # Update init script
    if [ -f "$SRC_DIR/scripts/manage.sh" ]; then
        # Recreate symlink in case it's stale
        ln -sf "$BASE_DIR/scripts/manage.sh" /opt/bin/hysteria-keenetic 2>/dev/null
    fi

    rm -rf "$TMP_DIR"
    log "  Scripts updated."

    # 3. Upgrade sing-box via opkg
    log "  Checking sing-box updates..."
    CURRENT_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    opkg update >/dev/null 2>&1
    AVAIL_VER=$(opkg info sing-box-go 2>/dev/null | grep '^Version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [ -n "$AVAIL_VER" ] && [ "$CURRENT_VER" != "$AVAIL_VER" ]; then
        log "  sing-box: $CURRENT_VER -> $AVAIL_VER"
        opkg upgrade sing-box-go 2>&1 | while read -r line; do log "    $line"; done
    else
        log "  sing-box: v$CURRENT_VER (up to date)"
    fi

    # 4. Update domain lists (force: self-update is an explicit "refresh
    #    everything", and it must bypass the version-check so a user whose
    #    .lists-version is stuck on a previously-broken download gets a clean
    #    re-download instead of a short-circuit)
    log "  Updating domain lists..."
    sh "$UPDATE_SCRIPT" --force

    # 5. Restart if running
    if pidof sing-box >/dev/null 2>&1; then
        log "  Restarting service..."
        do_stop
        sleep 2
        do_start
    else
        log "  Service not running, skipping restart."
    fi

    log "Self-update complete."
}

# ── Status ───────────────────────────────────────────────────────

do_status() {
    echo ""
    echo "  hysteria-keenetic status"
    echo "  ========================"
    echo ""

    # Processes
    echo "  Processes"
    echo "  ---------"
    if pidof sing-box >/dev/null 2>&1; then
        echo "  sing-box:  running (PID $(pidof sing-box))"
    else
        echo "  sing-box:  stopped"
    fi
    if pidof dnscrypt-proxy >/dev/null 2>&1; then
        echo "  dnscrypt:  running (PID $(pidof dnscrypt-proxy), port $DNSCRYPT_PORT via SOCKS5)"
    else
        echo "  dnscrypt:  stopped (DNS goes direct)"
    fi
    DNSMASQ_PID=$(cat "$DNSMASQ_PID_FILE" 2>/dev/null)
    if [ -n "$DNSMASQ_PID" ] && [ -d "/proc/$DNSMASQ_PID" ]; then
        echo "  dnsmasq:   running (PID $DNSMASQ_PID, port $DNSMASQ_PORT)"
    else
        echo "  dnsmasq:   stopped"
    fi
    echo ""

    # Routing
    echo "  Traffic routing"
    echo "  ---------------"
    if [ "$ROUTE_MODE" = "all" ]; then
        echo "  mode:         ALL traffic through VPN"
    else
        echo "  mode:         selective (ipset-matched only)"
    fi
    if iptables -t nat -L HYSTERIA_REDIRECT -n >/dev/null 2>&1; then
        REDIR_PKTS=$(iptables -t nat -L HYSTERIA_REDIRECT -n -v 2>&1 | grep "REDIRECT" | awk '{sum+=$1} END {print sum+0}')
        echo "  TCP redirect: active ($REDIR_PKTS packets redirected to :$REDIRECT_PORT)"
    else
        echo "  TCP redirect: not configured"
    fi
    if iptables -t mangle -L HYSTERIA_TPROXY -n >/dev/null 2>&1; then
        TPROXY_PKTS=$(iptables -t mangle -L HYSTERIA_TPROXY -n -v 2>&1 | grep "TPROXY" | awk '{sum+=$1} END {print sum+0}')
        echo "  UDP tproxy:   active ($TPROXY_PKTS packets proxied to :$TPROXY_PORT)"
    else
        echo "  UDP tproxy:   not configured"
    fi
    if ip rule show 2>/dev/null | grep -q "fwmark 0x$FWMARK"; then
        echo "  policy route: active (fwmark 0x$FWMARK -> table $ROUTE_TABLE -> lo)"
    else
        echo "  policy route: not configured"
    fi
    echo ""

    # IPSet
    echo "  IPSet"
    echo "  -----"
    if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        IPCOUNT=$(ipset list "$IPSET_NAME" | tail -n +8 | wc -l)
        echo "  set '$IPSET_NAME': $IPCOUNT IPs loaded"
    else
        echo "  set '$IPSET_NAME': not created"
    fi
    echo ""

    # Domains
    echo "  Domains"
    echo "  -------"
    if [ -f "$BASE_DIR/domains.lst" ]; then
        echo "  domains.lst: $(wc -l < "$BASE_DIR/domains.lst") domains"
        echo "  last updated: $(ls -l "$BASE_DIR/domains.lst" 2>/dev/null | awk '{print $6, $7, $8}')"
    else
        echo "  domains.lst: not found (run: hysteria-keenetic update)"
    fi
    echo ""

    # System (RAM-backed /tmp is the OOM risk on Keenetic)
    echo "  System"
    echo "  ------"
    TMP_USE=$(df /tmp 2>/dev/null | awk 'NR==2{print $5}')
    echo "  /tmp (RAM):  $(df -h /tmp 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5" used)"}')"
    TMP_PCT=$(echo "$TMP_USE" | tr -d '%')
    if [ -n "$TMP_PCT" ] && [ "$TMP_PCT" -ge 80 ]; then
        echo "  WARNING: /tmp tmpfs ${TMP_USE} full — OOM risk. Inspect: ls -laS /tmp"
    fi
    echo ""

    # Services
    echo "  Enabled services"
    echo "  ----------------"
    echo "  $SERVICES" | tr ',' '\n' | sed 's/^[[:space:]]*/  /'
    echo ""

    # DNS encryption blocking
    echo "  DNS encryption blocking"
    echo "  -----------------------"
    if iptables -C FORWARD -i "$LAN_IF" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null \
       || iptables -C FORWARD -i "$LAN_IF" -p tcp --dport 853 -j DROP 2>/dev/null; then
        DOH_IPS=$(ipset list force_dns 2>/dev/null | tail -n +8 | wc -l)
        echo "  DoT block: enabled (port 853 rejected)"
        echo "  DoH block: enabled ($DOH_IPS provider IPs rejected)"
    else
        echo "  DoH/DoT block: disabled"
    fi
    echo ""

    # VPN connectivity test
    echo "  VPN test"
    echo "  --------"
    if pidof sing-box >/dev/null 2>&1; then
        if netstat -tlnup 2>/dev/null | grep -q ":1080"; then
            echo "  SOCKS5: listening on port 1080"
        else
            echo "  SOCKS5: NOT listening"
        fi
        if netstat -tlnup 2>/dev/null | grep -q ":$REDIRECT_PORT"; then
            echo "  redirect: listening on port $REDIRECT_PORT"
        else
            echo "  redirect: NOT listening"
        fi
        if netstat -tlnup 2>/dev/null | grep -q ":$TPROXY_PORT"; then
            echo "  tproxy: listening on port $TPROXY_PORT"
        else
            echo "  tproxy: NOT listening"
        fi
        if netstat -tlnup 2>/dev/null | grep -q ":$DNS_TPROXY_PORT"; then
            echo "  dns-tproxy: listening on port $DNS_TPROXY_PORT"
        else
            echo "  dns-tproxy: NOT listening"
        fi
    else
        echo "  sing-box: not running"
    fi
    echo ""

    # Cron
    echo "  Auto-update"
    echo "  -----------"
    if crontab -l 2>/dev/null | grep -q hysteria-keenetic; then
        echo "  cron: $(crontab -l 2>/dev/null | grep hysteria-keenetic)"
    else
        echo "  cron: not configured"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────

case "$1" in
    start)       do_start ;;
    stop)        do_stop ;;
    restart)     do_stop; sleep 2; do_start ;;
    update)      do_update ;;
    upgrade)     do_upgrade ;;
    self-update) do_self_update ;;
    status)      do_status ;;
    firewall-reload)
        # Called by /opt/etc/ndm/netfilter.d/ hook when Keenetic rebuilds firewall.
        # Only re-apply iptables rules if sing-box is running.
        if pidof sing-box >/dev/null 2>&1; then
            setup_iptables
            conntrack -F 2>/dev/null
            log "iptables rules restored (firewall reload)"
        fi
    ;;
    *)
        echo "hysteria-keenetic — selective VPN routing for Keenetic"
        echo ""
        echo "Usage: $0 {start|stop|restart|update|upgrade|self-update|status}"
        echo ""
        echo "  start       Start all components"
        echo "  stop        Stop all, clean iptables"
        echo "  restart     Stop + start"
        echo "  update      Re-download domain lists"
        echo "  upgrade     Update sing-box via opkg"
        echo "  self-update Update everything (scripts + sing-box + domains)"
        echo "  status      Show status of all components"
        echo ""
        echo "Config:  $CONFIG"
        echo "Domains: $BASE_DIR/custom-domains.txt"
        exit 1
    ;;
esac

exit 0
