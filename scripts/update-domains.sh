#!/bin/sh
# update-domains.sh — Download domain lists and generate dnsmasq ipset config
# Part of hysteria-keenetic
#
# Downloads pre-built domain+CIDR lists from GitHub Releases.
# Falls back to direct upstream URLs if Release is unavailable.

BASE_DIR="/opt/etc/hysteria-keenetic"
CONFIG="$BASE_DIR/config"
DOMAINS_FILE="$BASE_DIR/domains.lst"
STATIC_IPS_FILE="$BASE_DIR/static-ips.lst"
IPSET_CONF="$BASE_DIR/dnsmasq-ipset.conf"
CUSTOM_FILE="$BASE_DIR/custom-domains.txt"
DNSMASQ_CONF="$BASE_DIR/dnsmasq.conf"
DNSMASQ_PID_FILE="/tmp/hysteria-dnsmasq.pid"
IPSET_NAME="unblock"
VERSION_FILE="$BASE_DIR/.lists-version"
RU_IPS_FILE="$BASE_DIR/ru-ips.lst"
RU_IPSET_NAME="ru_direct"
# Aggregated RU IPv4 CIDRs (RIR delegation data). ~8.7k lines as of 2026-11.
RU_IPS_URLS="https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt
https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
RU_IPS_MIN=5000

log() { logger -s -t "hy-update" "$1"; }

# ── Service name -> slug conversion ──────────────────────────────
# "Youtube" -> "youtube", "Github Copilot" -> "github-copilot"
_service_to_slug() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

# ── GitHub Release URL (primary source) ──────────────────────────
get_url() {
    _slug=$(_service_to_slug "$1")
    echo "${LISTS_BASE_URL}/${_slug}.lst"
}

# ── Direct upstream URLs (fallback) ──────────────────────────────
get_upstream_url() {
    case "$1" in
        "Antifilter community edition") echo "https://community.antifilter.download/list/domains.lst" ;;
        "ITDog Inside")       echo "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst" ;;
        "ITDog Outside")      echo "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst" ;;
        "Youtube")            echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-youtube.txt" ;;
        "Google")             echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-google.txt" ;;
        "Facebook")           echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-facebook.txt" ;;
        "Tik-Tok")            echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-tiktok.txt" ;;
        "Twitter")            echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-twitter.txt" ;;
        "Openai")             echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-openai.txt" ;;
        "Instagram")          echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-instagram.txt" ;;
        "Torrent Trackers")   echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-ttrackers.txt" ;;
        "Github Copilot")     echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-github-pilot.txt" ;;
        "Discord")            echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-discord.txt" ;;
        "Twitch")             echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-twitch.txt" ;;
        "Online movie theaters") echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-onlinetheater.txt" ;;
        "Telegram")           echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-telegram.txt" ;;
        "Netflix")            echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-netflix.txt" ;;
        "Bing")               echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-bing.txt" ;;
        "Adobe")              echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-adobe.txt" ;;
        "Apple")              echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-apple.txt" ;;
        "Search engines")     echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-search-engines.txt" ;;
        "Jetbrains")          echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-jetbrains.txt" ;;
        "Xbox")               echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-xbox.txt" ;;
        "WhatsApp")           echo "https://raw.githubusercontent.com/HybridNetworks/whatsapp-cidr/main/WhatsApp/whatsapp_domainlist.txt" ;;
        "Windsurf")           echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-windsurf.txt" ;;
        "Roblox")             echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-roblox.txt" ;;
        "Zscaler")            echo "https://raw.githubusercontent.com/Ground-Zerro/DomainMapper/refs/heads/main/platforms/dns-zscaler.txt" ;;
    esac
}

# ── RU CIDR list for ROUTE_MODE=except-ru ────────────────────────
# Keeps the previous list if every source fails or returns a suspiciously
# short list (same reasoning as the domain sanity gate below).
update_ru_ips() {
    for _u in $RU_IPS_URLS; do
        curl -sL -f -m 60 "$_u" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' > "$RU_IPS_FILE.new"
        _n=$(wc -l < "$RU_IPS_FILE.new")
        if [ "$_n" -ge "$RU_IPS_MIN" ]; then
            mv "$RU_IPS_FILE.new" "$RU_IPS_FILE"
            log "RU IPs: $_n CIDRs ($_u)"
            # Live reload with an atomic swap (manage.sh creates the set on start)
            if ipset list "$RU_IPSET_NAME" -t >/dev/null 2>&1; then
                ipset destroy "${RU_IPSET_NAME}_new" 2>/dev/null
                ipset create "${RU_IPSET_NAME}_new" hash:net maxelem 65536 \
                    && awk -v s="${RU_IPSET_NAME}_new" '{print "add " s " " $0}' "$RU_IPS_FILE" | ipset restore -exist \
                    && ipset swap "${RU_IPSET_NAME}_new" "$RU_IPSET_NAME"
                ipset destroy "${RU_IPSET_NAME}_new" 2>/dev/null
            fi
            return 0
        fi
        log "  ! RU IPs: $_u returned $_n CIDRs (min $RU_IPS_MIN)"
    done
    rm -f "$RU_IPS_FILE.new"
    log "ERROR: RU IP list download failed — keeping previous list"
    return 1
}

