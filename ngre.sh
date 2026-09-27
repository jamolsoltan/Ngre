#!/usr/bin/env bash
#
#    _   _  ____ ____  _____
#   | \ | |/ ___|  _ \| ____|
#   |  \| | |  _| |_) |  _|
#   | |\  | |_| |  _ <| |___
#   |_| \_|\____|_| \_\_____|
#
#   Ngre - GRE + Nginx tunnel manager
#
#   Tunnel core (same commands you would type by hand):
#     ip tunnel add <iface> mode gre local <this-ip> remote <peer-ip> ttl 255
#     ip addr add <tunnel-ip>/30 dev <iface>
#     ip link set <iface> mtu 1476 up
#   IRAN side forwards ports with nginx stream:
#     TCP  -> proxy_timeout 600s
#     UDP  -> proxy_timeout 60s
#
#   Run as root:  bash ngre.sh   (after the first run just type: ngre)
#
[ -z "$BASH_VERSION" ] && { echo "Please run with bash:  bash $0"; exit 1; } #
if [ -f "$0" ] && grep -q $'\r' "$0" 2>/dev/null; then if [ -w "$0" ] && sed -i 's/\r$//' "$0"; then echo "Windows line endings fixed in $0 - starting again..."; exec bash "$0" "$@"; else printf '%s\n' "This file has Windows line endings. Run: sed -i 's/\r\$//' $0"; exit 1; fi; fi #
if [ -f "$0" ] && [ "$(tail -n 1 "$0" 2>/dev/null)" != "# ngre:eof" ]; then echo "This copy of ngre is incomplete (the upload/download was cut). Upload the whole file again."; exit 1; fi #

SCRIPT_VERSION="v1.3.4"

# GitHub repository (format: username/repository). Used by
#   bash <(curl -Ls --ipv4 https://raw.githubusercontent.com/jamolsoltan/Ngre/main/ngre.sh)
# and by "Update script". Set it to USER/REPO to install / update only by hand.
NGRE_REPO="jamolsoltan/Ngre"
NGRE_BRANCH="main"

# Safe defaults for everything this script creates and runs
umask 022
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

# ----------------------------------------------------------------------------
# Paths & defaults
# ----------------------------------------------------------------------------
NGRE_BIN="/usr/local/bin/ngre"
NGRE_DIR="/etc/ngre"
TUN_DIR="$NGRE_DIR/tunnels"
NGX_DIR="$NGRE_DIR/nginx"
NGX_CONF="$NGX_DIR/nginx.conf"
NGX_STREAMS="$NGX_DIR/streams"
GLOBAL_CONF="$NGRE_DIR/ngre.conf"
BACKUP_DIR="$NGRE_DIR/backup"
FW_DIR="$NGRE_DIR/firewall"
STATE_DIR="/var/lib/ngre"
TRAFFIC_DIR="$STATE_DIR/traffic"
LOG_DIR="/var/log/ngre"
LOG_FILE="$LOG_DIR/ngre.log"
WD_LOG="$LOG_DIR/watchdog.log"
NGX_ERR_LOG="$LOG_DIR/nginx-error.log"
SERVICE_DIR="/etc/systemd/system"
NGX_SERVICE="ngre-nginx"
WD_SERVICE="ngre-watchdog"
TRAFFIC_UNIT="ngre-traffic"
NGX_PID="/run/ngre-nginx.pid"
LOCK_FILE="/run/ngre.lock"
MODULES_LOAD_FILE="/etc/modules-load.d/ngre.conf"
LOGROTATE_FILE="/etc/logrotate.d/ngre"

DEFAULT_MTU=1476
GRE_TTL=255
TCP_PROXY_TIMEOUT="600s"
UDP_PROXY_TIMEOUT="60s"
MAX_TOTAL_PORTS=10000       # all listen ports of all IRAN tunnels (nginx socket budget)

# ----------------------------------------------------------------------------
# Colors & output helpers
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;95m'
WHITE='\033[0;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

colorize() {
    local color="$1" text="$2" style="${3:-normal}" c s
    case "$color" in
        red) c=$RED ;; green) c=$GREEN ;; yellow) c=$YELLOW ;; blue) c=$BLUE ;;
        cyan) c=$CYAN ;; magenta) c=$MAGENTA ;; white) c=$WHITE ;; *) c=$NC ;;
    esac
    case "$style" in
        bold) s=$BOLD ;; *) s="" ;;
    esac
    echo -e "${s}${c}${text}${NC}"
}

ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
fail()  { echo -e "  ${RED}✖${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; }
info()  { echo -e "  ${CYAN}•${NC} $*"; }
line()  { echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"; }

press_key() {
    echo
    read -r -p "Press Enter to continue..." _ || true
}

# clear the screen even when TERM is not set
cls() {
    clear 2>/dev/null || printf '\033[H\033[2J'
}

# Normalize user input: drop CR, trim spaces, Persian/Arabic digits -> 0-9, "،" -> ","
normalize_input() {
    local s="$1"
    s="${s//$'\r'/}"
    if [[ "$s" == *[^[:print:]]* || "$s" =~ [^\ -~] ]]; then
        s="$(printf '%s' "$s" | sed 's/۰/0/g;s/۱/1/g;s/۲/2/g;s/۳/3/g;s/۴/4/g;s/۵/5/g;s/۶/6/g;s/۷/7/g;s/۸/8/g;s/۹/9/g;s/٠/0/g;s/١/1/g;s/٢/2/g;s/٣/3/g;s/٤/4/g;s/٥/5/g;s/٦/6/g;s/٧/7/g;s/٨/8/g;s/٩/9/g;s/،/,/g')"
    fi
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ask VAR : read one line from the user into VAR (normalized). Returns 1 on EOF.
ask() {
    local __ngre_in
    IFS= read -r __ngre_in || { echo; return 1; }
    printf -v "$1" '%s' "$(normalize_input "$__ngre_in")"
}

# Strip terminal control characters from text we did not write ourselves
# (log lines, process names...) before showing it: no escape-sequence tricks.
safe_text() {
    tr -d '\000-\010\013-\037\177'
}

show_log() {
    if [[ -s "$1" ]]; then tail -n "${2:-50}" "$1" | safe_text; else echo "(empty)"; fi
}

# confirm "question" [Y|N]  -> returns 0 for yes
confirm() {
    local q="$1" def="${2:-Y}" ans hint
    [[ "$def" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        echo -ne "${YELLOW}[?]${NC} $q $hint: "
        ask ans || return 1
        ans="${ans:-$def}"
        case "$ans" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
            *) colorize red "    Please answer y or n." ;;
        esac
    done
}

die() {
    colorize red "Error: $*" bold
    exit 1
}

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null
}

wd_log() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WD_LOG" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Validation & formatting helpers
# ----------------------------------------------------------------------------
is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ "$o" =~ ^0[0-9] ]] && return 1
        (( o <= 255 )) || return 1
    done
    return 0
}

# Only plain non-negative integers are allowed into arithmetic (no injection)
is_uint() { [[ "$1" =~ ^[0-9]{1,19}$ ]]; }
uint_or_zero() { if is_uint "$1"; then echo "$((10#$1))"; else echo 0; fi; }

# a normal unicast address a server can have (not 0.x, 127.x, multicast/reserved)
is_usable_ipv4() {
    is_ipv4 "$1" || return 1
    [[ "$1" =~ ^(0|127)\. ]] && return 1
    (( ${1%%.*} < 224 ))
}

# RFC 1918 / carrier-grade NAT address (server behind NAT)
is_private_ipv4() {
    [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]
}

# inside 10.64.0.0/14 = the range Ngre uses for tunnel addresses
in_tunnel_range() {
    [[ "$1" =~ ^10\.(6[4-7])\. ]]
}

is_tunnel_name() { [[ "$1" =~ ^(iran|kharej)[0-9]{1,5}$ ]]; }

is_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# num_in VALUE LOW HIGH : decimal number inside [LOW, HIGH] ("08" is 8, not an
# octal error; very long input is refused instead of overflowing)
num_in() {
    [[ "$1" =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

# Tunnel configs that load correctly (menus number them 1..N; an unreadable
# config must not shift the numbering)
list_valid_tunnel_files() {
    local f
    while IFS= read -r f; do
        ( load_tunnel "$f" ) >/dev/null 2>&1 && printf '%s\n' "$f"
    done < <(list_tunnel_files)
}

# Monotonic clock (uptime): immune to NTP / manual clock changes
#   mono_s  -> whole seconds     mono_cs -> centiseconds
mono_s()  { local up; read -r up _ < /proc/uptime; echo "${up%.*}"; }
mono_cs() { local up; read -r up _ < /proc/uptime; up="${up/./}"; echo "$((10#$up))"; }

# Human readable bytes: 1536 -> 1.50 KB
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB", u, " "); i=1
        while (b >= 1024 && i < 6) { b = b / 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i]
    }'
}

# Human readable bit rate from bytes and seconds: rate_fmt <bytes> <seconds>
rate_fmt() {
    awk -v b="${1:-0}" -v s="${2:-1}" 'BEGIN{
        if (s <= 0) s = 1
        r = b * 8 / s
        if (r >= 1000000000) printf "%.2f Gbps", r / 1000000000
        else if (r >= 1000000) printf "%.2f Mbps", r / 1000000
        else if (r >= 1000) printf "%.1f Kbps", r / 1000
        else printf "%d bps", r
    }'
}

# Absolute path of a binary (for systemd units)
bin_path() {
    command -v "$1" 2>/dev/null || {
        local d
        for d in /usr/sbin /sbin /usr/bin /bin; do
            [[ -x "$d/$1" ]] && { echo "$d/$1"; return 0; }
        done
        return 1
    }
}

# ss without header line (old iproute2 has no -H)
SS_HAS_H=""
ssq() {
    if [[ -z "$SS_HAS_H" ]]; then
        if ss -H -ltn >/dev/null 2>&1; then SS_HAS_H=1; else SS_HAS_H=0; fi
    fi
    if (( SS_HAS_H )); then ss -H "$@"; else ss "$@" | tail -n +2; fi
}

