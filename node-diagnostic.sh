#!/usr/bin/env bash
# node-diagnostic.sh — diagnose a VPN/Linux node for YouTube, video CDNs and popular services.
# Compact dashboard: progress bar → summary → verdict → fix application.
# A detailed log is written to /tmp/node-diagnostic-<ts>.log
# Source: https://github.com/Case211/node-diagnostic
# Run:
#   sudo bash node-diagnostic.sh           # normal run
#   sudo bash node-diagnostic.sh --quick   # without the long tests (~1 min instead of ~5)
#   sudo bash node-diagnostic.sh -a        # apply all recommended fixes immediately
#   sudo bash node-diagnostic.sh -h        # help on options

SCRIPT_VERSION="3.4"
set -u
LANG=C.UTF-8

# ────────────────────────────────────────────────────────────────────
# Palette / formatting
# ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; C=$'\033[0;36m'; M=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    CLR_LINE=$'\033[K'
else
    R=""; G=""; Y=""; B=""; C=""; M=""; BOLD=""; DIM=""; NC=""; CLR_LINE=""
fi

VERBOSE=0
APPLY_MODE="prompt"   # prompt | all | none
DRY_RUN=0
QUICK=0
NO_NET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose)         VERBOSE=1 ;;
        -q|--quick)           QUICK=1 ;;
        -a|--apply-all|--yes) APPLY_MODE="all" ;;
        -n|--no-fixes)        APPLY_MODE="none" ;;
        --dry-run)            DRY_RUN=1; APPLY_MODE="all" ;;
        --no-net)             NO_NET=1 ;;
        --version)            echo "node-diagnostic $SCRIPT_VERSION"; exit 0 ;;
        -h|--help)
            cat <<HELP
node-diagnostic.sh v$SCRIPT_VERSION — diagnose a VPN/Linux node.

Options:
  -q, --quick        Skip the long tests (mtr/4-flow/multi-CDN/services/variance/bufferbloat)
  -v, --verbose      Old verbose mode (everything on screen)
  -a, --apply-all    Apply ALL recommended fixes without asking
  -n, --no-fixes     Don't offer fixes at all
      --dry-run      Show what would be applied, but don't do it
      --no-net       No network tests (local configuration only)
      --version      Show version and exit
  -h, --help         This help

Examples:
  sudo bash node-diagnostic.sh                    # full run ~5 min
  sudo bash node-diagnostic.sh -q                 # quick run ~1 min
  sudo bash node-diagnostic.sh -q -a              # quick + auto-fix
  sudo bash node-diagnostic.sh --dry-run          # show which fixes would be applied
HELP
            exit 0 ;;
        *)
            echo "Unknown option: $1 (see --help)" >&2
            exit 2 ;;
    esac
    shift
done

LOG="/tmp/node-diagnostic-$(date +%Y%m%d-%H%M%S).log"
RES_FILE=$(mktemp)
FINDINGS_FILE=$(mktemp)
SUMMARY_FILE=$(mktemp)

# ────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    trap - INT TERM EXIT
    local pids
    pids=$(jobs -p 2>/dev/null)
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
    rm -f "$RES_FILE" "$FINDINGS_FILE" "$SUMMARY_FILE"
}
trap cleanup EXIT

interrupted() {
    echo
    echo -e "${Y}Interrupted by user.${NC} Log: $LOG"
    cleanup
    exit 130
}
trap interrupted INT TERM

# severity: 1=info(↓), 2=warn, 3=bad(↑)
finding() {
    echo "$1|$2|$3" >> "$FINDINGS_FILE"
}

summary_kv() {
    echo "$1|$2" >> "$SUMMARY_FILE"
}

CURL_FLAGS=(--connect-timeout 5 --retry 0 -4)

# Final check line (after completion)
print_line() {
    local i=$1 total=$2 icon=$3 name=$4 tail=$5
    local pct=$(( i * 100 / total ))
    printf "\r${CLR_LINE}${DIM}[%2d/%2d %3d%%]${NC} %b %-26s ${DIM}%s${NC}\n" \
        "$i" "$total" "$pct" "$icon" "$name" "$tail"
}

# "In progress" indicator — Braille spinner, 10 frames, refreshed ~10 times/s.
# Shows overall % and ETA based on the average time of already-completed checks.
print_progress() {
    local i=$1 total=$2 name=$3 frame=${4:-0} elapsed=${5:-0}
    local spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local spin=${spin_frames[$(( frame % 10 ))]}
    local pct=$(( (i - 1) * 100 / total ))
    local eta_str=""
    if [ "${ETA_AVG:-0}" -gt 0 ] && [ "${i}" -gt 1 ]; then
        local remaining=$(( (total - i + 1) * ETA_AVG ))
        if [ "$remaining" -gt 60 ]; then
            eta_str=" · ETA $(( remaining / 60 ))m $(( remaining % 60 ))s"
        elif [ "$remaining" -gt 0 ]; then
            eta_str=" · ETA ${remaining}s"
        fi
    fi
    if [ "$elapsed" -ge 1 ]; then
        printf "\r${CLR_LINE}${DIM}[%2d/%2d %3d%%]${NC} ${C}%s${NC} %-26s ${DIM}%ds%s${NC}" \
            "$i" "$total" "$pct" "$spin" "$name" "$elapsed" "$eta_str"
    else
        printf "\r${CLR_LINE}${DIM}[%2d/%2d %3d%%]${NC} ${C}%s${NC} %-26s${DIM}%s${NC}" \
            "$i" "$total" "$pct" "$spin" "$name" "$eta_str"
    fi
}

# Icon by status
icon_for() {
    case "$1" in
        ok)   echo "${G}✓${NC}" ;;
        warn) echo "${Y}⚠${NC}" ;;
        bad)  echo "${R}✗${NC}" ;;
        skip) echo "${DIM}·${NC}" ;;
        *)    echo "?" ;;
    esac
}

# Runs the check function in the background, draws smooth progress, prints the result.
# ETA is computed as (total - done) * average_time_per_check.
declare -i CHECK_NUM=0
declare -i CHECK_TOTAL_TIME=0
declare -i CHECK_DONE=0
declare -i ETA_AVG=0
CHECK_TOTAL=0

run_check() {
    local name=$1 fn=$2
    CHECK_NUM=$(( CHECK_NUM + 1 ))

    {
        echo
        echo "════════════════════════════════════════════════════════════════"
        echo "[$CHECK_NUM/$CHECK_TOTAL] $name"
        echo "════════════════════════════════════════════════════════════════"
    } >> "$LOG"

    : > "$RES_FILE"
    (
        RES_STATUS=ok
        RES_SUMMARY=""
        exec >> "$LOG" 2>&1
        $fn || true
        printf '%s\n%s\n' "$RES_STATUS" "$RES_SUMMARY" > "$RES_FILE"
    ) &
    local pid=$!

    local start frame=0
    start=$(date +%s)
    # Poll every ~100ms — the spinner looks alive, not jerky
    while kill -0 "$pid" 2>/dev/null; do
        local el=$(( $(date +%s) - start ))
        print_progress "$CHECK_NUM" "$CHECK_TOTAL" "$name" "$frame" "$el"
        sleep 0.1
        frame=$(( frame + 1 ))
    done
    wait "$pid" 2>/dev/null || true

    local dur=$(( $(date +%s) - start ))
    CHECK_TOTAL_TIME=$(( CHECK_TOTAL_TIME + dur ))
    CHECK_DONE=$(( CHECK_DONE + 1 ))
    [ "$CHECK_DONE" -gt 0 ] && ETA_AVG=$(( CHECK_TOTAL_TIME / CHECK_DONE ))

    local st="bad" su="(no result)"
    if [ -s "$RES_FILE" ]; then
        st=$(sed -n '1p' "$RES_FILE")
        su=$(sed -n '2p' "$RES_FILE")
        [ -z "$st" ] && st="ok"
    fi
    print_line "$CHECK_NUM" "$CHECK_TOTAL" "$(icon_for "$st")" "$name" "$su"
}