# ── Load config ──────────────────────────────────────────────────
[ -f "$CONFIG" ] || { log "Error: config not found"; exit 1; }
. "$CONFIG"

# GitHub Release base URL
LISTS_REPO="${LISTS_REPO:-denisnikonov/hysteria-keenetic}"
LISTS_BASE_URL="https://github.com/$LISTS_REPO/releases/latest/download"

# Parse flags
_force=0
_ru_only=0
for _arg in "$@"; do
    [ "$_arg" = "--force" ] && _force=1
    [ "$_arg" = "--ru-only" ] && _ru_only=1
done

# RU list is independent of the domain-list release version, so refresh it
# before the version short-circuit below
if [ "${ROUTE_MODE:-selective}" = "except-ru" ] || [ "$_ru_only" = "1" ]; then
    update_ru_ips; _ru_rc=$?
    [ "$_ru_only" = "1" ] && exit "$_ru_rc"
fi

# ── Version check (skip download if up to date) ─────────────────
if [ "$_force" = "0" ]; then
    _remote_ver=$(curl -sL -f -m 10 "${LISTS_BASE_URL}/manifest.txt" 2>/dev/null \
        | grep '^version=' | cut -d= -f2)
    _local_ver=""
    [ -f "$VERSION_FILE" ] && _local_ver=$(cat "$VERSION_FILE" 2>/dev/null)

    if [ -n "$_remote_ver" ] && [ "$_remote_ver" = "$_local_ver" ]; then
        log "Lists up to date (version $_local_ver)"
        exit 0
    fi

    if [ -n "$_remote_ver" ]; then
        log "New version available: $_remote_ver (local: ${_local_ver:-none})"
    fi
fi

log "Updating domain lists..."

# ── Download domains — try Release first, fallback to upstream ───
_dldir=$(mktemp -d)

# Write services to a temp file to avoid pipe subshell
_svcfile="$_dldir/_services.list"
echo "$SERVICES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' > "$_svcfile"

# Launch parallel downloads
while read -r service; do
    if [ "$service" = "custom" ]; then
        if [ -f "$CUSTOM_FILE" ]; then
            grep -v '^#' "$CUSTOM_FILE" | grep -v '^$' > "$_dldir/_custom.tmp"
            log "  + custom: $(wc -l < "$_dldir/_custom.tmp") entries"
        fi
        continue
    fi

    _safename=$(echo "$service" | tr ' /' '__')
    (
        url=$(get_url "$service")
        if curl -sL -f -m 30 "$url" > "$_dldir/$_safename.tmp" 2>/dev/null && [ -s "$_dldir/$_safename.tmp" ]; then
            _count=$(wc -l < "$_dldir/$_safename.tmp")
            log "  + $service: $_count entries (release)"
        else
            # Fallback to direct upstream URL
            rm -f "$_dldir/$_safename.tmp"
            _upstream=$(get_upstream_url "$service")
            if [ -n "$_upstream" ] && curl -sL -m 30 "$_upstream" > "$_dldir/$_safename.tmp" 2>/dev/null && [ -s "$_dldir/$_safename.tmp" ]; then
                _count=$(wc -l < "$_dldir/$_safename.tmp")
                log "  + $service: $_count entries (upstream fallback)"
            else
                rm -f "$_dldir/$_safename.tmp"
                : > "$_dldir/_fail.$_safename"
                log "  ! Failed to download: $service"
            fi
        fi
    ) &
done < "$_svcfile"
wait