# Main IPv4 address of this server (route lookup only, no traffic is sent)
detect_server_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# Source IPv4 this server would use to reach <peer>
detect_local_ip_for() {
    ip -4 route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

ip_is_local() {
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$1"
}

# ----------------------------------------------------------------------------
# Locking (prevents two ngre sessions from changing configs at once)
# ----------------------------------------------------------------------------
lock_acquire() {
    exec 9>"$LOCK_FILE" || return 0
    if ! flock -w 15 9; then
        colorize red "Another ngre process is changing the configuration. Try again in a moment."
        return 1
    fi
}

lock_release() {
    flock -u 9 2>/dev/null
    exec 9>&-      # (never "exec 9>&- 2>/dev/null": that would silence stderr for good)
}

# Critical section: hold the config lock and ignore Ctrl+C / hangup / kill, so a
# change is never left half applied (for example when the SSH session drops).
critical_begin() {
    lock_acquire || return 1
    trap '' INT HUP QUIT TERM
}

critical_end() {
    trap - INT HUP QUIT TERM
    lock_release
}

# ----------------------------------------------------------------------------
# Tunnel naming & addressing
#   Tunnel port P is the tunnel ID.
#   name  : iranP / kharejP        unit : ngre-iranP / ngre-kharejP
#   iface : gre-P                  conf : /etc/ngre/tunnels/<name>.conf
#   Private /30 is derived from P inside 10.64.0.0/14, so both servers compute
#   the same addresses without talking to each other:
#   KHAREJ = first host (.1 of the /30), IRAN = second host (.2 of the /30)
# ----------------------------------------------------------------------------
tun_ips() {
    local p=$((10#$1)) n a b c
    n=$(( p * 4 ))
    a=$(( 64 + n / 65536 ))
    b=$(( (n / 256) % 256 ))
    c=$(( n % 256 ))
    TUN_NET="10.$a.$b.$c/30"
    TUN_KHAREJ_IP="10.$a.$b.$((c + 1))"
    TUN_IRAN_IP="10.$a.$b.$((c + 2))"
}

tunnel_name()  { echo "${1}${2}"; }       # role port
tunnel_iface() { echo "gre-${1}"; }       # port
tunnel_port_of() { local p="${1#iran}"; echo "${p#kharej}"; }   # name -> port
tunnel_unit()  { echo "ngre-${1}"; }      # name
tunnel_conf()  { echo "$TUN_DIR/${1}.conf"; }

# ----------------------------------------------------------------------------
# Tunnel config file I/O  (simple KEY=VALUE, values are validated before save)
# ----------------------------------------------------------------------------
TUN_KEYS=(ROLE TUNNEL_PORT IFACE LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP MTU PORTS FIREWALL CREATED)

reset_tunnel_vars() {
    local k
    for k in "${TUN_KEYS[@]}"; do printf -v "T_$k" '%s' ""; done
    T_NAME=""; T_UNIT=""; T_CONF=""
}

load_tunnel() {
    local file="$1" k v key
    reset_tunnel_vars
    [[ -f "$file" ]] || return 1
    while IFS='=' read -r k v; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        for key in "${TUN_KEYS[@]}"; do
            if [[ "$k" == "$key" ]]; then
                v="${v%\"}"; v="${v#\"}"
                printf -v "T_$k" '%s' "$v"
                break
            fi
        done
    done < "$file"
    T_NAME="$(tunnel_name "$T_ROLE" "$T_TUNNEL_PORT")"
    T_UNIT="$(tunnel_unit "$T_NAME")"
    T_CONF="$file"
    if ! tunnel_vars_valid || [[ "${file##*/}" != "${T_NAME}.conf" ]]; then
        reset_tunnel_vars
        return 1
    fi
    return 0
}

# Every value that ends up in a systemd unit, an nginx config or a command
# must pass these checks (protects against broken or tampered config files).
tunnel_vars_valid() {
    [[ "$T_ROLE" == "iran" || "$T_ROLE" == "kharej" ]] || return 1
    is_port "$T_TUNNEL_PORT" && [[ "$T_TUNNEL_PORT" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$T_IFACE" == "gre-$T_TUNNEL_PORT" ]] || return 1
    is_ipv4 "$T_LOCAL_IP" && is_ipv4 "$T_REMOTE_IP" || return 1
    tun_ips "$T_TUNNEL_PORT"
    if [[ "$T_ROLE" == "iran" ]]; then
        [[ "$T_LOCAL_TUN_IP" == "$TUN_IRAN_IP" && "$T_REMOTE_TUN_IP" == "$TUN_KHAREJ_IP" ]] || return 1
    else
        [[ "$T_LOCAL_TUN_IP" == "$TUN_KHAREJ_IP" && "$T_REMOTE_TUN_IP" == "$TUN_IRAN_IP" ]] || return 1
    fi
    [[ "$T_MTU" =~ ^[1-9][0-9]{2,3}$ ]] && (( T_MTU >= 576 && T_MTU <= 1500 )) || return 1
    case "$T_FIREWALL" in none|skip|ufw|firewalld|iptables) ;; *) return 1 ;; esac
    [[ "$T_CREATED" =~ ^[0-9:\ -]*$ ]] || return 1
    if [[ "$T_ROLE" == "iran" ]]; then
        [[ -n "$T_PORTS" && "$T_PORTS" =~ ^[0-9.:=,-]+$ ]] || return 1
        local spec specs
        IFS=',' read -ra specs <<<"$T_PORTS"
        for spec in "${specs[@]}"; do parse_spec "$spec" || return 1; done
    else
        [[ -z "$T_PORTS" ]] || return 1
    fi
    return 0
}

save_tunnel() {
    local file="$1" k v
    mkdir -p "$TUN_DIR" || return 1
    {
        echo "# Ngre tunnel config - managed by ngre, edit with the ngre menu"
        for k in "${TUN_KEYS[@]}"; do
            v="T_$k"
            printf '%s="%s"\n' "$k" "${!v}"
        done
    } | write_atomic "$file" 600
}

# All tunnel config files, sorted by tunnel port
list_tunnel_files() {
    local f
    for f in "$TUN_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        local n="${f##*/}"; n="${n%.conf}"
        is_tunnel_name "$n" || continue
        local p="${n#iran}"; p="${p#kharej}"
        printf '%s\t%s\n' "$p" "$f"
    done | sort -n | cut -f2
}

tunnel_count() {
    list_tunnel_files | grep -c . 2>/dev/null
}

iran_tunnel_count() {
    list_tunnel_files | grep -c '/iran[0-9]*\.conf$' 2>/dev/null
}

# ----------------------------------------------------------------------------
# Global settings
# ----------------------------------------------------------------------------
load_global() {
    WATCHDOG_ENABLED=1
    WATCHDOG_INTERVAL=30
    WATCHDOG_FAILS=3
    local k v
    [[ -f "$GLOBAL_CONF" ]] || return 0
    while IFS='=' read -r k v; do
        v="${v%\"}"; v="${v#\"}"
        case "$k" in
            WATCHDOG_ENABLED)  [[ "$v" =~ ^[01]$ ]] && WATCHDOG_ENABLED=$v ;;
            WATCHDOG_INTERVAL) [[ "$v" =~ ^[0-9]{1,4}$ ]] && WATCHDOG_INTERVAL=$((10#$v)) ;;
            WATCHDOG_FAILS)    [[ "$v" =~ ^[0-9]{1,2}$ ]] && WATCHDOG_FAILS=$((10#$v)) ;;
        esac
    done < "$GLOBAL_CONF"
    (( WATCHDOG_INTERVAL < 5 )) && WATCHDOG_INTERVAL=5
    (( WATCHDOG_INTERVAL > 3600 )) && WATCHDOG_INTERVAL=3600
    (( WATCHDOG_FAILS < 1 )) && WATCHDOG_FAILS=1
    (( WATCHDOG_FAILS > 20 )) && WATCHDOG_FAILS=20
    return 0
}

save_global() {
    mkdir -p "$NGRE_DIR"
    write_atomic "$GLOBAL_CONF" 600 <<EOF
# Ngre global settings - managed by ngre
WATCHDOG_ENABLED="$WATCHDOG_ENABLED"
WATCHDOG_INTERVAL="$WATCHDOG_INTERVAL"
WATCHDOG_FAILS="$WATCHDOG_FAILS"
EOF
}

# ----------------------------------------------------------------------------
# Atomic file writes: stdin -> FILE, all or nothing (safe on "disk full",
# power loss or a killed process - a file is never left half written)
#   write_atomic FILE [MODE]
# ----------------------------------------------------------------------------
write_atomic() {
    local f="$1" mode="${2:-644}" tmp
    tmp="$(mktemp "$(dirname "$f")/.ngre-tmp.XXXXXX" 2>/dev/null)" || { cat >/dev/null; return 1; }
    if cat > "$tmp" 2>/dev/null && chmod "$mode" "$tmp" && mv -f "$tmp" "$f"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# ----------------------------------------------------------------------------
# Backups
# ----------------------------------------------------------------------------
backup_file() {
    local src="$1" tag="$2" dst
    [[ -f "$src" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    dst="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-${tag:-$(basename "$src")}"
    cp -a "$src" "$dst" 2>/dev/null
    # keep the newest 50 backups
    find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +51 \
        | cut -d' ' -f2- | while read -r old; do rm -f "$old"; done
}

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------
PKG_MGR=""
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    else PKG_MGR=""
    fi
}

# ---------------------------------------------------------------------------
# Package installation with a live progress bar.
#  - apt-get runs detached from the terminal (setsid): an SSH drop or Ctrl+C
#    can never kill dpkg halfway and leave the package system broken
#  - Ctrl+C cancels while waiting / downloading; once packages are being
#    unpacked it waits (that part must finish)
#  - a download that makes no progress for 3 minutes is stopped
# Return codes: 0 ok, 130 canceled, 124 stalled / waited too long,
# anything else = error of the package manager (details in PKG_ERROR)
# ---------------------------------------------------------------------------
APT_UPDATED=0
PKG_CANCEL=0
PKG_LAST_STEP=""
PKG_ERROR=""
PKG_STALL_SECONDS=180
PKG_LOCK_FILES=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)

fmt_elapsed() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# pkg_bar PERCENT TEXT ELAPSED_SECONDS
pkg_bar() {
    local p="$1" txt="$2" el w=26 fill bar rest step
    el="$(fmt_elapsed "$3")"
    (( p < 0 )) && p=0
    (( p > 100 )) && p=100
    if [[ -t 1 ]]; then
        fill=$(( p * w / 100 ))
        printf -v bar '%*s' "$fill" ''; bar="${bar// /#}"
        printf -v rest '%*s' $(( w - fill )) ''; rest="${rest// /.}"
        printf '\r    [%s%s] %3d%%  %-46.46s %s\033[K' "$bar" "$rest" "$p" "$txt" "$el"
    else
        # no terminal (logs): one line per 10% step
        step="$(( p / 10 ))"
        [[ "$step" != "$PKG_LAST_STEP" ]] && printf '    %3d%%  %s  (%s)\n' "$p" "$txt" "$el"
        PKG_LAST_STEP="$step"
    fi
}
pkg_bar_end() { [[ -t 1 ]] && echo; PKG_LAST_STEP=""; return 0; }

# PID of a process holding an apt/dpkg lock (unattended-upgrades on a fresh
# server, another apt in a second SSH session, ...). Reads /proc/locks.
pkg_lock_holder() {
    local f inodes=""
    for f in "${PKG_LOCK_FILES[@]}"; do
        [[ -e "$f" ]] && inodes+=" $(stat -c %i "$f" 2>/dev/null)"
    done
    [[ -z "${inodes// /}" ]] && return 0
    awk -v list="$inodes" -v me="$$" '
        BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        $2 != "->" { k = split($6, d, ":"); if ((d[k] in want) && $5 != me) { print $5; exit } }' /proc/locks 2>/dev/null
}

# keep / restore the current Ctrl+C handling around our own temporary trap
PKG_OLD_INT=""
pkg_trap_int()    { PKG_OLD_INT="$(trap -p INT)"; PKG_CANCEL=0; trap 'PKG_CANCEL=1' INT; }
pkg_restore_int() { if [[ -n "$PKG_OLD_INT" ]]; then eval "$PKG_OLD_INT"; else trap - INT; fi; }

# Wait (with a visible timer) until no other program holds the apt/dpkg lock. Max 20 min.
pkg_wait_others() {
    local t0 el pid name
    pid="$(pkg_lock_holder)"
    [[ -z "$pid" ]] && return 0
    t0=$(mono_s)
    pkg_trap_int
    while [[ -n "$pid" ]]; do
        name="$(ps -o comm= -p "$pid" 2>/dev/null | safe_text)"
        el=$(( $(mono_s) - t0 ))
        pkg_bar 0 "Waiting for ${name:-another program} (pid $pid) to finish" "$el"
        if (( PKG_CANCEL )); then pkg_bar_end; pkg_restore_int; return 130; fi
        if (( el > 1200 )); then
            pkg_bar_end; pkg_restore_int
            PKG_ERROR="${name:-pid $pid} has been using the package manager for 20 minutes"
            return 124
        fi
        sleep 1
        pid="$(pkg_lock_holder)"
    done
    pkg_bar_end; pkg_restore_int
    return 0
}

# pkg_stop PID : stop a detached apt-get (its own session / process group)
pkg_stop() { kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# pkg_apt FROM TO LABEL apt-get-arguments...
# Runs one apt-get command and shows its progress as FROM..TO percent.
pkg_apt() {
    local from="$1" to="$2" label="$3"; shift 3
    local sf lf pid rc t0 now last el line kind b msg pct best="$from" txt="$label" seen="" inpm=0 x y mode=install
    [[ " $* " == *" update "* ]] && mode=update
    sf="$(mktemp)"; lf="$(mktemp)"
    DEBIAN_FRONTEND=noninteractive setsid -w apt-get -o APT::Status-Fd=3 "$@" 3>"$sf" >"$lf" 2>&1 </dev/null 9>&- 8>&- &
    pid=$!
    t0=$(mono_s); last=$t0
    pkg_trap_int
    while kill -0 "$pid" 2>/dev/null; do
        now=$(mono_s)
        line="$(tail -n 1 "$sf" 2>/dev/null)"
        if [[ -n "$line" && "$line" != "$seen" ]]; then
            seen="$line"; last=$now
            IFS=: read -r kind _ b msg <<<"$line"
            pct="${b%%.*}"; [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
            msg="$(printf '%s' "$msg" | safe_text)"
            case "$kind" in
                dlstatus)
                    # apt often reports 0% with "Retrieving file X of Y": use X/Y then
                    if [[ "$msg" =~ file\ ([0-9]+)\ of\ ([0-9]+) ]]; then
                        x=${BASH_REMATCH[1]}; y=${BASH_REMATCH[2]}
                        (( y > 0 && x * 100 / y > pct )) && pct=$(( x * 100 / y ))
                    fi
                    if [[ "$mode" == "update" ]]; then
                        pct=$(( from + (to - from) * pct / 100 )); txt="$label (${msg#Retrieving })"
                    else
                        pct=$(( from + (to - from) * 40 * pct / 10000 )); txt="Downloading (${msg#Retrieving })"
                    fi ;;
                pmstatus)
                    inpm=1
                    pct=$(( from + (to - from) * 40 / 100 + (to - from) * 60 * pct / 10000 )); txt="$msg" ;;
                *) pct=$best ;;
            esac
            (( pct > best )) && best=$pct
        fi
        el=$(( now - t0 ))
        if [[ -z "$seen" ]] && grep -q 'held by process' "$lf" 2>/dev/null; then
            pkg_bar "$best" "Waiting for another program using apt to finish" "$el"
            last=$now
        else
            pkg_bar "$best" "$txt" "$el"
        fi
        if (( PKG_CANCEL )); then
            if (( inpm )); then
                PKG_CANCEL=0
                pkg_bar_end
                warn "Packages are being installed right now - this part cannot be stopped safely. Please wait."
            else
                pkg_stop "$pid"; pkg_bar_end; pkg_restore_int
                rm -f "$sf" "$lf"; PKG_ERROR="canceled"
                return 130
            fi
        fi
        if (( ! inpm && now - last > PKG_STALL_SECONDS )); then     # no progress at all (default 3 min)
            pkg_stop "$pid"; pkg_bar_end; pkg_restore_int
            PKG_ERROR="download made no progress for $(fmt_elapsed "$PKG_STALL_SECONDS") min (package mirror unreachable?) $(tail -n 3 "$lf" | tr '\n' ' ' | safe_text)"
            rm -f "$sf" "$lf"
            return 124
        fi
        sleep 0.5
    done
    wait "$pid"; rc=$?
    pkg_restore_int
    (( rc == 0 )) && pkg_bar "$to" "$label - done" $(( $(mono_s) - t0 ))
    pkg_bar_end
    PKG_ERROR="$(grep -E '^(E|W): ' "$lf" | tail -n 4 | safe_text)"
    rm -f "$sf" "$lf"
    return "$rc"
}

# dnf / yum have no machine-readable progress: show a timer
pkg_plain() {
    local label="$1" pid rc t0 spin='.oOo' i=0; shift
    setsid -w "$@" >/dev/null 2>&1 </dev/null 9>&- 8>&- &
    pid=$!; t0=$(mono_s)
    while kill -0 "$pid" 2>/dev/null; do
        pkg_bar 0 "$label ${spin:$(( i++ % 4 )):1}" $(( $(mono_s) - t0 ))
        sleep 0.5
    done
    wait "$pid"; rc=$?
    pkg_bar_end
    return "$rc"
}

pkg_install() {
    [[ -z "$PKG_MGR" ]] && detect_pkg_mgr
    local rc from=0
    local aopt=(-o DPkg::Lock::Timeout=600 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20
                -o Acquire::Retries=1 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    PKG_ERROR=""
    case "$PKG_MGR" in
        apt)
            pkg_wait_others; rc=$?
            (( rc != 0 )) && return "$rc"
            # refresh the package lists only when needed (mirrors can be slow / filtered in Iran)
            if (( APT_UPDATED == 0 )) && ! apt-cache show "$@" >/dev/null 2>&1; then
                pkg_apt 0 30 "Updating package lists" "${aopt[@]}" update; rc=$?
                (( rc == 130 )) && return 130
                APT_UPDATED=1; from=30
            fi
            pkg_apt "$from" 100 "Installing $*" "${aopt[@]}" install -y "$@"; rc=$?
            if (( rc != 0 && rc != 130 && rc != 124 && APT_UPDATED == 0 )); then
                # the lists were there but outdated (404 on download): refresh and try once more
                pkg_apt 0 30 "Updating package lists" "${aopt[@]}" update; rc=$?
                (( rc == 130 )) && return 130
                APT_UPDATED=1
                pkg_apt 30 100 "Installing $*" "${aopt[@]}" install -y "$@"; rc=$?
            fi
            return "$rc" ;;
        dnf) pkg_plain "Installing $*" dnf install -y -q "$@" ;;
        yum) pkg_plain "Installing $*" yum install -y -q "$@" ;;
        *) return 1 ;;
    esac
}

ensure_base_deps() {
    local missing=()
    command -v ip    >/dev/null 2>&1 || missing+=(iproute2)
    command -v ss    >/dev/null 2>&1 || missing+=(iproute2)
    command -v ping  >/dev/null 2>&1 || missing+=(iputils-ping)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    (( ${#missing[@]} == 0 )) && return 0
    detect_pkg_mgr
    if [[ "$PKG_MGR" != "apt" ]]; then
        # package names differ on RHEL-like systems
        missing=("${missing[@]/iputils-ping/iputils}")
        missing=("${missing[@]/iproute2/iproute}")
    fi
    local uniq=()
    mapfile -t uniq < <(printf '%s\n' "${missing[@]}" | sort -u)
    colorize yellow "Installing missing tools: ${uniq[*]} ..."
    if ! pkg_install "${uniq[@]}"; then
        colorize red "Could not install: ${uniq[*]} (install them manually)."
        [[ -n "$PKG_ERROR" ]] && echo "$PKG_ERROR" | sed 's/^/      /'
    fi
}

preflight() {
    [[ $EUID -eq 0 ]] || { echo "This script must be run as root"; sleep 1; exit 1; }
    [[ "$(uname -s)" == "Linux" ]] || die "Unsupported operating system (Linux only)."
    [[ -d /run/systemd/system ]] || die "systemd is required."
    (( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is required."
    mkdir -p "$NGRE_DIR" "$TUN_DIR" "$NGX_STREAMS" "$BACKUP_DIR" "$FW_DIR" "$TRAFFIC_DIR" "$LOG_DIR"
    chmod 700 "$NGRE_DIR" "$STATE_DIR"
    chmod 750 "$LOG_DIR"
    ensure_base_deps
    ssq -ltn >/dev/null 2>&1      # detect ss features once
}

# A complete Ngre script: valid bash syntax, has a version and ends with the
# end marker (catches half-finished uploads/downloads that still parse)
script_complete() {
    [[ -s "$1" ]] && bash -n "$1" 2>/dev/null && grep -q '^SCRIPT_VERSION=' "$1" \
        && [[ "$(tail -n 1 "$1")" == "# ngre:eof" ]]
}

# Put a new copy of the script in place as $NGRE_BIN, all or nothing: the copy
# is checked before it replaces the old one (never a half-written command).
install_atomic() {
    local src="$1" tmp
    tmp="$(mktemp "$(dirname "$NGRE_BIN")/.ngre-new.XXXXXX" 2>/dev/null)" || return 1
    if cat "$src" > "$tmp" 2>/dev/null && chmod 755 "$tmp" && script_complete "$tmp" && mv -f "$tmp" "$NGRE_BIN"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Started as "bash <(curl ...)": the script cannot be read a second time to
# install it, and the services need the installed copy. Checked before
# anything is changed on the server.
repo_configured() {
    [[ "$NGRE_REPO" != "USER/REPO" && "$NGRE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
       && "$NGRE_BRANCH" =~ ^[A-Za-z0-9_./-]+$ ]]
}
raw_url() { echo "https://raw.githubusercontent.com/${NGRE_REPO}/${NGRE_BRANCH}/ngre.sh"; }

# download_script FILE : latest ngre.sh from GitHub (IPv4 first, like the install command)
download_script() {
    { curl -fsSL --ipv4 --max-time 60 "$(raw_url)" -o "$1" 2>/dev/null \
        || curl -fsSL --max-time 60 "$(raw_url)" -o "$1" 2>/dev/null; } && [[ -s "$1" ]]
}

# How to start Ngre, for messages
start_hint() {
    if repo_configured; then echo "  bash <(curl -Ls --ipv4 $(raw_url))"
    else echo "  upload ngre.sh to the server, then run:  bash ngre.sh"
    fi
}

source_check() {
    local src tmp
    src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
    if [[ ! -f "$src" || ! -r "$src" ]]; then
        # started as "bash <(curl -Ls ...)": the script can't be read a second time,
        # so fetch it as a real file and run that one (it installs itself)
        if [[ -z "${NGRE_BOOTSTRAPPED:-}" ]] && repo_configured && command -v curl >/dev/null 2>&1; then
            tmp="$(mktemp /tmp/ngre-dl.XXXXXX 2>/dev/null)"
            if [[ -n "$tmp" ]] && download_script "$tmp" && script_complete "$tmp"; then
                NGRE_BOOTSTRAPPED=1 exec bash "$tmp"
            fi
            rm -f "$tmp"
            colorize yellow "Could not download $(raw_url) (GitHub may be blocked on this server)." bold
        fi
        if [[ -f "$NGRE_BIN" ]] && script_complete "$NGRE_BIN"; then
            local iv
            iv="$(grep -m1 '^SCRIPT_VERSION=' "$NGRE_BIN" | cut -d'"' -f2 | safe_text)"
            if [[ "$iv" != "$SCRIPT_VERSION" ]]; then
                colorize yellow "Note: this copy ($SCRIPT_VERSION) was not started from a file, so it was not installed." bold
                echo "Background services keep using the installed version ($iv). To install this one:"
                echo "  save it as ngre.sh and run:  bash ngre.sh"
                sleep 2
            fi
            return 0
        fi
        colorize red "Ngre must be started from a file so it can install itself" bold
        colorize red "(the watchdog, traffic statistics and firewall hooks use the installed copy)." bold
        echo "Download ngre.sh another way, upload it to the server and run:  bash ngre.sh"
        exit 1
    fi
}

# Install this file as the "ngre" command (like Zenith's /usr/bin/backhaul)
self_install() {
    local src
    src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
    [[ -f "$src" && -r "$src" ]] || return 0
    [[ "$src" == "$NGRE_BIN" ]] && return 0
    if [[ ! -f "$NGRE_BIN" ]] || ! cmp -s "$src" "$NGRE_BIN"; then
        if ! script_complete "$src"; then
            colorize red "This copy of the script is incomplete or damaged (upload it again) - not installing it." bold
            sleep 2
            return 0
        fi
        if ! install_atomic "$src"; then
            colorize red "Could not install to $NGRE_BIN - watchdog and traffic statistics need it." bold
            sleep 2
            return 0
        fi
        log INFO "Installed $SCRIPT_VERSION to $NGRE_BIN"
        colorize green "Ngre $SCRIPT_VERSION installed. From now on just type: ngre" bold
        # refresh generated units in case this is an update of an existing setup
        if (( $(tunnel_count) > 0 )) && lock_acquire; then
            trap '' INT HUP QUIT TERM
            regen_all >/dev/null 2>&1 && colorize green "Existing tunnels' services refreshed."
            critical_end
        fi
        sleep 1
    fi
}

# ============================================================================
#  GRE tunnel engine (systemd oneshot unit that runs the exact ip commands)
# ============================================================================

# Is there already a GRE tunnel between <local> and <remote>?  Prints its name.
gre_pair_in_use() {
    local l="$1" r="$2"
    ip tunnel show 2>/dev/null | awk -v r="$r" -v l="$l" '
        $2 == "gre/ip" {
            name = $1; sub(/:$/, "", name); rem = ""; loc = ""
            for (i = 1; i <= NF; i++) { if ($i == "remote") rem = $(i+1); if ($i == "local") loc = $(i+1) }
            if (rem == r && (loc == l || loc == "any")) { print name; exit }
        }'
}

gre_kernel_ready() {
    modprobe ip_gre >/dev/null 2>&1
    [[ -d /sys/module/ip_gre ]] || lsmod 2>/dev/null | grep -q '^ip_gre'
}

write_tunnel_unit() {
    local ipb modb unit_file
    ipb="$(bin_path ip)" || return 1
    modb="$(bin_path modprobe)"
    unit_file="$SERVICE_DIR/${T_UNIT}.service"
    {
        cat <<EOF
# Managed by ngre - do not edit by hand
[Unit]
Description=Ngre GRE tunnel ${T_NAME} (${T_LOCAL_IP} <-> ${T_REMOTE_IP})
# not network-online.target: on many VPS images systemd-networkd-wait-online
# fails after 2 minutes at every boot, which kept the tunnel down that long.
# "ngre _wait-net" waits (max 30 s) only for what the tunnel really needs.
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-$NGRE_BIN _wait-net ${T_LOCAL_IP} ${T_REMOTE_IP}
EOF
        [[ -n "$modb" ]] && echo "ExecStartPre=-$modb ip_gre"
        cat <<EOF
ExecStartPre=-$ipb tunnel del ${T_IFACE}
ExecStart=$ipb tunnel add ${T_IFACE} mode gre local ${T_LOCAL_IP} remote ${T_REMOTE_IP} ttl ${GRE_TTL}
ExecStart=$ipb addr add ${T_LOCAL_TUN_IP}/30 dev ${T_IFACE}
ExecStart=$ipb link set ${T_IFACE} mtu ${T_MTU} up
ExecStartPost=-$NGRE_BIN _fw-up ${T_NAME}
ExecStop=-$NGRE_BIN _collect ${T_NAME}
ExecStop=-$NGRE_BIN _fw-down ${T_NAME}
ExecStop=-$ipb tunnel del ${T_IFACE}
ExecStopPost=-$ipb tunnel del ${T_IFACE}

[Install]
WantedBy=multi-user.target
EOF
    } | write_atomic "$unit_file"
}

ensure_gre_autoload() {
    [[ -f "$MODULES_LOAD_FILE" ]] || echo "ip_gre" | write_atomic "$MODULES_LOAD_FILE"
}

# unit_now start|restart UNIT : start / restart a unit right away.
# Units written by older Ngre versions wait for network-online.target. When one
# is started by hand and that target was never reached (minimal images), starting
# it pulls the target in and systemd-networkd-wait-online blocks everything for
# up to 2 minutes. The server is obviously online then, so that is skipped.
unit_now() {
    if systemctl is-active --quiet network-online.target 2>/dev/null; then
        systemctl "$1" "$2" >/dev/null 2>&1
    else
        systemctl "$1" --job-mode=ignore-dependencies "$2" >/dev/null 2>&1
    fi
}

# enable + start a unit. NOTE: "systemctl enable --now" exits 0 even when the
# start fails (systemd 255), so start separately to get the real result.
unit_enable_start() {
    systemctl enable "$1" >/dev/null 2>&1
    unit_now start "$1"
}

# stop + disable units ONE BY ONE: a multi-unit "systemctl disable --now a b c"
# does nothing at all when one of the unit files is missing (others keep running)
unit_disable_stop() {
    local u
    for u in "$@"; do
        systemctl disable "$u" >/dev/null 2>&1
        systemctl stop "$u" >/dev/null 2>&1
        systemctl reset-failed "$u" >/dev/null 2>&1   # no "failed" ghost after the unit file is gone
    done
}

# remove "*.wants/ngre-*" links whose unit file is gone
remove_dangling_wants() {
    local l
    for l in "$SERVICE_DIR"/*.wants/ngre-*; do
        [[ -L "$l" && ! -e "$l" ]] && rm -f "$l"
    done
    return 0
}

# a tunnel counts as running only if systemd says active AND the interface is up
tunnel_running() {
    systemctl is-active --quiet "$T_UNIT" 2>/dev/null && iface_up "$T_IFACE"
}

iface_up() {
    [[ -d "/sys/class/net/$1" ]] && ip link show "$1" 2>/dev/null | head -1 | grep -qE '[<,]UP[,>]'
}

# ping the other end of the tunnel; prints RTT in ms (empty if no reply)
tunnel_ping_ms() {
    ping -c "${2:-1}" -W 2 -i 0.3 -q "$1" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {if ($5 < 1) printf "%.2f", $5; else printf "%.1f", $5}'
}

# Ping many tunnels at once (a dead peer costs ~2s; done one by one this adds up).
#   parallel_ping DIR COUNT ip1 ip2 ...   -> DIR/<index> holds the RTT of reachable ones
parallel_ping() {
    local d="$1" count="$2" i=0 ip
    shift 2
    for ip in "$@"; do
        ( r="$(tunnel_ping_ms "$ip" "$count")"; [[ -n "$r" ]] && echo "$r" > "$d/$i" ) &
        i=$((i + 1))
        (( i % 64 == 0 )) && wait
    done
    wait
}

make_tmpdir() {
    mktemp -d /run/ngre-tmp.XXXXXX 2>/dev/null || mktemp -d
}

# temp dirs of ngre processes that were killed (older than 10 minutes)
clean_stale_tmp() {
    find /run -maxdepth 1 -type d -name 'ngre-tmp.*' -mmin +10 -exec rm -rf {} + 2>/dev/null
    return 0
}

# ============================================================================
#  Nginx engine (dedicated instance: ngre-nginx, config in /etc/ngre/nginx)
#  The system nginx and /etc/nginx/nginx.conf are never touched.
# ============================================================================
NGX_LAST_ERROR=""

ngx_bin() { bin_path nginx; }

ngx_stream_load_line() {
    local nb v p
    nb="$(ngx_bin)" || return 1
    v="$("$nb" -V 2>&1)"
    if grep -qE -- '--with-stream=dynamic( |$)' <<<"$v"; then
        for p in /usr/lib/nginx/modules /usr/lib64/nginx/modules /usr/share/nginx/modules \
                 /etc/nginx/modules /usr/local/nginx/modules; do
            if [[ -f "$p/ngx_stream_module.so" ]]; then
                echo "load_module $p/ngx_stream_module.so;"
                return 0
            fi
        done
        return 1
    elif grep -qE -- '--with-stream( |$)' <<<"$v"; then
        echo "# stream module is built into this nginx"
        return 0
    fi
    return 1
}

ngx_user() {
    if id -u www-data >/dev/null 2>&1; then echo www-data
    elif id -u nginx >/dev/null 2>&1; then echo nginx
    else echo nobody
    fi
}

ensure_nginx() {
    detect_pkg_mgr
    if ! command -v nginx >/dev/null 2>&1; then
        info "Installing nginx (only the first time; usually 1-3 minutes, Ctrl+C cancels) ..."
        local policy_created=0 rc
        # keep apt from auto-starting the system nginx (it could fight over port 80)
        if [[ "$PKG_MGR" == "apt" && ! -e /usr/sbin/policy-rc.d ]]; then
            printf '#!/bin/sh\n# ngre-temporary (removed automatically)\nexit 101\n' > /usr/sbin/policy-rc.d
            chmod +x /usr/sbin/policy-rc.d
            policy_created=1
        fi
        case "$PKG_MGR" in
            apt)     pkg_install nginx libnginx-mod-stream; rc=$?
                     (( rc != 0 && rc != 130 && rc != 124 )) && { pkg_install nginx; rc=$?; } ;;
            dnf|yum) pkg_install nginx nginx-mod-stream; rc=$?
                     (( rc != 0 && rc != 130 )) && { pkg_install nginx; rc=$?; } ;;
            *)       rc=1 ;;
        esac
        (( policy_created )) && rm -f /usr/sbin/policy-rc.d
        if (( rc == 130 )); then
            warn "Canceled - nothing was changed."
            return 1
        fi
        if ! command -v nginx >/dev/null 2>&1; then
            fail "nginx could not be installed."
            [[ -n "$PKG_ERROR" ]] && echo "$PKG_ERROR" | sed 's/^/      /'
            echo "      Check the server's internet / package mirror, then install it by hand and run ngre again:"
            echo "        apt update && apt install nginx libnginx-mod-stream"
            return 1
        fi
        # Ngre runs its own nginx instance; the freshly installed system service is not needed
        unit_disable_stop nginx
        ok "nginx installed (the default system nginx service was disabled; Ngre uses its own instance)"
        log INFO "nginx installed as a dependency; system nginx.service disabled"
    fi
    if ! ngx_stream_load_line >/dev/null; then
        info "Installing nginx stream module ..."
        case "$PKG_MGR" in
            apt) pkg_install libnginx-mod-stream ;;
            dnf|yum) pkg_install nginx-mod-stream ;;
        esac
        [[ -n "$PKG_ERROR" ]] && ! ngx_stream_load_line >/dev/null && echo "$PKG_ERROR" | sed 's/^/      /'
        if ! ngx_stream_load_line >/dev/null; then
            fail "nginx stream module is not available. Install it manually: apt install libnginx-mod-stream"
            return 1
        fi
    fi
    return 0
}

write_ngx_conf() {
    local load
    load="$(ngx_stream_load_line)" || { NGX_LAST_ERROR="nginx stream module not found"; return 1; }
    mkdir -p "$NGX_DIR" "$NGX_STREAMS" "$LOG_DIR"
    write_atomic "$NGX_CONF" 600 <<EOF
# Ngre dedicated nginx instance - managed by ngre, do not edit by hand.
# The system nginx (/etc/nginx) is not used or changed by ngre.
$load
user $(ngx_user);
worker_processes auto;
worker_rlimit_nofile 200000;
pid $NGX_PID;
error_log $NGX_ERR_LOG warn;

events {
    worker_connections 50000;
}

stream {
    include $NGX_STREAMS/*.conf;
}
EOF
}

write_ngx_unit() {
    local nb
    nb="$(ngx_bin)" || return 1
    write_atomic "$SERVICE_DIR/$NGX_SERVICE.service" <<EOF
# Managed by ngre - do not edit by hand
[Unit]
Description=Ngre nginx stream engine (forwards IRAN ports into GRE tunnels)
After=network.target

[Service]
Type=forking
PIDFile=$NGX_PID
ExecStartPre=$nb -t -q -c $NGX_CONF
ExecStart=$nb -c $NGX_CONF
ExecReload=$nb -t -q -c $NGX_CONF
ExecReload=$nb -c $NGX_CONF -s reload
ExecStop=-$nb -c $NGX_CONF -s quit
TimeoutStopSec=10
KillMode=mixed
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

ngx_test() {
    "$(ngx_bin)" -t -q -c "$NGX_CONF" 2>&1
}

stream_files_count() {
    local n=0 f
    for f in "$NGX_STREAMS"/*.conf; do [[ -f "$f" ]] && n=$((n + 1)); done
    echo "$n"
}

# Bring ngre-nginx to the right state for the current stream files
ngx_apply() {
    NGX_LAST_ERROR=""
    if (( $(stream_files_count) == 0 )); then
        unit_disable_stop "$NGX_SERVICE"
        return 0
    fi
    local out
    if ! out="$(ngx_test)"; then
        NGX_LAST_ERROR="$out"
        return 1
    fi
    systemctl daemon-reload
    local mpid
    mpid="$(cat "$NGX_PID" 2>/dev/null)"
    if systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null && [[ "$mpid" =~ ^[0-9]+$ ]] \
       && [[ "$(readlink "/proc/$mpid/exe" 2>/dev/null)" == *" (deleted)" ]]; then
        # nginx was upgraded by apt: the old master cannot load the new stream module
        if ! unit_now restart "$NGX_SERVICE"; then
            NGX_LAST_ERROR="$(journalctl -u "$NGX_SERVICE" -n 8 --no-pager 2>/dev/null)"
            return 1
        fi
    elif systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null; then
        if ! systemctl reload "$NGX_SERVICE" >/dev/null 2>&1; then
            NGX_LAST_ERROR="$(tail -n 5 "$NGX_ERR_LOG" 2>/dev/null)"
            return 1
        fi
    else
        if ! unit_enable_start "$NGX_SERVICE"; then
            NGX_LAST_ERROR="$(journalctl -u "$NGX_SERVICE" -n 8 --no-pager 2>/dev/null)"
            return 1
        fi
    fi
    return 0
}

# After a start/reload: is OUR nginx (ngre-nginx master pid) really bound to
# every listen port of the loaded tunnel?  "nginx -s reload" reports success even
# when a new port cannot be bound - nginx then logs "[emerg] ... still could not
# bind()" and silently keeps the old config.   $1 = error log size before apply
stream_verify_listen() {
    local size0="${1:-0}" try spec specs p lp missing mpid emerg
    for (( try = 1; try <= 14; try++ )); do
        emerg="$(tail -c +$(( size0 + 1 )) "$NGX_ERR_LOG" 2>/dev/null | grep -F '[emerg]' | tail -n 3)"
        if grep -q 'still could not bind' <<<"$emerg"; then
            NGX_LAST_ERROR="$emerg"
            return 1
        fi
        mpid="$(cat "$NGX_PID" 2>/dev/null)"
        missing=""
        if [[ -n "$mpid" ]]; then
            lp="$(ssq -ltnup 2>/dev/null | awk '{print $1" "$5" "$7}')"
            IFS=',' read -ra specs <<<"$T_PORTS"
            for spec in "${specs[@]}"; do
                parse_spec "$spec" || continue
                for p in $(printf '%s\n' "$PS_LFROM" "$PS_LTO" | sort -u); do
                    grep -qE "^tcp [^ ]*:${p} .*pid=${mpid}[,)]" <<<"$lp" || missing+=" ${p}/tcp"
                    grep -qE "^udp [^ ]*:${p} .*pid=${mpid}[,)]" <<<"$lp" || missing+=" ${p}/udp"
                done
            done
        else
            missing=" (ngre-nginx is not running)"
        fi
        [[ -z "$missing" ]] && return 0
        sleep 0.5
    done
    NGX_LAST_ERROR="nginx is not listening on:${missing}"$'\n'"$(tail -n 4 "$NGX_ERR_LOG" 2>/dev/null)"
    return 1
}

# Write the stream file of the loaded IRAN tunnel and apply it.
# On failure the previous file is restored (rollback).
stream_apply_current() {
    local f="$NGX_STREAMS/${T_NAME}.conf" had_old=0
    NGX_LAST_ERROR=""
    write_ngx_conf || { NGX_LAST_ERROR="${NGX_LAST_ERROR:-cannot write $NGX_CONF (disk full?)}"; return 1; }
    write_ngx_unit || { NGX_LAST_ERROR="cannot write the ${NGX_SERVICE} unit (disk full?)"; return 1; }
    if [[ -f "$f" ]]; then
        cp -a "$f" "$f.bak" || { NGX_LAST_ERROR="cannot write in $NGX_STREAMS (disk full?)"; return 1; }
        backup_file "$f" "stream-${T_NAME}.conf"
        had_old=1
    fi
    if ! gen_stream_file | write_atomic "$f" 600; then
        (( had_old )) && mv -f "$f.bak" "$f"
        NGX_LAST_ERROR="cannot write $f (disk full?)"
        return 1
    fi
    local size0
    size0="$(stat -c %s "$NGX_ERR_LOG" 2>/dev/null || echo 0)"
    if ngx_apply && stream_verify_listen "$size0"; then
        rm -f "$f.bak"
        log INFO "nginx stream config applied for ${T_NAME} (ports: ${T_PORTS})"
        return 0
    fi
    local err="$NGX_LAST_ERROR"
    if (( had_old )); then mv -f "$f.bak" "$f"; else rm -f "$f"; fi
    ngx_apply >/dev/null 2>&1
    NGX_LAST_ERROR="$err"
    log ERROR "nginx config for ${T_NAME} rejected, rolled back: ${err//$'\n'/ | }"
    return 1
}

# On RHEL-like systems SELinux may stop nginx from binding/connecting
selinux_hint() {
    [[ "$NGX_LAST_ERROR" == *"Permission denied"* ]] || return 0
    command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
    warn "SELinux is blocking nginx. Allow the ports and outgoing connections, for example:"
    echo "      semanage port -a -t http_port_t -p tcp <port>   (and the same with -p udp)"
    echo "      setsebool -P httpd_can_network_connect 1"
}

stream_remove() {
    local f="$NGX_STREAMS/${1}.conf"
    [[ -f "$f" ]] || return 0
    backup_file "$f" "stream-${1}.conf"
    rm -f "$f" "$f.bak"
    ngx_apply >/dev/null 2>&1
}

# ============================================================================
#  Port specs (IRAN side) - formats inspired by Backhaul/Zenith
#    443              listen 443        -> tunnel:443
#    443-600          listen 443..600   -> tunnel:same port
#    443-600:5201     listen 443..600   -> tunnel:5201
#    4000=5000        listen 4000       -> tunnel:5000
#    127.0.0.2:443=5201  bind 127.0.0.2:443 -> tunnel:5201
#  Every spec is forwarded for TCP (600s) and UDP (60s), exactly like the
#  original nginx config.
# ============================================================================
MAX_RANGE_PORTS=5000

# Sets PS_BIND PS_LFROM PS_LTO PS_TARGET, or PS_ERR on failure
parse_spec() {
    local s="$1"
    PS_BIND=""; PS_LFROM=""; PS_LTO=""; PS_TARGET=""; PS_ERR=""
    if [[ "$s" =~ ^([0-9]+)$ ]]; then
        PS_LFROM=${BASH_REMATCH[1]}; PS_LTO=$PS_LFROM
    elif [[ "$s" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        PS_LFROM=${BASH_REMATCH[1]}; PS_LTO=${BASH_REMATCH[2]}
    elif [[ "$s" =~ ^([0-9]+)-([0-9]+):([0-9]+)$ ]]; then
        PS_LFROM=${BASH_REMATCH[1]}; PS_LTO=${BASH_REMATCH[2]}; PS_TARGET=${BASH_REMATCH[3]}
    elif [[ "$s" =~ ^([0-9]+)=([0-9]+)$ ]]; then
        PS_LFROM=${BASH_REMATCH[1]}; PS_LTO=$PS_LFROM; PS_TARGET=${BASH_REMATCH[2]}
    elif [[ "$s" =~ ^([0-9.]+):([0-9]+)=([0-9]+)$ ]]; then
        PS_BIND=${BASH_REMATCH[1]}; PS_LFROM=${BASH_REMATCH[2]}; PS_LTO=$PS_LFROM; PS_TARGET=${BASH_REMATCH[3]}
        is_ipv4 "$PS_BIND" || { PS_ERR="invalid bind IP '$PS_BIND'"; return 1; }
    else
        PS_ERR="unknown format"
        return 1
    fi
    if ! is_port "$PS_LFROM" || ! is_port "$PS_LTO"; then PS_ERR="port out of range (1-65535)"; return 1; fi
    if [[ -n "$PS_TARGET" ]] && ! is_port "$PS_TARGET"; then PS_ERR="target port out of range (1-65535)"; return 1; fi
    PS_LFROM=$((10#$PS_LFROM)); PS_LTO=$((10#$PS_LTO))
    [[ -n "$PS_TARGET" ]] && PS_TARGET=$((10#$PS_TARGET))
    if (( PS_LFROM > PS_LTO )); then PS_ERR="range start is bigger than range end"; return 1; fi
    if (( PS_LTO - PS_LFROM + 1 > MAX_RANGE_PORTS )); then PS_ERR="range too large (max $MAX_RANGE_PORTS ports)"; return 1; fi
    return 0
}

# Canonical text of the last parsed spec
spec_canonical() {
    local s
    if (( PS_LFROM == PS_LTO )); then s="$PS_LFROM"; else s="$PS_LFROM-$PS_LTO"; fi
    if [[ -n "$PS_BIND" ]]; then
        s="$PS_BIND:$s=$PS_TARGET"
    elif [[ -n "$PS_TARGET" ]]; then
        if (( PS_LFROM == PS_LTO )); then s="$s=$PS_TARGET"; else s="$s:$PS_TARGET"; fi
    fi
    echo "$s"
}

spec_to_stream() {
    local spec="$1" rip="$2" listen target
    parse_spec "$spec" || return 1
    if (( PS_LFROM == PS_LTO )); then listen="$PS_LFROM"; else listen="$PS_LFROM-$PS_LTO"; fi
    [[ -n "$PS_BIND" ]] && listen="$PS_BIND:$listen"
    if [[ -n "$PS_TARGET" ]]; then target="$PS_TARGET"
    elif (( PS_LFROM == PS_LTO )); then target="$PS_LFROM"
    else target='$server_port'
    fi
    cat <<EOF

    # $spec
    server {
        listen $listen;
        proxy_pass $rip:$target;
        proxy_timeout $TCP_PROXY_TIMEOUT;
    }
    server {
        listen $listen udp;
        proxy_pass $rip:$target;
        proxy_timeout $UDP_PROXY_TIMEOUT;
    }
EOF
}

gen_stream_file() {
    local spec specs
    echo "# Ngre tunnel ${T_NAME}: ${T_IFACE} ${T_LOCAL_TUN_IP} -> ${T_REMOTE_TUN_IP} (KHAREJ ${T_REMOTE_IP})"
    echo "# Managed by ngre - do not edit by hand"
    IFS=',' read -ra specs <<<"$T_PORTS"
    for spec in "${specs[@]}"; do
        [[ -n "$spec" ]] && spec_to_stream "$spec" "$T_REMOTE_TUN_IP"
    done
}

# Target ports on the KHAREJ side for a port list (for tests). Ranges -> first & last.
spec_targets() {
    local spec specs
    IFS=',' read -ra specs <<<"$1"
    for spec in "${specs[@]}"; do
        parse_spec "$spec" || continue
        if [[ -n "$PS_TARGET" ]]; then echo "$PS_TARGET"
        elif (( PS_LFROM == PS_LTO )); then echo "$PS_LFROM"
        else echo "$PS_LFROM"; echo "$PS_LTO"
        fi
    done | awk '!seen[$0]++'
}

# Ports currently listening on this server (tcp + udp)
listening_ports() {
    ssq -ltnu 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un
}

# Listen ports used by all ngre IRAN tunnels (optionally excluding one tunnel name)
ngre_listen_ports() {
    local exclude="$1" f spec specs p
    local save_role="$T_ROLE" save_ports="$T_PORTS"
    for f in "$TUN_DIR"/iran*.conf; do
        [[ -f "$f" ]] || continue
        [[ -n "$exclude" && "$f" == "$TUN_DIR/${exclude}.conf" ]] && continue
        local ports
        ports="$(grep -E '^PORTS=' "$f" | head -1 | cut -d= -f2- | tr -d '"')"
        IFS=',' read -ra specs <<<"$ports"
        for spec in "${specs[@]}"; do
            parse_spec "$spec" || continue
            for (( p = PS_LFROM; p <= PS_LTO; p++ )); do echo "$p"; done
        done
    done
    T_ROLE="$save_role"; T_PORTS="$save_ports"
}

# Validate a comma separated list of specs.
#   validate_ports "<input>" "<existing specs to keep>" "<tunnel name being edited>"
# On success sets VALID_PORTS (canonical, comma separated, new specs only)
validate_ports() {
    local input="${1// /}" keep="$2" editing="$3" spec specs p bad=0
    VALID_PORTS=""
    [[ -z "$input" ]] && { colorize red "    No ports entered."; return 1; }
    declare -A busy=() taken=()
    while read -r p; do [[ -n "$p" ]] && busy[$p]=1; done < <(listening_ports)
    while read -r p; do [[ -n "$p" ]] && taken[$p]="ngre"; done < <(ngre_listen_ports "$editing")
    # ports of the specs we keep on this tunnel are allowed to stay busy but not to be reused
    IFS=',' read -ra specs <<<"$keep"
    for spec in "${specs[@]}"; do
        parse_spec "$spec" || continue
        for (( p = PS_LFROM; p <= PS_LTO; p++ )); do taken[$p]="this tunnel"; done
    done
    local out=()
    IFS=',' read -ra specs <<<"$input"
    for spec in "${specs[@]}"; do
        [[ -z "$spec" ]] && continue
        local shown="${spec//[^0-9A-Za-z.:=,-]/?}"
        if ! parse_spec "$spec"; then
            colorize red "    [ERROR] Invalid port mapping '$shown': $PS_ERR"
            bad=1; continue
        fi
        if [[ -n "$PS_BIND" && "$PS_BIND" != 127.* ]] && ! ip_is_local "$PS_BIND"; then
            colorize red "    [ERROR] '$shown': IP $PS_BIND is not assigned to this server"
            bad=1; continue
        fi
        local conflict=""
        for (( p = PS_LFROM; p <= PS_LTO; p++ )); do
            if [[ -n "${taken[$p]}" ]]; then conflict="port $p is already used by ${taken[$p]}"; break; fi
            if [[ -n "${busy[$p]}" ]]; then conflict="port $p is already in use on this server ($(port_owner "$p"))"; break; fi
        done
        if [[ -n "$conflict" ]]; then
            colorize red "    [ERROR] '$shown': $conflict"
            bad=1; continue
        fi
        for (( p = PS_LFROM; p <= PS_LTO; p++ )); do taken[$p]="mapping '$spec'"; done
        out+=("$(spec_canonical)")
    done
    (( bad )) && return 1
    (( ${#out[@]} == 0 )) && { colorize red "    No valid ports entered."; return 1; }
    local total=0
    total=${#taken[@]}
    if (( total > MAX_TOTAL_PORTS )); then
        colorize red "    [ERROR] Too many ports: $total in total (max $MAX_TOTAL_PORTS for all tunnels together)."
        return 1
    fi
    VALID_PORTS="$(IFS=','; echo "${out[*]}")"
    return 0
}

port_owner() {
    ssq -ltnup 2>/dev/null | awk -v p="$1" '{n=split($5,a,":"); if (a[n]==p) {print $7; exit}}' \
        | sed -E 's/users:\(\("([^"]+)".*/\1/' | head -1 | tr -cd 'A-Za-z0-9._:-' | sed 's/^$/unknown process/'
}

# ============================================================================
#  Firewall (ufw / firewalld / plain iptables)
#   - Only asks and opens what the tunnel needs, tagged "ngre-<name>"
#   - Removing a tunnel removes exactly the rules ngre added for it
# ============================================================================
# iptables that waits for the xtables lock: at boot all tunnel units start in
# parallel, and without waiting iptables fails ("holding the xtables lock")
IPT_WAIT=""
ipt() {
    if [[ -z "$IPT_WAIT" ]]; then
        if iptables -w 5 -S INPUT >/dev/null 2>&1; then IPT_WAIT="seconds"
        elif iptables -w -S INPUT >/dev/null 2>&1; then IPT_WAIT="flag"
        else IPT_WAIT="none"
        fi
    fi
    case "$IPT_WAIT" in
        seconds) iptables -w 5 "$@" ;;
        flag)    iptables -w "$@" ;;
        *)       iptables "$@" ;;
    esac
}

fw_detect() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo ufw; return
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo firewalld; return
    fi
    if command -v iptables >/dev/null 2>&1 && \
       ipt -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
        echo iptables; return
    fi
    echo none
}

fw_tag() { echo "ngre-${T_NAME}"; }

# Emits "proto port-or-range bind" lines for the IRAN listen ports
fw_port_items() {
    [[ "$T_ROLE" == "iran" ]] || return 0
    local spec specs rng
    IFS=',' read -ra specs <<<"$T_PORTS"
    for spec in "${specs[@]}"; do
        parse_spec "$spec" || continue
        [[ "$PS_BIND" == 127.* ]] && continue
        if (( PS_LFROM == PS_LTO )); then rng="$PS_LFROM"; else rng="$PS_LFROM:$PS_LTO"; fi
        echo "tcp $rng ${PS_BIND:--}"
        echo "udp $rng ${PS_BIND:--}"
    done
}

# Everything the loaded tunnel needs through the firewall, one item per line:
#   gre  <peer public IP>                    GRE packets from the other server
#   tun  <iface> <peer tunnel IP>            traffic inside the tunnel - only from
#                                            the peer's tunnel address, so packets
#                                            forged into the GRE link are not let in
#   port <tcp|udp> <port|from:to> <bind|->   IRAN listen ports
fw_items() {
    echo "gre $T_REMOTE_IP"
    echo "tun $T_IFACE $T_REMOTE_TUN_IP"
    fw_port_items | sed 's/^/port /'
}

# ---- plain iptables (rules tagged with a comment, applied by the tunnel unit)
fw_iptables_args() {
    local kind a b c
    read -r kind a b c <<<"$1"
    case "$kind" in
        gre)  echo "-p gre -s $a" ;;
        tun)  echo "-i $a -s $b" ;;
        port) if [[ "$c" == "-" ]]; then echo "-p $a --dport $b"; else echo "-p $a -d $c --dport $b"; fi ;;
    esac
}

# Tagged rules of this tunnel, as printed by "iptables -S"
fw_iptables_tagged() {
    ipt -S INPUT 2>/dev/null | grep -E -- "--comment \"?$(fw_tag)\"? " | tr -d '"'
}

# Make the tagged rules exactly match the tunnel's items. New rules are inserted
# first and the old ones deleted afterwards: no moment without the rules.
fw_iptables_up() {
    local tag item rule rc=0
    local -a old=() args=()
    command -v iptables >/dev/null 2>&1 || return 1
    tag="$(fw_tag)"
    mapfile -t old < <(fw_iptables_tagged)
    while read -r item; do
        [[ -z "$item" ]] && continue
        read -ra args <<<"$(fw_iptables_args "$item")"
        ipt -I INPUT "${args[@]}" -m comment --comment "$tag" -j ACCEPT 2>/dev/null || rc=1
    done < <(fw_items)
    for rule in "${old[@]}"; do
        read -ra args <<<"${rule/-A INPUT/-D INPUT}"
        [[ "${args[0]}" == "-D" ]] && ipt "${args[@]}" 2>/dev/null
    done
    return "$rc"
}

fw_iptables_down() {
    local rule
    local -a args=()
    command -v iptables >/dev/null 2>&1 || return 0
    while read -r rule; do
        read -ra args <<<"${rule/-A INPUT/-D INPUT}"
        [[ "${args[0]}" == "-D" ]] && ipt "${args[@]}" 2>/dev/null
    done < <(fw_iptables_tagged)
    return 0
}

# ---- ufw (persistent rules with comment "ngre-<name>")
# ufw arguments in the exact form "ufw show added" prints them
fw_ufw_args() {
    local kind a b c
    read -r kind a b c <<<"$1"
    case "$kind" in
        gre)  echo "allow from $a proto gre" ;;
        tun)  echo "allow in on $a from $b" ;;
        port) if [[ "$c" == "-" ]]; then echo "allow $b/$a"; else echo "allow to $c port $b proto $a"; fi ;;
    esac
}