# ────────────────────────────────────────────────────────────────────
# Dependency installation (quiet)
# ────────────────────────────────────────────────────────────────────
ensure_deps() {
    declare -A PKG_MAP=(
        [mpstat]="sysstat:sysstat:sysstat"
        [mtr]="mtr-tiny:mtr:mtr"
        [traceroute]="traceroute:traceroute:traceroute"
        [dig]="dnsutils:bind-utils:bind-tools"
        [nc]="netcat-openbsd:nmap-ncat:netcat-openbsd"
        [curl]="curl:curl:curl"
        [bc]="bc:bc:bc"
        [ethtool]="ethtool:ethtool:ethtool"
        [conntrack]="conntrack:conntrack-tools:conntrack-tools"
        [jq]="jq:jq:jq"
    )
    local PKG_INSTALL="" IDX=0
    if   have apt-get; then PKG_INSTALL="apt-get install -y -qq"; IDX=0
                            apt-get update -qq >/dev/null 2>&1 || true
    elif have dnf;     then PKG_INSTALL="dnf install -y -q";      IDX=1
    elif have yum;     then PKG_INSTALL="yum install -y -q";      IDX=1
    elif have apk;     then PKG_INSTALL="apk add --quiet";        IDX=2
                            apk update -q >/dev/null 2>&1 || true
    fi
    [ -z "$PKG_INSTALL" ] && return
    [ "$EUID" -ne 0 ] && return

    declare -A NEED=()
    for cmd in "${!PKG_MAP[@]}"; do
        if ! have "$cmd"; then
            IFS=':' read -ra pkgs <<< "${PKG_MAP[$cmd]}"
            NEED[${pkgs[$IDX]}]=1
        fi
    done
    [ ${#NEED[@]} -eq 0 ] && return
    # shellcheck disable=SC2086
    $PKG_INSTALL ${!NEED[*]} >/dev/null 2>&1 || true
}

# ════════════════════════════════════════════════════════════════════
# CHECKS — each one sets RES_STATUS and RES_SUMMARY
# ════════════════════════════════════════════════════════════════════

# 1. Identification
check_identify() {
    local h ip4 ip6 kern distro virt up
    h=$(hostname)
    ip4=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 https://api.ipify.org || echo "")
    ip6=$(curl --connect-timeout 5 -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")

    # Geo cross-check from 3 independent sources (ipinfo / ip-api / ipwho)
    # Hosting IPs are often shown as FI in one database and EE in another — the actual
    # datacenter is more reliably determined via latency, not WHOIS.
    local ipinfo_country="?" ipinfo_city="?" ipinfo_org="?"
    local ipapi_country="?"  ipapi_city="?"  ipapi_org="?"
    local ipwho_country="?"  ipwho_city="?"  ipwho_org="?"

    if [ -n "$ip4" ]; then
        if have jq; then
            local g1 g2 g3
            g1=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 "https://ipinfo.io/$ip4/json" 2>/dev/null)
            g2=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 "http://ip-api.com/json/$ip4?fields=country,countryCode,city,isp,as" 2>/dev/null)
            g3=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 "https://ipwho.is/$ip4" 2>/dev/null)
            ipinfo_country=$(echo "$g1" | jq -r '.country // "?"')
            ipinfo_city=$(echo    "$g1" | jq -r '.city // "?"')
            ipinfo_org=$(echo     "$g1" | jq -r '.org // "?"')
            ipapi_country=$(echo  "$g2" | jq -r '.countryCode // "?"')
            ipapi_city=$(echo     "$g2" | jq -r '.city // "?"')
            ipapi_org=$(echo      "$g2" | jq -r '.isp // .as // "?"')
            ipwho_country=$(echo  "$g3" | jq -r '.country_code // "?"')
            ipwho_city=$(echo     "$g3" | jq -r '.city // "?"')
            ipwho_org=$(echo      "$g3" | jq -r '.connection.isp // .connection.org // "?"')
        else
            ipinfo_city=$(curl    "${CURL_FLAGS[@]}" -s --max-time 5 https://ipinfo.io/city)
            ipinfo_country=$(curl "${CURL_FLAGS[@]}" -s --max-time 5 https://ipinfo.io/country)
            ipinfo_org=$(curl     "${CURL_FLAGS[@]}" -s --max-time 5 https://ipinfo.io/org)
        fi
    fi

    # Latency probe to local IXs — the most reliable estimate of the datacenter's real location
    # (the TLD picked by ipinfo isn't trusted — we probe both nearest ones)
    local lat_helsinki lat_tallinn lat_stockholm lat_riga lat_warsaw
    lat_helsinki=$(ping -c 3 -W 1 -q nordu.net 2>/dev/null     | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_tallinn=$(ping  -c 3 -W 1 -q estpak.ee 2>/dev/null     | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_stockholm=$(ping -c 3 -W 1 -q sunet.se 2>/dev/null     | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_riga=$(ping     -c 3 -W 1 -q lattelecom.lv 2>/dev/null | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')
    lat_warsaw=$(ping   -c 3 -W 1 -q nask.pl 2>/dev/null       | awk -F'/' '/rtt|round-trip/ {printf "%.1f", $5}')

    kern=$(uname -sr)
    distro=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)
    virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
    up=$(uptime -p 2>/dev/null || echo "?")

    echo "Hostname: $h"
    echo "IPv4:     $ip4"
    echo "IPv6:     ${ip6:-none}"
    echo
    echo "--- Geo cross-check (database | country | city | ISP) ---"
    printf "  ipinfo.io:   %-3s %s · %s\n"   "$ipinfo_country" "$ipinfo_city" "$ipinfo_org"
    printf "  ip-api.com:  %-3s %s · %s\n"   "$ipapi_country"  "$ipapi_city"  "$ipapi_org"
    printf "  ipwho.is:    %-3s %s · %s\n"   "$ipwho_country"  "$ipwho_city"  "$ipwho_org"
    echo
    echo "--- Latency to national endpoints (shows the real datacenter location) ---"
    printf "  Helsinki  (nordu.net):     %s ms\n" "${lat_helsinki:-n/a}"
    printf "  Tallinn   (estpak.ee):     %s ms\n" "${lat_tallinn:-n/a}"
    printf "  Stockholm (sunet.se):      %s ms\n" "${lat_stockholm:-n/a}"
    printf "  Riga      (lattelecom.lv): %s ms\n" "${lat_riga:-n/a}"
    printf "  Warsaw    (nask.pl):       %s ms\n" "${lat_warsaw:-n/a}"
    echo
    echo "Kernel: $kern  Distro: $distro  Virt: $virt  Uptime: $up"

    # Consensus country — if the databases agree, take it. If they disagree, flag it.
    local countries=""
    [ "$ipinfo_country" != "?" ] && countries="$countries $ipinfo_country"
    [ "$ipapi_country"  != "?" ] && countries="$countries $ipapi_country"
    [ "$ipwho_country"  != "?" ] && countries="$countries $ipwho_country"
    local uniq_countries
    uniq_countries=$(echo "$countries" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' '/' | sed 's:/$::')

    # Guess the "real" location from the smallest ping
    local real_loc="?" real_lat=99999
    for pair in "Helsinki:$lat_helsinki" "Tallinn:$lat_tallinn" "Stockholm:$lat_stockholm" "Riga:$lat_riga" "Warsaw:$lat_warsaw"; do
        local loc=${pair%%:*}
        local lat=${pair##*:}
        [ -z "$lat" ] && continue
        if have bc && (( $(echo "$lat < $real_lat" | bc -l 2>/dev/null || echo 0) )); then
            real_loc=$loc
            real_lat=$lat
        fi
    done

    # Validation: latency < 10ms = really close, 10-30ms = in the region, >30ms = unclear
    local geo_lat_str="?"
    if [ "$real_loc" != "?" ]; then
        if have bc && (( $(echo "$real_lat < 10" | bc -l 2>/dev/null || echo 0) )); then
            geo_lat_str="${real_loc} (~${real_lat} ms, close)"
        elif have bc && (( $(echo "$real_lat < 30" | bc -l 2>/dev/null || echo 0) )); then
            geo_lat_str="${real_loc} (~${real_lat} ms, in region)"
        else
            geo_lat_str="undetermined (all >30ms — tunnel/loss distorts it)"
        fi
    fi

    summary_kv "Host"           "$h"
    summary_kv "IP"             "$ip4"
    summary_kv "Geo (DBs)"      "$uniq_countries"
    summary_kv "Geo by latency" "$geo_lat_str"
    summary_kv "ASN"            "${ipinfo_org:-${ipapi_org}}"
    summary_kv "Kernel"         "$kern · $distro"

    RES_STATUS=ok
    RES_SUMMARY="$h · $uniq_countries"
    [ "$real_loc" != "?" ] && RES_SUMMARY="$RES_SUMMARY · ~${real_lat}ms→$real_loc"

    # Flag it if different databases give a different country
    local n_uniq
    n_uniq=$(echo "$uniq_countries" | tr '/' '\n' | grep -cv '^$')
    if [ "$n_uniq" -ge 2 ]; then
        RES_STATUS=warn
        finding 1 geo "Databases disagree on country ($uniq_countries) — typical for hosting IPs, ASN registration ≠ physical datacenter. Real location by latency: $real_loc"
    fi
}

# 2. CPU and load
check_cpu() {
    local nproc model load idle softirq iow
    nproc=$(nproc)
    model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
    load=$(cut -d' ' -f1 /proc/loadavg)

    if have mpstat; then
        local mp
        mp=$(mpstat -P ALL 1 1 2>/dev/null)
        idle=$(echo "$mp"   | awk '/Average:.*all/ {print $NF}')
        iow=$(echo "$mp"    | awk '/Average:.*all/ {print $6}')
        softirq=$(echo "$mp"| awk '/Average:.*all/ {print $9}')
        echo "$mp"
    else
        idle="?"; iow="?"; softirq="?"
        cat /proc/loadavg
    fi

    echo "Cores=$nproc  Model=$model  Load=$load  Idle=${idle}%  Softirq=${softirq}%  iowait=${iow}%"

    summary_kv "CPU" "$nproc cores · $model · load $load"

    RES_STATUS=ok
    RES_SUMMARY="${nproc}c · load $load · idle ${idle}%"

    if have bc; then
        if (( $(echo "$idle < 50" | bc -l 2>/dev/null || echo 0) )); then
            RES_STATUS=warn
            RES_SUMMARY="$RES_SUMMARY · ⚠ overloaded"
            finding 3 cpu "CPU idle ${idle}% — Xray is bottlenecked on encryption, add cores/offload the load"
        fi
        if (( $(echo "${softirq:-0} > 15" | bc -l 2>/dev/null || echo 0) )); then
            [ "$RES_STATUS" = "ok" ] && RES_STATUS=warn
            RES_SUMMARY="$RES_SUMMARY · softirq ${softirq}%"
            finding 2 cpu "softirq ${softirq}% — set up RPS/RSS, otherwise one core gets swamped by interrupts"
        fi
        if (( $(echo "${iow:-0} > 5" | bc -l 2>/dev/null || echo 0) )); then
            finding 2 cpu "iowait ${iow}% — disk bottleneck (Xray logs? swap?)"
        fi
    fi
}

# 3. Memory
check_mem() {
    free -h
    local avail total pct swap_used
    avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    pct=$((100 * avail / total))
    swap_used=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print t-f}' /proc/meminfo)

    summary_kv "RAM" "$(free -h | awk '/Mem:/ {print $2" total · "$7" available"}')"

    RES_STATUS=ok
    RES_SUMMARY="${pct}% available"
    if [ "$pct" -lt 15 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$RES_SUMMARY ⚠"
        finding 2 mem "Free memory <15% — page cache suffers, freezes under load"
    fi
    [ "$swap_used" -gt 0 ] && RES_SUMMARY="$RES_SUMMARY · swap used"
}

# 4. NIC / interface
check_nic() {
    local iface mtu drv speed rx_drops tx_drops rx_err tx_err
    iface=$(ip -4 route show default | awk '/default/ {print $5; exit}')
    mtu=$(ip link show "$iface" | grep -oP 'mtu \K\d+')
    drv=$(have ethtool && ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver/ {print $2}')
    speed=$(have ethtool && ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed/ {print $2}')

    rx_drops=$(ip -s link show "$iface" | awk '/RX:/{getline; print $4}')
    tx_drops=$(ip -s link show "$iface" | awk '/TX:/{getline; print $4}')
    rx_err=$(ip -s link show "$iface"   | awk '/RX:/{getline; print $3}')
    tx_err=$(ip -s link show "$iface"   | awk '/TX:/{getline; print $3}')

    echo "iface=$iface  mtu=$mtu  driver=${drv:-?}  speed=${speed:-?}"
    echo "RX errors=$rx_err  drops=$rx_drops"
    echo "TX errors=$tx_err  drops=$tx_drops"
    if have ethtool; then
        echo "--- ethtool -k (offloads) ---"
        ethtool -k "$iface" 2>/dev/null | grep -E '^(rx-|tx-|generic-|tcp-segm|scatter)' | head -10
        echo "--- ring buffers ---"
        ethtool -g "$iface" 2>/dev/null | head -10
        echo "--- non-zero errors/drops ---"
        ethtool -S "$iface" 2>/dev/null | awk '$NF+0 != 0' | grep -iE 'err|drop|miss|discard|fail|overflow' | head -10
    fi

    summary_kv "NIC" "$iface · ${drv:-?} · mtu $mtu"

    RES_STATUS=ok
    RES_SUMMARY="$iface · mtu $mtu · drops ${rx_drops}/${tx_drops}"

    if [ "$mtu" -lt 1500 ]; then
        finding 2 nic "MTU=$mtu < 1500 — sub-tunnel or GRE; check PMTU"
    fi
    if [ "${rx_drops:-0}" -gt 1000 ]; then
        RES_STATUS=warn
        finding 2 nic "RX drops $rx_drops — interface/kernel buffer can't keep up (rx_buffer / netdev_max_backlog)"
    fi
    if [ "${tx_drops:-0}" -gt 1000 ]; then
        RES_STATUS=warn
        finding 2 nic "TX drops $tx_drops — outbound link / qdisc saturation"
    fi
}

# 4b. Tunnels (WireGuard / NetBird / Tailscale / OpenVPN / IPsec)
check_tunnel() {
    local tunnels=()
    while IFS= read -r line; do
        local iface
        iface=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
        case "$iface" in
            wg*)         tunnels+=("WireGuard:$iface") ;;
            tun*)        tunnels+=("OpenVPN/tun:$iface") ;;
            tap*)        tunnels+=("OpenVPN/tap:$iface") ;;
            wt*)         tunnels+=("NetBird:$iface") ;;
            tailscale*|ts*) tunnels+=("Tailscale:$iface") ;;
            ipsec*|gre*) tunnels+=("IPsec/GRE:$iface") ;;
        esac
    done < <(ip -o link show 2>/dev/null)

    local def_iface
    def_iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    echo "default iface: $def_iface"

    if [ ${#tunnels[@]} -eq 0 ]; then
        RES_STATUS=ok
        RES_SUMMARY="no tunnels"
        return
    fi

    echo "Tunnels found: ${tunnels[*]}"
    local mtu_issue=0 def_via_tunnel=""
    for entry in "${tunnels[@]}"; do
        local kind=${entry%%:*}
        local iface=${entry##*:}
        local mtu peer
        mtu=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+')
        peer=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        echo "  $kind ($iface): MTU=$mtu addr=$peer"

        # NetBird/WireGuard MTU is usually 1280-1420 — fine, but at 1280 on a 1500 underlay there will be fragmentation
        if [ -n "$mtu" ] && [ "$mtu" -lt 1280 ]; then
            mtu_issue=1
            finding 2 tunnel "Tunnel $iface MTU=$mtu < 1280 — too small, you'll lose speed"
        fi
        if [ "$iface" = "$def_iface" ]; then
            def_via_tunnel=$iface
        fi
    done

    summary_kv "Tunnels" "${#tunnels[@]} active: ${tunnels[*]}"

    if [ -n "$def_via_tunnel" ]; then
        RES_STATUS=warn
        RES_SUMMARY="${#tunnels[@]} active, default via $def_via_tunnel"
        finding 2 tunnel "Default route goes through tunnel $def_via_tunnel — all node traffic is wrapped into the overlay (ASN peering doesn't work directly)"
    elif [ "$mtu_issue" = "1" ]; then
        RES_STATUS=warn
        RES_SUMMARY="${#tunnels[@]} active, MTU small"
    else
        RES_STATUS=ok
        RES_SUMMARY="${#tunnels[@]} active, default via $def_iface"
        finding 1 tunnel "Active tunnels (${tunnels[*]}). Default isn't via them — that's fine"
    fi
}

# 5. TCP congestion control
check_tcp_cc() {
    local cc qdisc avail
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    qdisc=$(sysctl -n net.core.default_qdisc)
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    echo "cc=$cc  qdisc=$qdisc"
    echo "available=$avail"

    summary_kv "TCP CC" "$cc + $qdisc"

    RES_STATUS=ok
    RES_SUMMARY="$cc + $qdisc"
    if [ "$cc" != "bbr" ]; then
        if echo "$avail" | grep -q bbr; then
            RES_STATUS=warn
            RES_SUMMARY="$cc (bbr available!)"
            finding 3 tcp "BBR is available but not active — sysctl -w net.ipv4.tcp_congestion_control=bbr"
        else
            RES_STATUS=bad
            RES_SUMMARY="bbr unavailable"
            finding 3 tcp "BBR is missing from the kernel — update the kernel"
        fi
    fi
    case "$qdisc" in
        fq|fq_codel|cake) ;;
        *)
            [ "$RES_STATUS" = "ok" ] && RES_STATUS=warn
            finding 2 tcp "qdisc=$qdisc — BBR needs fq, bufferbloat needs fq_codel/cake"
            ;;
    esac
}

# 6. TCP tuning
check_tcp_tuning() {
    local mtu_probe slow_start rmem_max wmem_max ntsl backlog
    mtu_probe=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)
    slow_start=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    ntsl=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
    backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)

    echo "tcp_mtu_probing=$mtu_probe"
    echo "tcp_slow_start_after_idle=$slow_start"
    echo "rmem_max=$rmem_max  wmem_max=$wmem_max"
    echo "tcp_notsent_lowat=$ntsl"
    echo "netdev_max_backlog=$backlog"
    sysctl -a 2>/dev/null | grep -E '^net\.ipv4\.(tcp_window_scaling|tcp_sack|tcp_timestamps|tcp_fastopen|tcp_ecn|tcp_no_metrics_save)' || true

    local issues=()
    [ "$mtu_probe" = "0" ] && issues+=("mtu_probing=0")
    [ "$slow_start" = "1" ] && issues+=("slow_start=1")
    [ "$rmem_max" -lt 16777216 ] && issues+=("rmem_max=$rmem_max")
    [ "${backlog:-0}" -lt 4096 ] && issues+=("backlog=$backlog")

    if [ ${#issues[@]} -eq 0 ]; then
        RES_STATUS=ok
        RES_SUMMARY="all good"
    else
        RES_STATUS=warn
        RES_SUMMARY="$(IFS=, ; echo "${issues[*]}")"
        [ "$mtu_probe" = "0" ] && finding 3 tcp "tcp_mtu_probing=0 — on a PMTU blackhole TCP sessions hang (the classic \"stuck loading\")"
        [ "$slow_start" = "1" ] && finding 2 tcp "tcp_slow_start_after_idle=1 — after a pause speed drops into slow-start. 0 is better"
        [ "$rmem_max" -lt 16777216 ] && finding 2 tcp "rmem_max=$rmem_max < 16M — on a gig link the small TCP window caps speed"
        [ "${backlog:-0}" -lt 4096 ] && finding 1 tcp "netdev_max_backlog=$backlog — too small for load, 16384 recommended"
    fi

    summary_kv "TCP tuning" "$RES_SUMMARY"
}

# 7. Conntrack
check_conntrack() {
    if [ ! -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        RES_STATUS=skip
        RES_SUMMARY="conntrack module not loaded"
        return
    fi
    local cur max pct
    cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    pct=$((100 * cur / (max > 0 ? max : 1)))
    echo "count=$cur max=$max ($pct%)"
    if have conntrack; then
        echo "--- top-10 dst ---"
        conntrack -L 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) {gsub("dst=","",$i); print $i; break}}' \
            | sort | uniq -c | sort -rn | head -10
    fi

    summary_kv "Conntrack" "$cur / $max ($pct%)"

    RES_STATUS=ok
    RES_SUMMARY="$cur / $max ($pct%)"
    if [ "$pct" -ge 80 ]; then
        RES_STATUS=bad
        finding 3 conntrack "Conntrack is $pct% full — new connections are being dropped. This is exactly \"Shorts won't open\". nf_conntrack_max → 524288"
    elif [ "$pct" -ge 50 ]; then
        RES_STATUS=warn
        finding 1 conntrack "Conntrack is $pct% used — close to the limit"
    fi
}

# 8. DNS
check_dns() {
    cat /etc/resolv.conf 2>/dev/null
    local fail=0 total=0 lat_sum=0
    if have dig; then
        echo "--- 5 queries to youtube.com ---"
        for _ in 1 2 3 4 5; do
            total=$((total+1))
            local ans t
            ans=$(dig +short +time=2 +tries=1 youtube.com A 2>/dev/null | head -1)
            t=$(dig +tries=1 +time=2 youtube.com A 2>/dev/null | awk '/Query time/ {print $4}')
            echo "  ans=$ans  ${t:-?}ms"
            if [ -z "$ans" ]; then
                fail=$((fail+1))
            elif [ -n "$t" ]; then
                lat_sum=$((lat_sum + t))
            fi
        done
        echo "--- main hosts ---"
        for host in www.google.com youtube.com googlevideo.com www.youtube.com i.ytimg.com; do
            local a4 a6
            a4=$(dig +short +time=2 +tries=1 "$host" A 2>/dev/null | head -1)
            a6=$(dig +short +time=2 +tries=1 "$host" AAAA 2>/dev/null | head -1)
            printf "  %-25s A=%-20s AAAA=%s\n" "$host" "${a4:-—}" "${a6:-—}"
        done
    fi

    summary_kv "DNS" "$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)"

    if [ "$total" -eq 0 ]; then
        RES_STATUS=skip
        RES_SUMMARY="(dig unavailable)"
    elif [ "$fail" -gt 0 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$fail/$total attempts failed"
        finding 3 dns "DNS is timing out ($fail/$total) — googlevideo resolution fails → the client lands on an old/slow PoP"
    else
        local avg=$((lat_sum / total))
        RES_SUMMARY="${avg}ms average"
        RES_STATUS=ok
        [ "$avg" -gt 100 ] && { RES_STATUS=warn; finding 1 dns "DNS latency ${avg}ms — slow resolver"; }
    fi
}

# 9. PMTU (binary search)
check_pmtu() {
    # Robust probe: a size is considered OK if at least 1 of 3 packets came back.
    # Otherwise, on a lossy network, a single-shot ping hits a false negative and convergence lies.
    pmtu_probe() {
        local size=$1 target=${2:-1.1.1.1}
        local recv
        recv=$(ping -M do -s "$size" -c 3 -W 2 "$target" 2>/dev/null | awk '/packets transmitted/ {print $4}')
        [ "${recv:-0}" -ge 1 ]
    }

    echo "ping -M do -s 1472 → 1.1.1.1 (3 packets)"
    if pmtu_probe 1472; then
        RES_STATUS=ok
        RES_SUMMARY="PMTU 1500 (full)"
        summary_kv "PMTU" "1500"
        return
    fi

    local hi=1472 lo=576 best=0 mid
    for _ in $(seq 1 12); do
        mid=$(( (hi + lo) / 2 ))
        if pmtu_probe "$mid"; then
            best=$mid; lo=$mid
        else
            hi=$mid
        fi
        [ $((hi - lo)) -le 1 ] && break
    done
    local mtu=$((best + 28))
    echo "Largest non-fragmented payload: $best (=> path MTU ~$mtu)"

    summary_kv "PMTU" "$mtu"

    RES_STATUS=warn
    RES_SUMMARY="$mtu (instead of 1500)"
    if [ "$mtu" -lt 1450 ]; then
        RES_STATUS=bad
        finding 3 pmtu "PMTU=$mtu — large packets are dropped. Needed: tcp_mtu_probing=1 + iptables TCPMSS clamp"
    else
        finding 2 pmtu "PMTU=$mtu < 1500 — enable tcp_mtu_probing=1 so TCP doesn't hang on a blackhole"
    fi
}

# 10. Loss / latency to Google
check_loss() {
    # Extracts loss% from ping output — look for a token like "20%"
    parse_loss() {
        echo "$1" | awk '/packet loss/ {
            for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+)?%$/) {
                sub("%","",$i); printf "%d", $i+0; exit
            }
        }'
    }
    local g_loss=0 g_loss_avg=0 cnt=0
    for host in 8.8.8.8 1.1.1.1 9.9.9.9; do
        local out loss
        out=$(ping -c 10 -W 2 -i 0.2 -q "$host" 2>/dev/null)
        loss=$(parse_loss "$out")
        echo "  $host loss=${loss:-?}%"
    done
    for host in www.google.com youtube.com googlevideo.com; do
        local out loss rtt
        out=$(ping -c 10 -W 2 -i 0.2 -q "$host" 2>/dev/null)
        loss=$(parse_loss "$out")
        rtt=$(echo "$out"  | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5}')
        echo "  $host loss=${loss:-?}% avg=${rtt:-?}ms"
        if [ -n "$loss" ] && [ "$loss" -gt 0 ]; then
            g_loss_avg=$((g_loss_avg + loss))
            cnt=$((cnt + 1))
        fi
        [ "${loss:-0}" -gt "$g_loss" ] && g_loss=$loss
    done

    summary_kv "Loss to Google" "max ${g_loss}%"

    RES_STATUS=ok
    RES_SUMMARY="max ${g_loss}% loss"
    if [ "$g_loss" -ge 5 ]; then
        RES_STATUS=bad
        finding 3 loss "Loss to Google up to ${g_loss}% — TCP retransmits, video freezes. Provider peering problem"
    elif [ "$g_loss" -gt 0 ]; then
        RES_STATUS=warn
        finding 2 loss "Light loss to Google (${g_loss}%) — borderline"
    fi
}

# 11. MTR — find the worst hop
check_mtr() {
    have mtr || { RES_STATUS=skip; RES_SUMMARY="mtr unavailable"; return; }
    local out worst_loss worst_hop hops_total
    out=$(mtr -r -c 15 -n youtube.com 2>/dev/null)
    echo "$out"
    # mtr line: "  3.|-- 100.64.120.0   0.0%  15  ..."
    # Literal `|` in ERE — via [|] (some greps read `\|` as alternation).
    hops_total=$(echo "$out" | grep -cE '^ *[0-9]+\.[|]')
    worst_loss=$(echo "$out" | awk '
        BEGIN { max = -1 }
        /^ *[0-9]+\.[|]/ {
            gsub("%","",$3)
            if ($3+0 > max) { max=$3+0; hop=$2"/"$3"%" }
        }
        END { print hop }')

    echo
    echo "--- mtr → googlevideo.com ---"
    mtr -r -c 15 -n googlevideo.com 2>/dev/null

    summary_kv "Route" "$hops_total hops · max loss $worst_loss"

    RES_STATUS=ok
    RES_SUMMARY="$hops_total hops"
    local worst_pct
    worst_pct=$(echo "$worst_loss" | awk -F'/' '{gsub("%","",$2); print $2+0}')
    if [ -n "$worst_pct" ] && [ "$worst_pct" -ge 30 ]; then
        RES_STATUS=bad
        RES_SUMMARY="${hops_total}h · loss ${worst_pct}% at $worst_loss"
        finding 3 route "On the path to YouTube there's a hop with loss $worst_loss — this is broken ASN peering"
    elif [ -n "$worst_pct" ] && [ "$worst_pct" -ge 10 ]; then
        RES_STATUS=warn
        RES_SUMMARY="${hops_total}h · loss ${worst_pct}% at $worst_loss"
        finding 2 route "Hop with loss $worst_loss — worth reporting to the host"
    fi
}

# 12. UDP / QUIC / HTTP/3
check_quic() {
    local udp_ok=0 h3_ok=0
    if have nc; then
        timeout 3 nc -u -z 8.8.8.8 443 >/dev/null 2>&1 && udp_ok=1
    fi
    echo "UDP/443 → 8.8.8.8: $([ $udp_ok -eq 1 ] && echo OK || echo FAIL)"

    if curl --help all 2>/dev/null | grep -q -- '--http3'; then
        if curl --http3 -sS -o /dev/null --max-time 6 https://www.youtube.com >/dev/null 2>&1; then
            h3_ok=1
            echo "HTTP/3 youtube.com: OK"
        fi
    fi

    summary_kv "QUIC/HTTP3" "udp=$([ $udp_ok = 1 ] && echo on || echo off) http3=$([ $h3_ok = 1 ] && echo on || echo off)"

    RES_STATUS=ok
    RES_SUMMARY="udp ok"
    if [ $udp_ok -eq 0 ]; then
        RES_STATUS=warn
        RES_SUMMARY="UDP/443 blocked?"
        finding 2 quic "UDP/443 doesn't get through — clients fall back to TCP, Shorts take longer to start"
    fi
    if [ $h3_ok -eq 0 ] && curl --help all 2>/dev/null | grep -q -- '--http3'; then
        finding 1 quic "curl --http3 doesn't respond — QUIC to Google is degraded"
    fi
}

# 13. Speed: single flow (Cachefly 100 MB)
check_speed_single() {
    local out spd_bps spd_mbit code size
    out=$(curl "${CURL_FLAGS[@]}" -sS -o /dev/null --max-time 12 \
        -w "%{speed_download}|%{size_download}|%{time_total}|%{http_code}" \
        "https://cachefly.cachefly.net/100mb.test" 2>/dev/null) || out=""
    echo "raw: $out"
    spd_bps=$(echo "$out" | cut -d'|' -f1)
    size=$(echo    "$out" | cut -d'|' -f2)
    code=$(echo    "$out" | cut -d'|' -f4)
    # curl returns "0.000" on timeout — coerce to an integer
    local spd_int
    spd_int=$(printf '%.0f' "${spd_bps:-0}" 2>/dev/null || echo 0)
    if [ -z "$spd_bps" ] || [ "${spd_int:-0}" -lt 10000 ]; then
        RES_STATUS=bad
        RES_SUMMARY="fail (size=${size:-?}, http=${code:-?})"
        finding 3 speed "Cachefly 100MB didn't finish downloading (${size:-0} bytes, http=${code:-?}) — link/block"
        summary_kv "Speed (1-flow)" "fail"
        return
    fi
    spd_mbit=$(( spd_int * 8 / 1000000 ))

    summary_kv "Speed (1-flow)" "${spd_mbit} Mbit/s"

    RES_STATUS=ok
    RES_SUMMARY="${spd_mbit} Mbit/s"
    if [ "${spd_mbit:-0}" -lt 50 ]; then
        RES_STATUS=bad
        finding 3 speed "1-flow ${spd_mbit} Mbit/s — very low speed, video won't play"
    elif [ "${spd_mbit:-0}" -lt 200 ]; then
        RES_STATUS=warn
        finding 2 speed "1-flow ${spd_mbit} Mbit/s — the node works, but Shorts may stutter with many users"
    fi
}

# 14. Speed: 4 parallel flows
check_speed_4flow() {
    local tmpd
    tmpd=$(mktemp -d)
    local PIDS=()
    local start
    start=$(date +%s)
    for i in 1 2 3 4; do
        ( curl "${CURL_FLAGS[@]}" -o "$tmpd/d$i" --max-time 10 -sS \
            "https://cachefly.cachefly.net/100mb.test" >/dev/null 2>&1 ) &
        PIDS+=($!)
    done
    local deadline=$(( start + 12 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local running=0
        for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && running=1; done
        [ "$running" = "0" ] && break
        sleep 1
    done
    for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done

    local end dur total=0 sz
    end=$(date +%s)
    dur=$(( end - start )); [ "$dur" -lt 1 ] && dur=1
    for f in "$tmpd"/d*; do
        [ -f "$f" ] || continue
        sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        total=$((total + sz))
    done
    rm -rf "$tmpd"

    if [ "$total" -eq 0 ]; then
        RES_STATUS=bad
        RES_SUMMARY="fail (Cachefly unreachable)"
        finding 2 speed "4-flow test got no data — are parallel TLS sessions being throttled?"
        summary_kv "Speed (4-flow)" "fail"
        return
    fi
    local mbits
    mbits=$(echo "scale=0; $total * 8 / $dur / 1000000 / 1" | bc -l 2>/dev/null)
    echo "4-flow combined: $mbits Mbit/s ($total bytes in ${dur}s)"

    summary_kv "Speed (4-flow)" "${mbits} Mbit/s"

    RES_STATUS=ok
    RES_SUMMARY="${mbits} Mbit/s combined"
    if [ "$mbits" -lt 100 ]; then
        RES_STATUS=warn
        finding 2 speed "4-flow only ${mbits} Mbit/s — the link is small or being throttled"
    fi
}

# 15. Bufferbloat
check_bufferbloat() {
    local base under
    base=$(ping -c 10 -i 0.2 -W 2 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5}')
    echo "baseline avg: ${base:-?} ms"

    # Count how much we actually downloaded — otherwise the test without load is meaningless
    local size_file
    size_file=$(mktemp)
    ( curl "${CURL_FLAGS[@]}" --max-time 12 -sS -o /dev/null \
        -w "%{size_download}" "https://cachefly.cachefly.net/100mb.test" \
        > "$size_file" 2>/dev/null ) &
    local DL=$!
    sleep 1
    under=$(ping -c 12 -i 0.2 -W 2 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5}')
    local deadline=$(( $(date +%s) + 4 ))
    while kill -0 "$DL" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
    kill -TERM "$DL" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$DL" 2>/dev/null || true
    wait "$DL" 2>/dev/null || true

    local downloaded
    downloaded=$(cat "$size_file" 2>/dev/null || echo 0)
    rm -f "$size_file"
    echo "under load avg: ${under:-?} ms · downloaded ${downloaded} bytes"

    # If the download didn't reach at least 5 MB — the link wasn't loaded, nothing to measure
    if [ "${downloaded:-0}" -lt 5000000 ]; then
        RES_STATUS=skip
        RES_SUMMARY="download fail (${downloaded:-0} bytes) — load didn't start"
        finding 1 bufferbloat "Couldn't load the link to measure bufferbloat (Cachefly blocked? link down?)"
        return
    fi

    if [ -z "$base" ] || [ -z "$under" ]; then
        RES_STATUS=skip
        RES_SUMMARY="(ping gave no result)"
        return
    fi

    local delta
    delta=$(echo "scale=0; ($under - $base) / 1" | bc -l 2>/dev/null)

    # Tidy sign (avoid "+-31 ms")
    local sign
    if [ "${delta:0:1}" = "-" ]; then
        sign=""   # the minus is already in the value
    elif [ "${delta:-0}" -gt 0 ] 2>/dev/null; then
        sign="+"
    else
        sign=""
    fi

    summary_kv "Bufferbloat" "${sign}${delta} ms"

    RES_STATUS=ok
    RES_SUMMARY="${sign}${delta} ms"

    # Negative delta (under load below baseline) = network weirdness, not bufferbloat
    if [ "${delta:0:1}" = "-" ]; then
        RES_SUMMARY="${delta} ms (odd: ping dropped under load)"
        finding 1 bufferbloat "Under load ping is below baseline — unstable network, the baseline caught a random spike"
        return
    fi

    if have bc && (( $(echo "$delta > 100" | bc -l) )); then
        RES_STATUS=bad
        finding 3 bufferbloat "Bufferbloat +${delta} ms — disaster, Shorts will freeze constantly. Fixed by qdisc=cake/fq_codel"
    elif have bc && (( $(echo "$delta > 50" | bc -l) )); then
        RES_STATUS=bad
        finding 3 bufferbloat "Bufferbloat +${delta} ms — large. Enable qdisc cake"
    elif have bc && (( $(echo "$delta > 20" | bc -l) )); then
        RES_STATUS=warn
        finding 2 bufferbloat "Bufferbloat +${delta} ms — noticeable, borderline"
    fi
}

# 16. Sustained variance — throttling detection
check_variance() {
    local samples=()
    local fails=0
    for i in 1 2 3 4 5; do
        local spd spd_int
        spd=$(curl "${CURL_FLAGS[@]}" -sS -o /dev/null --max-time 5 \
            -w "%{speed_download}" "https://cachefly.cachefly.net/100mb.test" 2>/dev/null) || spd="0"
        spd_int=$(printf '%.0f' "${spd:-0}" 2>/dev/null || echo 0)
        if [ -z "$spd" ] || [ "${spd_int:-0}" -lt 10000 ]; then
            fails=$((fails+1))
            samples+=("0")
            echo "  $i: fail (${spd_int}B/s)"
        else
            local mbit
            mbit=$(( spd_int * 8 / 1000000 ))
            samples+=("$mbit")
            echo "  $i: ${mbit} Mbit/s"
        fi
    done

    if [ "$fails" -ge 5 ]; then
        # All failed — more likely a link/Cachefly-block issue than instability
        RES_STATUS=warn
        RES_SUMMARY="5/5 fail"
        finding 2 variance "All 5 Cachefly pulls failed — Cachefly is blocked by this ASN or the link is extremely unstable (check the CDN section — if only Cachefly fails, it's not a disaster)"
        summary_kv "Variance (5x)" "5 fails"
        return
    elif [ "$fails" -ge 3 ]; then
        RES_STATUS=bad
        RES_SUMMARY="$fails/5 fail"
        finding 3 variance "$fails/5 pulls failed — the link/route is extremely unstable"
        summary_kv "Variance (5x)" "$fails fails"
        return
    fi

    local min=999999 max=0 v
    for v in "${samples[@]}"; do
        [ "$v" = "0" ] && continue
        [ "$v" -lt "$min" ] && min=$v
        [ "$v" -gt "$max" ] && max=$v
    done
    local ratio
    ratio=$(echo "scale=1; $max / ($min > 0 ? $min : 1)" | bc -l)
    echo "min=${min} max=${max} ratio=${ratio}x"

    summary_kv "Variance (5x)" "${min}–${max} Mbit/s (${ratio}x)"

    RES_STATUS=ok
    RES_SUMMARY="${min}–${max} Mbit/s"
    if have bc && (( $(echo "$ratio > 3" | bc -l) )); then
        RES_STATUS=bad
        finding 3 variance "Spread x${ratio} — Google is throttling the ASN or PoP routing is unstable"
    elif have bc && (( $(echo "$ratio > 2" | bc -l) )); then
        RES_STATUS=warn
        finding 2 variance "Spread x${ratio} — unstable link"
    fi
}

# 17. TCP retransmissions
check_tcp_stats() {
    # Diagnostic dump (not used for counting — `nstat -r` resets the cache)
    have nstat && nstat -rsz 2>/dev/null \
        | grep -iE 'TcpRetrans|TcpExt.*Retrans|TcpAttemptFails|ListenDrops|TCPBacklogDrop|OutOfOrder' \
        | head -20

    # Read absolute counters directly from /proc/net/snmp.
    # Tcp line: columns 11=InSegs 12=OutSegs 13=RetransSegs (see RFC2012/MIB-II).
    local seg out_seg retrans pct=0
    if [ -r /proc/net/snmp ]; then
        local snmp_vals
        snmp_vals=$(awk '/^Tcp:/ {n++} n==2 {print; exit}' /proc/net/snmp)
        seg=$(echo     "$snmp_vals" | awk '{print $11}')
        out_seg=$(echo "$snmp_vals" | awk '{print $12}')
        retrans=$(echo "$snmp_vals" | awk '{print $13}')
    fi
    if [ -n "${out_seg:-}" ] && [ "${out_seg:-0}" -gt 0 ] && [ -n "${retrans:-}" ]; then
        pct=$(echo "scale=2; $retrans * 100 / $out_seg" | bc -l 2>/dev/null)
    fi
    echo "InSegs=${seg:-?} OutSegs=${out_seg:-?} Retrans=${retrans:-?} (${pct}%)"

    if [ -z "${seg:-}" ]; then
        RES_STATUS=skip
        RES_SUMMARY="(couldn't read /proc/net/snmp)"
        return
    fi

    summary_kv "TCP retrans" "${pct}% ($retrans/$out_seg)"

    RES_STATUS=ok
    RES_SUMMARY="${pct}% retrans"
    if have bc && (( $(echo "$pct > 5" | bc -l 2>/dev/null || echo 0) )); then
        RES_STATUS=bad
        finding 3 retrans "TCP retrans ${pct}% — very high, clear loss on the route"
    elif have bc && (( $(echo "$pct > 2" | bc -l 2>/dev/null || echo 0) )); then
        RES_STATUS=warn
        finding 2 retrans "TCP retrans ${pct}% — noticeable loss on the path"
    fi
}

# 18. IPv6 readiness
check_ipv6() {
    local v6_route v6_ext v6_ping
    v6_route=$(ip -6 route show default 2>/dev/null | head -1)
    v6_ext=$(curl --connect-timeout 5 -6 -sS --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
    if [ -z "$v6_ext" ]; then
        RES_STATUS=warn
        RES_SUMMARY="no IPv6"
        finding 1 ipv6 "IPv6 isn't configured. Google serves a faster PoP over v6 → the client lands on slow v4"
        summary_kv "IPv6" "none"
        return
    fi
    v6_ping=$(ping -6 -c 4 -W 2 -q ipv6.google.com 2>/dev/null | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5}')
    echo "v6 external: $v6_ext"
    echo "v6 ping ipv6.google.com: ${v6_ping:-fail}ms"
    summary_kv "IPv6" "$v6_ext · ${v6_ping:-?}ms"
    RES_STATUS=ok
    RES_SUMMARY="$v6_ext · ${v6_ping:-?}ms"
}

# 19. Reachability of popular services (TTFB + HTTP code)
check_services() {
    local SERVICES=(
        "YouTube|https://www.youtube.com/"
        "Google|https://www.google.com/"
        "Netflix|https://www.netflix.com/"
        "Twitch|https://www.twitch.tv/"
        "TikTok|https://www.tiktok.com/"
        "Instagram|https://www.instagram.com/"
        "Twitter/X|https://x.com/"
        "Telegram-Web|https://web.telegram.org/"
        "Telegram-API|https://api.telegram.org/"
        "Discord|https://discord.com/api/v9/gateway"
        "WhatsApp|https://web.whatsapp.com/"
        "Signal|https://signal.org/"
        "ChatGPT|https://chat.openai.com/"
        "Claude|https://claude.ai/"
        "Gemini|https://gemini.google.com/"
        "Spotify|https://open.spotify.com/"
        "Steam|https://store.steampowered.com/"
        "GitHub|https://github.com/"
        "Reddit|https://www.reddit.com/"
    )

    local fails=0 blocked=0 slow=0 ok_count=0 total=0
    local failed_list="" blocked_list="" slow_list=""

    for entry in "${SERVICES[@]}"; do
        local name=${entry%%|*}
        local url=${entry##*|}
        total=$((total+1))
        local out code ttfb
        out=$(curl "${CURL_FLAGS[@]}" -sS -L -o /dev/null --max-time 8 \
            -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
            -w "%{http_code}|%{time_starttransfer}" "$url" 2>/dev/null) || out="000|0"
        code=${out%%|*}
        ttfb=$(echo "${out##*|}" | awk '{printf "%.0f", $1 * 1000}')

        case "$code" in
            200|301|302|307|308|401)
                ok_count=$((ok_count+1))
                if [ "${ttfb:-0}" -gt 2000 ]; then
                    slow=$((slow+1))
                    slow_list="$slow_list $name"
                    printf "  %-15s %s %3sms ${Y}slow${NC}\n" "$name" "$code" "$ttfb"
                else
                    printf "  %-15s %s %3sms\n" "$name" "$code" "$ttfb"
                fi
                ;;
            403|429|451)
                blocked=$((blocked+1))
                blocked_list="$blocked_list $name($code)"
                printf "  %-15s ${R}%s blocked${NC}\n" "$name" "$code"
                ;;
            000)
                fails=$((fails+1))
                failed_list="$failed_list $name"
                printf "  %-15s ${R}unreachable${NC}\n" "$name"
                ;;
            *)
                printf "  %-15s ${Y}%s${NC} %3sms\n" "$name" "$code" "$ttfb"
                ;;
        esac
    done

    summary_kv "Services" "$ok_count/$total ok · $blocked blocked · $fails fail"

    if [ "$fails" -ge 3 ]; then
        RES_STATUS=bad
        RES_SUMMARY="$ok_count/$total · ${fails} unreachable"
        finding 3 services "Unreachable:$failed_list — serious network problem or DNS"
    elif [ "$blocked" -ge 3 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$ok_count/$total · ${blocked} blocked"
        finding 2 services "Services are blocking the IP:$blocked_list — IP on datacenter blacklists"
    elif [ "$fails" -gt 0 ] || [ "$blocked" -gt 0 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$ok_count/$total · $((fails+blocked)) issues"
        [ -n "$failed_list" ]  && finding 2 services "Unreachable:$failed_list"
        [ -n "$blocked_list" ] && finding 2 services "Blocked the IP:$blocked_list"
    elif [ "$slow" -ge 3 ]; then
        RES_STATUS=warn
        RES_SUMMARY="$ok_count/$total · ${slow} slow"
        finding 1 services "Slow TTFB:$slow_list (>2s) — possibly bad peering or CDN route"
    else
        RES_STATUS=ok
        RES_SUMMARY="$ok_count/$total reachable"
    fi
}

# 20. Speed across multiple CDNs (ASN throttling detection)
check_cdn_multi() {
    local CDNS=(
        "Cloudflare|https://speed.cloudflare.com/__down?bytes=20000000"
        "Cachefly|https://cachefly.cachefly.net/10mb.test"
        "Hetzner|https://speed.hetzner.de/100MB.bin"
        "OVH|https://proof.ovh.net/files/100Mb.dat"
        "Linode-LON|https://speedtest.london.linode.com/100MB-london.bin"
    )

    local fastest=0 fastest_name="" slowest=999999999 slowest_name=""
    local total=0 ok=0 sum_mbit=0
    local results=()
    for entry in "${CDNS[@]}"; do
        local name=${entry%%|*}
        local url=${entry##*|}
        total=$((total+1))
        local spd code
        local out
        out=$(curl "${CURL_FLAGS[@]}" -sS -o /dev/null --max-time 8 \
            -w "%{speed_download}|%{http_code}" "$url" 2>/dev/null) || out="0|000"
        spd=${out%%|*}
        code=${out##*|}
        # curl returns "0.000" on timeout/error — normalize to an integer
        local spd_int
        spd_int=$(printf '%.0f' "${spd:-0}" 2>/dev/null || echo 0)
        if [ "${spd_int:-0}" -lt 10000 ] || [ "$code" != "200" ]; then
            printf "  %-12s ${R}fail${NC} (http=$code, ${spd_int}B/s)\n" "$name"
            results+=("$name|fail")
            continue
        fi
        ok=$((ok+1))
        local mbit
        mbit=$(( spd_int * 8 / 1000000 ))
        sum_mbit=$((sum_mbit + mbit))
        printf "  %-12s ${G}%s Mbit/s${NC}\n" "$name" "$mbit"
        results+=("$name|$mbit")
        if [ "$mbit" -gt "$fastest" ]; then fastest=$mbit; fastest_name=$name; fi
        if [ "$mbit" -lt "$slowest" ]; then slowest=$mbit; slowest_name=$name; fi
    done

    if [ "$ok" -eq 0 ]; then
        RES_STATUS=bad
        RES_SUMMARY="all CDNs fail"
        finding 3 cdn "No CDN responds — serious block/route loss"
        return
    fi

    local avg=$((sum_mbit / ok))
    summary_kv "CDN speed" "avg ${avg} Mbit/s · max ${fastest} (${fastest_name})"

    RES_STATUS=ok
    RES_SUMMARY="avg ${avg} Mbit/s · range ${slowest}–${fastest}"
    if [ "$avg" -lt 50 ]; then
        RES_STATUS=bad
        finding 3 cdn "Average CDN speed ${avg} Mbit/s — link/peering is broken"
    elif [ "$avg" -lt 200 ]; then
        RES_STATUS=warn
        finding 2 cdn "CDN avg ${avg} Mbit/s — not fast for a VPN node"
    fi

    # Huge spread (some CDNs fly, others sink) = different routing
    if [ "$fastest" -gt 0 ] && [ "$slowest" -gt 0 ]; then
        local ratio=$((fastest / slowest))
        if [ "$ratio" -ge 5 ]; then
            finding 2 cdn "Spread x${ratio} between CDNs ($slowest_name=$slowest, $fastest_name=$fastest Mbit/s) — peering differs, some ASNs are being throttled"
        fi
    fi
}

# 21. IP reputation and external visibility
check_ip_rep() {
    local trace cf_ip cf_loc cf_colo cf_warp cf_h
    trace=$(curl --connect-timeout 5 -sS --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    if [ -z "$trace" ]; then
        RES_STATUS=warn
        RES_SUMMARY="Cloudflare trace unavailable"
        finding 1 reputation "Couldn't fetch /cdn-cgi/trace — Cloudflare not responding"
        return
    fi
    cf_ip=$(echo "$trace"   | awk -F= '/^ip=/   {print $2}')
    cf_loc=$(echo "$trace"  | awk -F= '/^loc=/  {print $2}')
    cf_colo=$(echo "$trace" | awk -F= '/^colo=/ {print $2}')
    cf_warp=$(echo "$trace" | awk -F= '/^warp=/ {print $2}')
    cf_h=$(echo "$trace"    | awk -F= '/^h=/    {print $2}')

    echo "Cloudflare trace: ip=$cf_ip loc=$cf_loc colo=$cf_colo warp=$cf_warp h=$cf_h"

    # ipapi.co — they have a privacy.hosting / asn.type field
    local ipinfo=""
    if have jq; then
        ipinfo=$(curl --connect-timeout 5 -sS --max-time 5 "https://ipapi.co/$cf_ip/json/" 2>/dev/null)
    fi
    local org="" country="" city=""
    if [ -n "$ipinfo" ] && have jq; then
        org=$(echo "$ipinfo"     | jq -r '.org // ""')
        country=$(echo "$ipinfo" | jq -r '.country_name // ""')
        city=$(echo "$ipinfo"    | jq -r '.city // ""')
        echo "ipapi: org=$org country=$country city=$city"
    fi

    # Google CAPTCHA test: if the IP is flagged as abusive — Google returns 429 or /sorry/
    local g_test
    g_test=$(curl "${CURL_FLAGS[@]}" -sS -L -o /dev/null --max-time 5 \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        -w "%{http_code}|%{url_effective}" "https://www.google.com/search?q=test" 2>/dev/null)
    local g_code g_url
    g_code=${g_test%%|*}
    g_url=${g_test##*|}
    echo "Google search test: code=$g_code url=$g_url"

    local captcha_hit=0
    if echo "$g_url" | grep -qE 'sorry/|/sorry|captcha'; then
        captcha_hit=1
    fi

    # Reverse DNS — if the PTR contains "hosting"/"vps"/"server"/"datacenter" — almost certainly a datacenter
    # First try the system DNS, on failure fall back to 1.1.1.1 (the node's default DNS may be broken)
    local ptr=""
    if have dig && [ -n "$cf_ip" ]; then
        ptr=$(dig +short +time=2 +tries=1 -x "$cf_ip" 2>/dev/null \
            | grep -vE '^;;|^$' | head -1)
        if [ -z "$ptr" ]; then
            ptr=$(dig @1.1.1.1 +short +time=2 +tries=1 -x "$cf_ip" 2>/dev/null \
                | grep -vE '^;;|^$' | head -1)
        fi
        echo "PTR: ${ptr:-none}"
    fi

    summary_kv "Cloudflare colo" "$cf_colo / $cf_loc"
    summary_kv "Reverse DNS" "${ptr:-none}"
    [ -z "$ptr" ] && finding 1 reputation "Reverse DNS doesn't resolve — DNS on the node is broken or the IP has no PTR"

    RES_STATUS=ok
    RES_SUMMARY="cf=$cf_colo/$cf_loc"

    if [ "$captcha_hit" = "1" ]; then
        RES_STATUS=bad
        RES_SUMMARY="$RES_SUMMARY · Google shows CAPTCHA"
        finding 3 reputation "Google redirects to /sorry — IP is on abuse lists. Users will see a captcha"
    fi

    # "Is this a datacenter?" heuristic
    local dc=0
    if echo "$org $ptr" | grep -qiE 'hosting|datacenter|data.center|vps|server|cloud|colo|dedicated'; then
        dc=1
    fi
    if [ "$dc" = "1" ]; then
        finding 1 reputation "IP looks like a datacenter (org/ptr contains hosting/vps) — Netflix/Disney+/banking may block it"
    fi
}

# 22. Xray / Remnanode
check_xray() {
    if ! have docker; then RES_STATUS=skip; RES_SUMMARY="docker not found"; return; fi
    local cont
    cont=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'remnanode|xray|x-ui|sing-box' | head -1)
    if [ -z "$cont" ]; then RES_STATUS=skip; RES_SUMMARY="container not found"; return; fi

    local ver stats restarts
    ver=$(docker exec "$cont" /usr/local/bin/xray -version 2>/dev/null | head -1 | awk '{print $2}')
    stats=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}' "$cont" 2>/dev/null)
    restarts=$(docker inspect -f '{{.RestartCount}}' "$cont" 2>/dev/null)
    echo "container=$cont version=$ver"
    echo "stats=$stats"
    echo "restarts=$restarts"
    docker logs --tail 500 "$cont" 2>&1 | grep -iE 'error|fail|timeout|refused' | tail -5 || echo "(no errors in logs)"

    summary_kv "Xray" "$cont · v$ver · restarts $restarts"

    RES_STATUS=ok
    RES_SUMMARY="v${ver:-?} · $(echo "$stats" | cut -d'|' -f1) cpu"
    if [ "${restarts:-0}" -gt 5 ]; then
        RES_STATUS=warn
        finding 2 xray "Xray container restarted $restarts times — unstable"
    fi
}

# ════════════════════════════════════════════════════════════════════
# FIXES — applying corrections
# ════════════════════════════════════════════════════════════════════

run_or_dry() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} $*"
        return 0
    fi
    eval "$@"
}

# Universal "rollback" — collect the list of changes into a journal file
FIX_LOG="/etc/node-diagnostic.applied"
record_fix() {
    [ "$DRY_RUN" = "1" ] && return
    [ -d /etc ] && {
        printf '%s | %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$FIX_LOG" 2>/dev/null || true
    }
}

# Back up current settings before the fix — into /var/backups/node-diagnostic/
BACKUP_DIR="/var/backups/node-diagnostic"
BACKUP_DONE=0
backup_settings() {
    [ "$DRY_RUN" = "1" ] && return
    [ "$BACKUP_DONE" = "1" ] && return
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    sysctl -a 2>/dev/null > "$BACKUP_DIR/sysctl-$ts.txt"
    have iptables-save && iptables-save > "$BACKUP_DIR/iptables-$ts.rules" 2>/dev/null
    have ip6tables-save && ip6tables-save > "$BACKUP_DIR/ip6tables-$ts.rules" 2>/dev/null
    echo -e "    ${DIM}backup: $BACKUP_DIR/*-$ts.* — for rollback${NC}"
    BACKUP_DONE=1
    BACKUP_TS=$ts
    record_fix "backup snapshot $ts"
}

fix_sysctl() {
    backup_settings
    local target=/etc/sysctl.d/99-vpn-tuning.conf
    echo "  → writing $target"
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} (would create a file with BBR/cake/buffers/conntrack)"
    else
        cat > "$target" <<'SYSCTL_EOF'
# Generated by node-diagnostic.sh
# Congestion + qdisc
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
# PMTU & idle
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
# Buffers
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# Queues
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
# Conntrack
net.netfilter.nf_conntrack_max = 524288
SYSCTL_EOF
        sysctl --system >/dev/null 2>&1 && \
            echo -e "    ${G}✓${NC} sysctl --system applied" || \
            echo -e "    ${R}✗${NC} sysctl --system returned an error"
        record_fix "sysctl tuning ($target)"
    fi
}

fix_mss_clamp() {
    backup_settings
    local rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu)
    echo "  → adding iptables MSS clamp to FORWARD/OUTPUT"
    for chain in FORWARD OUTPUT; do
        if iptables -t mangle -C "$chain" "${rule_args[@]}" 2>/dev/null; then
            echo -e "    ${DIM}rule already present in $chain${NC}"
        else
            run_or_dry "iptables -t mangle -A $chain ${rule_args[*]}" \
                && echo -e "    ${G}✓${NC} $chain"
        fi
    done
    # persist
    if [ "$DRY_RUN" = "0" ]; then
        if have netfilter-persistent; then
            netfilter-persistent save >/dev/null 2>&1 && \
                echo -e "    ${G}✓${NC} netfilter-persistent save"
        elif [ -d /etc/iptables ] && have iptables-save; then
            iptables-save > /etc/iptables/rules.v4 && \
                echo -e "    ${G}✓${NC} saved to /etc/iptables/rules.v4"
        else
            echo -e "    ${Y}⚠${NC} no netfilter-persistent — rules will NOT survive a reboot. Install: apt install iptables-persistent"
        fi
        record_fix "iptables MSS clamp (FORWARD+OUTPUT)"
    fi
}

fix_rps() {
    local iface=$1
    [ -z "$iface" ] && { echo "  ${R}✗${NC} interface not determined"; return 1; }
    local n=$(nproc)
    # mask: all CPUs
    local mask
    mask=$(printf '%x' $(( (1 << n) - 1 )))
    echo "  → RPS mask=$mask on $iface"
    local applied=0
    for q in /sys/class/net/"$iface"/queues/rx-*; do
        [ -d "$q" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            echo -e "    ${DIM}[dry-run]${NC} echo $mask > $q/rps_cpus"
        else
            echo "$mask" > "$q/rps_cpus" 2>/dev/null && applied=$((applied+1))
        fi
    done
    [ "$DRY_RUN" = "0" ] && echo -e "    ${G}✓${NC} applied to $applied queues"

    # systemd unit for persistence
    if [ "$DRY_RUN" = "0" ]; then
        cat > /etc/systemd/system/vpn-rps.service <<UNIT
[Unit]
Description=Apply RPS mask for $iface
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for q in /sys/class/net/$iface/queues/rx-*; do echo $mask > \$q/rps_cpus; done'

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable --now vpn-rps.service >/dev/null 2>&1 && \
            echo -e "    ${G}✓${NC} systemd unit vpn-rps.service created and enabled"
        record_fix "RPS mask=$mask on $iface (vpn-rps.service)"
    fi
}

fix_ring_buffers() {
    local iface=$1
    have ethtool || { echo "  ${R}✗${NC} ethtool not installed"; return; }
    local max_rx max_tx cur_rx cur_tx
    max_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set maximums/,/Current/' | awk '/RX:/ {print $2; exit}')
    max_tx=$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set maximums/,/Current/' | awk '/TX:/ {print $2; exit}')
    cur_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/Current hardware settings/,0' | awk '/RX:/ {print $2; exit}')
    cur_tx=$(ethtool -g "$iface" 2>/dev/null | awk '/Current hardware settings/,0' | awk '/TX:/ {print $2; exit}')
    echo "  → ring buffers: max RX=$max_rx TX=$max_tx (current $cur_rx/$cur_tx)"
    if [ -z "$max_rx" ] || [ "$max_rx" = "0" ]; then
        echo -e "    ${Y}⚠${NC} NIC doesn't support changing ring buffers (often virtio_net)"
        return
    fi
    if [ "$cur_rx" = "$max_rx" ] && [ "$cur_tx" = "$max_tx" ]; then
        echo -e "    ${DIM}already at maximum${NC}"
        return
    fi
    run_or_dry "ethtool -G $iface rx $max_rx tx $max_tx" && \
        echo -e "    ${G}✓${NC} applied"
    if [ "$DRY_RUN" = "0" ]; then
        cat > /etc/systemd/system/vpn-ring.service <<UNIT
[Unit]
Description=Apply NIC ring buffers for $iface
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ethtool -G $iface rx $max_rx tx $max_tx

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable --now vpn-ring.service >/dev/null 2>&1 && \
            echo -e "    ${G}✓${NC} systemd unit vpn-ring.service created and enabled"
        record_fix "ring buffers RX=$max_rx TX=$max_tx on $iface (vpn-ring.service)"
    fi
}

fix_swappiness() {
    echo "  → vm.swappiness=10"
    if [ "$DRY_RUN" = "0" ]; then
        echo "vm.swappiness = 10" > /etc/sysctl.d/98-swappiness.conf
        sysctl -p /etc/sysctl.d/98-swappiness.conf >/dev/null 2>&1 && \
            echo -e "    ${G}✓${NC} applied"
        record_fix "vm.swappiness=10"
    fi
}

# Select and apply fixes
prompt_and_apply_fixes() {
    [ "$APPLY_MODE" = "none" ] && return
    if [ "$EUID" -ne 0 ]; then
        echo
        echo -e "${DIM}  Applying fixes requires root. Re-run under sudo.${NC}"
        return
    fi

    # Determine which fixes are relevant based on FINDINGS
    declare -a FIXES=()    # format: "key|short description|what it fixes"
    local f_sysctl=0 f_mss=0 f_rps=0 f_ring=0

    while IFS='|' read -r sev tag msg; do
        case "$tag" in
            tcp)         f_sysctl=1 ;;
            conntrack)   f_sysctl=1 ;;
            bufferbloat) f_sysctl=1 ;;
            pmtu)        f_mss=1; f_sysctl=1 ;;
            cpu)         echo "$msg" | grep -qi softirq && f_rps=1 ;;
            nic)         echo "$msg" | grep -qi drop && f_ring=1 ;;
        esac
    done < "$FINDINGS_FILE"

    # format: key|label|impact-stars|description
    [ "$f_sysctl" = "1" ] && FIXES+=("sysctl|sysctl tuning|★★★|BBR + cake + buffers + tcp_mtu_probing + conntrack")
    [ "$f_mss"    = "1" ] && FIXES+=("mss|MSS clamp|★★★|iptables TCPMSS — large chunks don't hit Frag-needed")
    [ "$f_rps"    = "1" ] && FIXES+=("rps|RPS on $DEFAULT_IFACE|★★|spread softirq across all CPUs (interrupt balancing)")
    [ "$f_ring"   = "1" ] && FIXES+=("ring|NIC ring buffers|★★|raise RX/TX to maximum for fewer drops")

    if [ ${#FIXES[@]} -eq 0 ]; then
        echo
        echo -e "${DIM}  ─────────────────────────────────  FIXES  ─────────────────────────────────${NC}"
        echo
        echo -e "  ${G}${BOLD}✓ No relevant fixes${NC} ${DIM}— the node is already optimally configured${NC}"
        echo
        return
    fi

    echo
    echo -e "${DIM}  ─────────────────────────────────  FIXES  ─────────────────────────────────${NC}"
    echo
    echo -e "  ${BOLD}${#FIXES[@]} ${NC}${DIM}recommended fixes available${NC} ${DIM}(★ = expected impact)${NC}"
    echo
    for i in "${!FIXES[@]}"; do
        local entry=${FIXES[$i]}
        local label=$(echo  "$entry" | cut -d'|' -f2)
        local stars=$(echo  "$entry" | cut -d'|' -f3)
        local desc=$(echo   "$entry" | cut -d'|' -f4)
        local clen pad
        clen=$(printf '%s' "$label" | wc -m)
        pad=$(( 22 - clen ))
        [ "$pad" -lt 0 ] && pad=0
        printf "    ${C}${BOLD}[%d]${NC} ${BOLD}%s${NC}%*s ${Y}%-3s${NC} ${DIM}%s${NC}\n" \
            $((i+1)) "$label" "$pad" "" "$stars" "$desc"
    done
    echo
    echo -e "    ${DIM}Before applying, a settings backup will be created in $BACKUP_DIR${NC}"
    echo

    local answer="all"
    if [ "$APPLY_MODE" = "prompt" ]; then
        if [ ! -t 0 ]; then
            echo -e "${DIM}  (not a TTY — run with -a for auto-apply)${NC}"
            echo
            return
        fi
        printf "  ${BOLD}Apply?${NC} ${DIM}[comma-separated numbers / all / none]${NC} ${BOLD}[none]${NC}: "
        read -r answer
        answer=${answer,,}
        [ -z "$answer" ] && answer="none"
    fi

    if [ "$answer" = "none" ]; then
        echo
        echo -e "  ${DIM}Skipped — nothing applied${NC}"
        echo
        return
    fi

    declare -a TO_APPLY=()
    if [ "$answer" = "all" ]; then
        TO_APPLY=("${FIXES[@]}")
    else
        IFS=',' read -ra nums <<< "$answer"
        for n in "${nums[@]}"; do
            n=$(echo "$n" | xargs)
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            local idx=$((n - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#FIXES[@]}" ]; then
                TO_APPLY+=("${FIXES[$idx]}")
            fi
        done
    fi
    if [ ${#TO_APPLY[@]} -eq 0 ]; then
        echo
        echo -e "  ${Y}nothing selected${NC}"
        echo
        return
    fi

    echo
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "  ${Y}${BOLD}▶ DRY-RUN${NC} ${DIM}— showing commands, not applying${NC}"
        echo
    fi
    local applied_n=0
    for entry in "${TO_APPLY[@]}"; do
        local key label
        key=$(echo   "$entry" | cut -d'|' -f1)
        label=$(echo "$entry" | cut -d'|' -f2)
        applied_n=$((applied_n + 1))
        echo -e "  ${C}${BOLD}▶${NC} ${BOLD}[$applied_n/${#TO_APPLY[@]}]${NC} ${BOLD}$label${NC}"
        case "$key" in
            sysctl) fix_sysctl ;;
            mss)    fix_mss_clamp ;;
            rps)    fix_rps "$DEFAULT_IFACE" ;;
            ring)   fix_ring_buffers "$DEFAULT_IFACE" ;;
        esac
        echo
    done

    echo -e "  ${G}${BOLD}┃${NC}  ${G}${BOLD}✓ Done${NC} ${DIM}—${NC} applied ${BOLD}${applied_n}${NC} ${DIM}fix(es)${NC}"
    echo -e "  ${G}${BOLD}┃${NC}  ${DIM}Re-check the effect:${NC} ${BOLD}sudo bash $0 -q${NC}"
    echo
}

# ════════════════════════════════════════════════════════════════════
# MAIN PART
# ════════════════════════════════════════════════════════════════════

# Header
echo
echo -e "  ${C}${BOLD}NODE DIAGNOSTIC${NC}  ${DIM}v${SCRIPT_VERSION}${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
echo -e "  ${DIM}$(date -u +'%Y-%m-%d %H:%M UTC') · $(hostname)${NC}"
echo

echo -ne "  ${DIM}Installing missing packages…${NC}"
ensure_deps >>"$LOG" 2>&1
echo -e "\r${CLR_LINE}  ${DIM}Log: $LOG${NC}"
echo

# Global values for fixes (needed outside the subshells)
DEFAULT_IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
export DEFAULT_IFACE

# Register the checklist
CHECKS=(
    "Identification:check_identify"
    "CPU and load:check_cpu"
    "Memory:check_mem"
    "NIC / interface:check_nic"
    "Tunnels:check_tunnel"
    "TCP congestion:check_tcp_cc"
    "TCP tuning:check_tcp_tuning"
    "Conntrack:check_conntrack"
    "DNS resolution:check_dns"
    "PMTU:check_pmtu"
    "Loss to Google:check_loss"
    "Route (mtr):check_mtr"
    "QUIC / HTTP-3:check_quic"
    "Speed: 1-flow:check_speed_single"
    "Speed: 4-flow:check_speed_4flow"
    "CDN multi-test:check_cdn_multi"
    "Services reach:check_services"
    "IP reputation:check_ip_rep"
    "Bufferbloat:check_bufferbloat"
    "Sustained variance:check_variance"
    "TCP retransmits:check_tcp_stats"
    "IPv6:check_ipv6"
    "Xray:check_xray"
)

# Long tests — skipped in --quick mode (~1 min instead of ~5)
SLOW_CHECKS="check_mtr check_speed_4flow check_cdn_multi check_services check_bufferbloat check_variance"
# Network tests — skipped in --no-net (for offline audit of local configuration)
NET_CHECKS="check_loss check_mtr check_quic check_speed_single check_speed_4flow check_cdn_multi check_services check_ip_rep check_bufferbloat check_variance check_ipv6 check_dns check_pmtu"

# Filter the checklist by flags
EFFECTIVE_CHECKS=()
SKIPPED_CHECKS=()
for entry in "${CHECKS[@]}"; do
    fn=${entry##*:}
    skip_reason=""
    [ "$QUICK"  = "1" ] && [[ " $SLOW_CHECKS " == *" $fn "* ]] && skip_reason="--quick"
    [ "$NO_NET" = "1" ] && [[ " $NET_CHECKS "  == *" $fn "* ]] && skip_reason="--no-net"
    if [ -n "$skip_reason" ]; then
        SKIPPED_CHECKS+=("$entry|$skip_reason")
    else
        EFFECTIVE_CHECKS+=("$entry")
    fi
done
CHECK_TOTAL=${#EFFECTIVE_CHECKS[@]}

# Run header
mode_label=""
[ "$QUICK"  = "1" ] && mode_label="$mode_label quick"
[ "$NO_NET" = "1" ] && mode_label="$mode_label no-net"
[ "$DRY_RUN" = "1" ] && mode_label="$mode_label dry-run"
if [ -n "$mode_label" ]; then
    echo -e "${DIM}Mode:$mode_label · $CHECK_TOTAL checks (skipped ${#SKIPPED_CHECKS[@]})${NC}"
else
    echo -e "${DIM}$CHECK_TOTAL checks${NC}"
fi
echo

DIAG_START=$(date +%s)
for entry in "${EFFECTIVE_CHECKS[@]}"; do
    # name may contain ":" (e.g. "Speed: 1-flow"), so use % not %%
    name=${entry%:*}
    fn=${entry##*:}
    run_check "$name" "$fn"
done
DIAG_DURATION=$(( $(date +%s) - DIAG_START ))

# Show the skipped ones in a single block at the end
if [ ${#SKIPPED_CHECKS[@]} -gt 0 ]; then
    echo
    echo -e "  ${DIM}skipped ${#SKIPPED_CHECKS[@]} checks:${NC}"
    for skip in "${SKIPPED_CHECKS[@]}"; do
        # format: "name:fn|reason" — name may contain ":"
        skip_entry=${skip%|*}
        skip_reason=${skip##*|}
        skip_name=${skip_entry%:*}
        printf "  ${DIM}  · %-26s %s${NC}\n" "$skip_name" "$skip_reason"
    done
fi
echo
echo -e "  ${DIM}run took ${DIAG_DURATION}s${NC}"

# ════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════

# Categorize summary keys (map name → section)
classify_kv() {
    case "$1" in
        Host|IP|"Geo (DBs)"|"Geo by latency"|ASN|Kernel|CPU|RAM|NIC|Tunnels|Xray)  echo sys ;;
        "TCP CC"|"TCP tuning"|Conntrack|DNS|PMTU|"Loss to Google"|"Route"|QUIC/HTTP3|IPv6) echo net ;;
        "Speed (1-flow)"|"Speed (4-flow)"|"CDN speed"|Bufferbloat|"Variance (5x)"|"TCP retrans") echo perf ;;
        "Services"|"Cloudflare colo"|"Reverse DNS") echo svc ;;
        *) echo other ;;
    esac
}

# Compute the score: bad → -3, warn → -1
ok_count=0; warn_count=0; bad_count=0; info_count=0; penalty=0
while IFS='|' read -r sev tag msg; do
    case "$sev" in
        3) bad_count=$((bad_count+1));   penalty=$((penalty + 3)) ;;
        2) warn_count=$((warn_count+1)); penalty=$((penalty + 1)) ;;
        1) info_count=$((info_count+1)) ;;
    esac
