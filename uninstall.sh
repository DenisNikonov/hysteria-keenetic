#!/bin/sh
#
# hysteria-keenetic uninstaller
# Cleanly removes all components
#

INSTALL_DIR="/opt/etc/hysteria-keenetic"
CONFIG="$INSTALL_DIR/config"
INIT_SCRIPT="/opt/etc/init.d/S99hysteria-keenetic"
DNSMASQ_PID_FILE="/tmp/hysteria-dnsmasq.pid"
IPSET_NAME="unblock"

log() { echo "[uninstall] $1"; }

echo ""
echo "  hysteria-keenetic uninstaller"
echo "  ============================="
echo ""
echo "This will remove:"
echo "  - All iptables rules (nat/REDIRECT, mangle/TPROXY, filter/DoH)"
echo "  - Policy routing (ip rule/route)"
echo "  - ipset, dnsmasq instance, sing-box, dnscrypt-proxy"
echo "  - Config files in $INSTALL_DIR"
echo "  - Init script and cron job"
echo ""
printf "Continue? [y/N] "
read -r answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Cancelled."; exit 0; }

# Load config for interface values
if [ -f "$CONFIG" ]; then
    . "$CONFIG"
else
    LAN_IF="br0"
    DNSMASQ_PORT=5300
    FWMARK=2
    ROUTE_TABLE=101
fi

# Defaults
FWMARK="${FWMARK:-2}"
ROUTE_TABLE="${ROUTE_TABLE:-101}"
DNSMASQ_PORT="${DNSMASQ_PORT:-5300}"
LAN_IF="${LAN_IF:-br0}"

# ── Stop services ────────────────────────────────────────────────

log "Stopping services..."

# manage.sh stop knows every LAN_IF interface and FULL_VPN_DEVICES rules;
# the manual cleanup below is a fallback for broken/partial installs
[ -x "$INSTALL_DIR/scripts/manage.sh" ] && "$INSTALL_DIR/scripts/manage.sh" stop >/dev/null 2>&1

# LAN_IF may be a comma-separated list. Chain -F/-X repeats per interface;
# it only succeeds once the last interface's jumps are gone.
for LAN_IF in $(echo "$LAN_IF" | tr ',' ' '); do
    # Current: nat REDIRECT chain (TCP) — both selective and all variants
    iptables -t nat -D PREROUTING -i "$LAN_IF" -m set --match-set "$IPSET_NAME" dst -p tcp -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -F HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -X HYSTERIA_REDIRECT 2>/dev/null
    log "  iptables: nat/REDIRECT cleaned"

    # Current: mangle TPROXY chain (UDP) — both selective and all variants
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -m set --match-set "$IPSET_NAME" dst -p udp -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -F HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -X HYSTERIA_TPROXY 2>/dev/null
    log "  iptables: mangle/TPROXY cleaned"

    # Current: TPROXY policy routing
    ip rule del fwmark "0x$FWMARK" table "$ROUTE_TABLE" 2>/dev/null
    ip route flush table "$ROUTE_TABLE" 2>/dev/null
    log "  policy routing: cleaned"

    # Legacy: mangle MARK chain (from TUN version)
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -m set --match-set "$IPSET_NAME" dst -j HYSTERIA 2>/dev/null
    iptables -t mangle -F HYSTERIA 2>/dev/null
    iptables -t mangle -X HYSTERIA 2>/dev/null

    # Legacy: TUN routing
    ip route del default dev tun0 table "$ROUTE_TABLE" 2>/dev/null
    iptables -t nat -D POSTROUTING -o tun0 -j RETURN 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -o tun0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i tun0 -o "$LAN_IF" -j ACCEPT 2>/dev/null

    # Legacy: old TPROXY (fwmark 0x1, table 100)
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null
    log "  legacy rules: cleaned"

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
    log "  iptables: DoH/DoT blocking cleaned"

    # DNS intercept cleanup
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j TPROXY --on-port 5302 --tproxy-mark "0x$FWMARK/0x$FWMARK" 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    # Legacy: old UDP REDIRECT
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    log "  iptables: DNS intercept cleaned"

    # Legacy redsocks cleanup (from older versions)
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -j DROP 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j REDSOCKS 2>/dev/null
    iptables -t nat -F REDSOCKS 2>/dev/null
    iptables -t nat -X REDSOCKS 2>/dev/null
    log "  iptables: legacy redsocks cleaned"
done

# dnsmasq
if [ -f "$DNSMASQ_PID_FILE" ]; then
    kill "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null
    rm -f "$DNSMASQ_PID_FILE"
fi
log "  dnsmasq: stopped"

# ipset
ipset destroy "$IPSET_NAME" 2>/dev/null
ipset destroy ru_direct 2>/dev/null
log "  ipset: destroyed"

# dnscrypt-proxy
killall dnscrypt-proxy 2>/dev/null
log "  dnscrypt-proxy: stopped"

# sing-box
killall sing-box 2>/dev/null
log "  sing-box: stopped"

# Legacy processes
killall redsocks 2>/dev/null
killall hysteria 2>/dev/null
log "  legacy processes: cleaned"

# ── Remove old TUN/route artifacts ───────────────────────────────

ip rule del iif br0 table 1000 priority 1995 2>/dev/null
ip route flush table 1000 2>/dev/null
iptables -t nat -D POSTROUTING -o hysteria0 -j MASQUERADE 2>/dev/null
log "  legacy routes: cleaned"

# ── Remove files ─────────────────────────────────────────────────

log "Removing files..."
rm -f "$INIT_SCRIPT"
rm -f /opt/bin/hysteria-keenetic
rm -f /opt/bin/hysteria
rm -rf "$INSTALL_DIR"

# NDM netfilter hook
rm -f /opt/etc/ndm/netfilter.d/100-hysteria.sh

# dnscrypt-proxy config
rm -f /opt/etc/dnscrypt-proxy.toml
rm -rf /opt/etc/dnscrypt-proxy

# Also clean old locations and old hysteria-unblock artifacts
rm -f /opt/etc/init.d/S99hysteria-unblock
rm -f /opt/bin/hysteria-unblock
rm -rf /opt/etc/hysteria-unblock
rm -f /opt/etc/hysteria/config.yaml
rm -f /opt/etc/redsocks.conf
rmdir /opt/etc/hysteria 2>/dev/null
log "  files: removed"

# ── Remove cron ──────────────────────────────────────────────────

if crontab -l 2>/dev/null | grep -q "hysteria-keenetic\|hysteria-unblock"; then
    crontab -l 2>/dev/null | grep -v "hysteria-keenetic\|hysteria-unblock" | crontab -
    log "  cron: removed"
fi

# ── Optionally remove packages ───────────────────────────────────

echo ""
printf "Remove packages (sing-box-go, ipset, iptables, dnscrypt-proxy2)? [y/N] "
read -r answer
if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    opkg remove sing-box-go ipset iptables dnscrypt-proxy2 2>/dev/null
    log "  packages: removed"
else
    log "  packages: kept"
fi

# ── Done ─────────────────────────────────────────────────────────

echo ""
echo "  Uninstall complete."
echo "  dnsmasq-full was kept (system package)."
echo ""