# "ufw show added" lines tagged for this tunnel, without the comment
fw_ufw_tagged() {
    awk -v s=" comment '$(fw_tag)'" 'length($0) > length(s) && substr($0, length($0) - length(s) + 1) == s {
        print substr($0, 1, length($0) - length(s)) }'
}

# Make the ufw rules of this tunnel exactly match its items:
#  - a rule that already exists (the admin's own, or another tunnel's) is left
#    alone: ufw would otherwise re-tag it as ours and removing the tunnel would
#    delete it
#  - missing rules are added first, rules no longer needed are deleted after
fw_ufw_open() {
    local tag item args line added failed="" gre_failed=0
    local -a a=()
    declare -A want=()
    command -v ufw >/dev/null 2>&1 || return 1
    tag="$(fw_tag)"
    added="$(ufw show added 2>/dev/null)"
    while read -r item; do
        [[ -z "$item" ]] && continue
        args="$(fw_ufw_args "$item")"; line="ufw $args"
        want[$line]=1
        awk -v l="$line" 'BEGIN { p = l " comment \047" } $0 == l || index($0, p) == 1 { f = 1 } END { exit !f }' \
            <<<"$added" && continue
        read -ra a <<<"$args"
        if ! ufw "${a[@]}" comment "$tag" >/dev/null 2>&1; then
            if [[ "$item" == gre* ]]; then gre_failed=1; else failed+=" ${args#allow }"; fi
        fi
    done < <(fw_items)
    while read -r line; do
        [[ -z "$line" || -n "${want[$line]:-}" ]] && continue
        read -ra a <<<"${line#ufw }"
        [[ "${a[0]}" == "allow" ]] && ufw --force delete "${a[@]}" >/dev/null 2>&1
    done < <(fw_ufw_tagged <<<"$added")
    if (( gre_failed )); then
        warn "ufw could not add the GRE rule (ufw older than 0.36 has no 'gre' protocol)."
        warn "Add this line before COMMIT in /etc/ufw/before.rules and run 'ufw reload':"
        echo "      -A ufw-before-input -p gre -s $T_REMOTE_IP -j ACCEPT"
        log WARN "ufw GRE rule failed for ${T_NAME}"
    fi
    if [[ -n "$failed" ]]; then
        warn "ufw could not add:${failed}"
        log WARN "ufw rules failed for ${T_NAME}:${failed}"
    fi
    return 0
}