done < "$FINDINGS_FILE"
score=$(( 100 - penalty * 5 ))
[ "$score" -lt 0 ] && score=0

# Render helpers
print_section_header() {
    echo -e "  ${C}${BOLD}▌${NC} ${BOLD}$1${NC}"
}

print_kv_aligned() {
    local k="$1" v="$2"
    local clen pad
    clen=$(printf '%s' "$k" | wc -m)
    pad=$(( 18 - clen ))
    [ "$pad" -lt 0 ] && pad=0
    printf "    ${DIM}%s%*s${NC}  %s\n" "$k" "$pad" "" "$v"
}

# Score gauge: 20-segment bar colored by range
print_score_gauge() {
    local s=$1
    local filled=$(( s * 20 / 100 ))
    [ "$filled" -gt 20 ] && filled=20
    local empty=$(( 20 - filled ))
    local color
    if   [ "$s" -ge 80 ]; then color=$G
    elif [ "$s" -ge 50 ]; then color=$Y
    else                       color=$R
    fi
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty;  i++)); do bar="${bar}░"; done
    printf "  %sScore%s  ${color}%s${NC}  ${BOLD}%3d${NC}${DIM}/100${NC}" \
        "$BOLD" "$NC" "$bar" "$s"
}

# Section header
echo
echo -e "${DIM}  ────────────────────────────────  SUMMARY  ────────────────────────────────${NC}"
echo