# Merge all downloaded files
cat "$_dldir"/*.tmp > "$DOMAINS_FILE.tmp" 2>/dev/null
_fail_count=$(ls "$_dldir"/_fail.* 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$_dldir"

# Clean: remove BOM, carriage returns, whitespace
sed 's/\xef\xbb\xbf//g' "$DOMAINS_FILE.tmp" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^#\|^$\|^[[:space:]]*$' \
    | sort -u > "$DOMAINS_FILE.clean"
rm -f "$DOMAINS_FILE.tmp"

# Separate domains from IP/CIDR entries
# IP/CIDR: lines matching N.N.N.N or N.N.N.N/M
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$DOMAINS_FILE.clean" \
    | sort -u > "$STATIC_IPS_FILE.new"

# Domains: everything else (lowercase, validate format)
grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$DOMAINS_FILE.clean" \
    | tr '[:upper:]' '[:lower:]' \
    | grep '^[a-z0-9]' \
    | grep -v '[^a-z0-9._-]' \
    | sort -u > "$DOMAINS_FILE.new"
rm -f "$DOMAINS_FILE.clean"

NEW_DOMAINS=$(wc -l < "$DOMAINS_FILE.new")
NEW_IPS=$(wc -l < "$STATIC_IPS_FILE.new")
OLD_DOMAINS=0
[ -f "$DOMAINS_FILE" ] && OLD_DOMAINS=$(wc -l < "$DOMAINS_FILE")

# ── Sanity gate: refuse to commit a gutted/partial download ──────
# A flaky run (VPN/network down, GitHub 5xx) can fail most source
# downloads and yield a tiny list. Without this guard that tiny list
# would (a) overwrite the good one and (b) let the version marker be
# saved below, so the daily version-check would then short-circuit
# forever and the list would stay broken until a manual --force.
# Two guards: never let a failed run shrink a good list, and never
# let a healthy list collapse below a floor.
MIN_DOMAINS=1000
_accept=1
if [ "$_fail_count" -gt 0 ] && [ "$NEW_DOMAINS" -lt "$OLD_DOMAINS" ]; then
    _accept=0
fi
if [ "$OLD_DOMAINS" -ge "$MIN_DOMAINS" ] && [ "$NEW_DOMAINS" -lt "$MIN_DOMAINS" ]; then
    _accept=0
fi

if [ "$_accept" = "0" ]; then
    log "ERROR: download looks broken ($NEW_DOMAINS domains, ${_fail_count} source(s) failed, previous $OLD_DOMAINS) — keeping previous lists, NOT saving version"
    rm -f "$DOMAINS_FILE.new" "$STATIC_IPS_FILE.new"
    exit 1
fi

mv "$DOMAINS_FILE.new" "$DOMAINS_FILE"
mv "$STATIC_IPS_FILE.new" "$STATIC_IPS_FILE"

TOTAL_DOMAINS="$NEW_DOMAINS"
TOTAL_IPS="$NEW_IPS"
log "Total unique domains: $TOTAL_DOMAINS"
[ "$TOTAL_IPS" -gt 0 ] && log "Total static IPs/CIDRs: $TOTAL_IPS"

# Generate dnsmasq ipset config (atomic: write to .tmp, validate, then rename)
log "Generating dnsmasq ipset config..."
awk -v set="$IPSET_NAME" '{print "ipset=/" $0 "/" set}' "$DOMAINS_FILE" > "$IPSET_CONF.tmp"

if [ -s "$IPSET_CONF.tmp" ] && grep -q '^ipset=/' "$IPSET_CONF.tmp"; then
    mv "$IPSET_CONF.tmp" "$IPSET_CONF"
    log "Generated $(wc -l < "$IPSET_CONF") ipset rules"
else
    log "ERROR: generated ipset config is invalid or empty, keeping old version"
    rm -f "$IPSET_CONF.tmp"
fi

# Restart dnsmasq if running (SIGHUP does NOT reload ipset directives)
DNSMASQ_PID=$(cat "$DNSMASQ_PID_FILE" 2>/dev/null)
if [ -n "$DNSMASQ_PID" ] && [ -d "/proc/$DNSMASQ_PID" ]; then
    kill "$DNSMASQ_PID" 2>/dev/null
    rm -f "$DNSMASQ_PID_FILE"
    sleep 1
    if [ -f "$DNSMASQ_CONF" ]; then
        dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID_FILE"
        log "dnsmasq restarted with new ipset config"
    fi
fi

# ── Load static IPs/CIDRs into ipset ────────────────────────────
# Static IPs/CIDRs extracted from downloaded .lst files are loaded
# into ipset. Domain-based IPs are populated dynamically by dnsmasq
# at query time.
if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    if [ -f "$STATIC_IPS_FILE" ] && [ -s "$STATIC_IPS_FILE" ]; then
        sed '/^$/d; /^#/d' "$STATIC_IPS_FILE" \
            | awk "{print \"add $IPSET_NAME \" \$0}" \
            | ipset restore -exist 2>/dev/null
        LOADED=$(wc -l < "$STATIC_IPS_FILE")
        log "Loaded $LOADED IPs/CIDRs from static-ips.lst"
    fi
fi

# ── Save version only after a fully successful update ────────────
# If any source failed, leave the version marker unchanged so the
# next run re-downloads instead of short-circuiting on a version
# match with an incomplete list.
if [ -n "${_remote_ver:-}" ] && [ "${_fail_count:-0}" = "0" ]; then
    echo "$_remote_ver" > "$VERSION_FILE"
    log "Version saved: $_remote_ver"
elif [ "${_fail_count:-0}" != "0" ]; then
    log "Skipped version save: ${_fail_count} source(s) failed — will retry next run"
fi

log "Update complete."