# Deletes every ufw rule tagged for this tunnel. "ufw show added" lists the
# rules even when ufw is disabled, so nothing is left behind.
fw_ufw_close() {
    local line
    local -a a=()
    command -v ufw >/dev/null 2>&1 || return 0
    while read -r line; do
        [[ -z "$line" ]] && continue
        read -ra a <<<"${line#ufw }"
        [[ "${a[0]}" == "allow" ]] && ufw --force delete "${a[@]}" >/dev/null 2>&1
    done < <(ufw show added 2>/dev/null | fw_ufw_tagged)
    return 0
}

# ---- firewalld (permanent rules; $FW_DIR/<name>.firewalld remembers the
#      entries Ngre itself added, so only those are ever removed)
fw_firewalld_entries() {
    local kind a b c
    while read -r kind a b c; do
        case "$kind" in
            gre)  echo "rich|rule family=\"ipv4\" source address=\"$a\" protocol value=\"gre\" accept" ;;
            tun)  echo "rich|rule family=\"ipv4\" source address=\"$b\" accept" ;;
            port) if [[ "$c" == "-" ]]; then echo "port|${b/:/-}/$a"
                  else echo "rich|rule family=\"ipv4\" destination address=\"$c\" port port=\"${b/:/-}\" protocol=\"$a\" accept"
                  fi ;;
        esac
    done < <(fw_items)
}

# fw_firewalld_cmd add|remove|query ENTRY
fw_firewalld_cmd() {
    local op="$1" kind="${2%%|*}" val="${2#*|}"
    case "$kind" in
        rich)  firewall-cmd --permanent "--${op}-rich-rule=$val" ;;
        port)  firewall-cmd --permanent "--${op}-port=$val" ;;
        iface) firewall-cmd --permanent --zone=trusted "--${op}-interface=$val" ;;   # older Ngre versions
        *)     return 1 ;;
    esac >/dev/null 2>&1
}

fw_firewalld_open() {
    local list="$FW_DIR/${T_NAME}.firewalld" e failed=""
    local -a mine=() plan=() todo=()
    declare -A was=() want=()
    command -v firewall-cmd >/dev/null 2>&1 || return 1
    if [[ -f "$list" ]]; then
        while IFS= read -r e; do [[ -n "$e" ]] && was[$e]=1; done < "$list"
    fi
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        want[$e]=1
        if fw_firewalld_cmd query "$e"; then
            [[ -n "${was[$e]:-}" ]] && mine+=("$e")   # ours; someone else's is left alone
        else
            todo+=("$e")
        fi
    done < <(fw_firewalld_entries)
    # record first (a crash in between must never leave unrecorded rules behind)
    plan=("${mine[@]}" "${todo[@]}")
    for e in "${!was[@]}"; do [[ -z "${want[$e]:-}" ]] && plan+=("$e"); done
    printf '%s\n' "${plan[@]}" | write_atomic "$list" 600 || { warn "Cannot write $list"; return 1; }
    for e in "${todo[@]}"; do
        if fw_firewalld_cmd add "$e"; then mine+=("$e"); else failed+=" ${e#*|}"; fi
    done
    for e in "${!was[@]}"; do
        [[ -z "${want[$e]:-}" ]] && fw_firewalld_cmd remove "$e"
    done
    printf '%s\n' "${mine[@]}" | write_atomic "$list" 600
    firewall-cmd --reload >/dev/null 2>&1
    if [[ -n "$failed" ]]; then
        warn "firewalld could not add:${failed}"
        log WARN "firewalld rules failed for ${T_NAME}:${failed}"
    fi
    return 0
}

fw_firewalld_close() {
    local list="$FW_DIR/${T_NAME}.firewalld" e
    [[ -f "$list" ]] || return 0
    if command -v firewall-cmd >/dev/null 2>&1; then
        while IFS= read -r e; do [[ -n "$e" ]] && fw_firewalld_cmd remove "$e"; done < "$list"
        firewall-cmd --reload >/dev/null 2>&1
    fi
    rm -f "$list"
}

# ---- common entry points
# fw_open: make the firewall match the loaded tunnel (add missing, drop unneeded)
fw_open() {
    case "$T_FIREWALL" in
        ufw)       fw_ufw_open ;;
        firewalld) fw_firewalld_open ;;
        # iptables rules exist only while the tunnel service runs (added by its unit)
        iptables)  if systemctl is-active --quiet "$T_UNIT" 2>/dev/null; then fw_iptables_up; fi ;;
    esac
}

fw_close() {
    case "$T_FIREWALL" in
        ufw)       fw_ufw_close ;;
        firewalld) fw_firewalld_close ;;
        iptables)  fw_iptables_down ;;
    esac
}

# Remove every rule tagged for tunnel NAME, whether or not its config still exists
fw_purge_name() {
    local T_NAME="$1"
    fw_iptables_down
    fw_ufw_close
    fw_firewalld_close
}

# Names of tunnels that still have firewall rules (iptables / ufw / firewalld lists)
fw_tagged_names() {
    local f n
    {
        command -v iptables >/dev/null 2>&1 && \
            ipt -S INPUT 2>/dev/null | grep -oE -- '--comment "?ngre-(iran|kharej)[0-9]+"? ' | grep -oE '(iran|kharej)[0-9]+'
        command -v ufw >/dev/null 2>&1 && \
            ufw show added 2>/dev/null | grep -oE " comment 'ngre-(iran|kharej)[0-9]+'\$" | grep -oE '(iran|kharej)[0-9]+'
        for f in "$FW_DIR"/*.firewalld; do
            [[ -f "$f" ]] || continue
            n="${f##*/}"; echo "${n%.firewalld}"
        done
    } | sort -u | while read -r n; do is_tunnel_name "$n" && echo "$n"; done
}

# After a tunnel is removed: tunnels to the same server may have shared its GRE
# rule (ufw / firewalld keep one copy) - make sure theirs are complete again
fw_reassert_peers() {
    local removed="$1" rip="$2" f
    while read -r f; do
        load_tunnel "$f" || continue
        [[ "$T_NAME" != "$removed" && "$T_REMOTE_IP" == "$rip" ]] || continue
        case "$T_FIREWALL" in ufw|firewalld) fw_open >/dev/null 2>&1 ;; esac
    done < <(list_tunnel_files)
}

# Ask the user during setup (sets T_FIREWALL)
fw_choose() {
    local mode what
    mode="$(fw_detect)"
    if [[ "$mode" == "none" ]]; then
        T_FIREWALL="none"
        return 0
    fi
    what="GRE from $T_REMOTE_IP and traffic from $T_REMOTE_TUN_IP on $T_IFACE"
    [[ "$T_ROLE" == "iran" ]] && what="$what, plus the tunnel ports ($T_PORTS)"
    echo
    colorize yellow "[*] Firewall detected: $mode (active)"
    echo    "    Ngre needs to allow: $what"
    if confirm "Add these firewall rules (tagged ngre-${T_NAME})?" Y; then
        T_FIREWALL="$mode"
    else
        T_FIREWALL="skip"
        warn "Firewall left unchanged - make sure GRE (protocol 47) from $T_REMOTE_IP is allowed."
    fi
}