# Group the summary by category
section_started=""
print_category() {
    local cat=$1 title=$2
    local has_keys=0
    while IFS='|' read -r k v; do
        if [ "$(classify_kv "$k")" = "$cat" ]; then
            if [ "$has_keys" = "0" ]; then
                [ -n "$section_started" ] && echo
                print_section_header "$title"
                has_keys=1
                section_started=1
            fi
            print_kv_aligned "$k" "$v"
        fi
    done < "$SUMMARY_FILE"
}
print_category sys  "System"
print_category net  "Network"
print_category perf "Performance"
print_category svc  "Services and reputation"

# Score gauge + verdict
echo
echo
print_score_gauge "$score"
echo
echo

# Verdict
verdict_icon=""; verdict_color=""; verdict_text=""; verdict_sub=""
if [ "$bad_count" = "0" ] && [ "$warn_count" = "0" ]; then
    verdict_icon="✓"; verdict_color=$G
    verdict_text="node is in good shape"
    verdict_sub="video and services should work without issues"
elif [ "$bad_count" = "0" ]; then
    verdict_icon="⚠"; verdict_color=$Y
    verdict_text="working, with caveats"
    verdict_sub="$warn_count warnings · it'll run, but not perfectly"
elif [ "$bad_count" -le 1 ]; then
    verdict_icon="⚠"; verdict_color=$Y
    verdict_text="there are problems"
    verdict_sub="$bad_count critical + $warn_count warnings"
