#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
# revert-tuning.sh — undo everything apply-tuning.sh / node-diagnostic.sh did.
#
#   • removes /etc/sysctl.d/99-vpn-tuning.conf and 98-swappiness.conf
#   • deletes the iptables MSS-clamp rules from FORWARD/OUTPUT
#   • disables + removes the vpn-rps.service and vpn-ring.service units
#   • optionally restores net.* sysctls from the latest backup snapshot
#   • clears the journal /etc/node-diagnostic.applied
#
#   sudo bash revert-tuning.sh              # remove tuning, reload defaults
#   sudo bash revert-tuning.sh --restore    # also restore net.* from backup
#   sudo bash revert-tuning.sh --dry-run    # show what would be removed
# ════════════════════════════════════════════════════════════════════
set -u

if [ -t 1 ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; C=$'\033[0;36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    R=""; G=""; Y=""; C=""; BOLD=""; DIM=""; NC=""
fi

have() { command -v "$1" >/dev/null 2>&1; }

DRY_RUN=0
RESTORE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --restore) RESTORE=1 ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = "0" ]; then
    echo -e "${R}✗${NC} Root required. Re-run under sudo (or use --dry-run)."
    exit 1
fi

FIX_LOG="/etc/node-diagnostic.applied"
BACKUP_DIR="/var/backups/node-diagnostic"

run_or_dry() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} $*"
        return 0
    fi
    eval "$@"
}

echo
echo -e "${BOLD}  Node tuning — reverting${NC}"
[ "$DRY_RUN" = "1" ] && echo -e "${DIM}  (dry-run — nothing will be changed)${NC}"
echo

# ── sysctl files ────────────────────────────────────────────────────
echo -e "  ${C}→${NC} removing sysctl drop-ins"
for f in /etc/sysctl.d/99-vpn-tuning.conf /etc/sysctl.d/98-swappiness.conf; do
    if [ -f "$f" ]; then
        run_or_dry "rm -f $f" && echo -e "    ${G}✓${NC} $f"
    else
        echo -e "    ${DIM}not present: $f${NC}"
    fi
done

# ── iptables MSS clamp ──────────────────────────────────────────────
if have iptables; then
    echo -e "  ${C}→${NC} removing iptables MSS clamp"
    rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu)
    for chain in FORWARD OUTPUT; do
        removed=0
        while iptables -t mangle -C "$chain" "${rule_args[@]}" 2>/dev/null; do
            run_or_dry "iptables -t mangle -D $chain ${rule_args[*]}" || break
            removed=$((removed+1))
            [ "$DRY_RUN" = "1" ] && break
        done
        if [ "$removed" -gt 0 ] || [ "$DRY_RUN" = "1" ]; then
            echo -e "    ${G}✓${NC} $chain"
        else
            echo -e "    ${DIM}no rule in $chain${NC}"
        fi
    done
    if [ "$DRY_RUN" = "0" ]; then
        if have netfilter-persistent; then
            netfilter-persistent save >/dev/null 2>&1 && echo -e "    ${G}✓${NC} netfilter-persistent save"
        elif [ -d /etc/iptables ] && have iptables-save; then
            iptables-save > /etc/iptables/rules.v4 && echo -e "    ${G}✓${NC} saved to /etc/iptables/rules.v4"
        fi
    fi
fi

# ── systemd units ───────────────────────────────────────────────────
echo -e "  ${C}→${NC} removing systemd units"
for unit in vpn-rps.service vpn-ring.service; do
    path=/etc/systemd/system/$unit
    if [ -f "$path" ]; then
        run_or_dry "systemctl disable --now $unit >/dev/null 2>&1; rm -f $path" \
            && echo -e "    ${G}✓${NC} $unit"
    else
        echo -e "    ${DIM}not present: $unit${NC}"
    fi
done
[ "$DRY_RUN" = "0" ] && systemctl daemon-reload

# ── restore net.* from backup (optional) ────────────────────────────
if [ "$RESTORE" = "1" ]; then
    echo -e "  ${C}→${NC} restoring net.* sysctls from latest backup"
    latest=$(ls -1t "$BACKUP_DIR"/sysctl-*.txt 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        echo -e "    ${Y}⚠${NC} no backup snapshot found in $BACKUP_DIR"
    else
        echo -e "    ${DIM}using $latest${NC}"
        # only restore writable net.* keys; many sysctls are read-only
        while IFS='=' read -r key val; do
            key=$(echo "$key" | tr -d '[:space:]')
            val=$(echo "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            case "$key" in
                net.ipv4.tcp_congestion_control|net.core.default_qdisc|\
                net.ipv4.tcp_mtu_probing|net.ipv4.tcp_slow_start_after_idle|\
                net.ipv4.tcp_notsent_lowat|net.ipv4.tcp_fastopen|\
                net.core.rmem_max|net.core.wmem_max|\
                net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|\
                net.core.netdev_max_backlog|net.core.somaxconn|\
                net.ipv4.tcp_max_syn_backlog|net.netfilter.nf_conntrack_max|\
                vm.swappiness)
                    run_or_dry "sysctl -w '$key=$val' >/dev/null 2>&1" ;;
            esac
        done < "$latest"
        echo -e "    ${G}✓${NC} tuned keys restored to pre-tuning values"
    fi
fi

# ── reload defaults + clear journal ─────────────────────────────────
if [ "$DRY_RUN" = "0" ]; then
    sysctl --system >/dev/null 2>&1 && echo -e "  ${G}✓${NC} sysctl --system reloaded"
    [ -f "$FIX_LOG" ] && { rm -f "$FIX_LOG"; echo -e "  ${G}✓${NC} cleared journal $FIX_LOG"; }
fi

echo
echo -e "  ${G}${BOLD}✓ Revert done.${NC}"
[ "$RESTORE" = "0" ] && echo -e "  ${DIM}Note: running net.* values stay until reboot unless you pass --restore.${NC}"
echo -e "  ${DIM}Backups kept in $BACKUP_DIR (not deleted).${NC}"
echo