# ============================================================================
#  Helper units: watchdog, traffic collector, logrotate
# ============================================================================
write_wd_unit() {
    write_atomic "$SERVICE_DIR/$WD_SERVICE.service" <<EOF
# Managed by ngre - do not edit by hand
[Unit]
Description=Ngre watchdog (restarts GRE tunnels that stop answering)
After=network.target
ConditionPathExists=$NGRE_BIN

[Service]
Type=simple
ExecStart=$NGRE_BIN _watchdog
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_traffic_units() {
    write_atomic "$SERVICE_DIR/$TRAFFIC_UNIT.service" <<EOF
# Managed by ngre - do not edit by hand
[Unit]
Description=Ngre traffic accounting
ConditionPathExists=$NGRE_BIN

[Service]
Type=oneshot
ExecStart=$NGRE_BIN _collect
EOF
    write_atomic "$SERVICE_DIR/$TRAFFIC_UNIT.timer" <<EOF
# Managed by ngre - do not edit by hand
[Unit]
Description=Ngre traffic accounting (every minute)

[Timer]
OnActiveSec=1min
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
}

write_logrotate() {
    [[ -d /etc/logrotate.d ]] || return 0
    write_atomic "$LOGROTATE_FILE" <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

# Keep helper services in line with the number of tunnels and settings
services_sync() {
    load_global
    write_wd_unit
    write_traffic_units
    write_logrotate
    systemctl daemon-reload
    if (( $(tunnel_count) > 0 )); then
        unit_enable_start "$TRAFFIC_UNIT.timer"
        if (( WATCHDOG_ENABLED )); then
            systemctl enable "$WD_SERVICE" >/dev/null 2>&1
            unit_now restart "$WD_SERVICE"
        else
            unit_disable_stop "$WD_SERVICE"
        fi
    else
        unit_disable_stop "$TRAFFIC_UNIT.timer" "$WD_SERVICE"
    fi
}

# Repair leftovers of an interrupted operation (power loss, kill -9, ...):
#  - units / nginx files without a tunnel config are removed
#  - tunnel configs without a unit get their unit back
#  - nginx stream files are rebuilt when they differ from the tunnel config
# Prints one line per repair. Must be called inside a critical section.
reconcile_state() {
    local f u n ngx_needed=0 reload=0
    for u in "$SERVICE_DIR"/ngre-iran*.service "$SERVICE_DIR"/ngre-kharej*.service; do
        [[ -f "$u" ]] || continue
        n="${u##*/}"; n="${n#ngre-}"; n="${n%.service}"
        is_tunnel_name "$n" || continue
        if [[ ! -f "$(tunnel_conf "$n")" ]]; then
            unit_disable_stop "ngre-$n"
            fw_purge_name "$n"
            rm -f "$u"; reload=1
            echo "removed orphan service ngre-$n"
            log WARN "Repair: removed orphan service ngre-$n"
        fi
    done
    rm -f "$NGX_STREAMS"/*.conf.bak 2>/dev/null
    for f in "$TUN_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        n="${f##*/}"; n="${n%.conf}"
        if ! is_tunnel_name "$n" || ! load_tunnel "$f"; then
            echo "WARNING: invalid tunnel config ignored: $f (fix or remove it)"
            log WARN "Invalid tunnel config ignored: $f"
        fi
    done
    # firewall rules left behind by a tunnel whose config is gone
    for n in $(fw_tagged_names); do
        if [[ ! -f "$(tunnel_conf "$n")" ]]; then
            fw_purge_name "$n"
            echo "removed firewall rules of deleted tunnel $n"
            log WARN "Repair: removed firewall rules of deleted tunnel $n"
        fi
    done
    for f in "$NGX_STREAMS"/*.conf; do
        [[ -f "$f" ]] || continue
        n="${f##*/}"; n="${n%.conf}"
        if [[ "$n" != iran* ]] || ! is_tunnel_name "$n" || [[ ! -f "$(tunnel_conf "$n")" ]]; then
            rm -f "$f"; ngx_needed=1
            echo "removed orphan nginx config $n"
            log WARN "Repair: removed orphan nginx config $n"
        fi
    done
    while read -r f; do
        load_tunnel "$f" || continue
        if [[ ! -f "$SERVICE_DIR/${T_UNIT}.service" ]]; then
            write_tunnel_unit && systemctl daemon-reload && unit_enable_start "$T_UNIT"
            echo "restored service ${T_UNIT}"
            log WARN "Repair: restored missing service ${T_UNIT}"
        fi
        if [[ "$T_ROLE" == "iran" ]] && command -v nginx >/dev/null 2>&1; then
            local sf="$NGX_STREAMS/${T_NAME}.conf"
            if [[ ! -f "$sf" || "$(gen_stream_file)" != "$(cat "$sf")" ]]; then
                gen_stream_file | write_atomic "$sf" 600; ngx_needed=1
                echo "rebuilt nginx config of ${T_NAME}"
                log WARN "Repair: rebuilt nginx config of ${T_NAME}"
            fi
        fi
    done < <(list_tunnel_files)
    local l
    for l in "$SERVICE_DIR"/*.wants/ngre-*; do
        if [[ -L "$l" && ! -e "$l" ]]; then
            rm -f "$l"; reload=1
            echo "removed dangling link ${l##*/}"
            log WARN "Repair: removed dangling link $l"
        fi
    done
    (( reload )) && systemctl daemon-reload
    if (( ngx_needed )); then
        if (( $(stream_files_count) > 0 )); then
            if ! { write_ngx_conf && write_ngx_unit && ngx_apply >/dev/null 2>&1; }; then
                echo "nginx engine could not be (re)started - see: ngre -> 7 -> 3"
                log ERROR "Repair: ngx_apply failed: ${NGX_LAST_ERROR//$'\n'/ | }"
            fi
        else
            ngx_apply >/dev/null 2>&1
        fi
    fi
    return 0
}

startup_repair() {
    local out
    # a crash during "apt install nginx" must never leave our temporary policy-rc.d behind
    if [[ -f /usr/sbin/policy-rc.d ]] && grep -q 'ngre-temporary' /usr/sbin/policy-rc.d 2>/dev/null; then
        # nginx got installed while our block was in place (the install was cut
        # off before Ngre could switch the system nginx off): do that now, so it
        # does not start on port 80 at the next boot
        local dl
        for dl in /var/lib/dpkg/info/nginx-common.list /var/lib/dpkg/info/nginx.list; do
            if [[ -f "$dl" && "$dl" -nt /usr/sbin/policy-rc.d ]] && ! systemctl is-active --quiet nginx 2>/dev/null \
               && systemctl is-enabled --quiet nginx 2>/dev/null; then
                systemctl disable nginx >/dev/null 2>&1
                log WARN "Repair: system nginx.service (installed by an interrupted Ngre setup) disabled"
                break
            fi
        done
        rm -f /usr/sbin/policy-rc.d
        log WARN "Repair: removed leftover temporary /usr/sbin/policy-rc.d"
    fi
    clean_stale_tmp
    [[ -d "$TUN_DIR" ]] || return 0
    lock_acquire || return 0
    trap '' INT HUP QUIT TERM
    out="$(reconcile_state)"
    critical_end
    if [[ -n "$out" ]]; then
        colorize yellow "Ngre startup check (repaired leftovers / warnings):" bold
        echo "$out" | sed 's/^/  - /'
        sleep 2
    fi
}

# Rewrite all generated units (used after updating the script)
regen_all() {
    local f
    while read -r f; do
        load_tunnel "$f" || continue
        write_tunnel_unit
        # firewall rules in the current format (older versions allowed all traffic on the GRE interface)
        case "$T_FIREWALL" in
            ufw|firewalld) fw_open >/dev/null 2>&1 ;;
            iptables) fw_open ;;
        esac
    done < <(list_tunnel_files)
    local ngx_written=0
    if (( $(iran_tunnel_count) > 0 )) && command -v nginx >/dev/null 2>&1; then
        write_ngx_conf && write_ngx_unit && ngx_written=1
    fi
    services_sync
    if (( ngx_written )) && systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null && ngx_test >/dev/null; then
        systemctl reload "$NGX_SERVICE" >/dev/null 2>&1
    fi
}

# ============================================================================
#  Header
# ============================================================================
SERVER_IP=""

display_logo() {
    echo -e "${CYAN}"
    cat << "EOF"
    _   _  ____ ____  _____
   | \ | |/ ___|  _ \| ____|
   |  \| | |  _| |_) |  _|
   | |\  | |_| |  _ <| |___
   |_| \_|\____|_| \_\_____|

      GRE + Nginx tunnel manager
EOF
    echo -e "${NC}${GREEN}Script Version: ${YELLOW}${SCRIPT_VERSION}${NC}"
}

display_server_info() {
    local total=0 up=0 ir=0 kh=0 f
    while read -r f; do
        [[ -z "$f" ]] && continue
        load_tunnel "$f" || continue
        total=$((total + 1))
        [[ "$T_ROLE" == "iran" ]] && ir=$((ir + 1)) || kh=$((kh + 1))
        iface_up "$T_IFACE" && up=$((up + 1))
    done < <(list_tunnel_files)

    line
    echo -e "${CYAN}IP Address:${NC}    ${SERVER_IP:-unknown}"
    echo -e "${CYAN}Hostname:${NC}      $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"
    if (( total == 0 )); then
        echo -e "${CYAN}Tunnels:${NC}       ${YELLOW}none yet${NC}"
    else
        local c=$GREEN; (( up < total )) && c=$YELLOW; (( up == 0 )) && c=$RED
        echo -e "${CYAN}Tunnels:${NC}       ${c}${up}/${total} up${NC}  (IRAN: $ir, KHAREJ: $kh)"
    fi
    if (( ir > 0 )); then
        if systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null; then
            echo -e "${CYAN}Nginx engine:${NC}  ${GREEN}running${NC}"
        else
            echo -e "${CYAN}Nginx engine:${NC}  ${RED}stopped${NC}"
        fi
    fi
    if (( total > 0 )); then
        load_global
        if (( WATCHDOG_ENABLED == 0 )); then
            echo -e "${CYAN}Watchdog:${NC}      ${YELLOW}disabled${NC}"
        elif systemctl is-active --quiet "$WD_SERVICE" 2>/dev/null; then
            echo -e "${CYAN}Watchdog:${NC}      ${GREEN}running${NC} (every ${WATCHDOG_INTERVAL}s, restart after ${WATCHDOG_FAILS} fails)"
        else
            echo -e "${CYAN}Watchdog:${NC}      ${RED}not running${NC}"
        fi
    fi
    line
}

display_menu() {
    cls
    display_logo
    display_server_info
    echo
    colorize green " 1. Configure a new tunnel [IRAN/KHAREJ]" bold
    colorize red   " 2. Tunnel management menu" bold
    colorize cyan  " 3. Check tunnels status" bold
    echo -e " 4. Live bandwidth monitor"
    echo -e " 5. Traffic statistics"
    echo -e " 6. Watchdog settings"
    echo -e " 7. View logs"
    echo -e " 8. Update script"
    echo -e " 9. Uninstall Ngre"
    echo -e " 0. Exit"
    echo
    echo "-------------------------------"
}

# ============================================================================
#  1) Configure a new tunnel
# ============================================================================
configure_tunnel() {
    cls
    echo
    colorize green   "1) Configure for IRAN server" bold
    colorize magenta "2) Configure for KHAREJ server" bold
    echo
    local configure_choice
    echo -ne "Enter your choice: "; ask configure_choice || return
    case "$configure_choice" in
        1) setup_tunnel iran ;;
        2) setup_tunnel kharej ;;
        *) echo -e "${RED}Invalid option!${NC}" && sleep 1; return ;;
    esac
    press_key
}

print_port_formats() {
    colorize green "[*] Supported Port Formats:" bold
    echo "1. 443-600             - Listen on all ports in the range 443 to 600 (forward to the same port)."
    echo "2. 443-600:5201        - Listen on all ports in the range 443 to 600 and forward traffic to 5201."
    echo "3. 443                 - Listen on local port 443 and forward to remote port 443."
    echo "4. 4000=5000           - Listen on local port 4000 and forward to remote port 5000."
    echo "5. 127.0.0.2:443=5201  - Bind to local IP 127.0.0.2, listen on port 443 and forward to remote port 5201."
    echo -e "${DIM}   Every port is forwarded for both TCP and UDP through the GRE tunnel.${NC}"
    echo
}

# Is there any GRE tunnel (running, or a stopped Ngre one) between these IPs?
pair_in_use() {
    local lip="$1" peer="$2" existing f
    existing="$(gre_pair_in_use "$lip" "$peer")"
    if [[ -z "$existing" ]]; then
        for f in "$TUN_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -qx "REMOTE_IP=\"$peer\"" "$f" && grep -qx "LOCAL_IP=\"$lip\"" "$f"; then
                existing="$(grep -E '^IFACE=' "$f" | cut -d'"' -f2) (Ngre tunnel, stopped)"
                break
            fi
        done
    fi
    echo "$existing"
}