else
    verdict_icon="✗"; verdict_color=$R
    verdict_text="unfit for video"
    verdict_sub="$bad_count critical + $warn_count warnings"
fi
echo -e "  ${verdict_color}${BOLD}${verdict_icon}  ${verdict_text}${NC}"
echo -e "     ${DIM}${verdict_sub}${NC}"
echo

# If the root cause is ASN peering, highlight it separately
if grep -q -E '^3\|(loss|route)\|' "$FINDINGS_FILE"; then
    echo -e "  ${R}${BOLD}┃${NC}  ${R}${BOLD}ROOT CAUSE${NC} ${DIM}—${NC} broken provider peering"
    echo -e "  ${R}${BOLD}┃${NC}  ${DIM}loss on the route to Google. sysctl does NOT help here.${NC}"
    echo -e "  ${R}${BOLD}┃${NC}  ${DIM}the fix — switch hosting to a different ASN.${NC}"
    echo
fi

# Findings, grouped by severity
if [ -s "$FINDINGS_FILE" ]; then
    print_findings_group() {
        local sev=$1 title=$2 color=$3 icon=$4
        local count
        count=$(awk -F'|' -v s="$sev" '$1 == s' "$FINDINGS_FILE" | wc -l)
        [ "$count" -eq 0 ] && return
        echo -e "  ${color}${BOLD}▌${NC} ${BOLD}$title${NC} ${DIM}($count)${NC}"
        awk -F'|' -v s="$sev" '$1 == s {print $2 "|" $3}' "$FINDINGS_FILE" | while IFS='|' read -r tag msg; do
            local pad_tag
            pad_tag=$(printf '%-12s' "[$tag]")
            echo -e "    ${color}${icon}${NC} ${DIM}${pad_tag}${NC} ${msg}"
        done
        echo
    }
    print_findings_group 3 "Critical"     "$R" "✗"
    print_findings_group 2 "Warnings"      "$Y" "⚠"
    print_findings_group 1 "Info"         "$B" "·"