setup_tunnel() {
    local role="$1" peer_label other_label tport peer lip auto mtu input
    if [[ "$role" == "iran" ]]; then peer_label="KHAREJ"; other_label="IRAN"; else peer_label="IRAN"; other_label="KHAREJ"; fi

    cls
    colorize cyan "Configuring ${other_label} server" bold
    echo

    # --- Tunnel port (tunnel ID) ---
    while true; do
        echo -ne "[*] Tunnel port: "
        ask tport || return 1
        if ! is_port "$tport"; then
            colorize red "Please enter a valid port number between 1 and 65535."
            echo -e "${DIM}    (The tunnel port is the tunnel ID - use the same number on both servers.)${NC}"
            echo
            continue
        fi
        tport=$((10#$tport))
        if [[ -f "$(tunnel_conf "iran$tport")" || -f "$(tunnel_conf "kharej$tport")" ]]; then
            colorize red "Tunnel port $tport already exists on this server. Choose another one."
            echo; continue
        fi
        if [[ -d "/sys/class/net/$(tunnel_iface "$tport")" ]]; then
            colorize red "Interface $(tunnel_iface "$tport") already exists on this server. Choose another tunnel port."
            echo; continue
        fi
        break
    done
    echo

    # --- Peer IP ---
    while true; do
        echo -ne "[*] ${peer_label} server IP address: "
        ask peer || return 1
        peer="${peer// /}"
        if ! is_ipv4 "$peer"; then
            colorize red "Please enter a valid IPv4 address."
            echo; continue
        fi
        if ! is_usable_ipv4 "$peer"; then
            colorize red "$peer is not a usable server address."
            echo; continue
        fi
        if in_tunnel_range "$peer"; then
            colorize red "$peer is inside 10.64.0.0/14, the range Ngre uses for tunnel addresses. Enter the server's real IP."
            echo; continue
        fi
        if ip_is_local "$peer"; then
            colorize red "$peer belongs to this server. Enter the IP of the ${peer_label} server."
            echo; continue
        fi
        break
    done
    echo

    # --- Local IP ---
    auto="$(detect_local_ip_for "$peer")"
    [[ -z "$auto" ]] && auto="$SERVER_IP"
    while true; do
        echo -ne "[-] This server IP (default ${auto}): "
        ask lip || return 1
        lip="${lip// /}"
        lip="${lip:-$auto}"
        if ! is_usable_ipv4 "$lip" || in_tunnel_range "$lip"; then
            colorize red "Please enter a valid IPv4 address of this server."
            echo; continue
        fi
        if [[ "$lip" == "$peer" ]]; then
            colorize red "This server and the ${peer_label} server cannot have the same IP."
            echo; continue
        fi
        if ! ip_is_local "$lip"; then
            colorize yellow "    $lip is not assigned to any interface of this server."
            colorize yellow "    GRE needs a local address (if the server is behind NAT, use its private IP)."
            confirm "Use $lip anyway?" N || { echo; continue; }
        fi
        break
    done
    echo

    # --- Only one keyless GRE tunnel per IP pair ---
    local existing
    existing="$(pair_in_use "$lip" "$peer")"
    if [[ -n "$existing" ]]; then
        colorize red "A GRE tunnel between $lip and $peer already exists: $existing" bold
        echo "Linux allows only one GRE tunnel (without key) between the same two IPs."
        local eif="${existing%% *}"
        if grep -qx "IFACE=\"$eif\"" "$TUN_DIR"/*.conf 2>/dev/null; then
            echo "It is managed by Ngre: use 'Tunnel management menu' -> that tunnel -> 'Add ports' (on the IRAN side)."
        else
            echo "Remove that tunnel first, or use another server."
        fi
        return 1
    fi

    # --- MTU ---
    while true; do
        echo -ne "[-] MTU (default ${DEFAULT_MTU}): "
        ask mtu || return 1
        mtu="${mtu:-$DEFAULT_MTU}"
        if [[ "$mtu" =~ ^[0-9]{3,4}$ ]] && (( 10#$mtu >= 576 && 10#$mtu <= 1500 )); then
            mtu=$((10#$mtu))
            (( mtu > DEFAULT_MTU )) && colorize yellow "    Note: GRE adds 24 bytes; above ${DEFAULT_MTU} packets may get fragmented."
            break
        fi
        colorize red "Please enter a valid MTU value between 576 and 1500."
        echo
    done
    echo

    # --- Ports (IRAN only) ---
    local ports=""
    if [[ "$role" == "iran" ]]; then
        print_port_formats
        while true; do
            echo -ne "[*] Enter your ports in the specified formats (separated by commas, default ${tport}): "
            ask input || return 1
            input="${input:-$tport}"
            if validate_ports "$input" "" ""; then
                ports="$VALID_PORTS"
                break
            fi
            echo
        done
        echo
    fi

    # --- Build tunnel values ---
    reset_tunnel_vars
    tun_ips "$tport"
    T_ROLE="$role"
    T_TUNNEL_PORT="$tport"
    T_IFACE="$(tunnel_iface "$tport")"
    T_LOCAL_IP="$lip"
    T_REMOTE_IP="$peer"
    if [[ "$role" == "iran" ]]; then
        T_LOCAL_TUN_IP="$TUN_IRAN_IP"; T_REMOTE_TUN_IP="$TUN_KHAREJ_IP"
    else
        T_LOCAL_TUN_IP="$TUN_KHAREJ_IP"; T_REMOTE_TUN_IP="$TUN_IRAN_IP"
    fi
    T_MTU="$mtu"
    T_PORTS="$ports"
    T_NAME="$(tunnel_name "$role" "$tport")"
    T_UNIT="$(tunnel_unit "$T_NAME")"
    T_CONF="$(tunnel_conf "$T_NAME")"

    # warn if the derived /30 overlaps something already on this server
    if ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxE "${TUN_KHAREJ_IP//./\\.}|${TUN_IRAN_IP//./\\.}"; then
        colorize red "The tunnel addresses $TUN_NET are already used on this server. Choose another tunnel port."
        return 1
    fi

    # the /30 must not hide a network this server already routes to (e.g. a provider LAN)
    local overlap
    overlap="$(ip -4 route show match "$TUN_KHAREJ_IP" 2>/dev/null | grep -v '^default' | head -1)"
    if [[ -n "$overlap" ]]; then
        colorize yellow "    Warning: $TUN_NET overlaps an existing route on this server:"
        echo "      $overlap"
        echo "      Hosts of that network inside $TUN_NET would become unreachable."
        confirm "Continue anyway? (or choose another tunnel port)" N || return 1
    fi

    # --- Summary ---
    line
    echo -e "${CYAN}Role:${NC}          ${other_label}"
    echo -e "${CYAN}Tunnel port:${NC}   ${T_TUNNEL_PORT}   (interface ${T_IFACE}, service ${T_UNIT})"
    echo -e "${CYAN}This server:${NC}   ${T_LOCAL_IP}"
    echo -e "${CYAN}$(printf '%-15s' "${peer_label} server:")${NC}${T_REMOTE_IP}"
    echo -e "${CYAN}Tunnel IPs:${NC}    ${T_LOCAL_TUN_IP} (this)  <->  ${T_REMOTE_TUN_IP} (${peer_label,,})   [${TUN_NET}]"
    echo -e "${CYAN}MTU / TTL:${NC}     ${T_MTU} / ${GRE_TTL}"
    [[ "$role" == "iran" ]] && echo -e "${CYAN}Ports:${NC}         ${T_PORTS}  (TCP + UDP)"
    line
    confirm "Create this tunnel?" Y || { colorize yellow "Canceled."; return 0; }

    fw_choose
    create_tunnel
}

# Removes everything of the loaded tunnel without questions (used for rollback)
purge_tunnel_quiet() {
    unit_disable_stop "$T_UNIT"
    fw_close
    [[ "$T_ROLE" == "iran" ]] && stream_remove "$T_NAME"
    rm -f "$SERVICE_DIR/${T_UNIT}.service" "$T_CONF"
    ip tunnel del "$T_IFACE" >/dev/null 2>&1
    systemctl daemon-reload
}

create_tunnel() {
    local peer_label other_choice role_label out
    if [[ "$T_ROLE" == "iran" ]]; then peer_label="KHAREJ"; role_label="IRAN"; other_choice="2 (KHAREJ)"
    else peer_label="IRAN"; role_label="KHAREJ"; other_choice="1 (IRAN)"
    fi

    echo
    colorize cyan "Creating tunnel ${T_NAME} ..." bold
    # packages first, outside the critical section: nothing of Ngre is changed
    # yet, so Ctrl+C can still cancel a slow download
    if [[ "$T_ROLE" == "iran" ]] && ! ensure_nginx; then
        return 1
    fi
    critical_begin || return 1

    # re-check everything under the lock: another ngre session may have changed things
    if [[ -f "$(tunnel_conf "iran$T_TUNNEL_PORT")" || -f "$(tunnel_conf "kharej$T_TUNNEL_PORT")" \
          || -d "/sys/class/net/$T_IFACE" ]]; then
        fail "Tunnel port ${T_TUNNEL_PORT} is already in use on this server."
        critical_end; return 1
    fi
    if [[ -n "$(pair_in_use "$T_LOCAL_IP" "$T_REMOTE_IP")" ]]; then
        fail "A GRE tunnel between ${T_LOCAL_IP} and ${T_REMOTE_IP} already exists."
        critical_end; return 1
    fi
    if [[ "$T_ROLE" == "iran" ]] && ! out="$(validate_ports "$T_PORTS" "" "")"; then
        fail "Some ports are no longer free:"
        echo "$out"
        critical_end; return 1
    fi
    T_CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
    if ! tunnel_vars_valid; then
        fail "Internal check failed: invalid tunnel values. Nothing was changed."
        critical_end; return 1
    fi

    gre_kernel_ready || warn "Could not confirm the ip_gre kernel module (trying anyway)."

    if ! save_tunnel "$T_CONF"; then
        fail "Could not write ${T_CONF} (disk full?). Nothing was changed."
        critical_end; return 1
    fi
    ensure_gre_autoload
    if ! write_tunnel_unit; then
        fail "Could not write the systemd unit (disk full?). Nothing was changed."
        rm -f "$T_CONF"; critical_end; return 1
    fi
    systemctl daemon-reload

    if ! unit_enable_start "${T_UNIT}.service" || ! tunnel_running; then
        fail "The tunnel service failed to start:"
        local jl
        # (the "delete tunnel ... No such device" lines are the harmless clean-up
        #  before the start - they must not be mistaken for a missing GRE module)
        jl="$(journalctl -u "$T_UNIT" -n 10 --no-pager -o cat 2>/dev/null | grep -v 'delete tunnel')"
        echo "$jl" | tail -n 6 | safe_text | sed 's/^/      /'
        if grep -qiE 'No such device|Operation not supported|not permitted' <<<"$jl"; then
            warn "GRE seems unsupported on this server's kernel (common on OpenVZ/LXC VPS)."
        elif grep -qi 'File exists' <<<"$jl"; then
            warn "A tunnel with the same addresses already exists."
        fi
        purge_tunnel_quiet
        log ERROR "Tunnel ${T_NAME} creation failed; rolled back"
        critical_end; return 1
    fi
    ok "GRE interface ${T_IFACE} is up (${T_LOCAL_TUN_IP}/30, MTU ${T_MTU})"

    case "$T_FIREWALL" in
        ufw|firewalld) fw_open; ok "Firewall rules added (${T_FIREWALL}, tag ngre-${T_NAME})" ;;
        iptables)
            if [[ -n "$(fw_iptables_tagged)" ]]; then
                ok "Firewall rules added (iptables, applied with the tunnel service)"
            else
                warn "iptables rules could not be added - allow GRE from ${T_REMOTE_IP} yourself."
                log WARN "iptables rules missing after start of ${T_UNIT}"
            fi ;;
        skip)          warn "Firewall not changed (your choice)" ;;
    esac

    if [[ "$T_ROLE" == "iran" ]]; then
        if stream_apply_current; then
            ok "Nginx stream config OK, listening on all ports (service ${NGX_SERVICE})"
        else
            fail "nginx could not use the configuration:"
            echo "$NGX_LAST_ERROR" | tail -n 6 | safe_text | sed 's/^/      /'; selinux_hint
            purge_tunnel_quiet
            log ERROR "Tunnel ${T_NAME} creation failed at nginx step; rolled back"
            critical_end; return 1
        fi
    fi
    ok "Service ${T_UNIT} enabled (starts on boot)"

    services_sync
    load_global
    (( WATCHDOG_ENABLED )) && ok "Watchdog active (every ${WATCHDOG_INTERVAL}s)"
    ok "Traffic accounting active"
    log INFO "Tunnel ${T_NAME} created: ${T_LOCAL_IP} <-> ${T_REMOTE_IP}, ${T_IFACE} ${T_LOCAL_TUN_IP}/30, MTU ${T_MTU}, ports '${T_PORTS}', firewall ${T_FIREWALL}"
    critical_end

    # --- quick test ---
    echo
    info "Testing the tunnel ..."
    local rtt
    rtt="$(tunnel_ping_ms "$T_REMOTE_TUN_IP" 3)"
    if [[ -n "$rtt" ]]; then
        ok "Ping ${peer_label} through tunnel (${T_REMOTE_TUN_IP}): ${rtt} ms"
    else
        warn "No reply from ${peer_label} (${T_REMOTE_TUN_IP}) yet - normal if the other side is not configured."
    fi

    echo
    colorize green "${role_label} server configuration completed successfully." bold
    echo
    colorize yellow "Next steps:" bold
    local my_ip="$T_LOCAL_IP"
    is_private_ipv4 "$T_LOCAL_IP" && my_ip="<public IP of this server>"
    if [[ -z "$rtt" ]]; then
        echo "  On the ${peer_label} server run: ngre -> 1 -> ${other_choice}"
        echo "  and enter  Tunnel port: ${T_TUNNEL_PORT}   ${role_label} server IP: ${my_ip}"
        is_private_ipv4 "$T_LOCAL_IP" && \
            echo "  (${T_LOCAL_IP} is a private address - the other server must use this server's public IP)"
    fi
    if [[ "$T_ROLE" == "iran" ]]; then
        local spec specs pub=() loc=()
        IFS=',' read -ra specs <<<"$T_PORTS"
        for spec in "${specs[@]}"; do
            if [[ "$spec" == 127.* ]]; then loc+=("$spec"); else pub+=("$spec"); fi
        done
        (( ${#pub[@]} )) && echo "  Clients connect to this server (${my_ip}) on port(s): $(IFS=','; echo "${pub[*]}")"
        (( ${#loc[@]} )) && echo "  Only reachable from this server itself (bound to 127.x): $(IFS=','; echo "${loc[*]}")"
        echo "  The service on KHAREJ (e.g. Xray inbound) must listen on 0.0.0.0 on the target port(s)."
    else
        echo "  Your service (e.g. Xray inbound) must listen on 0.0.0.0 (or ${T_LOCAL_TUN_IP}) on the target port(s)."
    fi
}

# ============================================================================
#  2) Tunnel management
# ============================================================================
status_dot() {
    if iface_up "$T_IFACE"; then echo -e "${GREEN}● up${NC}"
    elif systemctl is-enabled --quiet "$T_UNIT" 2>/dev/null; then echo -e "${RED}● down${NC}"
    else echo -e "${YELLOW}● stopped${NC}"
    fi
}

tunnel_management() {
    local files=() f idx=1 choice all=0
    all="$(list_tunnel_files | wc -l)"
    mapfile -t files < <(list_valid_tunnel_files)
    if (( ${#files[@]} == 0 )); then
        echo
        colorize red "No tunnels found. Create one with option 1." bold
        (( all > 0 )) && warn "$all tunnel config file(s) in $TUN_DIR could not be read."
        press_key
        return
    fi

    cls
    colorize cyan "List of existing tunnels to manage:" bold
    echo
    for f in "${files[@]}"; do
        load_tunnel "$f" || continue
        local r="${GREEN}Iran${NC}  "; [[ "$T_ROLE" == "kharej" ]] && r="${MAGENTA}Kharej${NC}"
        echo -e "${MAGENTA}${idx}${NC}) ${r} tunnel, Tunnel port: ${YELLOW}${T_TUNNEL_PORT}${NC}  (${T_IFACE} -> ${T_REMOTE_IP})  $(status_dot)"
        idx=$((idx + 1))
    done
    (( all > ${#files[@]} )) && { echo; warn "$(( all - ${#files[@]} )) tunnel config file(s) in $TUN_DIR could not be read and are not listed."; }
    echo
    while true; do
        echo -ne "Enter your choice (0 to return): "
        ask choice || return
        [[ "$choice" == "0" || -z "$choice" ]] && return
        if num_in "$choice" 1 "${#files[@]}"; then choice=$((10#$choice)); break; fi
        colorize red "Invalid choice. Please enter a number between 1 and ${#files[@]}." bold
    done
    load_tunnel "${files[$((choice - 1))]}" && tunnel_actions
}

tunnel_actions() {
    local conf="$T_CONF" c
    while true; do
        load_tunnel "$conf" || return
        cls
        colorize cyan "Tunnel ${T_NAME}  [${T_ROLE^^}]  ${T_IFACE}  ${T_LOCAL_IP} <-> ${T_REMOTE_IP}" bold
        echo -e "Status: $(status_dot)    Tunnel IPs: ${T_LOCAL_TUN_IP} <-> ${T_REMOTE_TUN_IP}    MTU: ${T_MTU}"
        [[ "$T_ROLE" == "iran" ]] && echo -e "Ports:  ${T_PORTS}"
        echo
        colorize cyan "List of available commands for ${T_NAME}:" bold
        echo
        colorize red    " 1) Remove this tunnel"
        colorize yellow " 2) Restart this tunnel"
        if systemctl is-enabled --quiet "$T_UNIT" 2>/dev/null; then
            echo " 3) Stop this tunnel"
        else
            echo " 3) Start this tunnel"
        fi
        if [[ "$T_ROLE" == "iran" ]]; then
            echo " 4) Add ports"
            echo " 5) Remove ports"
        fi
        echo " 6) Change MTU"
        echo " 7) Test this tunnel"
        echo " 8) View details"
        echo " 9) View service logs"
        echo
        echo -ne "Enter your choice (0 to return): "; ask c || return
        case "$c" in
            1) remove_tunnel_menu && return ;;
            2) restart_tunnel ;;
            3) toggle_tunnel ;;
            4) if [[ "$T_ROLE" == "iran" ]]; then add_ports; else echo -e "${RED}Invalid option!${NC}"; sleep 1; fi ;;
            5) if [[ "$T_ROLE" == "iran" ]]; then remove_ports; else echo -e "${RED}Invalid option!${NC}"; sleep 1; fi ;;
            6) change_mtu ;;
            7) test_tunnel ;;
            8) tunnel_details ;;
            9) tunnel_logs ;;
            0|"") return ;;
            *) echo -e "${RED}Invalid option!${NC}" && sleep 1 ;;
        esac
    done
}

remove_tunnel_menu() {
    echo
    confirm "Remove tunnel ${T_NAME} (${T_IFACE} <-> ${T_REMOTE_IP})?" N || return 1
    local wipe=0 name="$T_NAME"
    [[ -d "$TRAFFIC_DIR/$T_NAME" ]] && confirm "Delete its traffic statistics too?" N && wipe=1
    critical_begin || { press_key; return 1; }
    if ! load_tunnel "$T_CONF"; then
        critical_end; colorize red "Tunnel ${name} no longer exists."; press_key; return 0
    fi
    backup_file "$T_CONF" "${T_NAME}.conf"
    unit_disable_stop "$T_UNIT"
    fw_close
    [[ "$T_ROLE" == "iran" ]] && stream_remove "$T_NAME"
    rm -f "$SERVICE_DIR/${T_UNIT}.service" "$T_CONF" "$FW_DIR/${T_NAME}.firewalld"
    ip tunnel del "$T_IFACE" >/dev/null 2>&1
    systemctl daemon-reload
    [[ "$T_FIREWALL" == "ufw" || "$T_FIREWALL" == "firewalld" ]] && ( fw_reassert_peers "$T_NAME" "$T_REMOTE_IP" )
    (( wipe )) && rm -rf "${TRAFFIC_DIR:?}/${T_NAME:?}"
    services_sync
    log INFO "Tunnel ${T_NAME} removed"
    critical_end
    echo
    colorize green "Tunnel ${T_NAME} removed successfully!" bold
    if [[ "$T_ROLE" == "iran" ]]; then
        info "Remember to remove tunnel port ${T_TUNNEL_PORT} on the KHAREJ server too."
    else
        info "Remember to remove tunnel port ${T_TUNNEL_PORT} on the IRAN server too."
    fi
    press_key
    return 0
}

restart_tunnel() {
    echo
    colorize yellow "Restarting ${T_UNIT} ..." bold
    critical_begin || { press_key; return; }
    if unit_now restart "$T_UNIT" && tunnel_running; then
        critical_end
        log INFO "Tunnel ${T_NAME} restarted manually"
        ok "Tunnel restarted"
        local rtt; rtt="$(tunnel_ping_ms "$T_REMOTE_TUN_IP" 3)"
        if [[ -n "$rtt" ]]; then ok "Ping through tunnel: ${rtt} ms"; else warn "No reply from ${T_REMOTE_TUN_IP} yet"; fi
    else
        critical_end
        fail "Restart failed:"
        journalctl -u "$T_UNIT" -n 6 --no-pager -o cat 2>/dev/null | safe_text | sed 's/^/      /'
    fi
    press_key
}

toggle_tunnel() {
    echo
    if systemctl is-enabled --quiet "$T_UNIT" 2>/dev/null; then
        confirm "Stop tunnel ${T_NAME}? (it will stay stopped after reboot until you start it)" N || return
        critical_begin || { press_key; return; }
        unit_disable_stop "$T_UNIT"
        critical_end
        log INFO "Tunnel ${T_NAME} stopped manually"
        ok "Tunnel stopped (watchdog ignores stopped tunnels)"
    else
        critical_begin || { press_key; return; }
        if unit_enable_start "$T_UNIT" && tunnel_running; then
            critical_end
            log INFO "Tunnel ${T_NAME} started manually"
            ok "Tunnel started"
        else
            critical_end
            fail "Start failed:"
            journalctl -u "$T_UNIT" -n 6 --no-pager -o cat 2>/dev/null | safe_text | sed 's/^/      /'
        fi
    fi
    press_key
}

# Apply a new port list to the loaded IRAN tunnel (nginx + firewall) with rollback
# Change the port list of the loaded IRAN tunnel (nginx + firewall) with rollback.
#   apply_ports "<specs to add>" "<specs to remove>"
# Works on the current config (re-read under the lock) and re-validates new ports.
apply_ports() {
    local add="$1" remove="$2" old new out spec specs keep=()
    critical_begin || return 1
    if ! load_tunnel "$T_CONF"; then
        fail "This tunnel no longer exists."; critical_end; return 1
    fi
    old="$T_PORTS"
    declare -A drop=()
    IFS=',' read -ra specs <<<"$remove"
    for spec in "${specs[@]}"; do [[ -n "$spec" ]] && drop[$spec]=1; done
    IFS=',' read -ra specs <<<"$old"
    for spec in "${specs[@]}"; do [[ -n "$spec" && -z "${drop[$spec]}" ]] && keep+=("$spec"); done
    if [[ -n "$add" ]]; then
        if ! out="$(validate_ports "$add" "$(IFS=','; echo "${keep[*]}")" "$T_NAME")"; then
            fail "Ports are not available (anymore):"
            echo "$out"
            critical_end; return 1
        fi
        IFS=',' read -ra specs <<<"$add"
        keep+=("${specs[@]}")
    fi
    if (( ${#keep[@]} == 0 )); then
        fail "At least one port mapping must remain."
        critical_end; return 1
    fi
    new="$(IFS=','; echo "${keep[*]}")"
    [[ "$new" == "$old" ]] && { info "Nothing changed."; critical_end; return 0; }

    backup_file "$T_CONF" "${T_NAME}.conf"
    T_PORTS="$new"
    if ! save_tunnel "$T_CONF"; then
        T_PORTS="$old"
        fail "Could not write ${T_CONF} (disk full?). Nothing was changed."
        critical_end; return 1
    fi
    if stream_apply_current; then
        fw_open       # adds the new ports first, then drops the removed ones
        log INFO "Tunnel ${T_NAME} ports changed: '${old}' -> '${new}'"
        ok "Ports updated: ${new}"
        critical_end
        return 0
    fi
    fail "nginx could not use the new ports, nothing was changed:"
    echo "$NGX_LAST_ERROR" | tail -n 6 | safe_text | sed 's/^/      /'; selinux_hint
    T_PORTS="$old"
    save_tunnel "$T_CONF"      # firewall was not touched yet
    critical_end
    return 1
}

add_ports() {
    cls
    colorize cyan "Add ports to tunnel ${T_NAME}" bold
    echo -e "Current ports: ${YELLOW}${T_PORTS:-none}${NC}"
    echo
    print_port_formats
    local input
    while true; do
        echo -ne "[*] Enter new ports (separated by commas, 0 to cancel): "
        ask input || return
        [[ "$input" == "0" || -z "$input" ]] && return
        validate_ports "$input" "$T_PORTS" "$T_NAME" && break
        echo
    done
    echo
    apply_ports "$VALID_PORTS" ""
    press_key
}

remove_ports() {
    cls
    colorize cyan "Remove ports from tunnel ${T_NAME}" bold
    echo
    local specs=() i sel rm_list=() n nums=()
    IFS=',' read -ra specs <<<"$T_PORTS"
    if (( ${#specs[@]} <= 1 )); then
        colorize yellow "This tunnel has only one port mapping (${T_PORTS}). Add another one first, or remove the tunnel."
        press_key; return
    fi
    for i in "${!specs[@]}"; do
        echo -e "${MAGENTA}$((i + 1))${NC}) ${specs[$i]}"
    done
    echo
    echo -ne "Enter the numbers to remove (separated by commas, 0 to cancel): "
    ask sel || return
    [[ "$sel" == "0" || -z "$sel" ]] && return
    declare -A seen=()
    IFS=',' read -ra nums <<<"${sel// /}"
    for n in "${nums[@]}"; do
        [[ -z "$n" ]] && continue
        if num_in "$n" 1 "${#specs[@]}"; then
            n=$((10#$n))
            [[ -n "${seen[$n]}" ]] && continue
            seen[$n]=1
            rm_list+=("${specs[$((n - 1))]}")
        else
            colorize red "Invalid number: $n"; press_key; return
        fi
    done
    (( ${#rm_list[@]} == 0 )) && return
    if (( ${#rm_list[@]} >= ${#specs[@]} )); then
        colorize red "At least one port mapping must remain (or remove the whole tunnel)."
        press_key; return
    fi
    echo
    apply_ports "" "$(IFS=','; echo "${rm_list[*]}")"
    press_key
}

change_mtu() {
    echo
    local mtu
    while true; do
        echo -ne "[-] New MTU (current ${T_MTU}, default ${DEFAULT_MTU}, 0 to cancel): "
        ask mtu || return
        [[ "$mtu" == "0" ]] && return
        mtu="${mtu:-$DEFAULT_MTU}"
        [[ "$mtu" =~ ^[0-9]{3,4}$ ]] && (( 10#$mtu >= 576 && 10#$mtu <= 1500 )) && break
        colorize red "Please enter a valid MTU value between 576 and 1500."
    done
    mtu=$((10#$mtu))
    critical_begin || { press_key; return; }
    if ! load_tunnel "$T_CONF"; then critical_end; fail "This tunnel no longer exists."; press_key; return; fi
    if [[ "$mtu" == "$T_MTU" ]]; then critical_end; info "MTU unchanged."; press_key; return; fi
    backup_file "$T_CONF" "${T_NAME}.conf"
    local old_mtu="$T_MTU"
    T_MTU="$mtu"
    if ! save_tunnel "$T_CONF" || ! write_tunnel_unit; then
        T_MTU="$old_mtu"; save_tunnel "$T_CONF"; write_tunnel_unit
        critical_end
        fail "Could not save the new MTU (disk full?). Nothing was changed."
        press_key; return
    fi
    systemctl daemon-reload
    if iface_up "$T_IFACE"; then
        ip link set "$T_IFACE" mtu "$mtu" 2>/dev/null && ok "Applied live to ${T_IFACE} (no reconnect needed)"
    fi
    critical_end
    log INFO "Tunnel ${T_NAME} MTU set to ${mtu}"
    ok "MTU saved: ${mtu}"
    info "Use the same MTU on the other server (tunnel port ${T_TUNNEL_PORT})."
    press_key
}

test_tunnel() {
    cls
    colorize cyan "Testing tunnel ${T_NAME} (${T_IFACE})" bold
    echo
    local peer_label="KHAREJ"; [[ "$T_ROLE" == "kharej" ]] && peer_label="IRAN"

    if systemctl is-active --quiet "$T_UNIT" 2>/dev/null; then ok "Service ${T_UNIT} is active"
    else fail "Service ${T_UNIT} is not active (try: Restart this tunnel)"
    fi

    if iface_up "$T_IFACE"; then
        ok "Interface ${T_IFACE} is UP (MTU $(cat "/sys/class/net/$T_IFACE/mtu" 2>/dev/null))"
    else
        fail "Interface ${T_IFACE} is down or missing"
    fi

    local out loss avg
    out="$(ping -c 5 -i 0.3 -W 2 "$T_REMOTE_TUN_IP" 2>/dev/null)"
    loss="$(grep -oE '[0-9.]+% packet loss' <<<"$out" | cut -d% -f1)"
    avg="$(awk -F'/' '/^rtt|^round-trip/ {if ($5 < 1) printf "%.2f", $5; else printf "%.1f", $5}' <<<"$out")"
    if [[ -n "$avg" ]]; then
        ok "Ping ${peer_label} ${T_REMOTE_TUN_IP}: avg ${avg} ms, loss ${loss:-0}%"
        if ping -M "do" -s $(( T_MTU - 28 )) -c 2 -W 2 -q "$T_REMOTE_TUN_IP" >/dev/null 2>&1; then
            ok "Full-size packets (MTU ${T_MTU}) pass without fragmentation"
        else
            warn "Full-size packets (MTU ${T_MTU}) are dropped - try a lower MTU (e.g. 1420) on BOTH servers"
        fi
    else
        fail "No reply from ${peer_label} ${T_REMOTE_TUN_IP}"
        echo "      Check: the other server has tunnel port ${T_TUNNEL_PORT} configured,"
        echo "      GRE (protocol 47) is allowed by both firewalls / the datacenter."
    fi

    if [[ "$T_ROLE" == "iran" ]]; then
        echo
        if systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null; then ok "Nginx engine (${NGX_SERVICE}) is running"
        else fail "Nginx engine (${NGX_SERVICE}) is not running"
        fi
        local spec specs lp
        lp="$(ssq -ltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un)"
        IFS=',' read -ra specs <<<"$T_PORTS"
        for spec in "${specs[@]}"; do
            parse_spec "$spec" || continue
            if grep -qx "$PS_LFROM" <<<"$lp"; then ok "Port ${PS_LFROM} is listening ($spec)"
            else fail "Port ${PS_LFROM} is not listening ($spec)"
            fi
        done
        if [[ -n "$avg" ]]; then
            local tp
            while read -r tp; do
                [[ -z "$tp" ]] && continue
                if timeout 3 bash -c "exec 3<>/dev/tcp/${T_REMOTE_TUN_IP}/${tp}" 2>/dev/null; then
                    ok "KHAREJ service answers on ${T_REMOTE_TUN_IP}:${tp} (TCP)"
                else
                    warn "Nothing answers on KHAREJ port ${tp} (TCP) - is your service (e.g. Xray inbound) listening on 0.0.0.0:${tp}?"
                fi
            done < <(spec_targets "$T_PORTS")
        fi
    else
        echo
        info "TCP services on this server reachable through the tunnel:"
        ssq -ltn 2>/dev/null | awk '{print $4}' | grep -E "^(0\.0\.0\.0|\*|\[::\]|${T_LOCAL_TUN_IP//./\\.}):" \
            | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ' | sed 's/^/      ports: /'
        echo
    fi

    echo
    case "$T_FIREWALL" in
        none) info "Firewall: none detected at setup" ;;
        skip) warn "Firewall: not managed by ngre (skipped at setup)" ;;
        *)    info "Firewall: ${T_FIREWALL} (rules tagged ngre-${T_NAME})" ;;
    esac
    press_key
}

tunnel_details() {
    cls
    colorize cyan "Tunnel ${T_NAME} details" bold
    line
    echo -e "${CYAN}Role:${NC}              ${T_ROLE^^}"
    echo -e "${CYAN}Tunnel port (ID):${NC}  ${T_TUNNEL_PORT}"
    echo -e "${CYAN}Created:${NC}           ${T_CREATED}"
    echo -e "${CYAN}Interface:${NC}         ${T_IFACE}"
    echo -e "${CYAN}This server:${NC}       ${T_LOCAL_IP}"
    echo -e "${CYAN}Other server:${NC}      ${T_REMOTE_IP}"
    echo -e "${CYAN}Tunnel IPs:${NC}        ${T_LOCAL_TUN_IP} (this) <-> ${T_REMOTE_TUN_IP} (other)"
    echo -e "${CYAN}MTU / TTL:${NC}         ${T_MTU} / ${GRE_TTL}"
    echo -e "${CYAN}Firewall:${NC}          ${T_FIREWALL}"
    echo -e "${CYAN}Service:${NC}           ${T_UNIT}.service ($(systemctl is-active "$T_UNIT" 2>/dev/null))"
    echo -e "${CYAN}Config file:${NC}       ${T_CONF}"
    if [[ "$T_ROLE" == "iran" ]]; then
        echo -e "${CYAN}Nginx config:${NC}      ${NGX_STREAMS}/${T_NAME}.conf"
        echo -e "${CYAN}Port mappings:${NC}"
        local spec specs
        IFS=',' read -ra specs <<<"$T_PORTS"
        for spec in "${specs[@]}"; do
            parse_spec "$spec" || continue
            local l="$PS_LFROM" t
            (( PS_LFROM != PS_LTO )) && l="$PS_LFROM-$PS_LTO"
            if [[ -n "$PS_BIND" ]]; then l="$PS_BIND:$l"; else l="${T_LOCAL_IP}:$l"; fi
            if [[ -n "$PS_TARGET" ]]; then t="$PS_TARGET"; elif (( PS_LFROM == PS_LTO )); then t="$PS_LFROM"; else t="same port"; fi
            echo "      ${l}  ->  ${T_REMOTE_TUN_IP}:${t}   (TCP ${TCP_PROXY_TIMEOUT} / UDP ${UDP_PROXY_TIMEOUT})"
        done
    fi
    line
    colorize yellow "Equivalent manual commands:" bold
    echo "  ip tunnel add ${T_IFACE} mode gre local ${T_LOCAL_IP} remote ${T_REMOTE_IP} ttl ${GRE_TTL}"
    echo "  ip addr add ${T_LOCAL_TUN_IP}/30 dev ${T_IFACE}"
    echo "  ip link set ${T_IFACE} mtu ${T_MTU} up"
    press_key
}

tunnel_logs() {
    cls
    colorize cyan "Service log of ${T_UNIT} (last 30 lines)" bold
    journalctl -u "$T_UNIT" -n 40 --no-pager 2>/dev/null | grep -v 'delete tunnel ".*" failed: No such device' \
        | tail -n 30 | safe_text
    echo
    colorize cyan "Ngre events for ${T_NAME}" bold
    grep -wF "$T_NAME" "$LOG_FILE" 2>/dev/null | tail -n 15 | safe_text
    grep -F "[$T_NAME]" "$WD_LOG" 2>/dev/null | tail -n 10 | safe_text
    press_key
}

# ============================================================================
#  3) Status
# ============================================================================
check_tunnel_status() {
    local nopause="$1" files=() f i tmpd
    mapfile -t files < <(list_tunnel_files)
    [[ -z "$nopause" ]] && cls
    if (( ${#files[@]} == 0 )); then
        colorize red "No tunnels found." bold
        [[ -z "$nopause" ]] && press_key
        return
    fi
    colorize yellow "Checking all tunnels status..." bold
    echo
    local -a names=() peers=() valid=()
    for f in "${files[@]}"; do
        if load_tunnel "$f"; then valid+=("$f"); peers+=("$T_REMOTE_TUN_IP"); fi
    done
    tmpd="$(make_tmpdir)"
    parallel_ping "$tmpd" 1 "${peers[@]}"
    printf "%-7s %-7s %-10s %-16s %-15s %-9s %-6s %s\n" "PORT" "ROLE" "IFACE" "OTHER SERVER" "TUNNEL IP" "SERVICE" "LINK" "PING"
    for i in "${!valid[@]}"; do
        load_tunnel "${valid[$i]}" || continue
        local svc link ping_ms sc lc pc
        svc="$(systemctl is-active "$T_UNIT" 2>/dev/null)"
        [[ "$svc" == "active" ]] && sc=$GREEN || sc=$RED
        if iface_up "$T_IFACE"; then link="UP"; lc=$GREEN; else link="DOWN"; lc=$RED; fi
        ping_ms="$(cat "$tmpd/$i" 2>/dev/null)"
        if [[ -n "$ping_ms" ]]; then ping_ms="${ping_ms} ms"; pc=$GREEN; else ping_ms="no reply"; pc=$RED; fi
        printf "%-7s %-7s %-10s %-16s %-15s " "$T_TUNNEL_PORT" "${T_ROLE^^}" "$T_IFACE" "$T_REMOTE_IP" "$T_LOCAL_TUN_IP"
        printf "${sc}%-9s${NC} ${lc}%-6s${NC} ${pc}%s${NC}\n" "$svc" "$link" "$ping_ms"
        [[ "$T_ROLE" == "iran" ]] && echo -e "        ${DIM}ports: ${T_PORTS}${NC}"
    done
    rm -rf "${tmpd:?}"
    if (( $(iran_tunnel_count) > 0 )); then
        echo
        if systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null; then ok "Nginx engine (${NGX_SERVICE}) is running"
        else fail "Nginx engine (${NGX_SERVICE}) is not running - see: ngre -> 7 -> 3"
        fi
    fi
    [[ -z "$nopause" ]] && press_key
}

# ============================================================================
#  7) Logs
# ============================================================================
view_logs() {
    while true; do
        cls
        colorize cyan "Logs" bold
        echo
        echo " 1) Ngre events log (last 50 lines)"
        echo " 2) Watchdog log (last 50 lines)"
        echo " 3) Nginx engine error log (last 50 lines)"
        echo " 4) Tunnel service logs (journal)"
        echo " 5) Follow all Ngre logs live (Ctrl+C to stop)"
        echo " 6) Clear Ngre logs"
        echo " 0) Back"
        echo
        local c
        echo -ne "Enter your choice: "; ask c || return
        case "$c" in
            1) cls; colorize cyan "$LOG_FILE" bold; show_log "$LOG_FILE"; press_key ;;
            2) cls; colorize cyan "$WD_LOG" bold; show_log "$WD_LOG"; press_key ;;
            3) cls; colorize cyan "$NGX_ERR_LOG" bold; show_log "$NGX_ERR_LOG"; press_key ;;
            4) cls; journalctl -u 'ngre-*' -n 60 --no-pager 2>/dev/null | safe_text; press_key ;;
            5)
                cls
                colorize yellow "Following logs - press Ctrl+C to stop" bold
                touch "$LOG_FILE" "$WD_LOG" "$NGX_ERR_LOG" 2>/dev/null
                trap ':' INT
                tail -n 20 -F "$LOG_FILE" "$WD_LOG" "$NGX_ERR_LOG" 2>/dev/null | safe_text
                trap - INT
                ;;
            6)
                if confirm "Clear all Ngre log files?" N; then
                    : > "$LOG_FILE"; : > "$WD_LOG"; : > "$NGX_ERR_LOG"
                    log INFO "Logs cleared"
                    ok "Logs cleared"; sleep 1
                fi
                ;;
            0|"") return ;;
            *) echo -e "${RED}Invalid option!${NC}" && sleep 1 ;;
        esac
    done
}

# ============================================================================
#  9) Uninstall
# ============================================================================
uninstall_ngre() {
    cls
    colorize red "Uninstall Ngre" bold
    echo
    echo "This removes ALL Ngre tunnels, services, firewall rules added by Ngre and its settings."
    echo "The system nginx and /etc/nginx are not touched."
    echo "A backup of /etc/ngre is saved in /root before removal."
    echo
    local ans
    echo -ne "Type ${RED}yes${NC} to confirm: "
    ask ans || return
    [[ "$ans" == "yes" ]] || { colorize yellow "Canceled."; sleep 1; return; }

    critical_begin || { press_key; return; }
    local bk="/root/ngre-backup-$(date +%Y%m%d-%H%M%S).tar.gz" f
    tar czf "$bk" -C "$(dirname "$NGRE_DIR")" "$(basename "$NGRE_DIR")" 2>/dev/null && chmod 600 "$bk" && ok "Backup saved: $bk"
    while read -r f; do
        load_tunnel "$f" || continue
        unit_disable_stop "$T_UNIT"
        fw_close
        ip tunnel del "$T_IFACE" >/dev/null 2>&1
        rm -f "$SERVICE_DIR/${T_UNIT}.service"
        ok "Removed tunnel ${T_NAME}"
    done < <(list_tunnel_files)
    # tunnels whose config is broken or missing: their services keep running otherwise
    local u n
    for u in "$SERVICE_DIR"/ngre-iran*.service "$SERVICE_DIR"/ngre-kharej*.service; do
        [[ -f "$u" ]] || continue
        n="${u##*/}"; n="${n#ngre-}"; n="${n%.service}"
        is_tunnel_name "$n" || continue
        unit_disable_stop "ngre-$n"
        ip tunnel del "$(tunnel_iface "$(tunnel_port_of "$n")")" >/dev/null 2>&1
        rm -f "$u"
        ok "Removed tunnel $n (its config was unreadable)"
    done
    for n in $(fw_tagged_names); do fw_purge_name "$n"; done
    unit_disable_stop "$NGX_SERVICE" "$WD_SERVICE" "$TRAFFIC_UNIT.timer" "$TRAFFIC_UNIT.service"
    rm -f "$SERVICE_DIR/$NGX_SERVICE.service" "$SERVICE_DIR/$WD_SERVICE.service" \
          "$SERVICE_DIR/$TRAFFIC_UNIT.service" "$SERVICE_DIR/$TRAFFIC_UNIT.timer" \
          "$LOGROTATE_FILE" "$MODULES_LOAD_FILE"
    remove_dangling_wants
    systemctl daemon-reload
    systemctl reset-failed 'ngre-*' >/dev/null 2>&1
    rm -rf "${NGRE_DIR:?}" "${STATE_DIR:?}" "${LOG_DIR:?}"
    rm -f "$NGRE_BIN" "$LOCK_FILE"
    ok "Ngre services and settings removed"
    echo
    colorize green "Ngre has been uninstalled." bold
    exit 0
}

# ============================================================================
#  Watchdog daemon  (ngre _watchdog, run by ngre-watchdog.service)
#   Every WATCHDOG_INTERVAL seconds each enabled tunnel pings the other side.
#   After WATCHDOG_FAILS failed checks in a row the tunnel service is
#   restarted; if it keeps failing, restarts are spaced out (max 10 min).
# ============================================================================
# Non-blocking config lock for the watchdog: never act while a menu operation runs
wd_lock() {
    { exec 7>"$LOCK_FILE"; } 2>/dev/null || return 1
    flock -n 7 || { exec 7>&-; return 1; }
}
wd_unlock() {
    flock -u 7 2>/dev/null
    exec 7>&-
}

watchdog_loop() {
    declare -A fails=() last_restart=() backoff=() lastrx=()
    local f now wait b n rxnow alive engine_fail_logged=0 tmpd i
    local -a wf=() wpeer=()
    ssq -ltn >/dev/null 2>&1
    trap 'rm -rf "${tmpd:-/nonexistent}"; exit 0' TERM INT HUP
    clean_stale_tmp
    wd_log "watchdog started (pid $$)"
    # self-heal after a crash/power loss even if nobody opens the menu
    if wd_lock; then
        reconcile_state 2>/dev/null | while IFS= read -r l; do wd_log "[repair] $l"; done
        wd_unlock
    fi
    while true; do
        load_global
        if (( WATCHDOG_ENABLED == 0 )); then sleep 30; continue; fi

        # 1) enabled tunnels (tunnels stopped by the user are left alone)
        wf=(); wpeer=()
        while read -r f; do
            load_tunnel "$f" || continue
            if ! systemctl is-enabled --quiet "$T_UNIT" 2>/dev/null; then
                fails[$T_NAME]=0; continue
            fi
            wf+=("$f"); wpeer+=("$T_REMOTE_TUN_IP")
        done < <(list_tunnel_files)

        # 2) ping all of them at the same time
        tmpd="$(make_tmpdir)"
        parallel_ping "$tmpd" 2 "${wpeer[@]}"

        # 3) evaluate
        for i in "${!wf[@]}"; do
            f="${wf[$i]}"
            load_tunnel "$f" || continue
            n="$T_NAME"
            alive=0
            [[ -f "$tmpd/$i" ]] && alive=1
            # RX counter sampled after the ping, so replies to our own pings never
            # count as "traffic from the peer" in the next round
            rxnow="$(cat "/sys/class/net/$T_IFACE/statistics/rx_bytes" 2>/dev/null)"
            is_uint "$rxnow" || rxnow=-1
            if (( alive == 0 && rxnow >= 0 )) && [[ -n "${lastrx[$n]:-}" ]] && (( lastrx[$n] >= 0 && rxnow > lastrx[$n] )); then
                # no ping reply, but packets keep arriving from the peer (ICMP may be blocked)
                alive=1
            fi
            lastrx[$n]=$rxnow
            if (( alive )); then
                if (( ${fails[$n]:-0} >= WATCHDOG_FAILS )); then
                    wd_log "[$n] RECOVERED: ${T_REMOTE_TUN_IP} answers again"
                    log INFO "Watchdog: tunnel $n recovered"
                fi
                fails[$n]=0; backoff[$n]=0; unset "last_restart[$n]"
                continue
            fi
            fails[$n]=$(( ${fails[$n]:-0} + 1 ))
            (( fails[$n] == WATCHDOG_FAILS )) && \
                wd_log "[$n] DOWN: no reply from ${T_REMOTE_TUN_IP} (${WATCHDOG_FAILS} checks failed)"
            if (( fails[$n] >= WATCHDOG_FAILS )); then
                now=$(mono_s)
                b=${backoff[$n]:-0}
                wait=$(( WATCHDOG_INTERVAL * WATCHDOG_FAILS * (2 ** b) ))
                (( wait > 600 )) && wait=600
                # (uptime clock: the first restart must not wait for "uptime > wait")
                if { [[ -z "${last_restart[$n]:-}" ]] || (( now - last_restart[$n] >= wait )); } && wd_lock; then
                    # re-check: the user may have stopped or removed it meanwhile
                    if [[ -f "$f" ]] && systemctl is-enabled --quiet "$T_UNIT" 2>/dev/null; then
                        unit_now restart "$T_UNIT"
                        wd_log "[$n] restarted ${T_UNIT} (attempt $(( b + 1 )))"
                        log WARN "Watchdog restarted tunnel $n (no reply from ${T_REMOTE_TUN_IP})"
                        last_restart[$n]=$now
                        (( b < 6 )) && backoff[$n]=$(( b + 1 ))
                    fi
                    wd_unlock
                fi
            fi
        done
        rm -rf "${tmpd:?}"

        # keep the nginx engine alive on IRAN servers
        systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null && engine_fail_logged=0
        if (( $(stream_files_count) > 0 )) && ! systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null && wd_lock; then
            if (( $(stream_files_count) > 0 )) && ! systemctl is-active --quiet "$NGX_SERVICE" 2>/dev/null; then
                if unit_now restart "$NGX_SERVICE"; then
                    engine_fail_logged=0
                    wd_log "[engine] ${NGX_SERVICE} was not running - restarted"
                    log WARN "Watchdog restarted ${NGX_SERVICE}"
                elif (( engine_fail_logged == 0 )); then
                    wd_log "[engine] ${NGX_SERVICE} cannot start - see ${NGX_ERR_LOG}"
                    engine_fail_logged=1
                fi
            fi
            wd_unlock
        fi
        sleep "$WATCHDOG_INTERVAL"
    done
}

watchdog_settings() {
    while true; do
        load_global
        cls
        colorize cyan "Watchdog settings" bold
        line
        if (( WATCHDOG_ENABLED )); then
            echo -e "${CYAN}Status:${NC}                  ${GREEN}enabled${NC} (service: $(systemctl is-active "$WD_SERVICE" 2>/dev/null))"
        else
            echo -e "${CYAN}Status:${NC}                  ${YELLOW}disabled${NC}"
        fi
        echo -e "${CYAN}Check interval:${NC}          ${WATCHDOG_INTERVAL} seconds"
        echo -e "${CYAN}Failures before restart:${NC} ${WATCHDOG_FAILS}"
        line
        echo -e "${DIM}Every ${WATCHDOG_INTERVAL}s each tunnel pings the other side. After ${WATCHDOG_FAILS} failed checks"
        echo -e "in a row the tunnel is restarted; if it keeps failing, restarts are spaced out.${NC}"
        echo
        if (( WATCHDOG_ENABLED )); then echo " 1) Disable watchdog"; else echo " 1) Enable watchdog"; fi
        echo " 2) Change check interval"
        echo " 3) Change failures before restart"
        echo " 4) View watchdog log"
        echo " 0) Back"
        echo
        local c v
        echo -ne "Enter your choice: "; ask c || return
        case "$c" in
            1)
                WATCHDOG_ENABLED=$(( 1 - WATCHDOG_ENABLED ))
                save_global || warn "Could not save settings (disk full?)"; services_sync
                log INFO "Watchdog $( (( WATCHDOG_ENABLED )) && echo enabled || echo disabled )"
                ;;
            2)
                echo -ne "[-] Check interval in seconds (5-3600, current ${WATCHDOG_INTERVAL}): "
                ask v || return
                if num_in "$v" 5 3600; then
                    WATCHDOG_INTERVAL=$((10#$v)); save_global || warn "Could not save settings (disk full?)"; services_sync
                    log INFO "Watchdog interval set to ${WATCHDOG_INTERVAL}s"
                else
                    colorize red "Invalid value."; sleep 1
                fi
                ;;
            3)
                echo -ne "[-] Failed checks before restart (1-20, current ${WATCHDOG_FAILS}): "
                ask v || return
                if num_in "$v" 1 20; then
                    WATCHDOG_FAILS=$((10#$v)); save_global || warn "Could not save settings (disk full?)"; services_sync
                    log INFO "Watchdog failure threshold set to ${WATCHDOG_FAILS}"
                else
                    colorize red "Invalid value."; sleep 1
                fi
                ;;
            4) cls; show_log "$WD_LOG"; press_key ;;
            0|"") return ;;
            *) echo -e "${RED}Invalid option!${NC}" && sleep 1 ;;
        esac
    done
}

# ============================================================================
#  Traffic accounting  (ngre _collect, run every minute by ngre-traffic.timer
#  and right before a tunnel stops). Per tunnel and per day, kept on disk.
# ============================================================================
collect_one() {
    local d="$TRAFFIC_DIR/$T_NAME" sys="/sys/class/net/$T_IFACE/statistics"
    local rx tx key lkey="" lrx=0 ltx=0 drx dtx df crx=0 ctx=0
    mkdir -p "$d"
    [[ -r "$sys/rx_bytes" ]] || return 0
    rx="$(uint_or_zero "$(<"$sys/rx_bytes")")"; tx="$(uint_or_zero "$(<"$sys/tx_bytes")")"
    # counters reset when the interface is re-created or the server reboots
    key="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)-$(cat "/sys/class/net/$T_IFACE/ifindex" 2>/dev/null)"
    [[ -f "$d/last" ]] && read -r lrx ltx lkey < "$d/last"
    lrx="$(uint_or_zero "$lrx")"; ltx="$(uint_or_zero "$ltx")"
    if [[ "$key" != "$lkey" ]] || (( rx < lrx || tx < ltx )); then
        drx=$rx; dtx=$tx
    else
        drx=$(( rx - lrx )); dtx=$(( tx - ltx ))
    fi
    # day file first: if it cannot be written, "last" stays old and nothing is lost
    if (( drx > 0 || dtx > 0 )); then
        df="$d/$(date +%F)"
        [[ -f "$df" ]] && read -r crx ctx < "$df"
        crx="$(uint_or_zero "$crx")"; ctx="$(uint_or_zero "$ctx")"
        echo "$(( crx + drx )) $(( ctx + dtx ))" | write_atomic "$df" 600 || return 0
    fi
    echo "$rx $tx $key" | write_atomic "$d/last" 600
}