fi

prompt_and_apply_fixes

# ════════════════════════════════════════════════════════════════════
# SAVING THE SUMMARY TO A SEPARATE FILE
# ════════════════════════════════════════════════════════════════════
SUMMARY_TXT="/tmp/node-diagnostic-summary-$(date +%Y%m%d-%H%M%S).txt"
{
    echo "Node Diagnostic v$SCRIPT_VERSION — $(date -u +'%Y-%m-%d %H:%M UTC')"
    echo "Hostname: $(hostname)"
    echo "Run duration: ${DIAG_DURATION}s · ${CHECK_TOTAL} checks"
    echo
    echo "═══ Summary table ═══"
    while IFS='|' read -r k v; do
        clen=$(printf '%s' "$k" | wc -m)
        pad=$(( 22 - clen ))
        [ "$pad" -lt 0 ] && pad=0
        printf "  %s%*s %s\n" "$k" "$pad" "" "$v"
    done < "$SUMMARY_FILE"
    echo
    echo "═══ Issues found ═══"
    if [ ! -s "$FINDINGS_FILE" ]; then
        echo "  (none)"
    else
        sort -t'|' -k1 -rn "$FINDINGS_FILE" | while IFS='|' read -r sev tag msg; do
            case "$sev" in
                3) echo "  [CRIT] [$tag] $msg" ;;
                2) echo "  [WARN] [$tag] $msg" ;;
                1) echo "  [INFO] [$tag] $msg" ;;
            esac
        done
    fi
    echo
    echo "═══ Score: $score/100 ═══"
    echo
    echo "Full log: $LOG"
    if [ "${BACKUP_DONE:-0}" = "1" ]; then
        echo "Settings backup: $BACKUP_DIR/*-${BACKUP_TS}.*"
    fi
} > "$SUMMARY_TXT"