collect_traffic() {
    local only="$1" f
    mkdir -p "$TRAFFIC_DIR"
    exec 8>"$TRAFFIC_DIR/.lock" || return 0
    flock -w 20 8 || { exec 8>&-; return 0; }
    while read -r f; do
        load_tunnel "$f" || continue
        [[ -n "$only" && "$T_NAME" != "$only" ]] && continue
        collect_one
    done < <(list_tunnel_files)
    find "$TRAFFIC_DIR" -type f -name '20??-??-??' -mtime +400 -delete 2>/dev/null
    flock -u 8; exec 8>&-
}

# traffic_sum <name> <glob-prefix>  -> "rx tx"
traffic_sum() {
    local d="$TRAFFIC_DIR/$1" pfx="$2"
    cat "$d/$pfx"* 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {rx += $1; tx += $2} END {printf "%.0f %.0f\n", rx, tx}'
}

traffic_stats() {
    local files=() f
    while true; do
        mapfile -t files < <(list_valid_tunnel_files)
        cls
        colorize cyan "Traffic statistics" bold
        echo -e "${DIM}Collected every minute and kept across reboots.  RX = received from the other server, TX = sent to it.${NC}"
        echo
        if (( ${#files[@]} == 0 )); then colorize red "No tunnels found."; press_key; return; fi
        collect_traffic
        local today month
        today="$(date +%F)"; month="$(date +%Y-%m)"
        printf "%-4s %-10s %-7s %-25s %-25s %-25s\n" "#" "TUNNEL" "ROLE" "TODAY  RX / TX" "THIS MONTH  RX / TX" "TOTAL  RX / TX"
        local i=1 trx=0 ttx=0 mrx=0 mtx=0 arx=0 atx=0
        for f in "${files[@]}"; do
            load_tunnel "$f" || continue
            local a b c d e g
            read -r a b < <(traffic_sum "$T_NAME" "$today")
            read -r c d < <(traffic_sum "$T_NAME" "$month-")
            read -r e g < <(traffic_sum "$T_NAME" "20")
            printf "%-4s %-10s %-7s %-25s %-25s %-25s\n" "$i" "$T_IFACE" "${T_ROLE^^}" \
                "$(human_bytes "$a") / $(human_bytes "$b")" \
                "$(human_bytes "$c") / $(human_bytes "$d")" \
                "$(human_bytes "$e") / $(human_bytes "$g")"
            trx=$((trx + a)); ttx=$((ttx + b)); mrx=$((mrx + c)); mtx=$((mtx + d)); arx=$((arx + e)); atx=$((atx + g))
            i=$((i + 1))
        done
        if (( ${#files[@]} > 1 )); then
            printf "${BOLD}%-4s %-10s %-7s %-25s %-25s %-25s${NC}\n" "" "ALL" "" \
                "$(human_bytes "$trx") / $(human_bytes "$ttx")" \
                "$(human_bytes "$mrx") / $(human_bytes "$mtx")" \
                "$(human_bytes "$arx") / $(human_bytes "$atx")"
        fi
        echo
        echo " 1) Daily breakdown of a tunnel (last 30 days)"
        echo " 2) Reset statistics of a tunnel"
        echo " 0) Back"
        echo
        local c n
        echo -ne "Enter your choice: "; ask c || return
        case "$c" in
            1|2)
                echo -ne "Tunnel number (1-${#files[@]}): "
                ask n || return
                if ! num_in "$n" 1 "${#files[@]}"; then
                    colorize red "Invalid number."; sleep 1; continue
                fi
                n=$((10#$n))
                load_tunnel "${files[$((n - 1))]}" || continue
                if [[ "$c" == "1" ]]; then
                    cls
                    colorize cyan "Daily traffic of ${T_NAME} (${T_IFACE})" bold
                    printf "%-12s %-14s %-14s %-14s\n" "DAY" "RX" "TX" "TOTAL"
                    local day r t df days=()
                    for df in "$TRAFFIC_DIR/$T_NAME"/20??-??-??; do
                        [[ -f "$df" ]] && days+=("${df##*/}")
                    done
                    (( ${#days[@]} == 0 )) && echo "(no data yet)"
                    for day in $(printf '%s\n' "${days[@]}" | sort -r | head -30); do
                        read -r r t < "$TRAFFIC_DIR/$T_NAME/$day"
                        r="$(uint_or_zero "$r")"; t="$(uint_or_zero "$t")"
                        printf "%-12s %-14s %-14s %-14s\n" "$day" "$(human_bytes "$r")" "$(human_bytes "$t")" "$(human_bytes $((r + t)))"
                    done
                    press_key
                else
                    if confirm "Reset all statistics of ${T_NAME}?" N; then
                        rm -f "$TRAFFIC_DIR/$T_NAME"/20??-??-?? 2>/dev/null
                        log INFO "Traffic statistics of ${T_NAME} reset"
                        ok "Statistics reset"; sleep 1
                    fi
                fi
                ;;
            0|"") return ;;
            *) echo -e "${RED}Invalid option!${NC}" && sleep 1 ;;
        esac
    done
}

# ============================================================================
#  4) Live bandwidth monitor
# ============================================================================
live_monitor() {
    local files=() f
    mapfile -t files < <(list_tunnel_files)
    if (( ${#files[@]} == 0 )); then
        echo; colorize red "No tunnels found." bold
        [[ -t 0 ]] && press_key
        return
    fi
    local -a names=() ifaces=() roles=() peers=()
    declare -A prx=() ptx=()
    for f in "${files[@]}"; do
        load_tunnel "$f" || continue
        names+=("$T_NAME"); ifaces+=("$T_IFACE"); roles+=("${T_ROLE^^}"); peers+=("$T_REMOTE_TUN_IP")
    done

    read_counters() {
        local i s
        for i in "${!ifaces[@]}"; do
            s="/sys/class/net/${ifaces[$i]}/statistics"
            if [[ -r "$s/rx_bytes" ]]; then
                CUR_RX[$i]=$(<"$s/rx_bytes"); CUR_TX[$i]=$(<"$s/tx_bytes")
            else
                CUR_RX[$i]=-1; CUR_TX[$i]=-1
            fi
        done
    }

    declare -a CUR_RX=() CUR_TX=()
    local t0 t1 el key i
    read_counters
    for i in "${!ifaces[@]}"; do prx[$i]=${CUR_RX[$i]}; ptx[$i]=${CUR_TX[$i]}; done
    t0=$(mono_cs)
    tput civis 2>/dev/null
    LM_STOP=0
    trap 'LM_STOP=1' INT
    while (( LM_STOP == 0 )); do
        key=""
        read -rsn1 -t 1 key
        (( $? == 1 )) && break          # end of input (not a timeout): leave
        [[ "$key" == "q" || "$key" == "Q" ]] && break
        (( LM_STOP )) && break
        t1=$(mono_cs)
        el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{d = (b - a) / 100; if (d <= 0) d = 1; printf "%.2f", d}')
        t0=$t1
        read_counters
        # active connections per peer tunnel IP (TCP + connected UDP), one ss call
        local -A CONN=()
        local cpeer ccnt
        while read -r cpeer ccnt; do
            [[ -n "$cpeer" ]] && CONN[$cpeer]=$ccnt
        done < <(ssq -tun state established 2>/dev/null | awk '{p=$5; sub(/:[0-9]+$/, "", p); c[p]++} END {for (k in c) print k, c[k]}')
        local out="" srx=0 stx=0 sconn=0
        out+="$(printf '\033[H\033[2J')"
        out+="${CYAN}${BOLD} Ngre live bandwidth monitor${NC}    $(date '+%H:%M:%S')    ${DIM}press q to quit${NC}\n"
        out+="${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}\n"
        out+="$(printf '%-10s %-7s %-5s %13s %13s %11s %11s %6s' TUNNEL ROLE LINK 'IN (RX)' 'OUT (TX)' 'RX(up)' 'TX(up)' CONNS)\n"
        for i in "${!ifaces[@]}"; do
            local rxr txr link lc conns row
            if (( CUR_RX[i] < 0 )); then
                link="DOWN"; lc=$RED; rxr="-"; txr="-"; conns="-"
                row="$(printf '%-10s %-7s ' "${ifaces[$i]}" "${roles[$i]}")"
                out+="${row}${lc}$(printf '%-5s' "$link")${NC}$(printf ' %13s %13s %11s %11s %6s' "$rxr" "$txr" "-" "-" "$conns")\n"
                prx[$i]=-1; ptx[$i]=-1
                continue
            fi
            # interface just came (back) up: start measuring from now
            (( prx[$i] < 0 )) && { prx[$i]=${CUR_RX[$i]}; ptx[$i]=${CUR_TX[$i]}; }
            local drx=$(( CUR_RX[i] - prx[$i] )) dtx=$(( CUR_TX[i] - ptx[$i] ))
            (( drx < 0 )) && drx=0; (( dtx < 0 )) && dtx=0
            prx[$i]=${CUR_RX[$i]}; ptx[$i]=${CUR_TX[$i]}
            srx=$((srx + drx)); stx=$((stx + dtx))
            rxr="$(rate_fmt "$drx" "$el")"; txr="$(rate_fmt "$dtx" "$el")"
            conns="${CONN[${peers[$i]}]:-0}"
            sconn=$((sconn + conns))
            link="UP"; lc=$GREEN
            row="$(printf '%-10s %-7s ' "${ifaces[$i]}" "${roles[$i]}")"
            out+="${row}${lc}$(printf '%-5s' "$link")${NC}$(printf ' %13s %13s %11s %11s %6s' "$rxr" "$txr" "$(human_bytes "${CUR_RX[$i]}")" "$(human_bytes "${CUR_TX[$i]}")" "$conns")\n"
        done
        if (( ${#ifaces[@]} > 1 )); then
            out+="${BOLD}$(printf '%-10s %-7s %-5s %13s %13s %11s %11s %6s' ALL '' '' "$(rate_fmt "$srx" "$el")" "$(rate_fmt "$stx" "$el")" '' '' "$sconn")${NC}\n"
        fi
        out+="\n${DIM}IN = received from the other server, OUT = sent to it. RX/TX(up) = since the tunnel came up.${NC}\n"
        echo -ne "$out"
    done
    trap - INT
    tput cnorm 2>/dev/null
    unset -f read_counters
}

# ============================================================================
#  8) Update script
# ============================================================================
update_script() {
    echo
    if ! repo_configured; then
        colorize yellow "Online update is not configured (NGRE_REPO is not set in the script)." bold
        echo "Update manually: upload the new ngre.sh to the server and run:  bash ngre.sh"
        press_key
        return
    fi
    local url tmp new
    url="$(raw_url)"
    if ! command -v curl >/dev/null 2>&1; then
        fail "curl is not installed (apt install curl), or update manually: upload ngre.sh and run: bash ngre.sh"
        press_key; return
    fi
    tmp="$(mktemp)"
    info "Downloading $url ..."
    if ! download_script "$tmp"; then
        fail "Download failed (GitHub may be blocked on this server). Update manually: upload ngre.sh and run: bash ngre.sh"
        rm -f "$tmp"; press_key; return
    fi
    if ! script_complete "$tmp"; then
        fail "The downloaded file is not a valid Ngre script. Nothing changed."
        rm -f "$tmp"; press_key; return
    fi
    new="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
    echo -e "Current version: ${YELLOW}${SCRIPT_VERSION}${NC}   Latest version: ${GREEN}${new}${NC}"
    if [[ "$new" == "$SCRIPT_VERSION" ]]; then
        confirm "You already have the latest version. Reinstall anyway?" N || { rm -f "$tmp"; return; }
    else
        confirm "Install ${new}?" Y || { rm -f "$tmp"; return; }
    fi
    if ! install_atomic "$tmp"; then
        rm -f "$tmp"
        fail "Could not install the new version to $NGRE_BIN (disk full / read-only?). Nothing changed."
        press_key; return
    fi
    rm -f "$tmp"
    "$NGRE_BIN" _regen >/dev/null 2>&1
    log INFO "Script updated ${SCRIPT_VERSION} -> ${new}"
    ok "Updated to ${new}. Restarting ngre ..."
    sleep 1
    exec "$NGRE_BIN"
}

# ============================================================================
#  Main
# ============================================================================
usage() {
    cat <<EOF
Ngre ${SCRIPT_VERSION} - GRE + Nginx tunnel manager

Usage:
  ngre            open the menu
  ngre status     show the status of all tunnels
  ngre monitor    live bandwidth monitor
  ngre stats      traffic statistics
  ngre logs       last lines of the Ngre log
  ngre version    show the version
EOF
}

main_menu() {
    while true; do
        display_menu
        local choice
        echo -ne "Enter your choice [0-9]: "; ask choice || { echo; exit 0; }
        case "$choice" in
            1) configure_tunnel ;;
            2) tunnel_management ;;
            3) check_tunnel_status ;;
            4) live_monitor ;;
            5) traffic_stats ;;
            6) watchdog_settings ;;
            7) view_logs ;;
            8) update_script ;;
            9) uninstall_ngre ;;
            0) exit 0 ;;
            *) echo -e "${RED} Invalid option!${NC}" && sleep 1 ;;
        esac
    done
}

main() {
    case "${1:-}" in
        _watchdog) [[ $EUID -eq 0 ]] || exit 1; mkdir -p "$LOG_DIR"; watchdog_loop ;;
        _wait-net)
            # tunnel start at boot: wait (max 30 s) until this server's IP and a
            # route to the other server exist, then go on in any case
            is_ipv4 "${2:-}" && is_ipv4 "${3:-}" || exit 0
            local i
            for i in $(seq 1 30); do
                ip_is_local "$2" && ip -4 route get "$3" >/dev/null 2>&1 && exit 0
                sleep 1
            done
            exit 0 ;;
        _collect)
            [[ $EUID -eq 0 ]] || exit 1
            [[ -z "${2:-}" ]] || is_tunnel_name "$2" || exit 1
            collect_traffic "${2:-}" ;;
        _fw-up|_fw-down)
            [[ $EUID -eq 0 ]] && is_tunnel_name "${2:-}" || exit 0
            if load_tunnel "$(tunnel_conf "$2")"; then
                if [[ "$T_FIREWALL" == "iptables" ]]; then
                    if [[ "$1" == "_fw-up" ]]; then fw_iptables_up; else fw_iptables_down; fi
                fi
            elif [[ "$1" == "_fw-down" ]]; then
                T_NAME="$2"; fw_iptables_down    # config gone or broken: still remove its rules
            fi
            exit 0 ;;
        _regen)    preflight; lock_acquire && { regen_all; reconcile_state >/dev/null; lock_release; } ;;
        status)    preflight; check_tunnel_status nopause ;;
        monitor)   preflight; live_monitor ;;
        stats)     preflight; traffic_stats ;;
        logs)      show_log "$LOG_FILE" ;;
        version|-v|--version) echo "Ngre $SCRIPT_VERSION" ;;
        help|-h|--help) usage ;;
        "")
            if [[ ! -t 0 && -z "${NGRE_NONINTERACTIVE_OK:-}" ]]; then
                echo "Ngre is interactive. Start it like this:"
                start_hint
                exit 1
            fi
            source_check
            preflight
            self_install
            # the copy downloaded by "bash <(curl ...)" is installed now
            if [[ -n "${NGRE_BOOTSTRAPPED:-}" && "$(readlink -f "${BASH_SOURCE[0]}")" == /tmp/ngre-dl.* ]]; then
                rm -f "$(readlink -f "${BASH_SOURCE[0]}")"
            fi
            startup_repair
            SERVER_IP="$(detect_server_ip)"
            main_menu
            ;;
        *) usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
# ngre:eof