echo
echo -e "${DIM}  ─────────────────────────────────  TOTAL  ─────────────────────────────────${NC}"
echo

# Artifacts — compact list with icons
printf "  ${DIM}%-12s${NC} %s\n" "Full log" "$LOG"
printf "  ${DIM}%-12s${NC} %s\n" "Summary"  "$SUMMARY_TXT"
if [ "${BACKUP_DONE:-0}" = "1" ]; then
    printf "  ${DIM}%-12s${NC} %s\n" "Backup" "$BACKUP_DIR/*-${BACKUP_TS}.*"
fi
echo

# Rollback — only if something was actually applied
if [ "${BACKUP_DONE:-0}" = "1" ]; then
    echo -e "  ${DIM}${BOLD}⤺  Roll back fixes:${NC}"
    echo -e "  ${DIM}    rm /etc/sysctl.d/99-vpn-tuning.conf 2>/dev/null${NC}"
    echo -e "  ${DIM}    iptables -t mangle -F FORWARD; iptables -t mangle -F OUTPUT${NC}"
    echo -e "  ${DIM}    systemctl disable --now vpn-rps.service vpn-ring.service 2>/dev/null${NC}"
    echo -e "  ${DIM}    sysctl --system   ${DIM}# or restore from $BACKUP_DIR/sysctl-${BACKUP_TS}.txt${NC}"
    echo
fi

# Footer with run metadata
printf "  ${DIM}%s · %ds · %d/%d checks · v%s${NC}\n" \
    "$(date +'%H:%M:%S')" "$DIAG_DURATION" "$CHECK_TOTAL" "${#CHECKS[@]}" "$SCRIPT_VERSION"
echo
