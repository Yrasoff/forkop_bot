#!/bin/sh
# ==============================================================================
# Podkop Telegram Bot v0.13.90
#
# ARCHITECTURE OVERVIEW:
# Stateless long-polling Telegram bot for OpenWrt routers managing the
# 'podkop' package (sing-box wrapper). Written in strict POSIX ash.
#
# KEY SUBSYSTEMS:
# 1. 4-Tier Fallback Transport: SOCKS5 -> Custom Proxy -> Direct -> Emergency IPs
# 2. UCI Native Core: direct uci read/write, protected by flock
# 3. Dynamic State Machine: STATE_FILE for multi-step text inputs
# 4. Sub-Function Routing: _handle_proxy / _handle_settings / _handle_lists /
#    _handle_dns / _handle_bot / _handle_sections
# 5. Background Health Daemon: TG connectivity + sing-box watchdog
#
# ==============================================================================

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
BOT_VERSION="0.13.90"
# Path to this script — used by self-update (mv + exec/restart).
# Resolved at startup: follows symlinks, falls back to hardcoded installer path.
BOT_PATH=$(readlink -f "$0" 2>/dev/null || echo "/usr/bin/podkop_bot")

BOT_START_TIME=$(date +%s)
BOT_START_STR=$(date "+%Y-%m-%d %H:%M:%S")

# ==============================================================================
# SECTION 0: Configuration & Global Constants
# ==============================================================================

TOKEN=$(uci -q get podkop_bot.settings.bot_token)
ADMIN_ID=$(uci -q get podkop_bot.settings.chat_id)
ADMIN_IDS=$(uci -q get podkop_bot.settings.admin_ids 2>/dev/null)
ADMIN_SENDER_CHAT_IDS=$(uci -q get podkop_bot.settings.admin_sender_chat_ids 2>/dev/null)
ALLOW_ANON_ADMINS=$(uci -q get podkop_bot.settings.allow_anonymous_admins 2>/dev/null)
[ -z "$ALLOW_ANON_ADMINS" ] && ALLOW_ANON_ADMINS="1"

BOT_USERNAME_FILE="/tmp/podkop_bot_username"
BOT_USERNAME=""
BOT_ID_FILE="/tmp/podkop_bot_id"
BOT_ID=""

TARGET_CHAT_ID="$ADMIN_ID"
TARGET_MESSAGE_ID=""
TARGET_CHAT_TYPE=""
TARGET_REPLY_THREAD_ID=""

TAG_URI_CACHE="/tmp/podkop_tag_uri_cache.txt"
UCI_LINKS_CACHE="/tmp/podkop_uci_links_cache.txt"
# tag → human name extracted from #fragment in UCI links (selector + urltest)
TAG_NAME_CACHE="/tmp/podkop_tag_name_cache.txt"
ACTIVE_SECTION_FILE="/tmp/podkop_bot_active_section"
RELOAD_TS_FILE="/tmp/podkop_bot_last_reload_ts"

# Community lists: GitHub API cache with 1h TTL (60 req/hr rate limit protection)
COMMUNITY_LISTS_FALLBACK="anime block cloudflare cloudfront digitalocean discord geoblock google_ai google_meet google_play hdrezka hetzner hodca meta news ovh porn roblox russia_inside russia_outside telegram tiktok twitter ukraine_inside youtube"
CL_CACHE_FILE="/tmp/podkop_cl_cache.txt"
CL_CACHE_TS="/tmp/podkop_cl_cache_ts"

# Public IP cache: updated in background, read instantly in Status screen.
# Three sources: ipinfo.io, ifconfig.me (foreign) + yandex.ru (Russian, works under RKN).
PUBIP_CACHE="/tmp/podkop_pubip_cache.txt"
PUBIP_CACHE_TTL=300  # 5 minutes — balance between freshness and traffic

if [ -z "$TOKEN" ] || { [ -z "$ADMIN_ID" ] && [ -z "$ADMIN_IDS" ]; }; then
    logger -t podkop-bot "FATAL: Bot token or Admin Chat ID not set in /etc/config/podkop_bot."
    exit 1
fi

# Auto-initialize default bot settings if missing
[ -z "$(uci -q get podkop_bot.settings.transport)" ]       && uci set podkop_bot.settings.transport="auto"
[ -z "$(uci -q get podkop_bot.settings.startup_notify)" ]  && uci set podkop_bot.settings.startup_notify="1"
[ -z "$(uci -q get podkop_bot.settings.alert_notify)" ]    && uci set podkop_bot.settings.alert_notify="1"
[ -z "$(uci -q get podkop_bot.settings.health_interval)" ] && uci set podkop_bot.settings.health_interval="60"

API_URL="https://api.telegram.org/bot${TOKEN}"
TG_EMERGENCY_IPS="149.154.167.220 149.154.166.110 91.108.4.249"

OFFSET_FILE="/tmp/podkop_bot_offset"
STATE_FILE="/tmp/podkop_bot_state"
RELOAD_LOCK="/tmp/podkop_bot_reload_ts"
HEALTH_STATE_FILE="/tmp/podkop_bot_health_state"
# Structured SOCKS/TG state: written by watchdog, read by status/tunnel screens
SOCKS_STATE_FILE="/tmp/podkop_bot_socks_state"
# Periodic SOCKS latency probe results: key=value per endpoint, written by watchdog
SOCKS_PROBE_FILE="/tmp/podkop_bot_socks_probe"
# Timestamp of last SOCKS re-probe from degraded tier4/tier5 sticky path
SOCKS_REPROBE_TS_FILE="/tmp/podkop_bot_socks_reprobe_ts"
# Main process writes current route name here so watchdog subshell can read it
MAIN_ROUTE_FILE="/tmp/podkop_bot_main_route"
# Main process writes current route KEY here (tier1/tier2_N/tier3/tier4/tier5/fail).
# Separate from MAIN_ROUTE_FILE (which holds human-readable name).
# Watchdog reads this for per-cycle nudge logic — never writes to it.
MAIN_ROUTE_KEY_FILE="/tmp/podkop_bot_main_route_key"

# Write both route name and route key atomically from main process.
# Called at every successful tier resolution so watchdog always reads fresh data.
_write_main_route() {
    local _key="$1" _name="$2"
    printf '%s' "$_name" > "$MAIN_ROUTE_FILE"
    printf '%s' "$_key"  > "$MAIN_ROUTE_KEY_FILE"
}
ROUTE_CMD_FILE="/tmp/podkop_bot_route_cmd"
LAST_CMD_FILE="/tmp/podkop_bot_last_cmd"
UNAUTH_FILE="/tmp/podkop_bot_unauth"
# Menu/alert interleaving fix: track last menu msg_id and last health alert msg_id.
# send_or_edit uses these to detect when an alert has pushed the menu up and
# re-sends the menu as a new message (delete old + send new) to keep it current.
LAST_MENU_MSG_FILE="/tmp/podkop_bot_last_menu_msg"
LAST_ALERT_MSG_FILE="/tmp/podkop_bot_last_alert_msg"

# Dynamically resolve Clash API endpoint from sing-box config
CLASH_API_ADDR=$(jq -r '.experimental.clash_api.external_controller // empty' /etc/sing-box/config.json 2>/dev/null)
if [ -z "$CLASH_API_ADDR" ]; then
    ROUTER_IP=$(uci -q get network.lan.ipaddr || echo "127.0.0.1")
    CLASH_API_ADDR="${ROUTER_IP}:9090"
fi
CLASH_API="http://${CLASH_API_ADDR}"

# SSH/locale-safe emoji constants (hex-encoded UTF-8)
E_OK=$(printf '\xE2\x9C\x85')
E_ERR=$(printf '\xE2\x9D\x8C')
E_WARN=$(printf '\xE2\x9A\xA0')
E_GLOB=$(printf '\xF0\x9F\x8C\x90')
E_STAT=$(printf '\xF0\x9F\x93\x8A')
E_DWN=$(printf '\xE2\xAC\x87\xEF\xB8\x8F')
E_UP=$(printf '\xE2\xAC\x86\xEF\xB8\x8F')
E_SHLD=$(printf '\xF0\x9F\x9B\xA1\xEF\xB8\x8F')
E_RTR=$(printf '\xF0\x9F\x96\xA5\xEF\xB8\x8F')
E_PRX=$(printf '\xF0\x9F\x94\x8C')
E_SET=$(printf '\xE2\x9A\x99')
E_ADD=$(printf '\xE2\x9E\x95')
E_BACK=$(printf '\xE2\x86\x90')
E_FILE=$(printf '\xF0\x9F\x93\x84')
E_LOG=$(printf '\xF0\x9F\x93\x8B')
E_RST=$(printf '\xF0\x9F\x94\x84')
E_STP=$(printf '\xF0\x9F\x9B\x91')
E_DEL=$(printf '\xF0\x9F\x97\x91')
E_KEY=$(printf '\xF0\x9F\x94\x91')
E_CPU=$(printf '\xF0\x9F\xA7\xA0')
E_RAM=$(printf '\xF0\x9F\x92\xBE')
E_NET=$(printf '\xF0\x9F\x94\x97')
E_ON=$(printf '\xF0\x9F\x9F\xA2')
E_OFF=$(printf '\xE2\x9A\xAA')
E_SKULL=$(printf '\xF0\x9F\x92\x80')
E_YLW=$(printf '\xF0\x9F\x9F\xA1')
E_RED=$(printf '\xF0\x9F\x94\xB4')
E_PLAY=$(printf '\xE2\x96\xB6')
E_EDIT=$(printf '\xE2\x9C\x8F')
E_INFO=$(printf '\xE2\x84\xB9')
E_SCAN=$(printf '\xF0\x9F\xAA\xBA')
E_BOT=$(printf '\xF0\x9F\xA4\x96')
E_TIME=$(printf '\xE2\x8F\xB1')
E_NEW=$(printf '\xF0\x9F\x86\x95')
E_CLIP=$(printf '\xF0\x9F\x93\x8E')
E_TEST=$(printf '\xF0\x9F\xA7\xAA')
E_HEALTH=$(printf '\xF0\x9F\xA9\xBA')
E_IDEA=$(printf '\xF0\x9F\x92\xA1')   # [bulb] light bulb — hints/tips
E_TGT=$(printf '\xF0\x9F\x8E\xAF')    # [target] target — protocol selector

LAST_ROUTE="unknown"
LAST_ROUTE_NAME="Initializing..."
# Split route tracking: fast (sendMessage etc), poll (getUpdates), doc (sendDocument)
# Doc path never updates FAST or POLL to avoid poisoning transport state with multipart failures.
LAST_ROUTE_FAST="unknown"
LAST_ROUTE_POLL="unknown"
LAST_ROUTE_DOC="unknown"
# Recovery mode: set to N after All transports FAILED; decrements each poll cycle.
# While >0 bot aggressively probes SOCKS tiers before falling to direct.
RECOVERY_MODE=0
API_RESPONSE=""
HEALTH_PID=""
# Optional toast text for answerCallbackQuery — handlers set this to show a brief
# popup notification to the user without modifying the card. Cleared after each use.
CB_ANSWER_TEXT=""

# ==============================================================================
# SECTION 1: Input Validation & Escaping Helpers
# ==============================================================================

# Validate IPv4 address or CIDR (e.g. 192.168.1.1 or 10.0.0.0/24)
validate_ip_or_cidr() {
    echo "$1" | awk -F'/' '{
        ip=$1; mask=$2;
        if (mask != "" && (mask !~ /^[0-9]+$/ || mask < 0 || mask > 32)) exit 1;
        split(ip, octets, ".");
        if (length(octets) != 4) exit 1;
        for (i=1; i<=4; i++) {
            if (octets[i] !~ /^[0-9]+$/ || octets[i] < 0 || octets[i] > 255) exit 1;
        }
        exit 0;
    }'
}

# Validate domain name (basic: letters, digits, dots, hyphens)
validate_domain() {
    echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'
}

html_escape() {
    # Escapes all 5 HTML special chars including " for safe use inside href="..."
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'
}

url_decode() {
    local data="$1"
    [ -z "$data" ] && { echo ""; return 0; }
    # Replace + with space first
    data=$(printf '%s' "$data" | sed 's/+/ /g')
    # Convert %XX to octal \NNN via awk, then interpret with printf.
    # BusyBox printf does not support \xNN escapes but does support \NNN (octal).
    # This correctly handles multi-byte UTF-8 sequences (emoji flags etc).
    local escaped
    escaped=$(printf '%s' "$data" | \
        awk 'BEGIN{for(i=0;i<256;i++) oct[sprintf("%02X",i)]=sprintf("\\%03o",i)}
        {
            s=$0; r=""
            while(match(s,/%[0-9A-Fa-f][0-9A-Fa-f]/)){
                r=r substr(s,1,RSTART-1)
                h=toupper(substr(s,RSTART+1,2))
                r=r oct[h]
                s=substr(s,RSTART+3)
            }
            printf "%s", r s
        }')
    printf "$escaped"
}

# ==============================================================================
# SECTION 2: Network Transport Layer
#
# ARCHITECTURE (P1 overhaul):
#   - Two independent transport profiles:
#       api_request_fast()  sendMessage/editMessage/answerCB/deleteMessage
#       api_poll_long()     getUpdates only (50s poll, separate timeouts)
#   - api_document()        sendDocument, never updates FAST/POLL route state
#   - Tier order:
#       tier1               Podkop SOCKS5 (primary)
#       tier2_N             fallback_socks list (UCI list, N entries)
#       tier3               custom_proxy (single legacy entry)
#       tier4               Direct
#       tier5               Emergency hardcoded Telegram IPs
#   - Sticky-route fast path: each profile remembers its last working tier
#       and retries it first with short connect-timeout (1-2s).
#   - Recovery mode: after All transports FAILED, next 4 poll cycles
#       aggressively probe SOCKS tiers first before falling to direct.
#   - Logging: one line per event, structured format:
#       [Transport] route=X ok/fail  |  [Transport] recover old=X new=Y
# ==============================================================================

get_proxy_ip() {
    local m_port sb_ip lan_ip sec
    sec=$(get_active_section)
    m_port=$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")
    if [ -f "/etc/sing-box/config.json" ]; then
        sb_ip=$(jq -r --arg p "$m_port" \
            '.inbounds[]? | select(.listen_port==($p|tonumber)) | .listen // empty' \
            /etc/sing-box/config.json 2>/dev/null | head -n 1)
        if [ -n "$sb_ip" ]; then
            if [ "$sb_ip" = "0.0.0.0" ] || [ "$sb_ip" = "::" ]; then
                lan_ip=$(uci -q get network.lan.ipaddr)
                echo "${lan_ip:-127.0.0.1}"
            else
                echo "$sb_ip"
            fi
            return
        fi
    fi
    lan_ip=$(uci -q get network.lan.ipaddr)
    echo "${lan_ip:-127.0.0.1}"
}

_is_telegram_response() {
    printf '%s' "$1" | jq -e '.ok == true' >/dev/null 2>&1
}

# _try_curl PROXY_FLAGS MAX_TIME CURL_ARGS [CONNECT_TIMEOUT]
_try_curl() {
    local res ct="${4:-3}"
    # shellcheck disable=SC2086
    res=$(curl -s -k --connect-timeout "$ct" --max-time "$2" $1 $3 2>/dev/null)
    if _is_telegram_response "$res"; then
        API_RESPONSE="$res"
        return 0
    fi
    return 1
}

# _load_transport_ctx: populate shared locals for transport functions.
# Call at the top of each transport function.
_load_transport_ctx() {
    _t_sec=$(get_active_section)
    _t_policy=$(uci -q get podkop_bot.settings.transport || echo "auto")
    _t_port=$(uci -q get podkop."${_t_sec}".mixed_proxy_port || echo "2080")
    _t_ip=$(get_proxy_ip)
    _t_custom=$(uci -q get podkop_bot.settings.custom_proxy 2>/dev/null || echo "")
    _t_biface=$(uci -q get podkop_bot.settings.bind_interface 2>/dev/null || echo "")
    _t_ifflag=""; [ -n "$_t_biface" ] && _t_ifflag="--interface $_t_biface"
    # Load fallback_socks list via eval set -- (same pattern as url_proxy_links)
    local _fb_raw
    _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
    _t_fb_socks=""
    if [ -n "$_fb_raw" ]; then
        eval "set -- $_fb_raw"
        _t_fb_socks="$*"
    fi
}

# _try_socks_tiers: attempt tier1 + all fallback_socks in order.
# Sets ROUTE_KEY and ROUTE_NAME on success. Returns 0 on first success.
# ROUTE_KEY: tier1 | tier2_1 | tier2_2 | ...
_try_socks_tiers() {
    local args="$1" max_time="$2" ct="$3"
    # tier1: primary Podkop SOCKS
    if [ "$_t_policy" != "direct" ]; then
        if _try_curl "-x socks5h://${_t_ip}:${_t_port}" "$max_time" "$args" "$ct"; then
            ROUTE_KEY="tier1"
            ROUTE_NAME="Podkop (SOCKS5:${_t_ip}:${_t_port})"
            return 0
        fi
    fi
    # tier2_N: fallback_socks entries
    local _n=0 _fb
    for _fb in $_t_fb_socks; do
        _n=$((_n + 1))
        logger -t podkop-bot "[Transport] Trying fallback SOCKS: ${_fb}"
        if _try_curl "-x ${_fb}" "$max_time" "$args" "$ct"; then
            ROUTE_KEY="tier2_${_n}"
            ROUTE_NAME="Fallback SOCKS${_n} (${_fb})"
            return 0
        fi
    done
    return 1
}

# _try_all_tiers: full cascade including custom/direct/emergency.
# Sets ROUTE_KEY and ROUTE_NAME on success.
_try_all_tiers() {
    local args="$1" max_time="$2" ct_fast="$3"
    # SOCKS tiers first
    if _try_socks_tiers "$args" "$max_time" "$ct_fast"; then
        return 0
    fi
    # tier3: custom_proxy
    if [ -n "$_t_custom" ] && [ "$_t_policy" != "direct" ]; then
        if _try_curl "$_t_ifflag -x $_t_custom" "$max_time" "$args" "$ct_fast"; then
            ROUTE_KEY="tier3"
            ROUTE_NAME="Custom (${_t_custom})${_t_biface:+ via $_t_biface}"
            return 0
        fi
    fi
    # tier4: direct
    if [ "$_t_policy" != "socks" ]; then
        if _try_curl "$_t_ifflag" "$max_time" "$args" "5"; then
            ROUTE_KEY="tier4"
            ROUTE_NAME="Direct${_t_biface:+ via $_t_biface}"
            return 0
        fi
        # tier5: emergency IPs
        local _eip
        for _eip in $TG_EMERGENCY_IPS; do
            if _try_curl "$_t_ifflag --resolve api.telegram.org:443:${_eip}" "$max_time" "$args" "5"; then
                ROUTE_KEY="tier5"
                ROUTE_NAME="Emergency IP (${_eip})"
                return 0
            fi
        done
    fi
    return 1
}

# _route_request: core engine used by api_request_fast and api_poll_long.
# $1=curl_args  $2=max_time  $3=ct_sticky  $4=ct_full  $5=route_var (LAST_ROUTE_FAST|LAST_ROUTE_POLL)
# Updates the named route variable and LAST_ROUTE/LAST_ROUTE_NAME (for UI display).
_route_request() {
    local _args="$1" _max="$2" _ct_sticky="$3" _ct_full="$4" _rvar="$5"
    local _last ROUTE_KEY ROUTE_NAME

    # --- IPC: read command from watchdog subshell ---
    # Watchdog cannot modify parent variables directly (subshell isolation).
    # It writes "down" or "up" to ROUTE_CMD_FILE; we act on it here at the
    # top of every transport call (both api_request_fast and api_poll_long).
    if [ -f "$ROUTE_CMD_FILE" ]; then
        local _wd_cmd
        _wd_cmd=$(cat "$ROUTE_CMD_FILE" 2>/dev/null)
        rm -f "$ROUTE_CMD_FILE"
        LAST_ROUTE_FAST="unknown"
        LAST_ROUTE_POLL="unknown"
        LAST_ROUTE="unknown"
        if [ "$_wd_cmd" = "down" ]; then
            RECOVERY_MODE=4
            logger -t podkop-bot "[Transport] sing-box down signal received. Resetting routes."
        else
            # RECOVERY_MODE=2: next 2 poll cycles probe SOCKS tiers first (aggressive),
            # preventing bot from settling on tier4/Direct when tier1 just recovered.
            # Using 0 caused _try_all_tiers to miss tier1 on tight connect-timeout
            # and fall through to Direct if tier1 was slow to respond post-restart.
            RECOVERY_MODE=2
            # Clear tier5 reprobe timestamp: forces immediate SOCKS retry on tier5 path
            rm -f "$SOCKS_REPROBE_TS_FILE"
            logger -t podkop-bot "[Transport] Recovery signal received. Resetting routes, forcing SOCKS rediscovery."
        fi
    fi
    # ------------------------------------------------

    _load_transport_ctx
    eval "_last=\$$_rvar"

    # --- Sticky fast path: retry last known working tier first ---
    if [ "$_last" != "unknown" ] && [ "$_last" != "fail" ]; then
        case "$_last" in
            tier1)
                [ "$_t_policy" != "direct" ] && \
                _try_curl "-x socks5h://${_t_ip}:${_t_port}" "$_max" "$_args" "$_ct_sticky" && {
                    LAST_ROUTE="tier1"; LAST_ROUTE_NAME="Podkop (SOCKS5:${_t_ip}:${_t_port})"
                    _write_main_route "tier1" "$LAST_ROUTE_NAME"
                    eval "$_rvar=tier1"; return 0
                }
                ;;
            tier2_*)
                local _n="${_last#tier2_}" _fb="" _i=0 _item
                for _item in $_t_fb_socks; do
                    _i=$((_i + 1))
                    if [ "$_i" -eq "$_n" ]; then
                        _fb="$_item"
                        break
                    fi
                done
                [ -n "$_fb" ] && \
                _try_curl "-x $_fb" "$_max" "$_args" "$_ct_sticky" && {
                    LAST_ROUTE="$_last"; LAST_ROUTE_NAME="Fallback SOCKS${_n} (${_fb})"
                    _write_main_route "$_last" "$LAST_ROUTE_NAME"
                    eval "$_rvar=$_last"; return 0
                }
                ;;
            tier3)
                [ -n "$_t_custom" ] && \
                _try_curl "$_t_ifflag -x $_t_custom" "$_max" "$_args" "$_ct_sticky" && {
                    LAST_ROUTE="tier3"; LAST_ROUTE_NAME="Custom (${_t_custom})"
                    _write_main_route "tier3" "$LAST_ROUTE_NAME"
                    eval "$_rvar=tier3"; return 0
                }
                ;;
            tier4)
                # On degraded path (tier4): periodically try SOCKS tiers before using direct.
                # Mirrors tier5 reprobe logic — prevents sticking on Direct when tier2
                # recovers but tier1 is still down (Telegram accessible directly).
                local _now _last_reprobe
                _now=$(date +%s)
                _last_reprobe=$(cat "$SOCKS_REPROBE_TS_FILE" 2>/dev/null || echo 0)
                if [ $((_now - _last_reprobe)) -ge 30 ]; then
                    echo "$_now" > "$SOCKS_REPROBE_TS_FILE"
                    local ROUTE_KEY ROUTE_NAME
                    # Try SOCKS tiers (tier1+tier2) first.
                    # Then try tier3 (custom proxy) separately — _try_socks_tiers doesn't cover it.
                    # NOTE: the compound || {...} pattern is split into sequential if-branches
                    # to avoid a POSIX ash parsing ambiguity where the inner && chain inside
                    # {...} can short-circuit in unexpected ways across some BusyBox versions.
                    if _try_socks_tiers "$_args" "$_max" "2"; then
                        :
                    elif [ -n "$_t_custom" ] && [ "$_t_policy" != "direct" ] && \
                         _try_curl "$_t_ifflag -x $_t_custom" "$_max" "$_args" "2"; then
                        ROUTE_KEY="tier3"; ROUTE_NAME="Custom (${_t_custom})"
                    else
                        ROUTE_KEY=""
                    fi
                    if [ -n "$ROUTE_KEY" ]; then
                        LAST_ROUTE="$ROUTE_KEY"; LAST_ROUTE_NAME="$ROUTE_NAME"
                        _write_main_route "$ROUTE_KEY" "$ROUTE_NAME"
                        eval "$_rvar=$ROUTE_KEY"
                        logger -t podkop-bot "[Transport] Recovered from Direct. Active route: ${ROUTE_NAME}"
                        return 0
                    fi
                fi
                # Reprobe failed or not yet due — use direct path
                [ "$_t_policy" != "socks" ] && \
                _try_curl "$_t_ifflag" "$_max" "$_args" "5" && {
                    LAST_ROUTE="tier4"; LAST_ROUTE_NAME="Direct"
                    _write_main_route "tier4" "$LAST_ROUTE_NAME"
                    eval "$_rvar=tier4"; return 0
                }
                ;;
            tier5)
                # On degraded path (tier5): periodically try SOCKS tiers before using emergency IP.
                # Without this, bot stays on tier5 forever even after fallback_socks recovers.
                local _now _last_reprobe
                _now=$(date +%s)
                _last_reprobe=$(cat "$SOCKS_REPROBE_TS_FILE" 2>/dev/null || echo 0)
                if [ $((_now - _last_reprobe)) -ge 30 ]; then
                    echo "$_now" > "$SOCKS_REPROBE_TS_FILE"
                    local ROUTE_KEY ROUTE_NAME
                    if _try_socks_tiers "$_args" "$_max" "2"; then
                        :
                    elif [ -n "$_t_custom" ] && [ "$_t_policy" != "direct" ] && \
                         _try_curl "$_t_ifflag -x $_t_custom" "$_max" "$_args" "2"; then
                        ROUTE_KEY="tier3"; ROUTE_NAME="Custom (${_t_custom})"
                    else
                        ROUTE_KEY=""
                    fi
                    if [ -n "$ROUTE_KEY" ]; then
                        LAST_ROUTE="$ROUTE_KEY"; LAST_ROUTE_NAME="$ROUTE_NAME"
                        _write_main_route "$ROUTE_KEY" "$ROUTE_NAME"
                        eval "$_rvar=$ROUTE_KEY"
                        logger -t podkop-bot "[Transport] Recovered from Emergency IP. Active route: ${ROUTE_NAME}"
                        return 0
                    fi
                fi
                # Reprobe failed or not yet due — use emergency path.
                # Try direct first (may work outside RKN), then hardcoded emergency IPs.
                [ "$_t_policy" != "socks" ] && \
                _try_curl "$_t_ifflag" "$_max" "$_args" "3" && {
                    LAST_ROUTE="tier4"; LAST_ROUTE_NAME="Direct"
                    _write_main_route "tier4" "$LAST_ROUTE_NAME"
                    eval "$_rvar=tier4"; return 0
                }
                for _eip in $TG_EMERGENCY_IPS; do
                    _try_curl "$_t_ifflag --resolve api.telegram.org:443:${_eip}" "$_max" "$_args" "3" && {
                        LAST_ROUTE="tier5"; LAST_ROUTE_NAME="Emergency IP (${_eip})"
                        _write_main_route "tier5" "$LAST_ROUTE_NAME"
                        eval "$_rvar=tier5"; return 0
                    }
                done
                ;;
        esac
        # Sticky path failed — log and fall through to full discovery
        logger -t podkop-bot "[Transport] Sticky route missed, running full discovery."
    fi

    # --- Full discovery cascade ---
    if _try_all_tiers "$_args" "$_max" "$_ct_full"; then
        local _prev_name="$LAST_ROUTE_NAME"
        LAST_ROUTE="$ROUTE_KEY"
        LAST_ROUTE_NAME="$ROUTE_NAME"
        _write_main_route "$ROUTE_KEY" "$ROUTE_NAME"
        eval "$_rvar=$ROUTE_KEY"
        if [ "$_last" = "fail" ] || [ "$_last" = "unknown" ]; then
            logger -t podkop-bot "[Transport] Connection recovered. Active route: ${ROUTE_NAME}"
            RECOVERY_MODE=0
        elif [ "$_prev_name" != "$ROUTE_NAME" ]; then
            logger -t podkop-bot "[Transport] Route: ${ROUTE_NAME}"
        fi
        return 0
    fi

    # --- All tiers failed ---
    if [ "$_last" != "fail" ]; then
        logger -t podkop-bot "[Transport] Connection failed. All proxy tiers exhausted."
        RECOVERY_MODE=4
    fi
    LAST_ROUTE="fail"; LAST_ROUTE_NAME="Disconnected"
    eval "$_rvar=fail"
    return 1
}

# api_request_fast: sendMessage, editMessageText, answerCallbackQuery, deleteMessage
# connect-timeout: 2s sticky / 3s full   max-time: 8s
api_request_fast() {
    local method="$1" payload="$2" max_time="${3:-8}" tmp final_args
    API_RESPONSE=""
    tmp=$(mktemp /tmp/podkop_req.XXXXXX)
    printf '%s' "$payload" > "$tmp"
    final_args="-X POST -H Content-Type:application/json --data-binary @${tmp} ${API_URL}/${method}"
    # Recovery mode: try SOCKS tiers first before sticky (mirrors api_poll_long behaviour)
    if [ "${RECOVERY_MODE:-0}" -gt 0 ]; then
        _load_transport_ctx
        local ROUTE_KEY ROUTE_NAME
        # Use reduced max_time so all SOCKS tiers fit within one fast request budget.
        # Default max_time=8s with ct=3s means tier1 alone can consume all 8s before
        # tier2 gets a chance. Cap at 5s per tier: tier1(3s ct)+tier2(3s ct) = ~6s total.
        local _fast_max=5
        logger -t podkop-bot "[Transport] Fast recovery starting. Trying SOCKS tiers..."
        if _try_socks_tiers "$final_args" "$_fast_max" "3"; then
            LAST_ROUTE="$ROUTE_KEY"; LAST_ROUTE_NAME="$ROUTE_NAME"
            _write_main_route "$ROUTE_KEY" "$ROUTE_NAME"
            LAST_ROUTE_FAST="$ROUTE_KEY"
            # Decrement but do NOT zero — let api_poll_long confirm stability
            # before fully exiting recovery mode. Zeroing here causes the next
            # poll cycle to skip SOCKS-first and potentially land on Direct.
            RECOVERY_MODE=$((RECOVERY_MODE > 1 ? RECOVERY_MODE - 1 : 0))
            logger -t podkop-bot "[Transport] Fast recovery: connected via ${ROUTE_NAME}"
            rm -f "$tmp"; echo "$API_RESPONSE"; return 0
        else
            logger -t podkop-bot "[Transport] Fast recovery: all SOCKS tiers unavailable."
        fi
    fi
    if _route_request "$final_args" "$max_time" "2" "3" "LAST_ROUTE_FAST"; then
        rm -f "$tmp"; echo "$API_RESPONSE"; return 0
    fi
    rm -f "$tmp"; return 1
}
# api_request: alias for api_request_fast (backward compat for non-poll callers)
api_request() { api_request_fast "$@"; }

# api_poll_long: getUpdates only
# connect-timeout: 3s sticky / 4s full   max-time: 65s (50s poll + buffer)
# Recovery mode: if RECOVERY_MODE>0, skip sticky path and probe SOCKS tiers first
api_poll_long() {
    local offset="$1" poll_timeout="${2:-50}"
    local args="-X GET ${API_URL}/getUpdates?offset=${offset}&timeout=${poll_timeout}"
    API_RESPONSE=""
    _load_transport_ctx

    # Recovery mode: aggressively try SOCKS tiers, skip sticky
    if [ "$RECOVERY_MODE" -gt 0 ]; then
        RECOVERY_MODE=$((RECOVERY_MODE - 1))
        logger -t podkop-bot "[Transport] Probing SOCKS tiers (recovery mode)..."
        local ROUTE_KEY ROUTE_NAME
        if _try_socks_tiers "$args" "65" "4"; then
            local _prev="$LAST_ROUTE_POLL"
            LAST_ROUTE="$ROUTE_KEY"; LAST_ROUTE_NAME="$ROUTE_NAME"
            LAST_ROUTE_POLL="$ROUTE_KEY"
            [ "$_prev" = "fail" ] && \
                logger -t podkop-bot "[Transport] Connection recovered. Active route: ${ROUTE_NAME}"
            return 0
        fi
        # SOCKS still down in recovery — fall through to full cascade
    fi

    _route_request "$args" "65" "3" "4" "LAST_ROUTE_POLL"
}

# api_poll: backward-compat wrapper
api_poll() { api_poll_long "$1" "${2:-50}"; }

# probe_socks_upstream: check SOCKS connectivity via multiple endpoints.
# Returns 0 if any endpoint responds 204, 1 if all fail.
# Used by watchdog — never updates LAST_ROUTE*.
probe_socks_upstream() {
    local m_ip="$1" m_port="$2" code
    local _probe_urls="http://www.gstatic.com/generate_204 http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204"
    for _url in $_probe_urls; do
        code=$(curl -s -k \
            -x "socks5h://${m_ip}:${m_port}" \
            --connect-timeout 5 --max-time 8 \
            -o /dev/null -w "%{http_code}" \
            "$_url" 2>/dev/null)
        if [ "$code" = "204" ]; then
            return 0
        fi
    done
    return 1
}

# Measure round-trip latency through a SOCKS endpoint.
# Outputs latency in ms, or "timeout" / "fail".
# Uses a single lightweight HTTP probe (gstatic 204).
probe_socks_latency() {
    local proxy_url="$1" _out _code _time
    _out=$(curl -s -k \
        -x "$proxy_url" \
        --connect-timeout 5 --max-time 8 \
        -o /dev/null -w "%{http_code}:%{time_total}" \
        "http://www.gstatic.com/generate_204" 2>/dev/null)
    _code="${_out%%:*}"
    _time="${_out#*:}"
    if [ "$_code" = "204" ]; then
        awk -v t="$_time" 'BEGIN{printf "%dms", int(t*1000)}'
    else
        echo "timeout"
    fi
}

# Probe all configured SOCKS endpoints (tier1 + fallback_socks list) and write
# structured results to SOCKS_PROBE_FILE. Called periodically from watchdog.
# Format: tier1=<ms|timeout>  tier2_1=<ms|timeout>  ts=<epoch>
probe_all_socks_write() {
    local sec m_ip m_port lat
    sec=$(get_active_section)
    m_port=$(uci -q get podkop.${sec}.mixed_proxy_port 2>/dev/null || echo "2080")
    m_ip=$(get_proxy_ip)

    local out="ts=$(date +%s)"

    # tier1: primary Podkop SOCKS
    lat=$(probe_socks_latency "socks5h://${m_ip}:${m_port}")
    out="${out}\ntier1=${lat}"
    logger -t podkop-bot "[SOCKSProbe] Primary (${m_ip}:${m_port}): ${lat}"

    # tier2_N: fallback_socks list
    local _fb_raw _n=0 _item _fb=""
    _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
    if [ -n "$_fb_raw" ]; then
        eval "set -- $_fb_raw"
        for _item in "$@"; do
            _n=$((_n + 1))
            lat=$(probe_socks_latency "$_item")
            out="${out}\ntier2_${_n}=${lat} url=${_item}"
            logger -t podkop-bot "[SOCKSProbe] Fallback-${_n} (${_item}): ${lat}"
        done
    fi

    # tier3: custom_proxy (only if set and is a proxy URL, not just an IP)
    local _custom; _custom=$(uci -q get podkop_bot.settings.custom_proxy 2>/dev/null)
    if [ -n "$_custom" ]; then
        lat=$(probe_socks_latency "$_custom")
        out="${out}\ntier3=${lat} url=${_custom}"
        logger -t podkop-bot "[SOCKSProbe] Custom proxy (${_custom}): ${lat}"
    fi

    local _probe_tmp; _probe_tmp=$(mktemp /tmp/podkop_socks_probe.XXXXXX 2>/dev/null) || return 1
    printf '%b\n' "$out" > "$_probe_tmp"
    mv "$_probe_tmp" "$SOCKS_PROBE_FILE" 2>/dev/null || rm -f "$_probe_tmp"
}

# api_document: sendDocument — never updates FAST or POLL route state.
# Uses its own LAST_ROUTE_DOC so multipart failures don't poison polling.
api_document() {
    local file="$1" caption="$2"
    local res doc_kb nr sec m_port m_ip policy custom_url b_iface if_flag
    sec=$(get_active_section)
    m_port=$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")
    m_ip=$(get_proxy_ip)
    policy=$(uci -q get podkop_bot.settings.transport || echo "auto")
    custom_url=$(uci -q get podkop_bot.settings.custom_proxy 2>/dev/null)
    b_iface=$(uci -q get podkop_bot.settings.bind_interface 2>/dev/null)
    if_flag=""; [ -n "$b_iface" ] && if_flag="--interface $b_iface"
    doc_kb="{\"inline_keyboard\":[[{\"text\":\"${E_DEL} Delete\",\"callback_data\":\"delete_msg\"},{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"doc_to_runtime\"}]]}"

    _do_curl_doc() {
        # shellcheck disable=SC2086
        curl -s -k --connect-timeout 5 --max-time 30 \
            $1 \
            -F "chat_id=${TARGET_CHAT_ID}" \
            -F "document=@${file}" \
            -F "caption=${caption}" \
            -F "parse_mode=HTML" \
            -F "reply_markup=${doc_kb}" \
            ${TARGET_REPLY_THREAD_ID:+-F "message_thread_id=${TARGET_REPLY_THREAD_ID}"} \
            "${API_URL}/sendDocument" 2>/dev/null
    }

    # Full cascade top-to-bottom. sendDocument is rare (log uploads only) and
    # multipart uploads are sensitive to proxy behaviour, so no sticky fast-path
    # here — always try in tier order. LAST_ROUTE_DOC records the outcome for
    # diagnostics but does not influence FAST or POLL routing.

    if [ "$policy" != "direct" ]; then
        res=$(_do_curl_doc "-x socks5h://${m_ip}:${m_port}")
        _is_telegram_response "$res" && {
            unset -f _do_curl_doc
            LAST_ROUTE_DOC="tier1"; return 0
        }
        # fallback_socks for doc — only when policy allows SOCKS
        local _fb_raw _n=0 _fb
        _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
        if [ -n "$_fb_raw" ]; then
            eval "set -- $_fb_raw"
            for _fb in "$@"; do
                _n=$((_n + 1))
                res=$(_do_curl_doc "-x $_fb")
                _is_telegram_response "$res" && {
                    unset -f _do_curl_doc
                    LAST_ROUTE_DOC="tier2_${_n}"; return 0
                }
            done
        fi
        # custom_url — only when policy allows SOCKS/custom
        if [ -n "$custom_url" ]; then
            res=$(_do_curl_doc "$if_flag -x $custom_url")
            _is_telegram_response "$res" && {
                unset -f _do_curl_doc
                LAST_ROUTE_DOC="tier3"; return 0
            }
        fi
    fi
    if [ "$policy" != "socks" ]; then
        res=$(_do_curl_doc "$if_flag")
        _is_telegram_response "$res" && {
            unset -f _do_curl_doc
            LAST_ROUTE_DOC="tier4"; return 0
        }
        local _eip
        for _eip in $TG_EMERGENCY_IPS; do
            res=$(_do_curl_doc "$if_flag --resolve api.telegram.org:443:${_eip}")
            _is_telegram_response "$res" && {
                unset -f _do_curl_doc
                LAST_ROUTE_DOC="tier5"; return 0
            }
        done
    fi
    unset -f _do_curl_doc
    LAST_ROUTE_DOC="fail"
    return 1
}

# get_tg_latency: measure round-trip to Telegram on the current LAST_ROUTE_FAST
get_tg_latency() {
    local m_port m_ip custom_url b_iface if_flag p_args res sec
    sec=$(get_active_section)
    m_port=$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")
    m_ip=$(get_proxy_ip)
    custom_url=$(uci -q get podkop_bot.settings.custom_proxy 2>/dev/null)
    b_iface=$(uci -q get podkop_bot.settings.bind_interface 2>/dev/null)
    if_flag=""; [ -n "$b_iface" ] && if_flag="--interface $b_iface"
    case "$LAST_ROUTE_FAST" in
        tier1)
            p_args="-x socks5h://${m_ip}:${m_port}"
            ;;
        tier2_*)
            # Resolve the actual fallback SOCKS endpoint by index
            local _n="${LAST_ROUTE_FAST#tier2_}" _fb_raw _fb_url _i=0
            _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
            _fb_url=""
            if [ -n "$_fb_raw" ]; then
                eval "set -- $_fb_raw"
                for _fb_url in "$@"; do
                    _i=$((_i + 1))
                    [ "$_i" -eq "$_n" ] && break
                    _fb_url=""
                done
            fi
            [ -z "$_fb_url" ] && { echo "N/A"; return; }
            p_args="-x ${_fb_url}"
            ;;
        tier3)
            p_args="$if_flag -x ${custom_url}"
            ;;
        tier4)
            p_args="$if_flag"
            ;;
        tier5)
            p_args="$if_flag --resolve api.telegram.org:443:149.154.167.220"
            ;;
        *)
            echo "N/A"; return
            ;;
    esac
    res=$(curl -o /dev/null -s -w "%{time_total}" -m 3 $p_args https://api.telegram.org 2>/dev/null)
    if [ -n "$res" ] && [ "$res" != "0.000" ]; then
        awk -v t="$res" 'BEGIN{printf "%dms", int(t*1000)}'
    else
        echo "Timeout"
    fi
}

# ==============================================================================
# SECTION 3: Authorization & Chat Context
# ==============================================================================

get_active_section() { cat "$ACTIVE_SECTION_FILE" 2>/dev/null || echo "main"; }

set_chat_context() {
    TARGET_CHAT_ID="$1"; TARGET_MESSAGE_ID="$2"
    TARGET_CHAT_TYPE="$3"; TARGET_REPLY_THREAD_ID="$4"
    [ -z "$TARGET_CHAT_ID" ] && TARGET_CHAT_ID="$ADMIN_ID"
}

reset_chat_context() {
    TARGET_CHAT_ID="$ADMIN_ID"; TARGET_MESSAGE_ID=""
    TARGET_CHAT_TYPE=""; TARGET_REPLY_THREAD_ID=""
}

load_bot_identity() {
    [ -f "$BOT_USERNAME_FILE" ] && BOT_USERNAME=$(cat "$BOT_USERNAME_FILE" 2>/dev/null)
    [ -f "$BOT_ID_FILE" ]       && BOT_ID=$(cat "$BOT_ID_FILE" 2>/dev/null)
    [ -n "$BOT_USERNAME" ] && [ -n "$BOT_ID" ] && return 0
    local me_res uname bid
    me_res=$(api_request "getMe" "{}" "10" 2>/dev/null)
    uname=$(printf '%s' "$me_res" | jq -r '.result.username // empty' 2>/dev/null)
    bid=$(printf '%s' "$me_res" | jq -r '.result.id // empty' 2>/dev/null)
    [ -n "$uname" ] && { BOT_USERNAME="$uname"; printf '%s' "$uname" > "$BOT_USERNAME_FILE"; }
    [ -n "$bid" ]   && { BOT_ID="$bid";         printf '%s' "$bid"   > "$BOT_ID_FILE"; }
    [ -n "$BOT_USERNAME" ] && [ -n "$BOT_ID" ]
}

is_whitelisted_admin() {
    local uid="$1" a
    [ -z "$uid" ] && return 1
    [ "$uid" = "$ADMIN_ID" ] && return 0
    for a in $ADMIN_IDS; do [ "$uid" = "$a" ] && return 0; done
    return 1
}

is_whitelisted_sender_chat() {
    local scid="$1" a
    [ -z "$scid" ] && return 1
    for a in $ADMIN_SENDER_CHAT_IDS; do [ "$scid" = "$a" ] && return 0; done
    return 1
}

is_allowed_actor() {
    [ "$3" = "true" ] && return 1
    is_whitelisted_admin "$1" && return 0
    [ "$4" = "1" ] && is_whitelisted_sender_chat "$2" && return 0
    return 1
}

is_private_chat() { [ "$1" = "private" ]; }
is_group_chat()   { [ "$1" = "group" ] || [ "$1" = "supergroup" ]; }

text_mentions_bot() {
    [ -z "$1" ] || [ -z "$2" ] && return 1
    printf '%s\n' "$1" | grep -Eiq "(^|[^[:alnum:]_])@${2}([[:space:][:punct:]]|$)"
}
strip_bot_mention()      { printf '%s' "$1" | sed "s/@${2}\>//Ig"; }
normalize_group_command() { printf '%s' "$1" | sed "s#^\(/[^ @]*\)@${2}\>#\1#I"; }

is_reply_to_bot() {
    [ -z "$1" ] || [ -z "$2" ] && return 1
    local rid; rid=$(printf '%s' "$1" | jq -r '.message.reply_to_message.from.id // empty' 2>/dev/null)
    [ -n "$rid" ] && [ "$rid" = "$2" ]
}

# ==============================================================================
# SECTION 4: Messaging Functions
# ==============================================================================

send_message() {
    local txt="$1" kb="$2" payload resp new_mid
    if [ -n "$kb" ] && [ "$kb" != "null" ]; then
        if [ -n "$TARGET_REPLY_THREAD_ID" ] && [ "$TARGET_REPLY_THREAD_ID" != "null" ]; then
            payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg txt "$txt" --arg tid "$TARGET_REPLY_THREAD_ID" --argjson kb "$kb" \
                '{chat_id:$cid,text:$txt,parse_mode:"HTML",message_thread_id:($tid|tonumber),reply_markup:$kb}')
        else
            payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg txt "$txt" --argjson kb "$kb" \
                '{chat_id:$cid,text:$txt,parse_mode:"HTML",reply_markup:$kb}')
        fi
    else
        if [ -n "$TARGET_REPLY_THREAD_ID" ] && [ "$TARGET_REPLY_THREAD_ID" != "null" ]; then
            payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg txt "$txt" --arg tid "$TARGET_REPLY_THREAD_ID" \
                '{chat_id:$cid,text:$txt,parse_mode:"HTML",message_thread_id:($tid|tonumber)}')
        else
            payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg txt "$txt" \
                '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
        fi
    fi
    resp=$(api_request "sendMessage" "$payload")
    # Track the new message_id so send_or_edit can detect alert interleaving
    new_mid=$(printf '%s' "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$new_mid" ] && printf '%s' "$new_mid" > "$LAST_MENU_MSG_FILE"
}

edit_message() {
    local mid="$1" txt="$2" kb="$3" payload
    [ -z "$mid" ] && { send_message "$txt" "$kb"; return; }
    if [ -n "$kb" ] && [ "$kb" != "null" ]; then
        payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg mid "$mid" --arg txt "$txt" --argjson kb "$kb" \
            '{chat_id:$cid,message_id:($mid|tonumber),text:$txt,parse_mode:"HTML",reply_markup:$kb}')
    else
        payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg mid "$mid" --arg txt "$txt" \
            '{chat_id:$cid,message_id:($mid|tonumber),text:$txt,parse_mode:"HTML"}')
    fi
    api_request "editMessageText" "$payload" >/dev/null
}

# send_or_edit: edit existing message OR send new one.
# Alert interleaving fix: if health daemon sent an alert AFTER the current menu
# message (alert_msg_id > menu_msg_id), the menu card is now buried above the
# alert. In this case: delete the buried menu card and send a new one at the
# bottom so the user sees the current state below the alert.
send_or_edit() {
    local mid="$1" txt="$2" kb="$3"
    if [ -n "$mid" ] && [ "$mid" != "null" ] && [ "$mid" != "0" ]; then
        # Check if a health alert was sent after this menu card
        local alert_mid menu_mid
        alert_mid=$(cat "$LAST_ALERT_MSG_FILE" 2>/dev/null)
        menu_mid=$(cat "$LAST_MENU_MSG_FILE" 2>/dev/null)
        if [ -n "$alert_mid" ] && [ -n "$menu_mid" ] && [ "$alert_mid" -gt "$menu_mid" ] 2>/dev/null; then
            # Alert is newer than menu — re-float: delete buried menu, send fresh
            api_request "deleteMessage" \
                "$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg m "$mid" \
                '{chat_id:$cid,message_id:($m|tonumber)}')" >/dev/null 2>/dev/null
            rm -f "$LAST_ALERT_MSG_FILE"
            send_message "$txt" "$kb"
        else
            edit_message "$mid" "$txt" "$kb"
        fi
    else
        send_message "$txt" "$kb"
    fi
}

answer_callback() {
    api_request "answerCallbackQuery" \
        "$(jq -n -c --arg cb "$1" --arg txt "$2" '{callback_query_id:$cb,text:$txt}')" >/dev/null
}

delete_message() {
    [ -z "$1" ] && return 0
    echo "$1" | grep -qE '^[0-9]+$' || return 0
    api_request "deleteMessage" \
        "$(jq -n -c --arg cid "$TARGET_CHAT_ID" --arg mid "$1" '{chat_id:$cid,message_id:($mid|tonumber)}')" >/dev/null
}


# ==============================================================================
# SECTION 5: Clash API & UCI Helpers
# ==============================================================================

# Communicate with the local sing-box Clash API (proxy status, delay tests, etc.)
# --max-time 10: guards against the case where the local Clash API accepts the TCP
# connection but then hangs on the response (e.g. sing-box under high load, OOM).
# connect-timeout 3 alone only covers the TCP handshake, not the full transfer.
clash_request() {
    local endpoint="$1" method="${2:-GET}" data="$3"
    local secret tmp_body
    secret=$(uci -q get podkop.settings.yacd_secret_key)
    if [ "$method" = "GET" ]; then
        if [ -n "$secret" ]; then
            curl -s --connect-timeout 3 --max-time 10 -H "Authorization: Bearer ${secret}" "${CLASH_API}${endpoint}"
        else
            curl -s --connect-timeout 3 --max-time 10 "${CLASH_API}${endpoint}"
        fi
    else
        tmp_body=$(mktemp /tmp/podkop_clash.XXXXXX)
        printf '%s' "$data" > "$tmp_body"
        if [ -n "$secret" ]; then
            curl -s --connect-timeout 3 --max-time 10 -X "$method" -H "Authorization: Bearer ${secret}" \
                -H "Content-Type: application/json" -d @"$tmp_body" "${CLASH_API}${endpoint}"
        else
            curl -s --connect-timeout 3 --max-time 10 -X "$method" \
                -H "Content-Type: application/json" -d @"$tmp_body" "${CLASH_API}${endpoint}"
        fi
        rm -f "$tmp_body"
    fi
}

# Fetch available community list names from GitHub Releases API.
# Cache result for 1 hour to prevent rate limit (60 req/hr).
# Uses companion timestamp file instead of stat -c (BusyBox stat is limited).
get_available_community_lists() {
    local now last_sync lists
    now=$(date +%s); last_sync=0
    [ -f "$CL_CACHE_TS" ] && last_sync=$(cat "$CL_CACHE_TS" 2>/dev/null || echo 0)
    if [ -f "$CL_CACHE_FILE" ] && [ $((now - last_sync)) -lt 3600 ]; then
        cat "$CL_CACHE_FILE"; return
    fi
    lists=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://api.github.com/repos/itdoginfo/allow-domains/releases/latest" \
        | jq -r '.assets[].name' 2>/dev/null \
        | grep '\.srs$' | sed 's/\.srs$//' | sort | tr '\n' ' ')
    if [ -n "$lists" ]; then
        echo "$lists" > "$CL_CACHE_FILE"
        echo "$now"   > "$CL_CACHE_TS"
        echo "$lists"
    elif [ -f "$CL_CACHE_FILE" ]; then
        cat "$CL_CACHE_FILE"
    else
        echo "$COMMUNITY_LISTS_FALLBACK"
    fi
}

# ==============================================================================
# FUNCTION: refresh_public_ip_cache
# DESCRIPTION: Queries 3 independent public IP services in parallel, picks the
#              winner by majority vote (2-of-3). Services:
#                1. ipinfo.io    — international CDN, reliable
#                2. ifconfig.me  — simple, rarely blocked
#                3. yandex.ru    — Russian service (HTML parse), works under RKN
#              Atomic write via tmp+mv prevents torn reads.
#              mkdir-lock prevents duplicate parallel refresh processes.
#              Using mkdir (not lockfile with $$) because $$ in a background
#              subshell returns the PARENT PID, not the subshell's own PID.
#              If the subshell dies unexpectedly, a $$-based lockfile stays
#              forever (kill -0 on parent PID always succeeds). mkdir is atomic
#              on POSIX filesystems and the OS cleans nothing — so we add a
#              5-minute stale-lock timeout to survive OOM kills / crashes.
# ==============================================================================
PUBIP_REFRESH_LOCK="/tmp/podkop_pubip_refresh.lockdir"

_validate_ip() {
    echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
}

refresh_public_ip_cache() {
    # Atomic mkdir lock: mkdir is a single POSIX syscall (link(2) semantics).
    # Unlike a lockfile with $$, it cannot produce a false "alive" check after crash.
    if ! mkdir "$PUBIP_REFRESH_LOCK" 2>/dev/null; then
        # Stale-lock recovery: if lock directory is older than 5 minutes, the
        # subshell that created it likely died without cleanup (OOM kill, segfault).
        # Use stat -c %Y (mtime in epoch) — available on BusyBox/OpenWrt.
        local lock_mtime lock_age now_ts
        now_ts=$(date +%s)
        lock_mtime=$(stat -c %Y "$PUBIP_REFRESH_LOCK" 2>/dev/null || echo "$now_ts")
        lock_age=$((now_ts - lock_mtime))
        if [ "$lock_age" -gt 300 ]; then
            rm -rf "$PUBIP_REFRESH_LOCK"
            mkdir "$PUBIP_REFRESH_LOCK" 2>/dev/null || return 0
        else
            return 0  # Another refresh is running — skip silently
        fi
    fi

    local t1 t2 t3 f1 f2 f3 winner ts tmp

    # Temp files for parallel fetches.
    # Create all three before forking — if any mktemp fails, release lock and abort
    # cleanly instead of leaving a dangling lockdir.
    f1=$(mktemp /tmp/podkop_ip1.XXXXXX 2>/dev/null) || { rm -rf "$PUBIP_REFRESH_LOCK"; return 1; }
    f2=$(mktemp /tmp/podkop_ip2.XXXXXX 2>/dev/null) || { rm -f "$f1"; rm -rf "$PUBIP_REFRESH_LOCK"; return 1; }
    f3=$(mktemp /tmp/podkop_ip3.XXXXXX 2>/dev/null) || { rm -f "$f1" "$f2"; rm -rf "$PUBIP_REFRESH_LOCK"; return 1; }

    # 1. ipinfo.io — international, plain text IP
    curl -s --connect-timeout 5 --max-time 8 \
        "https://ipinfo.io/ip" 2>/dev/null | tr -d '\n\r\t ' > "$f1" &
    local p1=$!

    # 2. ifconfig.me — plain text IP, not blocked in RU
    curl -s --connect-timeout 5 --max-time 8 \
        "https://ifconfig.me" 2>/dev/null | tr -d '\n\r\t ' > "$f2" &
    local p2=$!

    # 3. yandex.ru/internet — Russian service, parse IP from JSON in HTML
    curl -s --connect-timeout 5 --max-time 8 \
        "https://yandex.ru/internet" 2>/dev/null \
        | grep -oE '"ip":"[^"]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        > "$f3" &
    local p3=$!

    wait "$p1" "$p2" "$p3" 2>/dev/null

    t1=$(cat "$f1" 2>/dev/null); rm -f "$f1"
    t2=$(cat "$f2" 2>/dev/null); rm -f "$f2"
    t3=$(cat "$f3" 2>/dev/null); rm -f "$f3"

    # Validate: clear non-IP responses
    _validate_ip "$t1" || t1=""
    _validate_ip "$t2" || t2=""
    _validate_ip "$t3" || t3=""

    # Majority vote: prefer 2-of-3 agreement; fall back to first available
    if   [ -n "$t1" ] && [ "$t1" = "$t2" ]; then winner="$t1"
    elif [ -n "$t1" ] && [ "$t1" = "$t3" ]; then winner="$t1"
    elif [ -n "$t2" ] && [ "$t2" = "$t3" ]; then winner="$t2"
    elif [ -n "$t1" ]; then winner="$t1"
    elif [ -n "$t2" ]; then winner="$t2"
    elif [ -n "$t3" ]; then winner="$t3"
    else winner="Unavailable"
    fi

    # Build source list for transparency in UI
    local sources=""
    [ -n "$t1" ] && sources="ipinfo.io"
    [ -n "$t2" ] && { [ -n "$sources" ] && sources="${sources}, ifconfig.me" || sources="ifconfig.me"; }
    [ -n "$t3" ] && { [ -n "$sources" ] && sources="${sources}, yandex.ru"   || sources="yandex.ru"; }
    [ -z "$sources" ] && sources="all failed"

    ts=$(date +%s)

    # Atomic write: write to tmp then rename — prevents torn reads in get_public_ip_display.
    # If mktemp fails here (RAM disk full), release lock and bail — don't corrupt cache.
    tmp=$(mktemp /tmp/podkop_pubip.XXXXXX 2>/dev/null) || { rm -rf "$PUBIP_REFRESH_LOCK"; return 1; }
    printf '%s\n%s\n%s\n' "$ts" "$winner" "$sources" > "$tmp"
    # mv is atomic on same filesystem (tmpfs→tmpfs). If it fails, rm tmp and release lock.
    mv "$tmp" "$PUBIP_CACHE" 2>/dev/null || { rm -f "$tmp"; rm -rf "$PUBIP_REFRESH_LOCK"; return 1; }

    rm -rf "$PUBIP_REFRESH_LOCK"
    logger -t podkop-bot "[PublicIP] ${winner} (via ${sources})"
}

# Read public IP from cache instantly (no blocking I/O).
# Triggers background refresh if cache is stale or missing.
# Sanity-checks ts before arithmetic to avoid errors on corrupted cache.
get_public_ip_display() {
    local now ts age winner sources

    now=$(date +%s)

    if [ -f "$PUBIP_CACHE" ]; then
        ts=$(sed -n '1p' "$PUBIP_CACHE" 2>/dev/null)
        winner=$(sed -n '2p' "$PUBIP_CACHE" 2>/dev/null)
        sources=$(sed -n '3p' "$PUBIP_CACHE" 2>/dev/null)

        # Sanity-check ts: must be a number to avoid arithmetic error
        case "$ts" in
            ''|*[!0-9]*) ts=0 ;;
        esac
        [ -z "$winner" ] && winner="?"
        [ -z "$sources" ] && sources="?"

        age=$((now - ts))
        if [ "$age" -gt "$PUBIP_CACHE_TTL" ]; then
            refresh_public_ip_cache &
        fi
        printf '%s' "$winner"
    else
        refresh_public_ip_cache &
        printf 'Checking... (open Status again in ~10s)'
    fi
}

# Check if a community list tag is enabled for the given section
is_list_enabled() {
    local sec="$1" tag="$2" item raw_list
    raw_list=$(uci -q show podkop.${sec}.community_lists 2>/dev/null | cut -d= -f2-)
    [ -z "$raw_list" ] && return 1
    eval "set -- $raw_list"
    for item in "$@"; do [ "$item" = "$tag" ] && return 0; done
    return 1
}

# Build tag->URI cache from sing-box config.json outbounds (fallback when UCI link missing)
build_tag_uri_cache() {
    local tmp; tmp=$(mktemp /tmp/podkop_tag_uri.XXXXXX)
    jq -r '.outbounds[]? | select(.server != null and .server != "") |
        .tag + "=" + (
            if .type == "hysteria2"     then "hy2://"    + (.password//"-") + "@" + (.server//"-") + ":" + (.server_port|tostring)
            elif .type == "vless"       then "vless://"  + (.uuid//"-")     + "@" + (.server//"-") + ":" + (.server_port|tostring)
            elif .type == "shadowsocks" then "ss://"     + (.server//"-")   + ":" + (.server_port|tostring)
            elif .type == "trojan"      then "trojan://" + (.password//"-") + "@" + (.server//"-") + ":" + (.server_port|tostring)
            elif .type == "tuic"        then "tuic://"   + (.uuid//"-")     + ":" + (.password//"-") + "@" + (.server//"-") + ":" + (.server_port|tostring)
            else (.server//"-") + ":" + (.server_port|tostring)
            end
        )
    ' /etc/sing-box/config.json 2>/dev/null > "$tmp"
    mv "$tmp" "$TAG_URI_CACHE"
    logger -t podkop-bot "[Core] Proxy URI cache ready ($(wc -l < "$TAG_URI_CACHE" 2>/dev/null || echo 0) entries)"
}

# Build UCI proxy links cache using eval "set --" (uci get option N is broken on BusyBox)
# One link per line, preserving original UCI order.
build_uci_links_cache() {
    local tmp sec raw_list
    sec=$(get_active_section)
    tmp=$(mktemp /tmp/podkop_uci_links.XXXXXX)
    raw_list=$(uci -q show podkop.${sec}.selector_proxy_links 2>/dev/null | cut -d= -f2-)
    if [ -n "$raw_list" ]; then
        eval "set -- $raw_list"
        for link in "$@"; do printf '%s\n' "$link" >> "$tmp"; done
    fi
    mv "$tmp" "$UCI_LINKS_CACHE"
    logger -t podkop-bot "[Core] Proxy link cache ready for '${sec}' ($(wc -l < "$UCI_LINKS_CACHE" 2>/dev/null || echo 0) entries)"
}

# Build tag->human_name cache from #fragment in ALL UCI proxy link lists.
# Covers selector_proxy_links, urltest_proxy_links, url_proxy_links.
# Format: tag=Human Name
# This is the only way to get display names for URLTest group members since
# sing-box config.json does not store the #fragment comment.
build_tag_name_cache() {
    local tmp sec raw_list link frag tag
    sec=$(get_active_section)
    tmp=$(mktemp /tmp/podkop_tag_name.XXXXXX)
    # url mode uses proxy_string (plain option, one URL per line) — handle separately
    for uci_key in selector_proxy_links urltest_proxy_links; do
        raw_list=$(uci -q show podkop.${sec}.${uci_key} 2>/dev/null | cut -d= -f2-)
        [ -z "$raw_list" ] && continue
        eval "set -- $raw_list"
        for link in "$@"; do
            # Extract #fragment
            case "$link" in *#?*) frag="${link##*#}" ;; *) continue ;; esac
            frag=$(url_decode "$frag")
            [ -z "$frag" ] && continue
            # Derive tag from sing-box config matching this link's server:port
            # Use TAG_URI_CACHE: find tag whose reconstructed URI matches link server:port
            local srv_port; srv_port=$(extract_server_port_from_uri "${link%%#*}")
            [ -z "$srv_port" ] || [ "$srv_port" = "N/A" ] && continue
            # Match by server:port suffix in TAG_URI_CACHE
            tag=$(grep "@${srv_port}$\|:${srv_port}$" "$TAG_URI_CACHE" 2>/dev/null \
                | head -1 | cut -d= -f1)
            [ -n "$tag" ] && printf '%s=%s\n' "$tag" "$frag" >> "$tmp"
        done
    done
    # Also index fragments from proxy_string (url mode, multiline one-URL-per-line)
    local ps_raw ps_link ps_frag ps_tag ps_srv
    ps_raw=$(uci -q get podkop.${sec}.proxy_string 2>/dev/null)
    if [ -n "$ps_raw" ]; then
        printf '%s\n' "$ps_raw" | grep -v '^[[:space:]]*$' | while IFS= read -r ps_link; do
            case "$ps_link" in *#?*) ps_frag="${ps_link##*#}" ;; *) continue ;; esac
            ps_frag=$(url_decode "$ps_frag")
            [ -z "$ps_frag" ] && continue
            ps_srv=$(extract_server_port_from_uri "${ps_link%%#*}")
            [ -z "$ps_srv" ] || [ "$ps_srv" = "N/A" ] && continue
            ps_tag=$(grep "@${ps_srv}$\|:${ps_srv}$" "$TAG_URI_CACHE" 2>/dev/null \
                | head -1 | cut -d= -f1)
            [ -n "$ps_tag" ] && printf '%s=%s\n' "$ps_tag" "$ps_frag" >> "$tmp"
        done
    fi
    mv "$tmp" "$TAG_NAME_CACHE"
    logger -t podkop-bot "[Core] Proxy name cache ready for '${sec}' ($(wc -l < "$TAG_NAME_CACHE" 2>/dev/null || echo 0) entries)"
}

# Rebuild all caches. Community lists cache intentionally NOT cleared here
# to protect against GitHub rate limits (60 req/hr).
build_all_caches() {
    build_tag_uri_cache
    build_uci_links_cache
    build_tag_name_cache
}

# Returns url_proxy_links for $1 (section) as newline-separated list.
# Uses eval "set --" on UCI shell-quoted output - handles = signs inside
# vless/hy2/vmess URLs correctly (base64 padding, query params, etc).
get_url_proxy_links() {
    # proxy_config_type=url uses proxy_string (multiline textarea, one URL per line).
    # url_proxy_links does NOT exist in podkop UCI schema — this helper now reads
    # proxy_string and emits one non-empty line per URL.
    local sec="$1" raw
    raw=$(uci -q get podkop.${sec}.proxy_string 2>/dev/null)
    [ -z "$raw" ] && return 0
    printf '%s\n' "$raw" | grep -v '^[[:space:]]*$'
}

get_urltest_proxy_links() {
    local sec="$1" raw_list
    raw_list=$(uci -q show podkop.${sec}.urltest_proxy_links 2>/dev/null | cut -d= -f2-)
    [ -z "$raw_list" ] && return 0
    eval "set -- $raw_list"
    for link in "$@"; do printf '%s\n' "$link"; done
}

get_uri_by_tag() {
    [ -f "$TAG_URI_CACHE" ] || build_tag_uri_cache
    grep "^${1}=" "$TAG_URI_CACHE" | cut -d= -f2-
}

get_selector_link_by_index() {
    local idx="$1" line i=0
    [ -f "$UCI_LINKS_CACHE" ] || build_uci_links_cache
    while IFS= read -r line; do
        [ "$i" -eq "$idx" ] && { printf '%s\n' "$line"; return 0; }
        i=$((i + 1))
    done < "$UCI_LINKS_CACHE"
    return 1
}

# Atomic UCI commit with optional flock to prevent concurrent writes
uci_commit_safe() {
    local rc
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9; uci commit "$1"; exit $? ) 9>/tmp/podkop_uci.lock
        rc=$?
    else
        uci commit "$1"; rc=$?
    fi
    [ "$rc" -ne 0 ] && logger -t podkop-bot "[Error] uci commit '$1' failed (RC=$rc)"
    return $rc
}

# ==============================================================================
# SECTION 6: Proxy Resolution Helpers
# ==============================================================================

get_selector_tag() {
    local proxies="$1" sec tag
    sec=$(get_active_section)
    [ -z "$proxies" ] && proxies=$(clash_request "/proxies" 2>/dev/null)
    tag=$(printf '%s' "$proxies" | jq -r --arg s "$sec" \
        'if .proxies[$s] then $s
         else (.proxies | to_entries | map(select(.value.type=="Selector" and .key!="GLOBAL"))
               | sort_by(.value.all|length) | last | .key // ($s+"-out"))
         end' 2>/dev/null)
    echo "${tag:-${sec}-out}"
}

get_active_proxy_name() {
    local proxies="$1" sel
    [ -z "$proxies" ] && proxies=$(clash_request "/proxies" 2>/dev/null)
    sel=$(get_selector_tag "$proxies")
    printf '%s' "$proxies" | jq -r --arg sel "$sel" '
        .proxies[$sel].now as $n1 |
        if .proxies[$n1].type == "Selector" then
            .proxies[$n1].now as $n2 |
            if .proxies[$n2].type == "Selector" then .proxies[$n2].now else $n2 end
        else $n1 end // "Unknown"' 2>/dev/null || echo "Unknown"
}

_resolve_leaf() {
    local curr="$1" proxies="$2" i=0 pt nxt
    while [ "$i" -lt 5 ]; do
        pt=$(echo "$proxies" | jq -r --arg n "$curr" '.proxies[$n].type // empty')
        case "$pt" in
            Selector|URLTest|Fallback|LoadBalance)
                nxt=$(echo "$proxies" | jq -r --arg n "$curr" '.proxies[$n].now // empty')
                [ -n "$nxt" ] && [ "$nxt" != "$curr" ] && curr="$nxt" || break ;;
            *) break ;;
        esac
        i=$((i + 1))
    done
    echo "$curr"
}

get_proxy_index_by_tag() {
    local tag="$1" sec num
    sec=$(get_active_section)
    [ "$tag" = "${sec}-out" ] && { echo "0"; return 0; }
    num=$(printf '%s\n' "$tag" | sed -n "s/^${sec}-\([0-9][0-9]*\)-out$/\1/p")
    [ -n "$num" ] || return 1
    echo $((num - 1))
}

get_proxy_human_name_from_link() {
    local link="$1" frag
    case "$link" in *#*) frag="${link##*#}" ;; *) return 1 ;; esac
    [ -z "$frag" ] && return 1
    url_decode "$frag"
}

get_proxy_human_name_by_index() {
    local idx="$1" link name
    link=$(get_selector_link_by_index "$idx") || return 1
    name=$(get_proxy_human_name_from_link "$link")
    [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
    return 1
}

get_proxy_human_name_by_tag() {
    local tag="$1" idx human
    idx=$(get_proxy_index_by_tag "$tag") || return 1
    human=$(get_proxy_human_name_by_index "$idx")
    [ -n "$human" ] && { printf '%s\n' "$human"; return 0; }
    return 1
}

display_proxy_name() {
    local tag="$1" human cached_uri srv_port type_str
    [ -z "$tag" ] && { echo "Unknown"; return 0; }
    # 1. Try human name from selector_proxy_links index (fast, works for selector mode)
    human=$(get_proxy_human_name_by_tag "$tag")
    [ -n "$human" ] && { printf '%s\n' "$human"; return 0; }
    # 2. Try tag_name_cache (covers urltest_proxy_links, url_proxy_links, all modes)
    if [ -f "$TAG_NAME_CACHE" ]; then
        human=$(grep "^${tag}=" "$TAG_NAME_CACHE" | cut -d= -f2-)
        [ -n "$human" ] && { printf '%s\n' "$human"; return 0; }
    fi
    # 3. Fallback: reconstruct [type] server:port from TAG_URI_CACHE
    cached_uri=$(get_uri_by_tag "$tag")
    if [ -n "$cached_uri" ] && [ "$cached_uri" != "N/A" ]; then
        srv_port=$(extract_server_port_from_uri "$cached_uri")
        type_str=$(printf '%s' "$cached_uri" | cut -d: -f1)
        [ -n "$srv_port" ] && [ "$srv_port" != "N/A" ] && { printf '[%s] %s\n' "$type_str" "$srv_port"; return 0; }
    fi
    # 4. Last resort: return raw tag
    printf '%s\n' "$tag"
}

display_proxy_name_with_tag() {
    local tag="$1" human
    [ -z "$tag" ] && { echo "Unknown"; return 0; }
    human=$(display_proxy_name "$tag")
    [ "$human" != "$tag" ] && printf '%s (%s)\n' "$human" "$tag" || printf '%s\n' "$tag"
}

extract_server_port_from_uri() {
    local clean="${1%%#*}" sp
    # Handles both formats:
    #   with auth:    scheme://user[:pass]@host:port  (vless, hy2, trojan, tuic, ss+auth)
    #   without auth: scheme://host:port              (ss no-auth as stored in TAG_URI_CACHE)
    sp=$(printf '%s\n' "$clean" | sed -nE 's|^[^:]+://([^@/?]+@)?([^/?#]+).*|\2|p')
    [ -n "$sp" ] && printf '%s' "$sp" || printf 'N/A'
}

format_proxy_delay_status() {
    local delay="$1"
    [ -z "$delay" ] || [ "$delay" = "0" ] || [ "$delay" = "N/A" ] && { printf '%s Offline' "$E_RED"; return; }
    case "$delay" in
        ''|*[!0-9]*) printf '%s Unknown' "$E_YLW" ;;
        *) if   [ "$delay" -lt 300 ]; then printf '%s Healthy'      "$E_ON"
           elif [ "$delay" -lt 400 ]; then printf '%s Slow'         "$E_YLW"
           else                            printf '%s High Latency' "$E_RED"; fi ;;
    esac
}

build_proxy_list_label() {
    local proxies="$1" selector="$2" idx="$3" current_proxy="$4"
    local name display_name leaf type delay_raw icon delay_txt active_mark

    name=$(echo "$proxies" | jq -r --arg sel "$selector" --arg idx "$idx" \
        '.proxies[$sel].all[$idx|tonumber] // empty' 2>/dev/null)
    [ -z "$name" ] && return 1

    active_mark=""; [ "$name" = "$current_proxy" ] && active_mark="${E_PLAY} "
    display_name=$(display_proxy_name "$name")
    leaf=$(_resolve_leaf "$name" "$proxies"); [ -z "$leaf" ] && leaf="$name"
    type=$(echo "$proxies" | jq -r --arg n "$leaf" '.proxies[$n].type // .proxies[$n].adapterType // "Unknown"' 2>/dev/null)
    delay_raw=$(echo "$proxies" | jq -r --arg n "$name" '.proxies[$n].history[-1].delay // 0' 2>/dev/null)
    [ -z "$delay_raw" ] || [ "$delay_raw" = "0" ] && \
        delay_raw=$(echo "$proxies" | jq -r --arg n "$leaf" '.proxies[$n].history[-1].delay // 0' 2>/dev/null)

    if [ -n "$delay_raw" ] && [ "$delay_raw" != "0" ]; then
        delay_txt="${delay_raw}ms"
        if   [ "$delay_raw" -lt 300 ]; then icon="${E_ON}"
        elif [ "$delay_raw" -lt 400 ]; then icon="${E_YLW}"
        else                                icon="${E_RED}"; fi
    else
        delay_txt="N/A"; icon="${E_RED}"
    fi
    printf '%s%s %s | %s | %s' "$active_mark" "$icon" "$display_name" "$type" "$delay_txt"
}

get_uci_bool_emoji() {
    local value; value=$(uci -q get "$1.$2")
    [ "$value" = "1" ] && echo "${E_ON}" || echo "${E_OFF}"
}

toggle_uci_bool() {
    local config="$1" option="$2" current new_value
    current=$(uci -q get "${config}.${option}")
    new_value="1"; [ "$current" = "1" ] && new_value="0"
    uci set "${config}.${option}=${new_value}"
    uci_commit_safe "$(echo "$config" | cut -d. -f1)"
}

# Reload podkop with 10-second cooldown and optional flock.
# Records reload timestamp for Tunnel Health display.
# Returns: 0=success, 1=skipped (cooldown), 2=failed
safe_reload_podkop() {
    local force="$1" rc

    if command -v flock >/dev/null 2>&1; then
        ( flock -n 9 || exit 1
          local now last diff
          now=$(date +%s)
          if [ "$force" != "force" ]; then
              last=$(cat "$RELOAD_LOCK" 2>/dev/null || echo "0")
              diff=$((now - last))
              [ "$diff" -lt 10 ] && exit 1
          fi
          echo "$now" > "$RELOAD_LOCK"
          echo "$now" > "$RELOAD_TS_FILE"
          exit 0
        ) 9>/tmp/podkop_reload.lock || {
            logger -t podkop-bot "[Reload] Skipped (cooldown active)"; return 1
        }
    else
        local now last diff
        now=$(date +%s)
        if [ "$force" != "force" ]; then
            last=$(cat "$RELOAD_LOCK" 2>/dev/null || echo "0")
            diff=$((now - last))
            if [ "$diff" -lt 10 ]; then logger -t podkop-bot "[Reload] Skipped"; return 1; fi
        fi
        echo "$now" > "$RELOAD_LOCK"
        echo "$now" > "$RELOAD_TS_FILE"
    fi

    /etc/init.d/podkop reload; rc=$?
    build_all_caches
    [ "$rc" -ne 0 ] && { logger -t podkop-bot "[Error] Reload failed (RC=$rc)"; return 2; }
    logger -t podkop-bot "[Reload] Success"; return 0
}

# Stop podkop via init.d with SIGTERM -> SIGKILL escalation for orphaned sing-box
do_podkop_stop() {
    local rc pid_list
    /etc/init.d/podkop stop 2>/dev/null; rc=$?
    pid_list=$(pidof sing-box 2>/dev/null)
    if [ -n "$pid_list" ]; then
        logger -t podkop-bot "[Stop] Orphaned sing-box PIDs: ${pid_list}, sending SIGTERM"
        kill $pid_list 2>/dev/null; sleep 1
        pid_list=$(pidof sing-box 2>/dev/null)
        if [ -n "$pid_list" ]; then
            logger -t podkop-bot "[Stop] Sending SIGKILL to: ${pid_list}"
            kill -9 $pid_list 2>/dev/null
        fi
    fi
    pidof sing-box >/dev/null 2>&1 && return 1 || return 0
}

# ==============================================================================
# SECTION 7: Diagnostics
# ==============================================================================

run_internal_diagnostics() {
    local out_file="$1" rc=0 selector delay_res
    {
        echo "=== BOT INTERNAL DIAGNOSTICS ==="
        echo "Date: $(date)"; echo "Host: $(cat /proc/sys/kernel/hostname 2>/dev/null || echo Router)"
        echo; echo "--- Bot Version ---"; echo "${BOT_VERSION}"
        echo; echo "--- Core UCI ---"
        uci -q show podkop.main 2>/dev/null || true
        uci -q show podkop.main_routing 2>/dev/null || true
        uci -q show podkop.dns 2>/dev/null || true
        uci -q show podkop.settings 2>/dev/null || true
        echo; echo "--- Clash API ---"
        if clash_request "/version" "GET" 2>/dev/null | jq . >/dev/null 2>&1; then echo "OK"
        else echo "FAIL"; rc=1; fi
        echo; echo "--- Selector Delay Test ---"
        selector="$(get_selector_tag "")"; echo "$selector"
        delay_res="$(clash_request "/proxies/${selector}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" 2>/dev/null)"
        echo "$delay_res"
        echo; echo "--- Native Routing ---"; ip -4 route show 2>&1 || true
        echo; echo "--- Interfaces ---"; ip -4 addr show 2>&1 || true
        echo; echo "--- Nftables (podkop) ---"; nft list ruleset 2>/dev/null | grep -i podkop || true
        echo; echo "--- Log Tail ---"; logread 2>/dev/null | grep -iE 'podkop|sing-box' | tail -n 50 || true
    } > "$out_file"
    return "$rc"
}

run_upstream_health_report() {
    local out_file="$1"
    local proxies selector names_file ok_count fail_count total
    local name display_name tag_idx raw_link p_svr_port name_url res delay type leaf_n

    proxies="$(clash_request "/proxies" 2>/dev/null)"
    selector="$(get_selector_tag "$proxies")"
    names_file="$(mktemp /tmp/podkop_upstream.XXXXXX)"

    { echo "=== UPSTREAM HEALTH REPORT ==="; echo "Date: $(date)"; echo "Selector: ${selector}"; echo; } > "$out_file"

    if [ -z "$proxies" ] || [ "$proxies" = "null" ]; then
        echo "FAIL: Clash API unavailable" >> "$out_file"; rm -f "$names_file"; return 1
    fi

    echo "--- Candidates ---" >> "$out_file"
    echo "$proxies" | jq -r --arg sel "$selector" '.proxies[$sel].all[]?' 2>/dev/null > "$names_file"
    cat "$names_file" >> "$out_file"; echo >> "$out_file"
    echo "--- Delay Results ---" >> "$out_file"

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        display_name="$(display_proxy_name "$name")"
        tag_idx=$(get_proxy_index_by_tag "$name")
        [ -n "$tag_idx" ] && raw_link=$(get_selector_link_by_index "$tag_idx")
        [ -z "$raw_link" ] && raw_link=$(get_uri_by_tag "$name")
        [ -n "$raw_link" ] && p_svr_port=$(extract_server_port_from_uri "${raw_link%%#*}") || p_svr_port="N/A"
        name_url="$(printf '%s' "$name" | jq -rR '@uri')"
        res="$(clash_request "/proxies/${name_url}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" 2>/dev/null)"
        delay="$(echo "$res" | jq -r '.delay // "0"' 2>/dev/null)"
        # Resolve leaf for accurate type (same logic as proxy_menu)
        leaf_n=$(_resolve_leaf "$name" "$proxies")
        [ -z "$leaf_n" ] && leaf_n="$name"
        type="$(echo "$proxies" | jq -r --arg n "$leaf_n" '.proxies[$n].type // .proxies[$n].adapterType // "Unknown"' 2>/dev/null)"
        case "$delay" in ''|*[!0-9]*) delay="0" ;; esac
        if [ "$delay" -gt 0 ]; then
            printf '[OK]   %s | %s | %s | %sms | tag=%s\n' "$display_name" "$type" "$p_svr_port" "$delay" "$name" >> "$out_file"
        else
            printf '[FAIL] %s | %s | %s | timeout | tag=%s\n' "$display_name" "$type" "$p_svr_port" "$name" >> "$out_file"
        fi
    done < "$names_file"

    ok_count="$(grep -c '^\[OK\]'   "$out_file" 2>/dev/null)"; case "$ok_count"   in ''|*[!0-9]*) ok_count=0   ;; esac
    fail_count="$(grep -c '^\[FAIL\]' "$out_file" 2>/dev/null)"; case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
    total=$((ok_count + fail_count))
    { echo; echo "--- Summary ---"; echo "Total: ${total}"; echo "Healthy: ${ok_count}"; echo "Failed: ${fail_count}"; } >> "$out_file"
    rm -f "$names_file"
    [ "$fail_count" -gt 0 ] && return 1 || return 0
}

# ==============================================================================
# SECTION 8: Health Daemon (Background TG + sing-box watchdog)
# ==============================================================================
#
# Three independent checks per cycle:
# A. Telegram API direct reachability (raw curl, not through bot transport stack)
#   B. sing-box process liveness
#   C. SOCKS upstream probe (via probe_socks_upstream, 3 endpoints)
#
# Anti-flap hysteresis:
#   SOCKS down alert fires only after 2 consecutive down probes.
#   SOCKS recover alert fires only after 2 consecutive up probes.
#   TG connectivity uses same 2/2 hysteresis.
#
# On SOCKS down: resets LAST_ROUTE_FAST and LAST_ROUTE_POLL to "unknown"
#   so main loop immediately rediscovers working tier.
# On SOCKS recover: same reset + 3s DNS warmup sleep.
#
# Structured state written to SOCKS_STATE_FILE (key=value, one per line):
#   tg=ok|fail
#   socks=up|down
#   route=<LAST_ROUTE value>
#   last_ok=<last tier that worked>
# ==============================================================================

# check_health() — probes Telegram reachability via two independent paths.
# Writes TWO keys to HEALTH_STATE_FILE (sourced by watchdog after call):
#   tg_direct=ok|fail   — raw direct curl, no proxy (expected fail under RKN)
#   tg_transport=ok|fail — via primary mixed_proxy SOCKS (Podkop tier1)
# Return value: 0 if either path succeeded, 1 if both failed.
# Does NOT touch LAST_ROUTE_* — uses its own independent curl sessions.
check_health() {
    local tmp_resp _direct=fail _transport=fail
    local _sec _port _ip

    # A1: direct (no proxy) — raw internet reachability
    tmp_resp=$(curl -s -k --connect-timeout 5 --max-time 10 \
        -X GET "${API_URL}/getMe" 2>/dev/null)
    if printf '%s' "$tmp_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        _direct=ok
    fi

    # A2: via primary SOCKS (mixed_proxy / Podkop tier1)
    _sec=$(get_active_section)
    _port=$(uci -q get podkop.${_sec}.mixed_proxy_port || echo "2080")
    _ip=$(get_proxy_ip)
    tmp_resp=$(curl -s -k --connect-timeout 5 --max-time 10 \
        --socks5-hostname "${_ip}:${_port}" \
        -X GET "${API_URL}/getMe" 2>/dev/null)
    if printf '%s' "$tmp_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        _transport=ok
    fi

    # Write both results; watchdog reads tg_direct= and tg_transport= separately
    printf 'tg_direct=%s
tg_transport=%s
' "$_direct" "$_transport" > "$HEALTH_STATE_FILE"

    # Return 0 (success) if at least one path works
    [ "$_direct" = "ok" ] || [ "$_transport" = "ok" ]
}

_write_socks_state() {
    # Args: $1=tg_aggregate(ok|fail)  $2=socks(up|down)  $3=last_ok_route
    # Reads tg_direct/tg_transport from HEALTH_STATE_FILE (written by check_health).
    # Keeps tg= for backward compat with any external tooling.
    local _tg_direct _tg_transport
    _tg_direct=$(grep "^tg_direct=" "$HEALTH_STATE_FILE" 2>/dev/null | cut -d= -f2)
    _tg_transport=$(grep "^tg_transport=" "$HEALTH_STATE_FILE" 2>/dev/null | cut -d= -f2)
    # route= and route_name= removed: watchdog subshell holds stale LAST_ROUTE.
    # Authoritative route key is in MAIN_ROUTE_KEY_FILE, written by main process.
    printf 'tg=%s
tg_direct=%s
tg_transport=%s
socks=%s
last_ok=%s
' \
        "$1" "${_tg_direct:-?}" "${_tg_transport:-?}" "$2" "$3" > "$SOCKS_STATE_FILE"
}

# send_health_alert: health daemon uses this instead of bare api_request_fast.
# Captures the sent message_id and writes it to LAST_ALERT_MSG_FILE so that
# send_or_edit in the main bot can detect when a menu card is buried under
# a health alert and re-float the menu.
send_health_alert() {
    local payload="$1" resp alert_mid
    resp=$(api_request_fast "sendMessage" "$payload")
    alert_mid=$(printf '%s' "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [ -n "$alert_mid" ] && printf '%s' "$alert_mid" > "$LAST_ALERT_MSG_FILE"
}

start_health_daemon() {
    kill "$HEALTH_PID" 2>/dev/null
    (
        trap 'exit' INT TERM QUIT

        local interval
        local last_tg_state="unknown"  curr_tg_state
        local tg_fail_streak=0         tg_ok_streak=0
        local last_sb_state="running"  curr_sb_state sb_alert_txt new_pid
        local last_socks_state=""      curr_socks_state socks_alert_txt
        local socks_fail_streak=0      socks_ok_streak=0
        local sec m_ip m_port admin_payload last_ok_route="tier1"
        # Latency probe runs every PROBE_EVERY cycles (not every cycle — heavier)
        local probe_cycle=0 PROBE_EVERY=5
        # Track probe background PID to reap it before launching next one.
        # Without this, probe subshells accumulate as zombies over months of uptime
        # (one probe every ~5min = ~8640/month, each leaving an ash zombie entry).
        local _last_probe_pid=""
        # Read hostname once for alert prefixes (multi-router identification)
        local _hn; _hn=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
        # Leaf proxy tracking — alert when active proxy changes
        local last_leaf="" curr_leaf=""
        # Debounce: don't send leaf-change alerts more often than once per 60s
        local last_leaf_alert_ts=0

        while true; do
            interval=$(uci -q get podkop_bot.settings.health_interval || echo "60")
            sleep "$interval"

            probe_cycle=$((probe_cycle + 1))
            if [ "$probe_cycle" -ge "$PROBE_EVERY" ]; then
                probe_cycle=0
                # Summary log every PROBE_EVERY cycles instead of per-cycle ok spam
                _wd_log_route=$(cat "$MAIN_ROUTE_FILE" 2>/dev/null | tr -d '\n' || echo "unknown")
                logger -t podkop-bot "[Health] System OK | SOCKS: ${last_socks_state:-?} | sing-box: ${last_sb_state:-?} | Route: ${_wd_log_route}"
                # Reap previous probe subshell before launching a new one.
                # In BusyBox ash, background children become zombies until the parent
                # calls wait. Over months of uptime these accumulate (one per 5min cycle).
                [ -n "$_last_probe_pid" ] && wait "$_last_probe_pid" 2>/dev/null
                probe_all_socks_write &
                _last_probe_pid=$!
            fi

            sec=$(get_active_section)
            m_port=$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")
            m_ip=$(get_proxy_ip)

            # ------------------------------------------------------------------
            # Check A: Telegram API connectivity.
            # Tries direct curl first (shown as "TG direct" in Tunnel Health).
            # If direct fails, falls back to SOCKS probe (mixed_proxy).
            # Does NOT touch LAST_ROUTE_FAST/POLL — uses its own curl session.
            # Under RKN: direct fails, SOCKS succeeds → status "via SOCKS".
            # ------------------------------------------------------------------
            check_health
            # check_health writes tg_direct= and tg_transport= to HEALTH_STATE_FILE.
            # TG is "reachable" if either path works (direct OK or transport OK).
            local _tgd _tgt
            _tgd=$(grep "^tg_direct=" "$HEALTH_STATE_FILE" 2>/dev/null | cut -d= -f2)
            _tgt=$(grep "^tg_transport=" "$HEALTH_STATE_FILE" 2>/dev/null | cut -d= -f2)
            curr_tg_state="${_tgd}/${_tgt}"
            if [ "$_tgd" = "ok" ] || [ "$_tgt" = "ok" ]; then
                tg_fail_streak=0
                tg_ok_streak=$((tg_ok_streak + 1))
                if [ "$last_tg_state" = "fail" ] && [ "$tg_ok_streak" -ge 2 ]; then
                    last_tg_state="ok"
                    logger -t podkop-bot "[Watchdog] Telegram reachable again."
                    if [ "$(uci -q get podkop_bot.settings.alert_notify || echo 1)" = "1" ]; then
                        admin_payload=$(jq -n -c --arg cid "$ADMIN_ID" \
                            --arg txt "$(printf '<b>[%s]</b> %s <b>Telegram reachable</b>\n\nBot connection restored.\n<b>Route:</b> <code>%s</code>' \
                                "$_hn" "$E_OK" "${LAST_ROUTE_NAME:-unknown}")" \
                            '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
                        send_health_alert "$admin_payload"
                    fi
                fi
                [ "$last_tg_state" = "unknown" ] && last_tg_state="ok"
            else
                tg_ok_streak=0
                tg_fail_streak=$((tg_fail_streak + 1))
                if [ "$last_tg_state" = "ok" ] && [ "$tg_fail_streak" -ge 2 ]; then
                    last_tg_state="fail"
                    logger -t podkop-bot "[Watchdog] Telegram unreachable."
                    if [ "$(uci -q get podkop_bot.settings.alert_notify || echo 1)" = "1" ]; then
                        admin_payload=$(jq -n -c --arg cid "$ADMIN_ID" \
                            --arg txt "$(printf '<b>[%s]</b> %s <b>Telegram unreachable</b>\n\nBot lost connection.\n<b>podkop proxy:</b> unaffected, running normally.' \
                                "$_hn" "$E_WARN" "${LAST_ROUTE_NAME:-unknown}")" \
                            '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
                        send_health_alert "$admin_payload"
                    fi
                fi
                [ "$last_tg_state" = "unknown" ] && last_tg_state="fail"
            fi

            # ------------------------------------------------------------------
            # Check B: sing-box process liveness
            # ------------------------------------------------------------------
            if pidof sing-box >/dev/null 2>&1; then curr_sb_state="running"
            else curr_sb_state="stopped"; fi

            if [ "$curr_sb_state" != "$last_sb_state" ]; then
                if [ "$(uci -q get podkop_bot.settings.alert_notify || echo 1)" = "1" ]; then
                    if [ "$curr_sb_state" = "stopped" ]; then
                        local _sb_leaf _sb_leaf_disp
                        _sb_leaf=$([ -n "$last_leaf" ] && echo "$last_leaf" || echo "unknown")
                        _sb_leaf_disp=$(display_proxy_name "$_sb_leaf")
                        sb_alert_txt=$(printf '<b>[%s]</b> %s <b>sing-box stopped</b>\n\nVPN tunnel is down.\n<b>Last proxy:</b> <code>%s</code>\n\n<i>Traffic routing interrupted. Bot switching to fallback channel.</i>' \
                            "$_hn" "$E_ERR" "$_sb_leaf_disp")
                        # IPC: force transport reset — tier1/tier2 SOCKS are dead without sing-box
                        printf 'down' > "$ROUTE_CMD_FILE"
                        logger -t podkop-bot "[Transport] sing-box stopped. Signalling route reset."
                    else
                        new_pid=$(pidof sing-box 2>/dev/null | awk '{print $1}')
                        # Get current leaf after recovery (may take a moment to settle)
                        local _rec_leaf_disp
                        _rec_leaf_disp=$(display_proxy_name "${last_leaf:-unknown}")
                        sb_alert_txt=$(printf '<b>[%s]</b> %s <b>sing-box recovered</b>\n\nVPN tunnel is back up.\n<b>Active proxy:</b> <code>%s</code>\n\n<i>Traffic routing restored.</i>' \
                            "$_hn" "$E_OK" "$_rec_leaf_disp")
                        # IPC: signal recovery — let transport rediscover tier1
                        printf 'up' > "$ROUTE_CMD_FILE"
                        logger -t podkop-bot "[Transport] sing-box recovered. Signalling route rediscovery."
                    fi
                    admin_payload=$(jq -n -c --arg cid "$ADMIN_ID" --arg txt "$sb_alert_txt" \
                        '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
                    send_health_alert "$admin_payload"
                fi
                last_sb_state="$curr_sb_state"
            fi

            # ------------------------------------------------------------------
            # Check C: SOCKS upstream via probe_socks_upstream (3 endpoints)
            # Suppressed when sing-box is stopped (Check B covers that alert).
            # Hysteresis: alert only after 2 consecutive same-state probes.
            # ------------------------------------------------------------------
            if [ "$curr_sb_state" = "stopped" ]; then
                curr_socks_state="${last_socks_state:-up}"
                logger -t podkop-bot "[Watchdog] SOCKS probe skipped (sing-box is stopped)"
            else
                if probe_socks_upstream "$m_ip" "$m_port"; then
                    curr_socks_state="up"
                    # Log ok only on state change — suppress per-cycle spam
                    [ "$last_socks_state" != "up" ] && \
                        logger -t podkop-bot "[Watchdog] SOCKS proxy reachable (${m_ip}:${m_port})"
                else
                    # tier1 down — check if any tier2 fallback_socks is reachable.
                    # If so, mark socks=up so IPC "up" fires and bot uses tier2
                    # instead of staying on Direct indefinitely.
                    curr_socks_state="down"
                    logger -t podkop-bot "[Watchdog] SOCKS proxy unreachable (${m_ip}:${m_port})"
                    local _fb_raw _fb _fb_ok=0
                    _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
                    if [ -n "$_fb_raw" ]; then
                        eval "set -- $_fb_raw"
                        for _fb in "$@"; do
                            local _fb_ip _fb_port
                            _fb_ip=$(echo "$_fb" | sed 's|socks5h\?://||' | cut -d: -f1)
                            _fb_port=$(echo "$_fb" | sed 's|socks5h\?://||' | cut -d: -f2)
                            if probe_socks_upstream "$_fb_ip" "$_fb_port"; then
                                curr_socks_state="up"
                                _fb_ok=1
                                logger -t podkop-bot "[Watchdog] Primary SOCKS down, fallback ${_fb} is alive."
                                break
                            fi
                        done
                    fi
                fi
            fi

            # Hysteresis counters
            if [ "$curr_socks_state" = "up" ]; then
                socks_fail_streak=0
                socks_ok_streak=$((socks_ok_streak + 1))
            else
                socks_ok_streak=0
                socks_fail_streak=$((socks_fail_streak + 1))
            fi

            # Determine effective state with hysteresis (require 2 consecutive)
            local effective_socks="$last_socks_state"
            if [ "$curr_socks_state" = "down" ] && [ "$socks_fail_streak" -ge 2 ]; then
                effective_socks="down"
            elif [ "$curr_socks_state" = "up" ] && [ "$socks_ok_streak" -ge 2 ]; then
                effective_socks="up"
            fi

            # Act on effective state transition
            if [ -n "$last_socks_state" ] && [ "$effective_socks" != "$last_socks_state" ]; then
                if [ "$(uci -q get podkop_bot.settings.alert_notify || echo 1)" = "1" ]; then
                    # Use last known leaf (populated by Check D) — avoids extra clash_request
                    local active_px_display
                    active_px_display=$(display_proxy_name "${last_leaf:-unknown}")

                    if [ "$effective_socks" = "down" ]; then
                        # IPC: signal main process to reset route state and enter recovery mode.
                        # Cannot modify parent variables directly (subshell isolation).
                        printf 'down' > "$ROUTE_CMD_FILE"
                        logger -t podkop-bot "[Watchdog] SOCKS down. Triggering route reset."
                        # Build fallback availability from last probe file
                        local _fb_avail=""
                        if [ -f "$SOCKS_PROBE_FILE" ]; then
                            local _fp=1
                            while true; do
                                local _fline; _fline=$(grep "^tier2_${_fp}=" "$SOCKS_PROBE_FILE" 2>/dev/null)
                                [ -z "$_fline" ] && break
                                local _flat; _flat=$(echo "$_fline" | cut -d= -f2 | awk '{print $1}')
                                _fb_avail="${_fb_avail}  tier2_${_fp}=${_flat}\n"
                                _fp=$((_fp + 1))
                            done
                        fi
                        [ -z "$_fb_avail" ] && _fb_avail="  (none configured)\n"
                        socks_alert_txt=$(printf \
                            '<b>[%s]</b> %s <b>Primary SOCKS unavailable</b>\n\nBot switching to fallback channels.\n\n<b>Down:</b> <code>%s:%s</code>\n<b>Active proxy (podkop):</b> <code>%s</code>\n<b>Fallback channels:</b>\n<code>%b</code>\n<i>podkop traffic routing may be affected.</i>' \
                            "$_hn" "$E_ERR" "$m_ip" "$m_port" \
                            "$active_px_display" \
                            "$_fb_avail")
                    else
                        # IPC: signal main process to clear recovery mode and rediscover tier1.
                        sleep 3
                        printf 'up' > "$ROUTE_CMD_FILE"
                        last_ok_route="tier1"
                        logger -t podkop-bot "[Watchdog] SOCKS recovered. Triggering route rediscovery."
                        socks_alert_txt=$(printf \
                            '<b>[%s]</b> %s <b>Primary SOCKS recovered</b>\n\nBot back on primary channel.\n\n<b>Proxy:</b> <code>%s:%s</code>\n<b>Active proxy (podkop):</b> <code>%s</code>' \
                            "$_hn" "$E_OK" "$m_ip" "$m_port" \
                            "$active_px_display")
                    fi
                    admin_payload=$(jq -n -c --arg cid "$ADMIN_ID" --arg txt "$socks_alert_txt" \
                        '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
                    send_health_alert "$admin_payload"
                fi
                logger -t podkop-bot "[Watchdog] SOCKS state: ${last_socks_state} → ${effective_socks}"
                last_socks_state="$effective_socks"
            fi

            # Baseline on first run
            if [ -z "$last_socks_state" ]; then
                last_socks_state="$curr_socks_state"
                logger -t podkop-bot "[Watchdog] SOCKS baseline: ${curr_socks_state} (${m_ip}:${m_port})"
                # If baseline is "up" but bot is already on degraded route,
                # send IPC up immediately — no transition will fire later.
                if [ "$curr_socks_state" = "up" ]; then
                    _wd_cur_route=$(cat "$MAIN_ROUTE_KEY_FILE" 2>/dev/null | tr -d '\n\r\t ')
                    # Nudge if route is NOT a good SOCKS tier (tier1 or tier2_N).
                    # Use negative match to handle unknown values, typos, stale files.
                    case "${_wd_cur_route:-unknown}" in
                        tier1|tier2_*)
                            logger -t podkop-bot "[Watchdog] Route OK (${_wd_cur_route}), no action needed."
                            ;;
                        *)
                            logger -t podkop-bot "[Watchdog] Route stuck on ${_wd_cur_route}. SOCKS alive, forcing reconnect..."
                            printf 'up' > "$ROUTE_CMD_FILE"
                            printf '%s' "$(date +%s)" > "/tmp/podkop_bot_last_nudge"
                            ;;
                    esac
                fi
            fi

            # ------------------------------------------------------------------
            # Check D: Active proxy leaf change (selector/urltest switch)
            # Fires alert when sing-box auto-switches to a different proxy.
            # Only runs when sing-box is running and Clash API is available.
            # ------------------------------------------------------------------
            if [ "$curr_sb_state" = "running" ]; then
                local _wd_proxies _wd_sel _wd_leaf_raw _wd_leaf_type
                _wd_proxies=$(clash_request "/proxies" 2>/dev/null)
                if [ -n "$_wd_proxies" ] && [ "$_wd_proxies" != "null" ]; then
                    _wd_sel=$(get_selector_tag "$_wd_proxies")
                    _wd_leaf_raw=$(echo "$_wd_proxies" | jq -r --arg s "$_wd_sel" \
                        '.proxies[$s].now // empty' 2>/dev/null)
                    if [ -n "$_wd_leaf_raw" ]; then
                        curr_leaf=$(_resolve_leaf "$_wd_leaf_raw" "$_wd_proxies")
                        # Only accept fully-resolved leaf (not a group/URLTest node)
                        _wd_leaf_type=$(echo "$_wd_proxies" | jq -r \
                            --arg n "$curr_leaf" '.proxies[$n].type // empty' 2>/dev/null)
                        case "$_wd_leaf_type" in
                            Selector|URLTest|Fallback|LoadBalance) curr_leaf="" ;;
                        esac
                    else
                        curr_leaf=""
                    fi
                    if [ -n "$curr_leaf" ] && [ -n "$last_leaf" ] && \
                       [ "$curr_leaf" != "$last_leaf" ]; then
                        local old_disp new_disp _now_ts
                        old_disp=$(display_proxy_name "$last_leaf")
                        new_disp=$(display_proxy_name "$curr_leaf")
                        logger -t podkop-bot "[Watchdog] Active proxy changed: ${last_leaf} → ${curr_leaf}"
                        _now_ts=$(date +%s)
                        if [ "$(uci -q get podkop_bot.settings.alert_notify || echo 1)" = "1" ] && \
                           [ $((_now_ts - last_leaf_alert_ts)) -ge 60 ]; then
                            last_leaf_alert_ts=$_now_ts
                            local leaf_txt _mode
                            _mode=$(uci -q get podkop.${sec}.proxy_config_type 2>/dev/null || echo "unknown")
                            leaf_txt=$(printf '<b>[%s]</b> %s <b>Proxy auto-switched</b>\n\n<b>From:</b> <code>%s</code>\n<b>To:</b>   <code>%s</code>\n\n<i>%s selected a faster server. No interruption expected.</i>' \
                                "$_hn" "$E_TGT" "$old_disp" "$new_disp" \
                                "$([ "$_mode" = "urltest" ] && echo "URLTest" || echo "Selector")")
                            admin_payload=$(jq -n -c --arg cid "$ADMIN_ID" --arg txt "$leaf_txt" \
                                '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
                            send_health_alert "$admin_payload"
                        fi
                    fi
                    # Only store fully-resolved leaf to avoid group tags as baseline
                    [ -n "$curr_leaf" ] && last_leaf="$curr_leaf"
                fi
            fi

            # Per-cycle: if SOCKS is up but bot route is degraded (tier4/tier5/fail),
            # send IPC up every cycle to nudge main loop back to SOCKS discovery.
            # Per-cycle nudge: if SOCKS is up but bot route is degraded,
            # send IPC up so main loop rediscovers tier1 within one health interval.
            # Reads MAIN_ROUTE_KEY_FILE — written by main process, never stale.
            # Nudge: if SOCKS (tier2+) is alive but bot route is degraded,
            # send IPC up to trigger SOCKS rediscovery.
            # Throttled to once per 120s to avoid continuous LAST_ROUTE_FAST resets
            # which would cause full discovery every poll cycle (recover old=fail loop).
            if [ "$curr_socks_state" = "up" ] && [ "$curr_sb_state" = "running" ]; then
                _wd_cur_route=$(cat "$MAIN_ROUTE_KEY_FILE" 2>/dev/null | tr -d '\n\r\t ')
                # Negative match: nudge on anything that is NOT tier1/tier2_*
                # Handles stale files with typos/old values from previous bot versions.
                case "${_wd_cur_route:-unknown}" in
                    tier1|tier2_*)
                        : # good route, no nudge needed
                        ;;
                    *)
                        local _now_nudge _last_nudge
                        _now_nudge=$(date +%s)
                        _last_nudge=$(cat "/tmp/podkop_bot_last_nudge" 2>/dev/null || echo 0)
                        if [ $((_now_nudge - _last_nudge)) -ge 120 ]; then
                            logger -t podkop-bot "[Watchdog] Route stuck on ${_wd_cur_route}. SOCKS alive, forcing reconnect..."
                            printf 'up' > "$ROUTE_CMD_FILE"
                            printf '%s' "$_now_nudge" > "/tmp/podkop_bot_last_nudge"
                        fi
                        ;;
                esac
            fi

            # Write structured state for status screens
            _write_socks_state "$last_tg_state" "$last_socks_state" "$last_ok_route"

        done
    ) &
    HEALTH_PID=$!
}

# ==============================================================================
# SECTION 9: Command Handlers
# ==============================================================================

# ------------------------------------------------------------------------------
# 9.1: Section Management
# Active section shown in header text only — no spinning active-section button.
# ------------------------------------------------------------------------------
_handle_sections() {
    local cmd="$1" mid="$2"
    local sec=$(get_active_section)

    case "$cmd" in
        "sections_menu")
            rm -f "$STATE_FILE"
            local sections rows s text kb
            # uci show gives "podkop.NAME=section" for section objects.
            # Correct pattern matches lines ending in =section exactly.
            sections=$(uci -q show podkop 2>/dev/null \
                | grep -E '^podkop\.[^.=]+=section$' \
                | sed 's/^podkop\.\([^=]*\)=section$/\1/' \
                | grep -v '_routing$')
            rows=""
            for s in $sections; do
                # Only inactive sections get a button (Variant C: no spinning active button)
                [ "$s" != "$sec" ] && rows="${rows}[{\"text\":\"${s}\",\"callback_data\":\"set_sec_${s}\"}],"
            done
            text=$(cat <<EOF
${E_CLIP} <b>Sections Management</b>

<b>Active section:</b> <code>${sec}</code>

<i>Select a section to switch to:</i>
EOF
)
            kb="{\"inline_keyboard\":[${rows}[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"main_settings_menu\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;
        "set_sec_"*)
            local new_sec="${cmd#set_sec_}"
            echo "$new_sec" > "$ACTIVE_SECTION_FILE"
            build_all_caches
            _handle_sections "sections_menu" "$mid"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9.2: Proxy Selector Handler
# Pagination (10/page), add/delete/switch/test, batch delay test.
# FIXED: cmd_all_delay_test uses explicit PID wait (no more HEALTH_PID deadlock).
# FIXED: build_uci_links_cache uses eval (uci get N broken on BusyBox).
# ------------------------------------------------------------------------------
_handle_proxy() {
    local cmd="$1" mid="$2" text="$3" state="$4"
    local sec=$(get_active_section)
    local per_page=10

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"
        if [ "$state" = "wait_proxy_link" ]; then
            delete_message "$mid"
            local safe_link=$(printf "%s" "$text" | tr -d '\r\n')
            if echo "$safe_link" | grep -q '[[:space:]]'; then
                send_message "$(printf '%s <b>Invalid!</b>\nLink contains spaces.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"proxy_menu\"}]]}"
            elif ! echo "$safe_link" | grep -qE '^(vless|hy2|hysteria2|ss|trojan|vmess|tuic)://'; then
                send_message "$(printf '%s <b>Invalid protocol!</b>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"proxy_menu\"}]]}"
            elif uci -q show podkop.${sec} 2>/dev/null | grep -qF "selector_proxy_links='$safe_link'"; then
                send_message "$(printf '%s <b>Duplicate!</b>\nThis link is already in the list.' "$E_WARN")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"proxy_menu\"}]]}"
            else
                uci add_list podkop.${sec}.selector_proxy_links="$safe_link"
                uci_commit_safe podkop; build_all_caches
                send_message "$(printf '%s <b>Applying...</b>' "$E_RST")" ""
                safe_reload_podkop "force"; sleep 1
                _handle_proxy "proxy_menu" "" "" ""
            fi
        fi
        return
    fi

    case "$cmd" in
        proxy_menu|proxy_menu_p_*)
            rm -f "$STATE_FILE"
            local proxies selector current_proxy current_proxy_display
            local total total_pages page start_idx end_idx
            local rows list_text nav_row text kb
            local page_tsv name ptype delay_raw delay_txt icon active_mark
            local human_name short_name short_name_json abs_idx

            page=0
            [ "$cmd" != "proxy_menu" ] && page="${cmd#proxy_menu_p_}"

            # Show toast notification via answerCallbackQuery (set in CB_ANSWER_TEXT,
            # consumed by main loop). Card stays completely unchanged during the request —
            # no flash, no content replacement, just a brief popup at top of screen.
            [ "$cmd" != "proxy_menu" ] && CB_ANSWER_TEXT="$(printf '%s Refreshing...' "$E_TIME")"

            proxies=$(clash_request "/proxies")
            # Clash API can be slow on busy routers — retry once before giving up
            if [ -z "$proxies" ] || [ "$proxies" = "null" ]; then
                sleep 2
                proxies=$(clash_request "/proxies")
            fi
            if [ -z "$proxies" ] || [ "$proxies" = "null" ]; then
                send_or_edit "$mid" "$(printf '%s <b>Clash API Unavailable</b>\n<i>sing-box may be restarting. Try Refresh in a moment.</i>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_RST} Retry\",\"callback_data\":\"proxy_menu\"},{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}"
                return
            fi

            selector=$(get_selector_tag "$proxies")
            current_proxy=$(get_active_proxy_name "$proxies")
            current_proxy_display=$(html_escape "$(display_proxy_name_with_tag "$current_proxy")")

            # Detect URLTest mode and whether auto or manual is active
            local proxy_mode_cur urltest_group urltest_now is_auto_mode auto_hint
            proxy_mode_cur=$(uci -q get podkop.${sec}.proxy_config_type 2>/dev/null || echo "selector")
            auto_hint=""
            if [ "$proxy_mode_cur" = "urltest" ]; then
                # The URLTest group is a member of the selector — find it
                urltest_group=$(echo "$proxies" | jq -r \
                    --arg sel "$selector" \
                    '.proxies[$sel].all[]? | select(. as $n | $ENV.proxies | (. // "") | if . != "" then true else false end) | empty' \
                    2>/dev/null || echo "")
                # Simpler: find the URLTest-type member of selector's all list
                urltest_group=$(echo "$proxies" | jq -r \
                    --arg sel "$selector" \
                    '[.proxies[$sel].all[]? | select(.? as $n | (.proxies[$n].type? // "") == "URLTest")] | .[0] // empty' \
                    2>/dev/null || echo "")
                # Even simpler direct approach
                urltest_group=$(echo "$proxies" | jq -r \
                    '.proxies | to_entries[] | select(.value.type == "URLTest") | .key' \
                    2>/dev/null | head -1)
                urltest_now=$(echo "$proxies" | jq -r \
                    --arg g "$urltest_group" '.proxies[$g].now // empty' 2>/dev/null)
                # Active selector .now points to the urltest group itself = Auto mode
                local selector_now
                selector_now=$(echo "$proxies" | jq -r \
                    --arg sel "$selector" '.proxies[$sel].now // empty' 2>/dev/null)
                if [ "$selector_now" = "$urltest_group" ] || [ -z "$urltest_group" ]; then
                    is_auto_mode="1"
                    auto_hint=" | <i>Auto: best ping</i>"
                else
                    is_auto_mode="0"
                    auto_hint=" | <i>Manual: fixed</i>"
                fi
            fi

            total=$(echo "$proxies" | jq -r --arg sel "$selector" \
                '.proxies[$sel].all | length // 0' 2>/dev/null)

            total_pages=$(( (total + per_page - 1) / per_page ))
            [ "$total_pages" -eq 0 ] && total_pages=1
            [ "$page" -ge "$total_pages" ] && page=$((total_pages - 1))
            [ "$page" -lt 0 ] && page=0
            start_idx=$(( page * per_page ))
            end_idx=$(( start_idx + per_page ))
            [ "$end_idx" -gt "$total" ] && end_idx="$total"

            # ONE jq call for the entire page: returns TSV name\ttype\tdelay_raw
            # Resolves leaf proxy for type/delay (follows Selector->URLTest chains).
            # This replaces 4 jq forks per proxy with a single call — ~10x faster on MIPS.
            # depth counter prevents infinite recursion on cyclic A->B->A proxy references.
            page_tsv=$(echo "$proxies" | jq -r \
                --arg sel "$selector" \
                --argjson s "$start_idx" \
                --argjson e "$end_idx" \
                '
                .proxies[$sel].all[$s:$e][] as $name |
                # Walk chain with depth limit (max 5 hops) to guard against cycles
                def leaf(n; depth):
                    if depth <= 0 then n
                    else
                        .proxies[n].type as $t |
                        if ($t == "Selector" or $t == "URLTest" or $t == "Fallback") then
                            (.proxies[n].now // n) as $next |
                            if $next != n then leaf($next; depth - 1) else n end
                        else n end
                    end;
                leaf($name; 5) as $lf |
                [
                    $name,
                    (.proxies[$lf].type // .proxies[$lf].adapterType // "Unknown"),
                    ((.proxies[$name].history[-1].delay //
                      .proxies[$lf].history[-1].delay // 0) | tostring)
                ] | @tsv
                ' 2>/dev/null)

            rows=""; list_text=""; abs_idx="$start_idx"

            while IFS=$(printf '\t') read -r name ptype delay_raw; do
                [ -z "$name" ] && { abs_idx=$((abs_idx + 1)); continue; }

                # Delay icon and label
                case "$delay_raw" in
                    ''|0|'0') delay_txt="N/A"; icon="${E_RED}" ;;
                    *)
                        delay_txt="${delay_raw}ms"
                        if   [ "$delay_raw" -lt 300 ]; then icon="${E_ON}"
                        elif [ "$delay_raw" -lt 400 ]; then icon="${E_YLW}"
                        else                                icon="${E_RED}"; fi ;;
                esac

                # Human-readable name (UCI fragment or tag)
                human_name=$(display_proxy_name "$name")
                # Button: just human name — clean, matches what user sees in list
                short_name=$(json_escape "$human_name")

                # List: active proxy gets ▶ + bold; others plain
                # html_escape name: URI fragment may contain < > & from user input
                safe_name=$(html_escape "$human_name")
                if [ "$name" = "$current_proxy" ]; then
                    list_text=$(printf '%s\n<code>[%s]</code> %s <b>%s</b> | %s | %s' \
                        "$list_text" "$abs_idx" "${E_PLAY}" \
                        "$safe_name" "$ptype" "$delay_txt")
                else
                    list_text=$(printf '%s\n<code>[%s]</code> %s %s | %s | %s' \
                        "$list_text" "$abs_idx" "$icon" \
                        "$safe_name" "$ptype" "$delay_txt")
                fi
                rows="${rows}[{\"text\":\"${short_name}\",\"callback_data\":\"px_view_${abs_idx}\"}],"
                abs_idx=$((abs_idx + 1))
            done <<EOF
$page_tsv
EOF

            # Strip leading newline from list_text
            list_text="${list_text#?}"

            nav_row=""
            if [ "$total" -gt "$per_page" ]; then
                local prev_p=$((page - 1)) next_p=$((page + 1))
                local prev_cb="proxy_menu_p_${prev_p}" next_cb="proxy_menu_p_${next_p}"
                [ "$page" -eq 0 ] && prev_cb="proxy_menu_p_0"
                [ "$next_p" -ge "$total_pages" ] && next_cb="proxy_menu_p_${page}"
                nav_row="[{\"text\":\"${E_BACK} Prev\",\"callback_data\":\"${prev_cb}\"},{\"text\":\"${E_FILE} $((page+1))/${total_pages}\",\"callback_data\":\"proxy_menu_p_${page}\"},{\"text\":\"Next >\",\"callback_data\":\"${next_cb}\"}],"
            fi

            kb="{\"inline_keyboard\":[${rows}${nav_row}"
            # URLTest mode: prepend Auto (best ping) button on its own row
            if [ "$proxy_mode_cur" = "urltest" ] && [ -n "$urltest_group" ]; then
                if [ "${is_auto_mode:-0}" = "1" ]; then
                    kb="${kb}[{\"text\":\"${E_SCAN} Auto: best ping  ✓\",\"callback_data\":\"proxy_menu\"}],"
                else
                    kb="${kb}[{\"text\":\"${E_SCAN} Auto: best ping\",\"callback_data\":\"do_px_auto_urltest\"}],"
                fi
            fi
            kb="${kb}[{\"text\":\"${E_ADD} Add\",\"callback_data\":\"cmd_proxy_add\"},{\"text\":\"${E_TEST} Test All\",\"callback_data\":\"cmd_all_delay_test\"},{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"proxy_menu_p_${page}\"}],[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"main_menu\"}]]}"
            text=$(cat <<EOF
${E_GLOB} <b>Outbound Selector</b> [<code>${sec}</code>]
<b>Active:</b> <code>${current_proxy_display}</code>${auto_hint}

${list_text}

<i>Tap a proxy name to view details and switch.</i>
EOF
)
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_all_delay_test")
            # FIXED: collect explicit PIDs, wait only on those (not on HEALTH_PID)
            # UX FIX: send a separate status message below the card (don't replace it),
            # then delete the status message and refresh the card inline when done.
            local names_file pids="" pid p name_url batch=0 status_resp status_mid
            # Send a NEW message below (not edit) so the card stays visible
            local _status_payload
            _status_payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" \
                --arg txt "$(printf '%s <b>Testing all proxies...</b>' "$E_TIME")" \
                '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
            status_resp=$(api_request_fast "sendMessage" "$_status_payload")
            status_mid=$(printf '%s' "$status_resp" | jq -r '.result.message_id // empty' 2>/dev/null)

            proxies=$(clash_request "/proxies")
            selector=$(get_selector_tag "$proxies")
            names_file=$(mktemp /tmp/podkop_delay_test.XXXXXX 2>/dev/null) || {
                [ -n "$status_mid" ] && delete_message "$status_mid"
                return
            }
            echo "$proxies" | jq -r --arg sel "$selector" '.proxies[$sel].all[]?' 2>/dev/null > "$names_file"

            while IFS= read -r name; do
                [ -n "$name" ] || continue
                name_url=$(printf '%s' "$name" | jq -rR '@uri')
                clash_request "/proxies/${name_url}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" \
                    >/dev/null 2>&1 &
                pid=$!; pids="$pids $pid"; batch=$((batch + 1))
                if [ "$batch" -ge 10 ]; then
                    for p in $pids; do wait "$p" 2>/dev/null; done
                    pids=""; batch=0
                fi
            done < "$names_file"
            for p in $pids; do wait "$p" 2>/dev/null; done

            sleep 1; rm -f "$names_file"
            # Delete the status message, then refresh the card inline.
            # Clear CB_ANSWER_TEXT so the internal proxy_menu call doesn't fire another toast.
            [ -n "$status_mid" ] && delete_message "$status_mid"
            CB_ANSWER_TEXT=""
            _handle_proxy "proxy_menu_p_${page}" "$mid" "" ""
            ;;

        "px_view_"*)
            rm -f "$STATE_FILE"
            local p_idx p_name p_display_name leaf_name p_type
            local p_svr_port p_delay_raw p_delay p_status
            local raw_link share_uri tag_idx ret_page=0 text kb proxies selector

            p_idx="${cmd#px_view_}"
            ret_page=$(( p_idx / per_page ))
            proxies=$(clash_request "/proxies"); selector=$(get_selector_tag "$proxies")
            p_name=$(echo "$proxies" | jq -r --arg sel "$selector" --arg idx "$p_idx" \
                '.proxies[$sel].all[$idx|tonumber] // empty')
            [ -z "$p_name" ] && return

            p_display_name=$(html_escape "$(display_proxy_name "$p_name")")
            leaf_name=$(_resolve_leaf "$p_name" "$proxies"); [ -z "$leaf_name" ] && leaf_name="$p_name"
            p_type=$(echo "$proxies" | jq -r --arg n "$leaf_name" \
                '.proxies[$n].type // .proxies[$n].adapterType // "Unknown"' 2>/dev/null)

            tag_idx=$(get_proxy_index_by_tag "$p_name")
            [ -n "$tag_idx" ] && raw_link=$(get_selector_link_by_index "$tag_idx")
            [ -z "$raw_link" ] && raw_link=$(get_uri_by_tag "$p_name")
            if [ -n "$raw_link" ]; then
                share_uri="${raw_link%%#*}"; p_svr_port=$(extract_server_port_from_uri "$share_uri")
            else share_uri="N/A"; p_svr_port="N/A"; fi
            p_svr_port_esc=$(html_escape "$p_svr_port")

            p_delay_raw=$(echo "$proxies" | jq -r --arg n "$p_name" '.proxies[$n].history[-1].delay // 0' 2>/dev/null)
            [ -z "$p_delay_raw" ] || [ "$p_delay_raw" = "0" ] && \
                p_delay_raw=$(echo "$proxies" | jq -r --arg n "$leaf_name" '.proxies[$n].history[-1].delay // 0' 2>/dev/null)
            [ -z "$p_delay_raw" ] || [ "$p_delay_raw" = "0" ] && p_delay="N/A" || p_delay="${p_delay_raw}ms"
            # Escape Clash API values that go into HTML context
            p_type_esc=$(html_escape "$p_type")
            p_name_esc=$(html_escape "$p_name")
            leaf_name_esc=$(html_escape "$leaf_name")

            # Human-readable delay verdict
            local p_verdict
            case "$p_delay_raw" in
                ''|0|'0') p_verdict="Offline - no response" ;;
                *)
                    if   [ "$p_delay_raw" -lt 150 ]; then p_verdict="${E_ON} Excellent"
                    elif [ "$p_delay_raw" -lt 300 ]; then p_verdict="${E_ON} Good"
                    elif [ "$p_delay_raw" -lt 400 ]; then p_verdict="${E_YLW} Acceptable"
                    elif [ "$p_delay_raw" -lt 600 ]; then p_verdict="${E_RED} High latency"
                    else                                  p_verdict="${E_RED} Very high - consider switching"; fi ;;
            esac

            text=$(cat <<EOF
${E_GLOB} <b>Proxy Card</b> [<code>${sec}</code>]
<code>────────────────────</code>
<b>${p_display_name}</b>
<b>Type:</b> ${p_type_esc}
<b>Delay:</b> ${p_delay} - ${p_verdict}
<b>Server:</b> <code>${p_svr_port_esc}</code>
<b>Tag:</b> <code>${p_name_esc}</code>
EOF
)
            [ "$leaf_name" != "$p_name" ] && text=$(printf '%s\n<b>Leaf:</b> <code>%s</code>' "$text" "$leaf_name_esc")
            text=$(printf '%s\n<code>────────────────────</code>\n<b>Share Link:</b>\n<code>%s</code>' "$text" "$(html_escape "$share_uri")")
            kb=$(jq -n -c --arg i "$p_idx" --arg p "$ret_page" \
                --arg ok "${E_OK} Switch" --arg test "${E_RST} Test" \
                --arg del "${E_DEL} Delete" --arg back "${E_BACK} Back" '{
                inline_keyboard: [
                    [{"text":$ok,  "callback_data":("do_px_"+$i)},   {"text":$test,"callback_data":("test_px_"+$i)}],
                    [{"text":$del, "callback_data":("ask_del_px_"+$i)},{"text":$back,"callback_data":("proxy_menu_p_"+$p)}],
                    [{"text":"Menu","callback_data":"/menu"}]
                ]}')
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "test_px_"*)
            local p_idx="${cmd#test_px_}" p_name p_name_url proxies selector status_resp status_mid
            proxies=$(clash_request "/proxies"); selector=$(get_selector_tag "$proxies")
            p_name=$(echo "$proxies" | jq -r --arg sel "$selector" --arg idx "$p_idx" \
                '.proxies[$sel].all[$idx|tonumber] // empty')
            # Send separate status message below card — don't replace the card
            local _tst_payload
            _tst_payload=$(jq -n -c --arg cid "$TARGET_CHAT_ID" \
                --arg txt "$(printf '%s Testing <b>%s</b>...' "$E_TIME" "$(html_escape "$p_name")")" \
                '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
            status_resp=$(api_request_fast "sendMessage" "$_tst_payload")
            status_mid=$(printf '%s' "$status_resp" | jq -r '.result.message_id // empty' 2>/dev/null)
            p_name_url=$(echo "$p_name" | jq -rR '@uri')
            clash_request "/proxies/${p_name_url}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" >/dev/null
            [ -n "$status_mid" ] && delete_message "$status_mid"
            _handle_proxy "px_view_${p_idx}" "$mid" "" ""
            ;;

        "do_px_auto_urltest")
            # Switch selector to point at the URLTest group — restores auto best-ping mode
            local proxies selector urltest_grp payload
            proxies=$(clash_request "/proxies")
            selector=$(get_selector_tag "$proxies")
            urltest_grp=$(echo "$proxies" | jq -r \
                '.proxies | to_entries[] | select(.value.type == "URLTest") | .key' \
                2>/dev/null | head -1)
            if [ -n "$urltest_grp" ]; then
                payload=$(jq -n -c --arg name "$urltest_grp" '{name:$name}')
                clash_request "/proxies/${selector}" "PUT" "$payload" >/dev/null
                logger -t podkop-bot "Audit: ${audit_str} -> auto urltest via ${urltest_grp}"
            fi
            _handle_proxy "proxy_menu" "$mid" "" ""
            ;;

        "do_px_"*)
            local p_idx="${cmd#do_px_}" ret_page=0 proxies selector proxy_name payload
            ret_page=$(( ${cmd#do_px_} / per_page ))
            proxies=$(clash_request "/proxies"); selector=$(get_selector_tag "$proxies")
            proxy_name=$(echo "$proxies" | jq -r --arg sel "$selector" --arg idx "$p_idx" \
                '.proxies[$sel].all[$idx|tonumber] // empty')
            payload=$(jq -n -c --arg name "$proxy_name" '{name:$name}')
            clash_request "/proxies/${selector}" "PUT" "$payload" >/dev/null
            _handle_proxy "proxy_menu_p_${ret_page}" "$mid" "" ""
            ;;

        "ask_del_px_"*)
            local p_idx="${cmd#ask_del_px_}" p_name p_display_name raw_link text kb proxies selector

            proxies=$(clash_request "/proxies"); selector=$(get_selector_tag "$proxies")
            p_name=$(echo "$proxies" | jq -r --arg sel "$selector" --arg idx "$p_idx" \
                '.proxies[$sel].all[$idx|tonumber] // empty')

            # Always find the full original link by server:port matching.
            # Do NOT use get_selector_link_by_index(tag_idx) — tag format "main-N-out"
            # assumes sing-box config order == UCI list order, which is false after
            # any add/remove. Wrong index silently deletes a DIFFERENT proxy.
            # server:port from TAG_URI_CACHE is unique per outbound and order-independent.
            local _cached_uri _srv_port _sec
            _sec=$(get_active_section)
            _cached_uri=$(get_uri_by_tag "$p_name")

            if [ -n "$_cached_uri" ] && [ "$_cached_uri" != "N/A" ]; then
                _srv_port=$(extract_server_port_from_uri "$_cached_uri")
                if [ -n "$_srv_port" ] && [ "$_srv_port" != "N/A" ]; then
                    [ -f "$UCI_LINKS_CACHE" ] || build_uci_links_cache
                    raw_link=$(grep -m1 \
                        "@${_srv_port}[/?#]\|@${_srv_port}$\|://${_srv_port}[/?#]\|://${_srv_port}$" \
                        "$UCI_LINKS_CACHE" 2>/dev/null)
                    if [ -z "$raw_link" ]; then
                        local _raw_uci
                        _raw_uci=$(uci -q show podkop.${_sec}.selector_proxy_links 2>/dev/null | cut -d= -f2-)
                        if [ -n "$_raw_uci" ]; then
                            eval "set -- $_raw_uci"
                            for _link in "$@"; do
                                case "$_link" in
                                    *"@${_srv_port}"*|*"@${_srv_port}/"*|*"@${_srv_port}#"*|\
                                    *"://${_srv_port}"*|*"://${_srv_port}/"*|*"://${_srv_port}#"*)
                                        raw_link="$_link"; break ;;
                                esac
                            done
                        fi
                    fi
                fi
            fi

            if [ -z "$raw_link" ]; then
                send_or_edit "$mid" "$(printf '%s <b>Cannot resolve link for deletion.</b>\n<i>Caches may be stale — try Reload Podkop first.</i>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"px_view_${p_idx}\"}]]}"
                return
            fi
            # Store link in STATE_FILE keyed by clash index so do_del_px_confirmed_N
            # can verify it's reading the right entry even if STATE_FILE was recycled.
            printf '%s\n%s\n' "$p_idx" "$raw_link" > "$STATE_FILE"
            p_display_name=$(html_escape "$(display_proxy_name "$p_name")")
            text=$(printf '%s <b>Confirm Delete</b>\n\nSection <code>%s</code>:\n<code>%s</code>' "$E_WARN" "$sec" "$p_display_name")
            # Callback carries the clash index — no reliance on STATE_FILE alone
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Delete\",\"callback_data\":\"do_del_px_confirmed_${p_idx}\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"px_view_${p_idx}\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "do_del_px_confirmed_"*)
            local p_idx="${cmd#do_del_px_confirmed_}" raw_link state_idx ret_page=0
            # Read link from STATE_FILE and cross-check that the stored index matches.
            # If STATE_FILE was recycled (parallel action), re-resolve by server:port.
            state_idx=$(sed -n '1p' "$STATE_FILE" 2>/dev/null)
            raw_link=$(sed -n '2p' "$STATE_FILE" 2>/dev/null)
            rm -f "$STATE_FILE"

            # Index mismatch or empty STATE_FILE — re-resolve the link
            if [ -z "$raw_link" ] || [ "$state_idx" != "$p_idx" ]; then
                local proxies selector p_name _cached_uri _srv_port _sec
                _sec=$(get_active_section)
                proxies=$(clash_request "/proxies"); selector=$(get_selector_tag "$proxies")
                p_name=$(echo "$proxies" | jq -r --arg sel "$selector" --arg idx "$p_idx" \
                    '.proxies[$sel].all[$idx|tonumber] // empty')
                _cached_uri=$(get_uri_by_tag "$p_name")
                if [ -n "$_cached_uri" ] && [ "$_cached_uri" != "N/A" ]; then
                    _srv_port=$(extract_server_port_from_uri "$_cached_uri")
                    if [ -n "$_srv_port" ] && [ "$_srv_port" != "N/A" ]; then
                        [ -f "$UCI_LINKS_CACHE" ] || build_uci_links_cache
                        raw_link=$(grep -m1 \
                            "@${_srv_port}[/?#]\|@${_srv_port}$\|://${_srv_port}[/?#]\|://${_srv_port}$" \
                            "$UCI_LINKS_CACHE" 2>/dev/null)
                        if [ -z "$raw_link" ]; then
                            local _raw_uci
                            _raw_uci=$(uci -q show podkop.${_sec}.selector_proxy_links 2>/dev/null | cut -d= -f2-)
                            if [ -n "$_raw_uci" ]; then
                                eval "set -- $_raw_uci"
                                for _link in "$@"; do
                                    case "$_link" in
                                        *"@${_srv_port}"*|*"://${_srv_port}"*)
                                            raw_link="$_link"; break ;;
                                    esac
                                done
                            fi
                        fi
                    fi
                fi
            fi

            if [ -z "$raw_link" ]; then
                send_or_edit "$mid" "$(printf '%s <b>Delete failed!</b>\nCould not resolve link. Try Reload Podkop.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"proxy_menu\"}]]}"
                return
            fi
            [ -n "$p_idx" ] && ret_page=$(( p_idx / per_page ))
            uci del_list podkop.${sec}.selector_proxy_links="$raw_link"
            uci_commit_safe podkop; build_all_caches
            send_or_edit "$mid" "$(printf '%s <b>Applying...</b>' "$E_RST")" ""
            safe_reload_podkop "force"; sleep 1
            _handle_proxy "proxy_menu_p_${ret_page}" "$mid" "" ""
            ;;

        "cmd_proxy_add")
            echo "wait_proxy_link" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Send outbound link.</b>\n<i>(vless, hy2, hysteria2, ss, trojan, vmess, tuic)</i>' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"proxy_menu\"}]]}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9.2b: URL Links Handler (proxy_config_type=url)
# Edits proxy_string (the real podkop UCI key for url mode).
# proxy_string is a multiline textarea — one proxy URL per line.
# Outbound info screen (proxy_config_type=outbound) - redirect to LuCI/console.
# ------------------------------------------------------------------------------
_handle_url_links() {
    local cmd="$1" mid="$2" text="$3" state="$4"
    local sec=$(get_active_section)
    local per_page=8

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"
        if [ "$state" = "wait_url_link" ]; then
            delete_message "$mid"
            local safe_link
            safe_link=$(printf "%s" "$text" | tr -d '\r\n' | sed 's/[[:space:]]//g')
            if [ -z "$safe_link" ]; then
                send_message "$(printf '%s <b>Empty input.</b>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"url_links_menu\"}]]}"
            elif ! echo "$safe_link" | grep -qE '^(vless|hy2|hysteria2|ss|trojan|vmess|tuic)://'; then
                send_message "$(printf '%s <b>Invalid protocol!</b>\n<i>Expected: vless://, hy2://, ss://, trojan://, vmess://, tuic://</i>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"url_links_menu\"}]]}"
            elif get_url_proxy_links "$sec" | grep -qxF "$safe_link"; then
                send_message "$(printf '%s <b>Duplicate!</b>\nThis link is already in the list.' "$E_WARN")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"url_links_menu\"}]]}"
            else
                # Append new URL to proxy_string (one per line)
                local existing new_val
                existing=$(uci -q get podkop.${sec}.proxy_string 2>/dev/null)
                if [ -z "$existing" ]; then
                    new_val="$safe_link"
                else
                    new_val=$(printf '%s\n%s' "$existing" "$safe_link")
                fi
                uci set podkop.${sec}.proxy_string="$new_val"
                uci_commit_safe podkop
                send_message "$(printf '%s <b>Applying...</b>' "$E_RST")" ""
                safe_reload_podkop "force"; sleep 1
                _handle_url_links "url_links_menu" "" "" ""
            fi
        fi
        return
    fi

    case "$cmd" in
        url_links_menu|url_links_p_*)
            rm -f "$STATE_FILE"
            local page=0 link_list total total_pages
            local start_idx end_idx rows list_text nav_row kb abs_idx
            local short human

            [ "$cmd" != "url_links_menu" ] && page="${cmd#url_links_p_}"

            # Load URLs from proxy_string (one per line, skip empty)
            link_list=$(get_url_proxy_links "$sec")
            if [ -z "$link_list" ]; then
                total=0
            else
                total=$(printf '%s\n' "$link_list" | grep -c .)
            fi

            total_pages=$(( (total + per_page - 1) / per_page ))
            [ "$total_pages" -eq 0 ] && total_pages=1
            [ "$page" -ge "$total_pages" ] && page=$((total_pages - 1))
            [ "$page" -lt 0 ] && page=0
            start_idx=$(( page * per_page ))
            end_idx=$(( start_idx + per_page ))
            [ "$end_idx" -gt "$total" ] && end_idx="$total"

            rows=""; list_text=""; abs_idx=0
            local line_n=0
            if [ "$total" -gt 0 ]; then
                while IFS= read -r link; do
                    [ -z "$link" ] && continue
                    if [ "$line_n" -ge "$start_idx" ] && [ "$line_n" -lt "$end_idx" ]; then
                        local disp proto host
                        proto=$(echo "$link" | cut -d: -f1)
                        host=$(echo "$link" | sed 's|.*@||; s|/.*||; s|?.*||' | cut -c1-30)
                        disp="${proto}://...${host}"
                        human=$(json_escape "$disp")
                        list_text=$(printf '%s\n<code>[%s]</code> %s' "$list_text" "$line_n" "$disp")
                        rows="${rows}[{\"text\":\"${E_DEL} [${line_n}] ${human}\",\"callback_data\":\"ask_del_ul_${line_n}\"}],"
                    fi
                    line_n=$((line_n + 1))
                done <<EOF
$link_list
EOF
            fi

            list_text="${list_text#?}"
            [ -z "$list_text" ] && list_text="<i>No links configured yet.</i>"

            nav_row=""
            if [ "$total" -gt "$per_page" ]; then
                local prev_p=$((page - 1)) next_p=$((page + 1))
                local prev_cb="url_links_p_${prev_p}" next_cb="url_links_p_${next_p}"
                [ "$page" -eq 0 ] && prev_cb="url_links_p_0"
                [ "$next_p" -ge "$total_pages" ] && next_cb="url_links_p_${page}"
                nav_row="[{\"text\":\"< Prev\",\"callback_data\":\"${prev_cb}\"},{\"text\":\"$((page+1))/${total_pages}\",\"callback_data\":\"url_links_p_${page}\"},{\"text\":\"Next >\",\"callback_data\":\"${next_cb}\"}],"
            fi

            kb="{\"inline_keyboard\":[${rows}${nav_row}[{\"text\":\"${E_ADD} Add Link\",\"callback_data\":\"cmd_url_link_add\"},{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"url_links_menu\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            text=$(cat <<EOF
${E_GLOB} <b>URL Links</b> [<code>${sec}</code>]
<b>Total:</b> ${total} link(s)
${E_IDEA} <i>Stored in <code>proxy_string</code> — one URL per line.</i>

${list_text}

<i>Tap [${E_DEL}] next to a link to remove it.</i>
EOF
)
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_url_link_add")
            echo "wait_url_link" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Send outbound link.</b>\n<i>(vless, hy2, hysteria2, ss, trojan, vmess, tuic)</i>\n\nOne link per message.' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"url_links_menu\"}]]}"
            ;;

        "ask_del_ul_"*)
            local idx="${cmd#ask_del_ul_}"
            local link_to_del="" ln=0
            while IFS= read -r link; do
                [ -z "$link" ] && continue
                if [ "$ln" -eq "$idx" ]; then link_to_del="$link"; break; fi
                ln=$((ln + 1))
            done <<EOF
$(get_url_proxy_links "$sec")
EOF
            if [ -z "$link_to_del" ]; then
                send_or_edit "$mid" "$(printf '%s Entry not found.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"url_links_menu\"}]]}"
                return
            fi
            local disp_link
            disp_link=$(echo "$link_to_del" | cut -d: -f1)://...$(echo "$link_to_del" | sed 's|.*@||; s|/.*||; s|?.*||' | cut -c1-30)
            send_or_edit "$mid" \
                "$(printf '%s <b>Remove this link?</b>\n\n<code>%s</code>\n\n[%s] from section <code>%s</code>' "$E_WARN" "$(html_escape "$disp_link")" "$idx" "$sec")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Remove\",\"callback_data\":\"do_del_ul_${idx}\"},{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"url_links_menu\"}]]}"
            ;;

        "do_del_ul_"*)
            local idx="${cmd#do_del_ul_}"
            local ln=0 new_val="" link
            while IFS= read -r link; do
                [ -z "$link" ] && continue
                if [ "$ln" -ne "$idx" ]; then
                    if [ -z "$new_val" ]; then new_val="$link"
                    else new_val=$(printf '%s\n%s' "$new_val" "$link"); fi
                fi
                ln=$((ln + 1))
            done <<EOF
$(get_url_proxy_links "$sec")
EOF
            send_or_edit "$mid" "$(printf '%s <b>Removed. Applying...</b>' "$E_RST")" ""
            if [ -z "$new_val" ]; then
                uci -q delete podkop.${sec}.proxy_string
            else
                uci set podkop.${sec}.proxy_string="$new_val"
            fi
            uci_commit_safe podkop
            safe_reload_podkop "force"; sleep 1
            _handle_url_links "url_links_menu" "$mid" "" ""
            ;;

        "outbound_info")
            rm -f "$STATE_FILE"
            local luci_ip
            luci_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
            send_or_edit "$mid" \
                "$(printf '%s <b>Outbound Config mode</b>\n\nThis mode requires editing raw sing-box JSON.\nEditing JSON via Telegram is error-prone and not supported by the bot.\n\n<b>Please use LuCI or console instead:</b>\n\n<b>LuCI:</b> <code>http://%s/cgi-bin/luci/admin/services/podkop</code>\n<b>SSH:</b> <code>uci set podkop.MAIN.outbound_json=...</code>\n\n<i>After editing in LuCI/console, use Reload Podkop in the bot to apply.</i>' "$E_WARN" "$luci_ip")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_RST} Reload Podkop\",\"callback_data\":\"ask_reload_podkop\"},{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"main_menu\"}]]}"
            ;;
    esac
}
# ------------------------------------------------------------------------------
# 9.3: Core Podkop Settings
# ------------------------------------------------------------------------------
_handle_settings() {
    local cmd="$1" mid="$2" text="$3" state="$4"
    local sec=$(get_active_section)

    case "$cmd" in
        "main_settings_menu")
            rm -f "$STATE_FILE"
            local text kb
            text=$(cat <<EOF
${E_SET} <b>Podkop Settings</b> [<code>${sec}</code>]

Select a category to manage:
EOF
)
            kb="{\"inline_keyboard\":[
                [{\"text\":\"${E_FILE} Routing & Lists\",\"callback_data\":\"community_lists\"}],
                [{\"text\":\"${E_SET} Core Settings\",\"callback_data\":\"advanced_settings\"}],
                [{\"text\":\"${E_CLIP} Sections\",\"callback_data\":\"sections_menu\"}],
                [{\"text\":\"${E_BACK} Back\",\"callback_data\":\"/menu\"}]
            ]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "advanced_settings")
            rm -f "$STATE_FILE"
            local dl quic wan excl_ntp log_lvl interval proxy_mode conn_type mixed_en mixed_port
            local next_log log_lvl_disp next_int outbound_iface text kb

            dl=$(get_uci_bool_emoji "podkop.settings" "download_lists_via_proxy")
            quic=$(get_uci_bool_emoji "podkop.settings" "disable_quic")
            wan=$(get_uci_bool_emoji "podkop.settings" "enable_badwan_interface_monitoring")
            excl_ntp=$(get_uci_bool_emoji "podkop.settings" "exclude_ntp")
            log_lvl=$(uci -q get podkop.settings.log_level || echo "warn")
            interval=$(uci -q get podkop.settings.update_interval || echo "1d")
            proxy_mode=$(uci -q get podkop.${sec}.proxy_config_type || echo "selector")
            conn_type=$(uci -q get podkop.${sec}.connection_type || echo "proxy")
            mixed_en=$(get_uci_bool_emoji "podkop.${sec}" "mixed_proxy_enabled")
            mixed_port=$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")
            outbound_iface=$(uci -q get podkop.${sec}.outbound_interface 2>/dev/null || echo "auto")

            next_log="info"
            [ "$log_lvl" = "info" ]  && next_log="warn"
            [ "$log_lvl" = "warn" ]  && next_log="error"
            [ "$log_lvl" = "error" ] && next_log="debug"
            [ "$log_lvl" = "debug" ] && next_log="info"
            log_lvl_disp=$(printf "%s" "$log_lvl" | tr 'a-z' 'A-Z')

            next_int="1h"
            [ "$interval" = "1h" ]  && next_int="6h"
            [ "$interval" = "6h" ]  && next_int="12h"
            [ "$interval" = "12h" ] && next_int="1d"
            [ "$interval" = "1d" ]  && next_int="3d"
            [ "$interval" = "3d" ]  && next_int="1h"

            local mode_hint conn_hint
            case "$proxy_mode" in
                selector) mode_hint="${E_IDEA} <i>Selector: manually choose the active proxy.</i>" ;;
                urltest)  mode_hint="${E_IDEA} <i>URLTest: sing-box auto-picks the fastest proxy.</i>" ;;
                url)      mode_hint="${E_IDEA} <i>URL: single proxy_string connection.</i>" ;;
                outbound) mode_hint="${E_IDEA} <i>Outbound: raw sing-box JSON config.</i>" ;;
                *)        mode_hint="" ;;
            esac
            case "$conn_type" in
                proxy)     conn_hint="${E_IDEA} <i>Proxy: route matched traffic through VPN tunnel.</i>" ;;
                vpn)       conn_hint="${E_IDEA} <i>VPN: full tunnel mode, all traffic goes through VPN.</i>" ;;
                block)     conn_hint="${E_IDEA} <i>Block: matched traffic is blocked.</i>" ;;
                exclusion) conn_hint="${E_IDEA} <i>Exclusion: matched traffic bypasses the tunnel.</i>" ;;
                *)         conn_hint="" ;;
            esac

            local autostart_btn autostart_lbl
            if /etc/init.d/podkop enabled >/dev/null 2>&1; then
                autostart_btn="${E_ON} Autostart ON"; autostart_lbl="ask_toggle_autostart_off"
            else
                autostart_btn="${E_OFF} Autostart OFF"; autostart_lbl="ask_toggle_autostart_on"
            fi

            text=$(cat <<EOF
${E_SET} <b>Core Settings</b> [<code>${sec}</code>]
<code>────────────────────</code>
<b>Connection:</b> <code>${conn_type}</code>  ${conn_hint}
<b>Mode:</b> <code>${proxy_mode}</code>  ${mode_hint}
<code>────────────────────</code>
<b>Mixed Proxy:</b> ${mixed_en} port <code>${mixed_port}</code>
<b>Outbound iface:</b> <code>${outbound_iface}</code>
<code>────────────────────</code>
<b>Log:</b> <code>${log_lvl}</code> | <b>Update:</b> ${interval}
<b>Bad WAN:</b> ${wan} | <b>Excl. NTP:</b> ${excl_ntp}
<b>DL via Proxy:</b> ${dl} | <b>Disable QUIC:</b> ${quic}
EOF
)
            # ── Keyboard: 2-column, grouped by theme ────────────────────────────
            # Row 1: Connection type + Proxy mode  (core routing behaviour)
            kb="{\"inline_keyboard\":["
            kb="${kb}[{\"text\":\"Conn: ${conn_type}\",\"callback_data\":\"conn_type_menu\"},{\"text\":\"${E_TGT} Mode: ${proxy_mode}\",\"callback_data\":\"proxy_mode_menu\"}],"
            # Row 2: Mixed proxy toggle + port editor  (same entity, same row)
            kb="${kb}[{\"text\":\"${mixed_en} Mixed Proxy\",\"callback_data\":\"ask_toggle_mixed\"},{\"text\":\"${E_EDIT} Port: ${mixed_port}\",\"callback_data\":\"cmd_set_mixed_port\"}],"
            # Row 3: Outbound interface + DNS  (network routing config)
            kb="${kb}[{\"text\":\"${E_NET} Outbound: ${outbound_iface}\",\"callback_data\":\"cmd_set_outbound_iface\"},{\"text\":\"${E_NET} DNS\",\"callback_data\":\"dns_settings\"}],"
            # Row 4: URLTest settings + Domain Resolver  (per-section extras)
            kb="${kb}[{\"text\":\"${E_TGT} URLTest\",\"callback_data\":\"urltest_settings\"},{\"text\":\"${E_NET} Resolver\",\"callback_data\":\"domain_resolver_settings\"}],"
            # Row 5: YACD dashboard + Autostart  (system-level)
            kb="${kb}[{\"text\":\"${E_STAT} YACD\",\"callback_data\":\"yacd_settings\"},{\"text\":\"${autostart_btn}\",\"callback_data\":\"${autostart_lbl}\"}],"
            # Row 6: Disable QUIC + Update interval  (global flags, both fire-and-forget toggles)
            kb="${kb}[{\"text\":\"${quic} Disable QUIC\",\"callback_data\":\"ask_toggle_quic\"},{\"text\":\"Update: ${interval}\",\"callback_data\":\"set_update_int_${next_int}\"}],"
            # Row 7: Download via proxy + Exclude NTP  (global flags pair 2)
            kb="${kb}[{\"text\":\"${dl} DL via Proxy\",\"callback_data\":\"ask_toggle_dl\"},{\"text\":\"${excl_ntp} Excl. NTP\",\"callback_data\":\"ask_toggle_ntp\"}],"
            # Row 8: Bad WAN toggle + Bad WAN Details  (same entity — monitor config)
            kb="${kb}[{\"text\":\"${wan} Bad WAN\",\"callback_data\":\"ask_toggle_wan\"},{\"text\":\"${E_SCAN} Bad WAN Details\",\"callback_data\":\"badwan_details\"}],"
            # Row 9: Log level + Back
            kb="${kb}[{\"text\":\"Log: ${log_lvl_disp}\",\"callback_data\":\"set_log_${next_log}\"},{\"text\":\"${E_BACK} Back\",\"callback_data\":\"main_settings_menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "proxy_mode_menu")
            local current_mode
            current_mode=$(uci -q get podkop.${sec}.proxy_config_type || echo "selector")
            local pm_txt kb_pm
            pm_txt=$(printf '%s <b>Proxy Mode</b> [<code>%s</code>]\n\nCurrent: <code>%s</code>\n\n<b>url</b> — single proxy URL (proxy_string)\n<b>selector</b> — manual proxy selection\n<b>urltest</b> — auto best-ping selection\n<b>outbound</b> — raw sing-box JSON (LuCI/console only)' \
                "$E_TGT" "$sec" "$current_mode")
            kb_pm="{\"inline_keyboard\":[["
            for _m in url selector urltest outbound; do
                if [ "$_m" = "$current_mode" ]; then
                    kb_pm="${kb_pm}{\"text\":\"${E_OK} ${_m}\",\"callback_data\":\"proxy_mode_menu\"},"
                else
                    kb_pm="${kb_pm}{\"text\":\"${_m}\",\"callback_data\":\"ask_switch_mode_${_m}\"},"
                fi
            done
            # Remove trailing comma, close row and add back button
            kb_pm="${kb_pm%,}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}"
            send_or_edit "$mid" "$pm_txt" "$kb_pm"
            ;;

        "ask_switch_mode_"*)
            local target_mode="${cmd#ask_switch_mode_}"
            local current_mode warn_txt kb
            current_mode=$(uci -q get podkop.${sec}.proxy_config_type || echo "selector")
            case "$target_mode" in
                urltest)
                    local _utl_count
                    _utl_raw=$(uci -q show podkop.${sec}.urltest_proxy_links 2>/dev/null | cut -d= -f2-); _utl_count=0; [ -n "$_utl_raw" ] && { eval "set -- $_utl_raw"; _utl_count=$#; }
                    if [ "${_utl_count:-0}" -eq 0 ]; then
                        warn_txt=$(printf '%s <b>Switch to URLTest mode?</b>\n\n%s <b>URLTest Proxy Links is empty!</b>\npodkop will fail to start after switching.\n\n<b>Add links first:</b> Settings → Core → URLTest → Proxy Links\n\nSection: <code>%s</code>' "$E_ERR" "$E_ERR" "$sec")
                    else
                        warn_txt=$(printf '%s <b>Switch to URLTest mode?</b>\n\nURLTest: sing-box auto-picks the fastest proxy.\n<b>You will no longer manually select a proxy.</b>\n%s <b>%s</b> URLTest link(s) ready.\n\nSection: <code>%s</code>' "$E_WARN" "$E_OK" "$_utl_count" "$sec")
                    fi
                    ;;
                selector) warn_txt=$(printf '%s <b>Switch to Selector mode?</b>\n\nSelector: you manually pick the active proxy.\n\nSection: <code>%s</code>' "$E_WARN" "$sec") ;;
                url)      warn_txt=$(printf '%s <b>Switch to URL mode?</b>\n\nURL mode: single proxy connection via <code>proxy_string</code>.\nExisting selector/urltest links will be preserved in UCI but inactive.\n\nSection: <code>%s</code>' "$E_WARN" "$sec") ;;
                outbound) warn_txt=$(printf '%s <b>Switch to Outbound mode?</b>\n\nOutbound mode requires editing raw sing-box JSON via LuCI or console.\nBot cannot edit outbound JSON directly.\n\nSection: <code>%s</code>' "$E_WARN" "$sec") ;;
                *)        warn_txt=$(printf '%s Unknown mode: %s' "$E_ERR" "$target_mode") ;;
            esac
            # For urltest: add clone button when selector has links but urltest is empty
            local _kb_extra=""
            if [ "$target_mode" = "urltest" ]; then
                local _utl_c _sel_c
                _utl_raw2=$(uci -q show podkop.${sec}.urltest_proxy_links 2>/dev/null | cut -d= -f2-); _utl_c=0; [ -n "$_utl_raw2" ] && { eval "set -- $_utl_raw2"; _utl_c=$#; }
                # Use Clash API count — captures ALL proxies, not just those added via bot
                _sel_c=$(clash_request "/proxies" 2>/dev/null | \
                    jq -r --arg sel "$(get_selector_tag "")" '.proxies[$sel].all | length // 0' 2>/dev/null)
                if [ "${_utl_c:-0}" -eq 0 ] && [ "${_sel_c:-0}" -gt 0 ]; then
                    _kb_extra="[{\"text\":\"${E_RST} Clone ${_sel_c} links from Selector first\",\"callback_data\":\"cmd_clone_sel_to_utl\"}],"
                fi
            fi
            kb="{\"inline_keyboard\":[${_kb_extra}[{\"text\":\"${E_OK} Yes, Switch\",\"callback_data\":\"do_switch_mode_${target_mode}\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"proxy_mode_menu\"}]]}"
            send_or_edit "$mid" "$warn_txt" "$kb"
            ;;

        "do_switch_mode_"*)
            local target_mode="${cmd#do_switch_mode_}"
            uci set podkop.${sec}.proxy_config_type="$target_mode"
            uci_commit_safe podkop
            send_or_edit "$mid" "$(printf '%s Applying mode switch to <code>%s</code>...' "$E_RST" "$target_mode")" ""
            safe_reload_podkop "force"; sleep 1
            _handle_settings "advanced_settings" "$mid" "" ""
            ;;

        "set_update_int_"*) uci set podkop.settings.update_interval="${cmd#set_update_int_}"; uci_commit_safe podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;
        "set_log_"*)        uci set podkop.settings.log_level="${cmd#set_log_}";               uci_commit_safe podkop; safe_reload_podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;

        "ask_toggle_dl")   send_or_edit "$mid" "$(printf '%s Toggle download lists via proxy?' "$E_WARN")"  "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_dl\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;
        "ask_toggle_quic") send_or_edit "$mid" "$(printf '%s Toggle QUIC blocking?' "$E_WARN")"             "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_quic\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;
        "ask_toggle_wan")  send_or_edit "$mid" "$(printf '%s Toggle bad WAN monitoring?' "$E_WARN")"        "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_wan\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;
        "ask_toggle_ntp")  send_or_edit "$mid" "$(printf '%s Toggle NTP exclusion?' "$E_WARN")"             "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_ntp\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;
        "ask_toggle_mixed") send_or_edit "$mid" "$(printf '%s Toggle Mixed Proxy (SOCKS5 listener on port %s)?' "$E_WARN" "$(uci -q get podkop.${sec}.mixed_proxy_port || echo 2080)")" \
            "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_mixed\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;

        "conn_type_menu")
            local curr_ct; curr_ct=$(uci -q get podkop.${sec}.connection_type || echo "proxy")
            local ct_txt; ct_txt=$(printf '%s <b>Connection Type</b> [<code>%s</code>]\n\nCurrent: <code>%s</code>\n\n<b>proxy</b> - route matched traffic through VPN tunnel\n<b>vpn</b> - full tunnel, all traffic through VPN\n<b>block</b> - drop matched traffic\n<b>exclusion</b> - matched traffic bypasses tunnel' "$E_SET" "$sec" "$curr_ct")
            send_or_edit "$mid" "$ct_txt" \
                "{\"inline_keyboard\":[[{\"text\":\"Proxy\",\"callback_data\":\"do_set_conn_proxy\"},{\"text\":\"VPN\",\"callback_data\":\"do_set_conn_vpn\"},{\"text\":\"Block\",\"callback_data\":\"do_set_conn_block\"},{\"text\":\"Exclusion\",\"callback_data\":\"do_set_conn_exclusion\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}"
            ;;
        "do_set_conn_"*)
            local new_ct="${cmd#do_set_conn_}"
            uci set podkop.${sec}.connection_type="$new_ct"
            uci_commit_safe podkop
            send_or_edit "$mid" "$(printf '%s Applying connection type <code>%s</code>...' "$E_RST" "$new_ct")" ""
            safe_reload_podkop "force"; sleep 1
            _handle_settings "advanced_settings" "$mid" "" ""
            ;;

        "do_toggle_dl")   toggle_uci_bool "podkop.settings" "download_lists_via_proxy";           safe_reload_podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;
        "do_toggle_quic") toggle_uci_bool "podkop.settings" "disable_quic";                        safe_reload_podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;
        "do_toggle_wan")  toggle_uci_bool "podkop.settings" "enable_badwan_interface_monitoring";   safe_reload_podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;
        "do_toggle_ntp")  toggle_uci_bool "podkop.settings" "exclude_ntp";                         safe_reload_podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;
        "do_toggle_mixed") toggle_uci_bool "podkop.${sec}" "mixed_proxy_enabled";                  safe_reload_podkop; _handle_settings "advanced_settings" "$mid" "" "" ;;

        "ask_toggle_autostart_off")
            send_or_edit "$mid" \
                "$(printf '%s <b>Disable Podkop autostart?</b>\n\nPodkop will NOT start on reboot.\nYou can re-enable it here at any time.' "$E_WARN")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Disable\",\"callback_data\":\"do_autostart_off\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;
        "ask_toggle_autostart_on")
            send_or_edit "$mid" \
                "$(printf '%s <b>Enable Podkop autostart?</b>\n\nPodkop will start automatically on every reboot.' "$E_WARN")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Enable\",\"callback_data\":\"do_autostart_on\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}" ;;
        "do_autostart_off")
            /etc/init.d/podkop disable 2>/dev/null
            send_or_edit "$mid" "$(printf '%s Podkop autostart <b>disabled</b>.' "$E_OK")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}" ;;
        "do_autostart_on")
            /etc/init.d/podkop enable 2>/dev/null
            send_or_edit "$mid" "$(printf '%s Podkop autostart <b>enabled</b>.' "$E_OK")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}" ;;
    esac
}


# ------------------------------------------------------------------------------
# 9.3b: Section Extras — URLTest tuning, Domain Resolver, Bad WAN details
# ------------------------------------------------------------------------------
_handle_section_extras() {
    local cmd="$1" mid="$2" text="$3" state="$4"
    local sec
    sec=$(get_active_section)

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"
        case "$state" in
            wait_urltest_url)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\r\n')
                if ! echo "$val" | grep -qE '^https?://'; then
                    send_message "$(printf '%s Invalid URL. Must start with http:// or https://' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_settings\"}]]}"
                else
                    uci set podkop.${sec}.urltest_testing_url="$val"
                    uci_commit_safe podkop; safe_reload_podkop
                    _handle_section_extras "urltest_settings" "" "" ""
                fi ;;
            wait_urltest_interval)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\n\r\t ')
                if ! echo "$val" | grep -qE '^[0-9]+[smh]$'; then
                    send_message "$(printf '%s Invalid interval. Examples: 3m, 180s, 1h' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_settings\"}]]}"
                else
                    uci set podkop.${sec}.urltest_check_interval="$val"
                    uci_commit_safe podkop; safe_reload_podkop
                    _handle_section_extras "urltest_settings" "" "" ""
                fi ;;
            wait_urltest_tolerance)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\n\r\t ')
                if ! echo "$val" | grep -qE '^[0-9]+$'; then
                    send_message "$(printf '%s Invalid value. Enter a number in milliseconds (e.g. 50).' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_settings\"}]]}"
                else
                    uci set podkop.${sec}.urltest_tolerance="$val"
                    uci_commit_safe podkop; safe_reload_podkop
                    _handle_section_extras "urltest_settings" "" "" ""
                fi ;;
            wait_dr_server)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\r\n\t ')
                uci set podkop.${sec}.domain_resolver_dns_server="$val"
                uci_commit_safe podkop; safe_reload_podkop
                _handle_section_extras "domain_resolver_settings" "" "" "" ;;
            wait_badwan_ifaces)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\r\n')
                uci set podkop.settings.badwan_monitored_interfaces="$val"
                uci_commit_safe podkop; safe_reload_podkop
                _handle_section_extras "badwan_details" "" "" "" ;;
            wait_badwan_delay)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\n\r\t ')
                if ! echo "$val" | grep -qE '^[0-9]+$'; then
                    send_message "$(printf '%s Invalid value. Enter seconds (e.g. 10).' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"badwan_details\"}]]}"
                else
                    uci set podkop.settings.badwan_reload_delay="$val"
                    uci_commit_safe podkop; safe_reload_podkop
                    _handle_section_extras "badwan_details" "" "" ""
                fi ;;
            wait_mixed_port)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\n\r\t ')
                if ! echo "$val" | grep -qE '^[0-9]+$' || [ "$val" -lt 1024 ] || [ "$val" -gt 65535 ]; then
                    send_message "$(printf '%s Invalid port. Must be 1024-65535.' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"}]]}"
                else
                    uci set podkop.${sec}.mixed_proxy_port="$val"
                    uci_commit_safe podkop
                    send_message "$(printf '%s Port set to %s. Applying...' "$E_OK" "$val")" ""
                    safe_reload_podkop "force"; sleep 1
                    _handle_settings "advanced_settings" "" "" ""
                fi ;;
            wait_outbound_iface)
                delete_message "$mid"
                local val; val=$(printf '%s' "$text" | tr -d '\r\n\t ')
                if [ -z "$val" ]; then
                    uci delete podkop.${sec}.outbound_interface 2>/dev/null
                else
                    uci set podkop.${sec}.outbound_interface="$val"
                fi
                uci_commit_safe podkop
                send_message "$(printf '%s Interface set to: %s. Applying...' "$E_OK" "${val:-auto}")" ""
                safe_reload_podkop "force"; sleep 1
                _handle_settings "advanced_settings" "" "" "" ;;
            wait_utl_link)
                delete_message "$mid"
                local safe_link; safe_link=$(printf "%s" "$text" | tr -d '\r\n' | sed 's/[[:space:]]//g')
                if ! echo "$safe_link" | grep -qE '^(vless|hy2|hysteria2|ss|trojan|vmess|tuic)://'; then
                    send_message "$(printf '%s <b>Invalid protocol!</b>\nExpected: vless://, hy2://, ss://, trojan://, vmess://, tuic://' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_links_menu\"}]]}"
                elif get_urltest_proxy_links "$sec" | grep -qxF "$safe_link"; then
                    send_message "$(printf '%s <b>Duplicate!</b> Link already in list.' "$E_WARN")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_links_menu\"}]]}"
                else
                    uci add_list podkop.${sec}.urltest_proxy_links="$safe_link"
                    uci_commit_safe podkop
                    send_message "$(printf '%s <b>Applying...</b>' "$E_RST")" ""
                    safe_reload_podkop "force"; sleep 1
                    _handle_section_extras "urltest_links_menu" "" "" ""
                fi ;;
        esac
        return
    fi

    case "$cmd" in
        "urltest_settings")
            rm -f "$STATE_FILE"
            local ut_url ut_interval ut_tol ut_links_count sel_links_count
            ut_url=$(uci -q get podkop.${sec}.urltest_testing_url 2>/dev/null || echo "https://www.gstatic.com/generate_204 (default)")
            ut_interval=$(uci -q get podkop.${sec}.urltest_check_interval 2>/dev/null || echo "3m (default)")
            ut_tol=$(uci -q get podkop.${sec}.urltest_tolerance 2>/dev/null || echo "50 (default)")
            _utl_lraw=$(uci -q show podkop.${sec}.urltest_proxy_links 2>/dev/null | cut -d= -f2-); ut_links_count=0; [ -n "$_utl_lraw" ] && { eval "set -- $_utl_lraw"; ut_links_count=$#; }
            _sel_lraw=$(uci -q show podkop.${sec}.selector_proxy_links 2>/dev/null | cut -d= -f2-); sel_links_count=0; [ -n "$_sel_lraw" ] && { eval "set -- $_sel_lraw"; sel_links_count=$#; }
            local _clone_btn=""
            if [ "${sel_links_count:-0}" -gt 0 ]; then
                _clone_btn="[{\"text\":\"${E_RST} Clone from Selector (${sel_links_count})\",\"callback_data\":\"cmd_clone_sel_to_utl\"}],"
            else
                # Fallback: check Clash API for proxy count even if UCI is empty
                local _clash_count
                _clash_count=$(clash_request "/proxies" 2>/dev/null | \
                    jq -r --arg sel "$(get_selector_tag "")" '.proxies[$sel].all | length // 0' 2>/dev/null)
                [ "${_clash_count:-0}" -gt 0 ] && \
                    _clone_btn="[{\"text\":\"${E_RST} Clone from Selector (${_clash_count})\",\"callback_data\":\"cmd_clone_sel_to_utl\"}],"
            fi
            local _links_hint=""
            [ "${ut_links_count:-0}" -eq 0 ] && \
                _links_hint="\n${E_ERR} <b>Empty — podkop will abort in URLTest mode!</b>"
            send_or_edit "$mid" \
                "$(printf '%s <b>URLTest Settings</b> [<code>%s</code>]\n\n<b>Testing URL:</b>\n<code>%s</code>\n\n<b>Check Interval:</b> <code>%s</code>\n<i>How often sing-box tests proxies. Format: 3m, 180s, 1h</i>\n\n<b>Tolerance:</b> <code>%s ms</code>\n<i>Max latency diff to switch proxies. Lower = more switching.</i>\n\n<b>Proxy Links:</b> %s entries%b' \
                    "$E_TGT" "$sec" "$ut_url" "$ut_interval" "$ut_tol" "$ut_links_count" "$_links_hint")" \
                "{\"inline_keyboard\":[${_clone_btn}[{\"text\":\"${E_EDIT} Testing URL\",\"callback_data\":\"cmd_set_ut_url\"},{\"text\":\"${E_EDIT} Interval\",\"callback_data\":\"cmd_set_ut_interval\"}],[{\"text\":\"${E_EDIT} Tolerance\",\"callback_data\":\"cmd_set_ut_tolerance\"},{\"text\":\"${E_GLOB} Proxy Links\",\"callback_data\":\"urltest_links_menu\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"}]]}"
            ;;

        "cmd_set_ut_url")
            echo "wait_urltest_url" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set URLTest Testing URL</b>\n\nCurrent: <code>%s</code>\n\nSend new URL (must start with http:// or https://).\nDefault: <code>https://www.gstatic.com/generate_204</code>' \
                    "$E_EDIT" "$(uci -q get podkop.${sec}.urltest_testing_url || echo "not set")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"urltest_settings\"}]]}"
            ;;

        "cmd_set_ut_interval")
            echo "wait_urltest_interval" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set URLTest Check Interval</b>\n\nCurrent: <code>%s</code>\n\nFormat: <code>3m</code>, <code>180s</code>, <code>1h</code>\nDefault: 3m' \
                    "$E_EDIT" "$(uci -q get podkop.${sec}.urltest_check_interval || echo "not set")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"urltest_settings\"}]]}"
            ;;

        "cmd_set_ut_tolerance")
            echo "wait_urltest_tolerance" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set URLTest Tolerance</b>\n\nCurrent: <code>%s ms</code>\n\nEnter value in milliseconds.\nDefault: 50ms. Lower values cause more proxy switching.' \
                    "$E_EDIT" "$(uci -q get podkop.${sec}.urltest_tolerance || echo "not set")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"urltest_settings\"}]]}"
            ;;

        "domain_resolver_settings")
            rm -f "$STATE_FILE"
            local dr_en dr_type dr_server dr_en_icon
            dr_en=$(uci -q get podkop.${sec}.domain_resolver_enabled 2>/dev/null || echo "0")
            dr_type=$(uci -q get podkop.${sec}.domain_resolver_dns_type 2>/dev/null || echo "udp")
            dr_server=$(uci -q get podkop.${sec}.domain_resolver_dns_server 2>/dev/null || echo "not set")
            dr_en_icon=$([ "$dr_en" = "1" ] && echo "$E_ON" || echo "$E_OFF")

            # Cycle DNS type: udp -> doh -> dot -> udp
            local next_dr_type="doh"
            [ "$dr_type" = "doh" ] && next_dr_type="dot"
            [ "$dr_type" = "dot" ] && next_dr_type="udp"

            send_or_edit "$mid" \
                "$(printf '%s <b>Domain Resolver</b> [<code>%s</code>]\n\n%s <b>Enabled:</b> <code>%s</code>\n<b>DNS Type:</b> <code>%s</code>\n<b>DNS Server:</b> <code>%s</code>\n\n<i>Domain Resolver resolves domains in rules via this DNS,\nindependently from the global DNS settings.</i>' \
                    "$E_NET" "$sec" "$dr_en_icon" \
                    "$([ "$dr_en" = "1" ] && echo "yes" || echo "no")" \
                    "$dr_type" "$dr_server")" \
                "{\"inline_keyboard\":[[{\"text\":\"${dr_en_icon} Toggle\",\"callback_data\":\"do_toggle_dr\"},{\"text\":\"DNS Type: ${dr_type}\",\"callback_data\":\"set_dr_type_${next_dr_type}\"}],[{\"text\":\"${E_EDIT} DNS Server\",\"callback_data\":\"cmd_set_dr_server\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"}]]}"
            ;;

        "do_toggle_dr")
            toggle_uci_bool "podkop.${sec}" "domain_resolver_enabled"
            uci_commit_safe podkop; safe_reload_podkop
            _handle_section_extras "domain_resolver_settings" "$mid" "" ""
            ;;

        "set_dr_type_"*)
            uci set podkop.${sec}.domain_resolver_dns_type="${cmd#set_dr_type_}"
            uci_commit_safe podkop; safe_reload_podkop
            _handle_section_extras "domain_resolver_settings" "$mid" "" ""
            ;;

        "cmd_set_dr_server")
            echo "wait_dr_server" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set Domain Resolver DNS Server</b>\n\nCurrent: <code>%s</code>\n\nSend new value.\nExamples: <code>8.8.8.8</code>, <code>dns.google</code>, <code>https://dns.google/dns-query</code>' \
                    "$E_EDIT" "$(uci -q get podkop.${sec}.domain_resolver_dns_server || echo "not set")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"domain_resolver_settings\"}]]}"
            ;;

        "badwan_details")
            rm -f "$STATE_FILE"
            local bw_en bw_ifaces bw_delay bw_en_icon
            bw_en=$(uci -q get podkop.settings.enable_badwan_interface_monitoring 2>/dev/null || echo "0")
            bw_ifaces=$(uci -q get podkop.settings.badwan_monitored_interfaces 2>/dev/null || echo "not set")
            bw_delay=$(uci -q get podkop.settings.badwan_reload_delay 2>/dev/null || echo "10 (default)")
            bw_en_icon=$([ "$bw_en" = "1" ] && echo "$E_ON" || echo "$E_OFF")

            send_or_edit "$mid" \
                "$(printf '%s <b>Bad WAN Monitor Details</b>\n\n%s <b>Enabled:</b> <code>%s</code>\n<b>Monitored Interfaces:</b>\n<code>%s</code>\n<b>Reload Delay:</b> <code>%s s</code>\n\n<i>Podkop reloads when WAN interface changes.\nLeave interfaces blank to monitor default WAN.</i>' \
                    "$E_SCAN" "$bw_en_icon" \
                    "$([ "$bw_en" = "1" ] && echo "yes" || echo "no")" \
                    "$bw_ifaces" "$bw_delay")" \
                "{\"inline_keyboard\":[[{\"text\":\"${bw_en_icon} Toggle\",\"callback_data\":\"do_toggle_wan\"},{\"text\":\"${E_EDIT} Interfaces\",\"callback_data\":\"cmd_set_bw_ifaces\"}],[{\"text\":\"${E_EDIT} Reload Delay\",\"callback_data\":\"cmd_set_bw_delay\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"}]]}"
            ;;

        "cmd_set_bw_ifaces")
            echo "wait_badwan_ifaces" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set Monitored Interfaces</b>\n\nCurrent: <code>%s</code>\n\nSend space-separated interface names.\nExample: <code>wan wan6</code>\nLeave blank to clear (monitor default WAN).' \
                    "$E_EDIT" "$(uci -q get podkop.settings.badwan_monitored_interfaces || echo "not set")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"badwan_details\"}]]}"
            ;;

        "cmd_set_bw_delay")
            echo "wait_badwan_delay" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set Reload Delay</b>\n\nCurrent: <code>%s s</code>\n\nSeconds to wait after WAN change before reload.\nDefault: 10' \
                    "$E_EDIT" "$(uci -q get podkop.settings.badwan_reload_delay || echo "10")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"badwan_details\"}]]}"
            ;;

        "cmd_set_mixed_port")
            echo "wait_mixed_port" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set Mixed Proxy Port</b>\n\nCurrent: <code>%s</code>\n\nEnter port number (1024-65535).\nDefault: 2080\n\n%s Changing the port requires reload. Make sure no other service uses this port.' \
                    "$E_EDIT" "$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")" "$E_WARN")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}"
            ;;

        "cmd_set_outbound_iface")
            echo "wait_outbound_iface" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Set Outbound Interface</b>\n\nCurrent: <code>%s</code>\n\nEnter UCI interface name (e.g. <code>wan</code>, <code>wwan0</code>).\nLeave blank to reset to auto.' \
                    "$E_EDIT" "$(uci -q get podkop.${sec}.outbound_interface || echo "auto")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"advanced_settings\"}]]}"
            ;;

        "urltest_links_menu"|"urltest_links_p_"*)
            rm -f "$STATE_FILE"
            local page=0
            [ "$cmd" != "urltest_links_menu" ] && page="${cmd#urltest_links_p_}"
            local per_page=8 link_list total total_pages
            local start_idx end_idx rows list_text nav_row kb line_n=0
            link_list=$(get_urltest_proxy_links "$sec")
            if [ -z "$link_list" ]; then total=0
            else total=$(printf '%s\n' "$link_list" | grep -c .); fi
            total_pages=$(( (total + per_page - 1) / per_page ))
            [ "$total_pages" -eq 0 ] && total_pages=1
            [ "$page" -ge "$total_pages" ] && page=$((total_pages - 1))
            [ "$page" -lt 0 ] && page=0
            start_idx=$(( page * per_page ))
            end_idx=$(( start_idx + per_page ))
            [ "$end_idx" -gt "$total" ] && end_idx="$total"
            rows=""; list_text=""
            if [ "$total" -gt 0 ]; then
                while IFS= read -r link; do
                    [ -z "$link" ] && continue
                    if [ "$line_n" -ge "$start_idx" ] && [ "$line_n" -lt "$end_idx" ]; then
                        local disp proto host
                        proto=$(echo "$link" | cut -d: -f1)
                        host=$(echo "$link" | sed 's|.*@||; s|/.*||; s|?.*||' | cut -c1-30)
                        disp="${proto}://...${host}"
                        local human; human=$(json_escape "$disp")
                        list_text=$(printf '%s\n<code>[%s]</code> %s' "$list_text" "$line_n" "$disp")
                        rows="${rows}[{\"text\":\"${E_DEL} [${line_n}] ${human}\",\"callback_data\":\"ask_del_utl_${line_n}\"}],"
                    fi
                    line_n=$((line_n + 1))
                done <<EOF
$link_list
EOF
            fi
            list_text="${list_text#?}"
            [ -z "$list_text" ] && list_text="<i>No outbound links yet.</i>"
            nav_row=""
            if [ "$total" -gt "$per_page" ]; then
                local prev_p=$((page-1)) next_p=$((page+1))
                [ "$page" -eq 0 ] && prev_p=0
                [ "$next_p" -ge "$total_pages" ] && next_p=$page
                nav_row="[{\"text\":\"< Prev\",\"callback_data\":\"urltest_links_p_${prev_p}\"},{\"text\":\"$((page+1))/${total_pages}\",\"callback_data\":\"urltest_links_menu\"},{\"text\":\"Next >\",\"callback_data\":\"urltest_links_p_${next_p}\"}],"
            fi
            kb="{\"inline_keyboard\":[${rows}${nav_row}[{\"text\":\"${E_ADD} Add Link\",\"callback_data\":\"cmd_utl_add\"},{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"urltest_links_menu\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_settings\"}]]}"
            send_or_edit "$mid" "$(printf '%s <b>URLTest Proxy Links</b> [<code>%s</code>]\n<b>Total:</b> %s\n\n%s\n\n<i>Tap [%s] to remove a link.</i>' \
                "$E_GLOB" "$sec" "$total" "$list_text" "${E_DEL}")" "$kb"
            ;;

        "cmd_clone_sel_to_utl")
            # Clone all outbound proxies from Clash API into urltest_proxy_links.
            # Uses Clash API as source (not just UCI selector_proxy_links) so it
            # captures ALL proxies including those added outside the bot.
            # Matches each proxy's server:port back to its full original UCI link.
            local _added=0 _skipped=0 _not_found=0
            local proxies selector proxy_name proxy_names_file

            proxies=$(clash_request "/proxies")
            selector=$(get_selector_tag "$proxies")
            if [ -z "$proxies" ] || [ "$proxies" = "null" ] || [ -z "$selector" ]; then
                send_or_edit "$mid" "$(printf '%s Clash API unavailable — cannot read proxy list.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_settings\"}]]}"
                return
            fi

            proxy_names_file=$(mktemp /tmp/podkop_clone.XXXXXX 2>/dev/null) || return
            echo "$proxies" | jq -r --arg sel "$selector" '.proxies[$sel].all[]?' 2>/dev/null > "$proxy_names_file"

            [ -f "$UCI_LINKS_CACHE" ] || build_uci_links_cache

            while IFS= read -r proxy_name; do
                [ -z "$proxy_name" ] && continue
                # Get server:port from TAG_URI_CACHE
                local _cached_uri _srv_port _full_link
                _cached_uri=$(get_uri_by_tag "$proxy_name")
                [ -z "$_cached_uri" ] && { _not_found=$((_not_found + 1)); continue; }
                _srv_port=$(extract_server_port_from_uri "$_cached_uri")
                [ -z "$_srv_port" ] || [ "$_srv_port" = "N/A" ] && { _not_found=$((_not_found + 1)); continue; }
                # Find full original link in UCI_LINKS_CACHE
                _full_link=$(grep -m1 \
                    "@${_srv_port}[/?#]\|@${_srv_port}$\|://${_srv_port}[/?#]\|://${_srv_port}$" \
                    "$UCI_LINKS_CACHE" 2>/dev/null)
                if [ -z "$_full_link" ]; then
                    # Fallback: try live uci show
                    local _raw_uci
                    _raw_uci=$(uci -q show podkop.${sec}.selector_proxy_links 2>/dev/null | cut -d= -f2-)
                    if [ -n "$_raw_uci" ]; then
                        eval "set -- $_raw_uci"
                        for _l in "$@"; do
                            case "$_l" in *"@${_srv_port}"*|*"://${_srv_port}"*)
                                _full_link="$_l"; break ;;
                            esac
                        done
                    fi
                fi
                if [ -z "$_full_link" ]; then
                    _not_found=$((_not_found + 1)); continue
                fi
                # Skip duplicates already in urltest_proxy_links
                if uci -q show podkop.${sec}.urltest_proxy_links 2>/dev/null | grep -qF "'${_full_link}'"; then
                    _skipped=$((_skipped + 1))
                else
                    uci add_list podkop.${sec}.urltest_proxy_links="$_full_link"
                    _added=$((_added + 1))
                fi
            done < "$proxy_names_file"
            rm -f "$proxy_names_file"

            uci_commit_safe podkop
            build_tag_name_cache

            local _result
            _result=$(printf '%s <b>Cloned %s link(s)</b> from Selector.' "$E_OK" "$_added")
            [ "$_skipped" -gt 0 ] && _result=$(printf '%s\n<i>%s duplicate(s) skipped.</i>' "$_result" "$_skipped")
            [ "$_not_found" -gt 0 ] && _result=$(printf '%s\n<i>%s proxy/proxies not in UCI (added outside bot) — skipped.</i>' "$_result" "$_not_found")
            send_or_edit "$mid" "$_result" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_GLOB} View URLTest Links\",\"callback_data\":\"urltest_links_menu\"},{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_settings\"}]]}"
            ;;

        "cmd_utl_add")
            echo "wait_utl_link" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Add URLTest Outbound Link</b>\n\n<i>(vless, hy2, hysteria2, ss, trojan, vmess, tuic)</i>\n\nOne link per message.' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"urltest_links_menu\"}]]}"
            ;;

        "ask_del_utl_"*)
            local idx="${cmd#ask_del_utl_}" link_to_del="" ln=0 _item
            while IFS= read -r _item; do
                [ -z "$_item" ] && continue
                [ "$ln" -eq "$idx" ] && { link_to_del="$_item"; break; }
                ln=$((ln + 1))
            done <<EOF
$(get_urltest_proxy_links "$sec")
EOF
            [ -z "$link_to_del" ] && {
                send_or_edit "$mid" "$(printf '%s Entry not found.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"urltest_links_menu\"}]]}"
                return
            }
            local disp_link; disp_link=$(echo "$link_to_del" | cut -d: -f1)://...$(echo "$link_to_del" | sed 's|.*@||; s|/.*||; s|?.*||' | cut -c1-30)
            send_or_edit "$mid" \
                "$(printf '%s <b>Remove this URLTest link?</b>\n\n<code>%s</code>' "$E_WARN" "$(html_escape "$disp_link")")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Remove\",\"callback_data\":\"do_del_utl_${idx}\"},{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"urltest_links_menu\"}]]}"
            ;;

        "do_del_utl_"*)
            local idx="${cmd#do_del_utl_}" link_to_del="" ln=0 _item
            while IFS= read -r _item; do
                [ -z "$_item" ] && continue
                [ "$ln" -eq "$idx" ] && { link_to_del="$_item"; break; }
                ln=$((ln + 1))
            done <<EOF
$(get_urltest_proxy_links "$sec")
EOF
            [ -n "$link_to_del" ] && {
                uci del_list podkop.${sec}.urltest_proxy_links="$link_to_del"
                uci_commit_safe podkop; safe_reload_podkop "force"; sleep 1
            }
            _handle_section_extras "urltest_links_menu" "$mid" "" ""
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9.4: DNS & YACD Settings
# ------------------------------------------------------------------------------
_handle_dns() {
    local cmd="$1" mid="$2" text="$3" state="$4"

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"
        local srv=$(printf "%s" "$text" | tr -d '\r\n\t ')
        if [ "$state" = "wait_dns_server" ]; then
            delete_message "$mid"
            uci set podkop.settings.dns_server="$srv"; uci_commit_safe podkop
            send_message "$(printf '%s DNS Server set to: %s' "$E_OK" "$srv")" ""
            safe_reload_podkop "force"; sleep 1; _handle_dns "dns_settings" "" "" ""
        elif [ "$state" = "wait_bootstrap_dns" ]; then
            delete_message "$mid"
            uci set podkop.settings.bootstrap_dns_server="$srv"; uci_commit_safe podkop
            send_message "$(printf '%s Bootstrap DNS set to: %s' "$E_OK" "$srv")" ""
            safe_reload_podkop "force"; sleep 1; _handle_dns "dns_settings" "" "" ""
        fi
        return
    fi

    case "$cmd" in
        "dns_settings")
            rm -f "$STATE_FILE"
            local protocol server boot_dns kb_boot text kb
            protocol=$(uci -q get podkop.settings.dns_type || echo "udp")
            server=$(uci -q get podkop.settings.dns_server || echo "Not set")
            boot_dns=$(uci -q get podkop.settings.bootstrap_dns_server || echo "Not set")
            local proto_hint
            case "$protocol" in
                udp)  proto_hint="${E_IDEA} <i>UDP: fast, unencrypted DNS. ISP can see your queries.</i>" ;;
                doh)  proto_hint="${E_IDEA} <i>DoH: DNS over HTTPS. Hides queries from ISP, uses port 443.</i>" ;;
                dot)  proto_hint="${E_IDEA} <i>DoT: DNS over TLS. Encrypted DNS, uses port 853.</i>" ;;
                *)    proto_hint="" ;;
            esac

            text=$(cat <<EOF
${E_NET} <b>DNS Settings</b> (Global)

<b>Protocol:</b> <code>${protocol}</code>
${proto_hint}
<b>Server:</b> <code>${server}</code>
<b>Bootstrap:</b> <code>${boot_dns}</code>
<i>Bootstrap resolves the DoH/DoT server hostname via plain DNS.
Only needed for DoH/DoT - ignored in UDP mode.</i>
EOF
)
            kb_boot=""
            [ "$protocol" = "doh" ] || [ "$protocol" = "dot" ] && \
                kb_boot="[{\"text\":\"${E_EDIT} Set Bootstrap\",\"callback_data\":\"cmd_boot_dns\"}],"
            kb="{\"inline_keyboard\":[${kb_boot}[{\"text\":\"Protocol: ${protocol}\",\"callback_data\":\"dns_proto_menu\"}],[{\"text\":\"${E_EDIT} Change Server\",\"callback_data\":\"cmd_dns_server\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;
        "cmd_dns_server")
            echo "wait_dns_server" > "$STATE_FILE"
            local _cur_dns; _cur_dns=$(uci -q get podkop.settings.dns_server || echo "not set")
            send_or_edit "$mid" \
                "$(printf '%s <b>Change DNS Server</b>\n\nCurrent: <code>%s</code>\n\nSend new value:\nExample: <code>8.8.8.8</code> or <code>dns.google</code>' "$E_EDIT" "$_cur_dns")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"dns_settings\"}]]}"
            ;;
        "cmd_boot_dns")
            echo "wait_bootstrap_dns" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Set Bootstrap DNS</b>\n\nExample: <code>77.88.8.8</code>' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"dns_settings\"}]]}"
            ;;
        "dns_proto_menu")
            send_or_edit "$mid" \
                "$(printf '%s <b>Select DNS Protocol</b>

<b>UDP</b> - fast, unencrypted. ISP sees all queries.
<b>DoH</b> - DNS over HTTPS (port 443). Best privacy, works through most firewalls.
<b>DoT</b> - DNS over TLS (port 853). Encrypted, may be blocked by some ISPs.' "$E_TGT")" \
                "{\"inline_keyboard\":[[{\"text\":\"UDP\",\"callback_data\":\"do_dns_pr_udp\"},{\"text\":\"DoH\",\"callback_data\":\"do_dns_pr_doh\"},{\"text\":\"DoT\",\"callback_data\":\"do_dns_pr_dot\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"dns_settings\"}]]}"
            ;;
        "do_dns_pr_"*)
            uci set podkop.settings.dns_type="${cmd#do_dns_pr_}"; uci_commit_safe podkop
            safe_reload_podkop; _handle_dns "dns_settings" "$mid" "" ""
            ;;

        "yacd_settings")
            rm -f "$STATE_FILE"
            local en wn sk text kb
            en=$(uci -q get podkop.settings.enable_yacd || echo "0")
            wn=$(uci -q get podkop.settings.enable_yacd_wan_access || echo "0")
            sk=$(uci -q get podkop.settings.yacd_secret_key || echo "Not set")
            text=$(cat <<EOF
${E_STAT} <b>YACD Settings</b> (Global)

YACD: $([ "$en" = "1" ] && echo "${E_ON} Enabled" || echo "${E_OFF} Disabled")
WAN Access: $([ "$wn" = "1" ] && echo "${E_ON}" || echo "${E_OFF}")
Secret Key: $([ "$sk" != "Not set" ] && echo "${E_OK} Set" || echo "${E_ERR} Not set")
EOF
)
            kb="{\"inline_keyboard\":[[{\"text\":\"$([ "$en" = "1" ] && echo "${E_ON}" || echo "${E_OFF}") Toggle YACD\",\"callback_data\":\"ask_toggle_yacd\"}],[{\"text\":\"$([ "$wn" = "1" ] && echo "${E_ON}" || echo "${E_OFF}") WAN Access\",\"callback_data\":\"ask_toggle_yacd_wan\"}],[{\"text\":\"${E_KEY} Secret Key\",\"callback_data\":\"yacd_secret_menu\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"advanced_settings\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;
        "ask_toggle_yacd")     send_or_edit "$mid" "$(printf '%s Toggle YACD?' "$E_WARN")"         "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_yacd\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"yacd_settings\"}]]}" ;;
        "ask_toggle_yacd_wan") send_or_edit "$mid" "$(printf '%s Toggle YACD WAN access?' "$E_WARN")" "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_toggle_yacd_wan\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"yacd_settings\"}]]}" ;;
        "do_toggle_yacd")      toggle_uci_bool "podkop.settings" "enable_yacd";            safe_reload_podkop; _handle_dns "yacd_settings" "$mid" "" "" ;;
        "do_toggle_yacd_wan")  toggle_uci_bool "podkop.settings" "enable_yacd_wan_access"; safe_reload_podkop; _handle_dns "yacd_settings" "$mid" "" "" ;;

        "yacd_secret_menu")
            local secret text kb
            secret=$(uci -q get podkop.settings.yacd_secret_key || echo "Not set")
            if [ "$secret" = "Not set" ]; then
                text=$(printf '%s <b>YACD Secret Key</b>\n\n%s No secret key set.' "$E_KEY" "$E_ERR")
            else
                text=$(printf '%s <b>YACD Secret Key</b>\n\n%s Set\n\n<code>%s</code>' "$E_KEY" "$E_OK" "$secret")
            fi
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_RST} Generate New\",\"callback_data\":\"ask_yacd_generate_secret\"}],[{\"text\":\"${E_DEL} Remove\",\"callback_data\":\"ask_yacd_remove_secret\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"yacd_settings\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;
        "ask_yacd_generate_secret") send_or_edit "$mid" "$(printf '%s Generate new secret? This disconnects all dashboards.' "$E_WARN")" "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_yacd_generate_secret\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"yacd_secret_menu\"}]]}" ;;
        "do_yacd_generate_secret")
            local new_secret
            new_secret=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 32 | tr 'a-f' 'A-F')
            uci set "podkop.settings.yacd_secret_key=${new_secret}"; uci_commit_safe podkop
            safe_reload_podkop "force"; sleep 1
            send_or_edit "$mid" "$(printf '%s New Secret:\n<code>%s</code>' "$E_OK" "$new_secret")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"yacd_secret_menu\"}]]}"
            ;;
        "ask_yacd_remove_secret") send_or_edit "$mid" "$(printf '%s Remove secret? YACD will be unprotected.' "$E_WARN")" "{\"inline_keyboard\":[[{\"text\":\"${E_WARN} Yes, Remove\",\"callback_data\":\"do_yacd_remove_secret\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"yacd_secret_menu\"}]]}" ;;
        "do_yacd_remove_secret")
            uci delete podkop.settings.yacd_secret_key 2>/dev/null; uci_commit_safe podkop
            safe_reload_podkop "force"; sleep 1
            send_or_edit "$mid" "$(printf '%s Secret removed.' "$E_OK")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"yacd_settings\"}]]}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9.5: Routing Lists Handler
#
# Community lists: 2-column grid, GitHub API with 1h cache.
# Remote domain/subnet lists: display + edit by index (bypasses 64-byte CB limit).
# Fully routed IPs: display + add + delete by IP from button.
# user_domains_text / user_subnets_text: paginated viewer, add line, remove by index.
#
# FIXED: remote list display uses eval "set --" (uci get N broken on BusyBox)
# ------------------------------------------------------------------------------
_handle_lists() {
    local cmd="$1" mid="$2" text="$3" state="$4"
    local sec=$(get_active_section)

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"

        if [ "$state" = "wait_fully_routed_ip" ]; then
            delete_message "$mid"
            local ip=$(printf "%s" "$text" | tr -d '\r\n\t ')
            if ! validate_ip_or_cidr "$ip"; then
                send_message "$(printf '%s Invalid IP/CIDR.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
                return
            fi
            uci add_list podkop.${sec}.fully_routed_ips="$ip"; uci_commit_safe podkop
            send_message "$(printf '%s Routed IP added: %s' "$E_OK" "$ip")" ""
            safe_reload_podkop "force"; sleep 1; _handle_lists "community_lists" "" "" ""

        elif [ "$state" = "wait_excl_ip" ]; then
            delete_message "$mid"
            local ip; ip=$(printf "%s" "$text" | tr -d '\r\n\t ')
            if ! validate_ip_or_cidr "$ip"; then
                send_message "$(printf '%s Invalid IP/CIDR.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"excl_ips_edit\"}]]}"
                return
            fi
            uci add_list podkop.settings.routing_excluded_ips="$ip"; uci_commit_safe podkop
            send_message "$(printf '%s Excluded IP added: %s' "$E_OK" "$ip")" ""
            safe_reload_podkop "force"; sleep 1; _handle_lists "excl_ips_edit" "" "" ""

        elif [ "$state" = "wait_remote_domain" ] || [ "$state" = "wait_remote_subnet" ]; then
            delete_message "$mid"
            local safe_link=$(printf "%s" "$text" | tr -d '\r\n\t ')
            if ! echo "$safe_link" | grep -qE '^https?://'; then
                send_message "$(printf '%s Must start with http:// or https://' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"}]]}"
                return
            fi
            if [ "$state" = "wait_remote_domain" ]; then
                uci add_list podkop.${sec}.remote_domain_lists="$safe_link"
            else
                uci add_list podkop.${sec}.remote_subnet_lists="$safe_link"
            fi
            uci_commit_safe podkop
            send_message "$(printf '%s Remote list saved.' "$E_OK")" ""
            safe_reload_podkop "force"; sleep 1; _handle_lists "community_lists" "" "" ""

        elif [ "$state" = "wait_user_domain_add" ] || [ "$state" = "wait_user_subnet_add" ]; then
            # Add a single line to user_domains_text or user_subnets_text.
            # Validation is intentionally different:
            #   domain list: only hostnames (no IPs — use fully_routed_ips for that)
            #   subnet list: only IP/CIDR (no domain names)
            delete_message "$mid"
            local entry=$(printf "%s" "$text" | tr -d '\r\n\t ')
            local field="user_domains_text" back_cb="user_domains_menu"
            [ "$state" = "wait_user_subnet_add" ] && { field="user_subnets_text"; back_cb="user_subnets_menu"; }

            if [ "$state" = "wait_user_domain_add" ]; then
                if ! validate_domain "$entry"; then
                    send_message "$(printf '%s Invalid domain name: <code>%s</code>\nExpected format: <code>example.com</code>' "$E_ERR" "$(html_escape "$entry")")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"${back_cb}\"}]]}"
                    return
                fi
            else
                if ! validate_ip_or_cidr "$entry"; then
                    send_message "$(printf '%s Invalid IP/CIDR: <code>%s</code>\nExpected format: <code>10.0.0.0/24</code> or <code>1.2.3.4</code>' "$E_ERR" "$(html_escape "$entry")")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"${back_cb}\"}]]}"
                    return
                fi
            fi
            local current
            current=$(uci -q get podkop.${sec}.${field} 2>/dev/null || echo "")
            if [ -n "$current" ]; then
                uci set podkop.${sec}.${field}="${current}
${entry}"
            else
                uci set podkop.${sec}.${field}="$entry"
            fi
            uci_commit_safe podkop
            send_message "$(printf '%s Added: %s' "$E_OK" "$(html_escape "$entry")")" ""
            safe_reload_podkop "force"; sleep 1; _handle_lists "$back_cb" "" "" ""

        elif [ "$state" = "wait_user_domain_del" ] || [ "$state" = "wait_user_subnet_del" ]; then
            # Delete a line from user_domains_text or user_subnets_text by index
            delete_message "$mid"
            local del_idx=$(printf "%s" "$text" | tr -d '\r\n\t ')
            local field="user_domains_text" back_cb="user_domains_menu"
            [ "$state" = "wait_user_subnet_del" ] && { field="user_subnets_text"; back_cb="user_subnets_menu"; }

            case "$del_idx" in
                ''|*[!0-9]*)
                    send_message "$(printf '%s Enter a valid line number.' "$E_ERR")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"${back_cb}\"}]]}"
                    return ;;
            esac

            local current new_val i=0 line
            current=$(uci -q get podkop.${sec}.${field} 2>/dev/null || echo "")
            new_val=""
            while IFS= read -r line; do
                if [ "$i" -ne "$del_idx" ]; then
                    if [ -z "$new_val" ]; then new_val="$line"
                    else new_val=$(printf '%s\n%s' "$new_val" "$line"); fi
                fi
                i=$((i + 1))
            done <<EOF
$current
EOF
            uci set podkop.${sec}.${field}="$new_val"; uci_commit_safe podkop
            send_message "$(printf '%s Line %s removed.' "$E_OK" "$del_idx")" ""
            safe_reload_podkop "force"; sleep 1; _handle_lists "$back_cb" "" "" ""
        fi
        return
    fi

    case "$cmd" in
        "community_lists")
            rm -f "$STATE_FILE"
            local cd_count sn_count fr_count r_dom_count r_sub_count excl_count
            local r_dom_text r_sub_text fr_ips_text active_lists
            local list_url clean_url filename ip raw

            cd_count=$(uci -q get podkop.${sec}.user_domains_text 2>/dev/null | grep -c "[^[:space:]]")
            sn_count=$(uci -q get podkop.${sec}.user_subnets_text  2>/dev/null | grep -c "[^[:space:]]")
            fr_count=$(uci -q show podkop.${sec} 2>/dev/null | grep -c "^podkop\.${sec}\.fully_routed_ips=")
            r_dom_count=$(uci -q show podkop.${sec} 2>/dev/null | grep -c "^podkop\.${sec}\.remote_domain_lists=")
            r_sub_count=$(uci -q show podkop.${sec} 2>/dev/null | grep -c "^podkop\.${sec}\.remote_subnet_lists=")
            excl_count=$(uci -q show podkop.settings 2>/dev/null | grep -c "^podkop\.settings\.routing_excluded_ips=")

            # FIXED: use eval "set --" for list parsing (uci get N broken on BusyBox)
            r_dom_text=""
            if [ "$r_dom_count" -gt 0 ]; then
                raw=$(uci -q show podkop.${sec}.remote_domain_lists 2>/dev/null | cut -d= -f2-)
                [ -n "$raw" ] && eval "set -- $raw" && for list_url in "$@"; do
                    clean_url="${list_url%%#*}"; clean_url="${clean_url%%\?*}"; filename="${clean_url##*/}"
                    r_dom_text=$(printf '%s\n• <a href="%s">%s</a>' "$r_dom_text" "$(html_escape "$list_url")" "$(html_escape "$filename")")
                done
            else
                r_dom_text=$(printf '\n<i>None</i>')
            fi

            r_sub_text=""
            if [ "$r_sub_count" -gt 0 ]; then
                raw=$(uci -q show podkop.${sec}.remote_subnet_lists 2>/dev/null | cut -d= -f2-)
                [ -n "$raw" ] && eval "set -- $raw" && for list_url in "$@"; do
                    clean_url="${list_url%%#*}"; clean_url="${clean_url%%\?*}"; filename="${clean_url##*/}"
                    r_sub_text=$(printf '%s\n• <a href="%s">%s</a>' "$r_sub_text" "$(html_escape "$list_url")" "$(html_escape "$filename")")
                done
            else
                r_sub_text=$(printf '\n<i>None</i>')
            fi

            fr_ips_text=""
            if [ "$fr_count" -gt 0 ]; then
                raw=$(uci -q show podkop.${sec}.fully_routed_ips 2>/dev/null | cut -d= -f2-)
                [ -n "$raw" ] && eval "set -- $raw" && for ip in "$@"; do
                    fr_ips_text=$(printf '%s\n• <code>%s</code>' "$fr_ips_text" "$ip")
                done
            else
                fr_ips_text=$(printf '\n<i>None</i>')
            fi

            active_lists=$(uci -q show podkop.${sec} 2>/dev/null \
                | grep "^podkop\.${sec}\.community_lists=" \
                | sed "s/^[^']*'//g; s/'$//g; s/' '/, /g" || echo "<i>None</i>")

            text=$(cat <<EOF
${E_FILE} <b>Routing & Lists</b> [<code>${sec}</code>]

<b>Community Lists:</b>
<code>${active_lists}</code>

<b>Remote Domain Lists:</b>${r_dom_text}

<b>Remote Subnet Lists:</b>${r_sub_text}

<b>Fully Routed IPs:</b>${fr_ips_text}

<b>Custom Domains:</b> ${cd_count} entries
<b>Custom Subnets:</b> ${sn_count} entries
<b>Routing Excluded IPs:</b> ${excl_count} entries
EOF
)
            local kb
            kb="{\"inline_keyboard\":["
            kb="${kb}[{\"text\":\"${E_SET} Community Lists\",\"callback_data\":\"community_lists_edit\"}],"
            kb="${kb}[{\"text\":\"${E_ADD} R-Domain\",\"callback_data\":\"cmd_add_r_dom\"},{\"text\":\"${E_SET} Edit R-Domains\",\"callback_data\":\"r_dom_edit\"}],"
            kb="${kb}[{\"text\":\"${E_ADD} R-Subnet\",\"callback_data\":\"cmd_add_r_sub\"},{\"text\":\"${E_SET} Edit R-Subnets\",\"callback_data\":\"r_sub_edit\"}],"
            kb="${kb}[{\"text\":\"${E_ADD} FR IP\",\"callback_data\":\"cmd_add_fr_ip\"},{\"text\":\"${E_SET} Edit FR IPs\",\"callback_data\":\"fr_ips_edit\"}],"
            kb="${kb}[{\"text\":\"${E_ADD} Excl IP\",\"callback_data\":\"cmd_add_excl_ip\"},{\"text\":\"${E_SET} Edit Excl IPs\",\"callback_data\":\"excl_ips_edit\"}],"
            kb="${kb}[{\"text\":\"${E_EDIT} Custom Domains\",\"callback_data\":\"user_domains_menu\"},{\"text\":\"${E_EDIT} Custom Subnets\",\"callback_data\":\"user_subnets_menu\"}],"
            kb="${kb}[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"main_settings_menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "community_lists_edit")
            rm -f "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s Loading lists...' "$E_TIME")" ""
            local available tag rows col=0 mark pair_left="" pair_left_tag="" text kb
            available=$(get_available_community_lists)
            rows=""
            for tag in $available; do
                is_list_enabled "$sec" "$tag" && mark="${E_ON}" || mark="${E_OFF}"
                if [ "$col" -eq 0 ]; then
                    pair_left="${mark} ${tag}"; pair_left_tag="$tag"; col=1
                else
                    rows="${rows}[{\"text\":\"${pair_left}\",\"callback_data\":\"toggle_cl_${pair_left_tag}\"},{\"text\":\"${mark} ${tag}\",\"callback_data\":\"toggle_cl_${tag}\"}],"
                    col=0; pair_left=""; pair_left_tag=""
                fi
            done
            [ -n "$pair_left" ] && rows="${rows}[{\"text\":\"${pair_left}\",\"callback_data\":\"toggle_cl_${pair_left_tag}\"}],"
            text=$(cat <<EOF
${E_FILE} <b>Community Lists</b> [<code>${sec}</code>]

${E_ON} enabled  ${E_OFF} disabled

${E_IDEA} <i>Enabled lists are routed strictly through the tunnel.
Domains in these lists bypass your ISP completely.</i>

Changes apply immediately with reload.
EOF
)
            kb="{\"inline_keyboard\":[${rows}[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "toggle_cl_"*)
            local tag="${cmd#toggle_cl_}"
            case "$tag" in *[!a-z0-9_-]*) send_or_edit "$mid" "$(printf '%s Invalid tag.' "$E_ERR")" ""; return ;; esac
            send_or_edit "$mid" "$(printf '%s Applying...' "$E_RST")" ""
            if is_list_enabled "$sec" "$tag"; then
                uci del_list podkop.${sec}.community_lists="$tag"
            else
                uci add_list podkop.${sec}.community_lists="$tag"
            fi
            uci_commit_safe podkop; safe_reload_podkop "force"; sleep 1
            _handle_lists "community_lists_edit" "$mid" "" ""
            ;;

        "r_dom_edit"|"r_sub_edit")
            rm -f "$STATE_FILE"
            local list_type="remote_domain_lists" human_type="Remote Domain Lists" cb_prefix="del_rdom_"
            [ "$cmd" = "r_sub_edit" ] && { list_type="remote_subnet_lists"; human_type="Remote Subnet Lists"; cb_prefix="del_rsub_"; }
            local rows="" text list_url clean_url filename raw i=0
            text=$(printf '%s <b>Manage %s</b> [<code>%s</code>]\n\n' "$E_FILE" "$human_type" "$sec")
            raw=$(uci -q show podkop.${sec}.${list_type} 2>/dev/null | cut -d= -f2-)
            if [ -n "$raw" ]; then
                eval "set -- $raw"
                for list_url in "$@"; do
                    clean_url="${list_url%%#*}"; clean_url="${clean_url%%\?*}"; filename="${clean_url##*/}"
                    text=$(printf '%s<b>[%d]</b> <a href="%s">%s</a>\n' "$text" "$i" "$(html_escape "$list_url")" "$(html_escape "$filename")")
                    rows="${rows}[{\"text\":\"${E_DEL} Remove [${i}]\",\"callback_data\":\"${cb_prefix}${i}\"}],"
                    i=$((i + 1))
                done
            fi
            [ "$i" -eq 0 ] && text=$(printf '%s<i>No lists configured.</i>' "$text")
            local add_cb="cmd_add_r_dom"
            [ "$cmd" = "r_sub_edit" ] && add_cb="cmd_add_r_sub"
            local kb="{\"inline_keyboard\":[${rows}[{\"text\":\"${E_ADD} Add URL\",\"callback_data\":\"${add_cb}\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "del_rdom_"*|"del_rsub_"*)
            local idx list_type target raw list_url url i=0
            if case "$cmd" in del_rdom_*) true ;; *) false ;; esac; then
                idx="${cmd#del_rdom_}"; list_type="remote_domain_lists"; target="r_dom_edit"
            else
                idx="${cmd#del_rsub_}"; list_type="remote_subnet_lists"; target="r_sub_edit"
            fi
            raw=$(uci -q show podkop.${sec}.${list_type} 2>/dev/null | cut -d= -f2-)
            if [ -n "$raw" ]; then
                eval "set -- $raw"
                for url in "$@"; do
                    if [ "$i" -eq "$idx" ]; then list_url="$url"; break; fi
                    i=$((i + 1))
                done
            fi
            if [ -n "$list_url" ]; then
                send_or_edit "$mid" "$(printf '%s Applying...' "$E_RST")" ""
                uci del_list podkop.${sec}.${list_type}="$list_url"
                uci_commit_safe podkop; safe_reload_podkop "force"; sleep 1
            fi
            _handle_lists "$target" "$mid" "" ""
            ;;

        "fr_ips_edit")
            rm -f "$STATE_FILE"
            local rows="" ip raw text kb
            raw=$(uci -q show podkop.${sec}.fully_routed_ips 2>/dev/null | cut -d= -f2-)
            [ -n "$raw" ] && eval "set -- $raw" && for ip in "$@"; do
                rows="${rows}[{\"text\":\"${E_DEL} ${ip}\",\"callback_data\":\"del_frip_${ip}\"}],"
            done
            local fr_count=0
            [ -n "$raw" ] && { eval "set -- $raw"; fr_count=$#; }
            text=$(cat <<EOF
${E_FILE} <b>Fully Routed IPs</b> [<code>${sec}</code>]
${fr_count} entries

Tap an IP button to remove it.
${E_IDEA} <i>Fully Routed IPs bypass the domain/subnet lists and always go through the tunnel.</i>
EOF
)
            kb="{\"inline_keyboard\":[${rows}[{\"text\":\"${E_ADD} Add IP\",\"callback_data\":\"cmd_add_fr_ip\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "del_frip_"*)
            local ip="${cmd#del_frip_}"
            if ! validate_ip_or_cidr "$ip"; then
                send_or_edit "$mid" "$(printf '%s Invalid IP.' "$E_ERR")" ""; return
            fi
            send_or_edit "$mid" "$(printf '%s Applying...' "$E_RST")" ""
            uci del_list podkop.${sec}.fully_routed_ips="$ip"
            uci_commit_safe podkop; safe_reload_podkop "force"; sleep 1
            _handle_lists "fr_ips_edit" "$mid" "" ""
            ;;

        "excl_ips_edit")
            rm -f "$STATE_FILE"
            local rows="" ip raw text kb excl_count=0
            raw=$(uci -q show podkop.settings.routing_excluded_ips 2>/dev/null | cut -d= -f2-)
            [ -n "$raw" ] && eval "set -- $raw" && for ip in "$@"; do
                rows="${rows}[{\"text\":\"${E_DEL} ${ip}\",\"callback_data\":\"del_excl_${ip}\"}],"
            done
            [ -n "$raw" ] && { eval "set -- $raw"; excl_count=$#; }
            text=$(cat <<EOF
${E_FILE} <b>Routing Excluded IPs</b> [<code>global</code>]
${excl_count} entries

Tap an IP button to remove it.
${E_IDEA} <i>Excluded IPs bypass the tunnel entirely — always go direct regardless of rules. This is a global setting (applies to all sections).</i>
EOF
)
            kb="{\"inline_keyboard\":[${rows}[{\"text\":\"${E_ADD} Add IP\",\"callback_data\":\"cmd_add_excl_ip\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "del_excl_"*)
            local ip="${cmd#del_excl_}"
            if ! validate_ip_or_cidr "$ip"; then
                send_or_edit "$mid" "$(printf '%s Invalid IP.' "$E_ERR")" ""; return
            fi
            send_or_edit "$mid" "$(printf '%s Applying...' "$E_RST")" ""
            uci del_list podkop.settings.routing_excluded_ips="$ip"
            uci_commit_safe podkop; safe_reload_podkop "force"; sleep 1
            _handle_lists "excl_ips_edit" "$mid" "" ""
            ;;

        # user_domains_text / user_subnets_text — line-by-line editor
        # Shows paginated list (20/page), add line, remove by entering index number.
        "user_domains_menu"|"user_domains_menu_p_"*|"user_subnets_menu"|"user_subnets_menu_p_"*)
            rm -f "$STATE_FILE"
            local field="user_domains_text" human="Custom Domains"
            local add_state="wait_user_domain_add" del_state="wait_user_domain_del"
            local back_cb="user_domains_menu" base_cmd="user_domains_menu"
            local page=0

            case "$cmd" in
                user_subnets_menu|user_subnets_menu_p_*)
                    field="user_subnets_text"; human="Custom Subnets"
                    add_state="wait_user_subnet_add"; del_state="wait_user_subnet_del"
                    back_cb="user_subnets_menu"; base_cmd="user_subnets_menu" ;;
            esac
            case "$cmd" in
                *_p_*) page="${cmd##*_p_}" ;;
            esac

            local per_pg=20 current total total_pages start end idx=0 line list_text
            current=$(uci -q get podkop.${sec}.${field} 2>/dev/null || echo "")
            total=$(printf '%s' "$current" | grep -c "[^[:space:]]" 2>/dev/null)
            case "$total" in ''|*[!0-9]*) total=0 ;; esac
            total_pages=$(( (total + per_pg - 1) / per_pg ))
            [ "$total_pages" -eq 0 ] && total_pages=1
            [ "$page" -ge "$total_pages" ] && page=$((total_pages - 1))
            [ "$page" -lt 0 ] && page=0
            start=$(( page * per_pg )); end=$(( start + per_pg ))

            list_text=""
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$idx" -ge "$start" ] && [ "$idx" -lt "$end" ]; then
                    list_text=$(printf '%s\n<code>[%d]</code> %s' "$list_text" "$idx" "$(html_escape "$line")")
                fi
                idx=$((idx + 1))
            done <<EOF
$current
EOF
            [ -z "$list_text" ] && list_text=$(printf '\n<i>No entries.</i>')

            local nav_row=""
            if [ "$total" -gt "$per_pg" ]; then
                local prev_p=$((page-1)) next_p=$((page+1))
                [ "$page" -eq 0 ] && prev_p=0
                [ "$next_p" -ge "$total_pages" ] && next_p=$((total_pages-1))
                nav_row="[{\"text\":\"${E_BACK} Prev\",\"callback_data\":\"${base_cmd}_p_${prev_p}\"},{\"text\":\"${E_FILE} $((page+1))/${total_pages}\",\"callback_data\":\"${base_cmd}_p_${page}\"},{\"text\":\"Next >\",\"callback_data\":\"${base_cmd}_p_${next_p}\"}],"
            fi

            text=$(cat <<EOF
${E_EDIT} <b>${human}</b> [<code>${sec}</code>]
${total} entries (page $((page+1))/${total_pages})
${list_text}

To remove: tap "${E_DEL} Remove by #" and enter the line number.
EOF
)
            local kb
            kb="{\"inline_keyboard\":[${nav_row}[{\"text\":\"${E_ADD} Add line\",\"callback_data\":\"cmd_user_add_${add_state}\"},{\"text\":\"${E_DEL} Remove by #\",\"callback_data\":\"cmd_user_del_${del_state}\"}],[{\"text\":\"${E_FILE} Download as file\",\"callback_data\":\"cmd_user_download_${field}\"},{\"text\":\"${E_BACK} Back\",\"callback_data\":\"community_lists\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_user_add_"*)
            local add_state="${cmd#cmd_user_add_}"
            local human_hint back_cb="user_domains_menu"
            if [ "$add_state" = "wait_user_subnet_add" ]; then
                human_hint="$(printf '%s <b>Add Custom Subnet</b>\n\nSend one IP or CIDR range.\nExample: <code>10.0.0.0/24</code> or <code>1.2.3.4</code>' "$E_EDIT")"
                back_cb="user_subnets_menu"
            else
                human_hint="$(printf '%s <b>Add Custom Domain</b>\n\nSend one domain name (no http://, no wildcards).\nExample: <code>example.com</code>' "$E_EDIT")"
            fi
            echo "$add_state" > "$STATE_FILE"
            send_or_edit "$mid" "$human_hint" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"${back_cb}\"}]]}"
            ;;

        "cmd_user_del_"*)
            local del_state="${cmd#cmd_user_del_}"
            local back_cb="user_domains_menu"
            [ "$del_state" = "wait_user_subnet_del" ] && back_cb="user_subnets_menu"
            echo "$del_state" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Remove entry</b>\n\nSend the line number to remove (shown in brackets above).' "$E_DEL")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"${back_cb}\"}]]}"
            ;;

        "cmd_user_download_"*)
            local field="${cmd#cmd_user_download_}"
            local current tmp_f
            current=$(uci -q get podkop.${sec}.${field} 2>/dev/null || echo "")
            tmp_f=$(mktemp /tmp/podkop_userlist.XXXXXX)
            printf '%s\n' "$current" > "$tmp_f"
            api_document "$tmp_f" "${field} [${sec}]"
            rm -f "$tmp_f"
            ;;

        "cmd_add_fr_ip")
            echo "wait_fully_routed_ip" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Add Fully Routed IP</b>\n\nSend IP or CIDR (e.g. <code>192.168.1.50</code>).' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"community_lists\"}]]}"
            ;;

        "cmd_add_excl_ip")
            echo "wait_excl_ip" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Add Routing Excluded IP</b>\n\nSend IP or CIDR.\nThis IP will always bypass the tunnel.\nExample: <code>10.0.0.0/8</code>' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"excl_ips_edit\"}]]}"
            ;;
        "cmd_add_r_dom")
            echo "wait_remote_domain" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Add Remote Domain List URL</b>\n\nSend http/https URL.' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"community_lists\"}]]}"
            ;;
        "cmd_add_r_sub")
            echo "wait_remote_subnet" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Add Remote Subnet List URL</b>\n\nSend http/https URL.' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"community_lists\"}]]}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9.6: Bot & System Handler
# Main menu, Status, Runtime Info, Tunnel Health, Bot Settings, system actions.
#
# FIXED: wan_ip uses ip route + uci (no blocking curl to api.ipify.org)
# FIXED: main_menu does NOT call get_tg_latency (removed 3s delay per open)
# NEW:   cmd_tunnel_health - dedicated Tunnel Health screen
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 9.6: Fallback SOCKS Manager
_handle_fallback_socks() {
    local cmd="$1" mid="$2" text="$3" state="$4"

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"
        if [ "$state" = "wait_fb_socks_add" ]; then
            delete_message "$mid"
            local safe_fb
            safe_fb=$(printf "%s" "$text" | tr -d '\r\n' | sed 's/[[:space:]]//g')
            if ! echo "$safe_fb" | grep -qE '^socks5h?://[^:]+:[0-9]+$'; then
                send_message "$(printf '%s <b>Invalid format!</b>\nExpected: <code>socks5://IP:PORT</code> or <code>socks5h://IP:PORT</code>\n<code>socks5h://</code> resolves DNS through the proxy (recommended under RKN).\nExample: <code>socks5h://192.168.2.238:18080</code>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"fallback_socks_menu\"}]]}"
            else
                local _existing _dup=0
                _existing=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
                # Normalize to host:port for duplicate check (socks5:// and socks5h:// same endpoint)
                local _new_hp; _new_hp=$(echo "$safe_fb" | sed 's|^socks5h\?://||')
                if [ -n "$_existing" ]; then
                    eval "set -- $_existing"
                    for _e in "$@"; do
                        local _e_hp; _e_hp=$(echo "$_e" | sed 's|^socks5h\?://||')
                        [ "$_e_hp" = "$_new_hp" ] && _dup=1 && break
                    done
                fi
                if [ "$_dup" = "1" ]; then
                    send_message "$(printf '%s <b>Duplicate!</b>\nEndpoint <code>%s</code> already in list (same host:port).' "$E_WARN" "$_new_hp")" \
                        "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"fallback_socks_menu\"}]]}"
                else
                    uci add_list podkop_bot.settings.fallback_socks="$safe_fb"
                    uci_commit_safe podkop_bot
                    _handle_fallback_socks "fallback_socks_menu" "" "" ""
                fi
            fi
        fi
        return
    fi

    case "$cmd" in
        "fallback_socks_menu")
            rm -f "$STATE_FILE"
            local rows list_text kb n=0 _fb
            local _fb_raw
            _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
            rows=""; list_text=""
            if [ -n "$_fb_raw" ]; then
                eval "set -- $_fb_raw"
                for _fb in "$@"; do
                    list_text=$(printf '%s\n<code>[%s]</code> %s' "$list_text" "$n" "$_fb")
                    rows="${rows}[{\"text\":\"${E_DEL} [${n}] ${_fb}\",\"callback_data\":\"ask_del_fb_${n}\"}],"
                    n=$((n + 1))
                done
            fi
            list_text="${list_text#?}"
            [ -z "$list_text" ] && list_text="<i>No fallback SOCKS configured.</i>"
            local text kb
            text=$(printf '%s <b>Fallback SOCKS</b>\n\nTried in order after Podkop SOCKS5 fails.\nFormat: <code>socks5://IP:PORT</code> or <code>socks5h://IP:PORT</code>\n\n%s' "$E_NET" "$list_text")
            kb="{\"inline_keyboard\":[${rows}[{\"text\":\"${E_ADD} Add\",\"callback_data\":\"cmd_fb_socks_add\"},{\"text\":\"${E_TEST} Test All\",\"callback_data\":\"cmd_test_fb_socks\"},{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"fallback_socks_menu\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"bot_settings\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "ask_del_fb_"*)
            local idx="${cmd#ask_del_fb_}" fb_to_del="" n=0 _fb
            local _fb_raw
            _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
            if [ -n "$_fb_raw" ]; then
                eval "set -- $_fb_raw"
                for _fb in "$@"; do
                    [ "$n" -eq "$idx" ] && fb_to_del="$_fb" && break
                    n=$((n + 1))
                done
            fi
            [ -z "$fb_to_del" ] && {
                send_or_edit "$mid" "$(printf '%s Entry not found.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"fallback_socks_menu\"}]]}"
                return
            }
            send_or_edit "$mid" \
                "$(printf '%s <b>Remove this fallback?</b>\n\n<code>%s</code>' "$E_WARN" "$fb_to_del")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Remove\",\"callback_data\":\"do_del_fb_${idx}\"},{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"fallback_socks_menu\"}]]}"
            ;;

        "do_del_fb_"*)
            local idx="${cmd#do_del_fb_}" n=0 _fb
            local _fb_raw
            _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
            if [ -n "$_fb_raw" ]; then
                eval "set -- $_fb_raw"
                # Find value by index, delete by value (most reliable on all OpenWrt builds)
                local _del_val=""
                for _fb in "$@"; do
                    [ "$n" -eq "$idx" ] && { _del_val="$_fb"; break; }
                    n=$((n + 1))
                done
                if [ -n "$_del_val" ]; then
                    uci del_list podkop_bot.settings.fallback_socks="$_del_val"
                    uci_commit_safe podkop_bot
                    # Verify — if del_list failed, rebuild without the index
                    local _after
                    _after=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
                    if printf '%s' "$_after" | grep -qF "$_del_val"; then
                        n=0
                        uci delete podkop_bot.settings.fallback_socks 2>/dev/null
                        for _fb in "$@"; do
                            [ "$n" -ne "$idx" ] && uci add_list podkop_bot.settings.fallback_socks="$_fb"
                            n=$((n + 1))
                        done
                        uci_commit_safe podkop_bot
                    fi
                fi
            fi
            _handle_fallback_socks "fallback_socks_menu" "$mid" "" ""
            ;;

        "cmd_test_fb_socks")
            send_or_edit "$mid" "$(printf '%s Testing SOCKS endpoints...' "$E_TIME")" ""
            local _fb_raw n=0 _fb result_text=""
            local sec m_ip m_port
            sec=$(get_active_section)
            m_port=$(uci -q get podkop.${sec}.mixed_proxy_port 2>/dev/null || echo "2080")
            m_ip=$(get_proxy_ip)
            # Short timeouts for interactive test (3s connect / 5s total per endpoint)
            _probe_fast() {
                local _url="$1" _out _code _time
                _out=$(curl -s -k -x "$_url" \
                    --connect-timeout 3 --max-time 5 \
                    -o /dev/null -w "%{http_code}:%{time_total}" \
                    "http://www.gstatic.com/generate_204" 2>/dev/null)
                _code="${_out%%:*}"
                _time="${_out#*:}"
                if [ "$_code" = "204" ]; then
                    awk -v t="$_time" 'BEGIN{printf "%dms", int(t*1000)}'
                else
                    echo "timeout"
                fi
            }
            local lat; lat=$(_probe_fast "socks5h://${m_ip}:${m_port}")
            case "$lat" in timeout|fail) result_text="${result_text}${E_ERR} tier1 Podkop: <code>$lat</code>\n" ;;
                *) result_text="${result_text}${E_ON} tier1 Podkop: <code>$lat</code>\n" ;; esac
            _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
            if [ -n "$_fb_raw" ]; then
                eval "set -- $_fb_raw"
                for _fb in "$@"; do
                    n=$((n + 1))
                    lat=$(_probe_fast "$_fb")
                    case "$lat" in timeout|fail)
                        result_text="${result_text}${E_ERR} tier2_${n}: <code>$lat</code> <i>${_fb}</i>\n" ;;
                        *) result_text="${result_text}${E_ON} tier2_${n}: <code>$lat</code> <i>${_fb}</i>\n" ;;
                    esac
                done
            fi
            unset -f _probe_fast
            [ -z "$result_text" ] && result_text="<i>No endpoints configured.</i>"
            send_or_edit "$mid" \
                "$(printf '%s <b>SOCKS Reachability Test</b>\n<i>(gstatic 204, 3s timeout)</i>\n\n%b' "$E_TEST" "$result_text")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_RST} Re-test\",\"callback_data\":\"cmd_test_fb_socks\"},{\"text\":\"${E_BACK} Back\",\"callback_data\":\"fallback_socks_menu\"}]]}"
            ;;

        "cmd_fb_socks_add")
            echo "wait_fb_socks_add" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Add Fallback SOCKS</b>\n\nFormat: <code>socks5://IP:PORT</code> or <code>socks5h://IP:PORT</code>\n<code>socks5h://</code> resolves DNS remotely (recommended under RKN).\n\nExample: <code>socks5h://192.168.2.238:18080</code>' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"fallback_socks_menu\"}]]}"
            ;;
    esac
}

_handle_bot() {
    local cmd="$1" mid="$2" text="$3" state="$4"

    if [ "$cmd" = "STATE_INPUT" ]; then
        rm -f "$STATE_FILE"
        if [ "$state" = "wait_restart_router_confirm" ]; then
            local input; input=$(printf "%s" "$text" | tr -d '\r\n\t ')
            if [ "$input" = "YES" ]; then
                send_message "$(printf '%s <b>Rebooting %s now...</b>\nBot will be back online in ~60 seconds.' "$E_OFF" "$(cat /proc/sys/kernel/hostname 2>/dev/null || echo Router)")" ""
                logger -t podkop-bot "[Restart Router] Manual reboot requested via Telegram"
                sleep 2
                reboot
            else
                delete_message "$mid"
                send_message "$(printf '%s Reboot cancelled. You typed: <code>%s</code>' "$E_BACK" "$(html_escape "$input")")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_info\"}]]}"
            fi
            return
        elif [ "$state" = "wait_custom_proxy" ]; then
            delete_message "$mid"
            local safe_link=$(printf "%s" "$text" | tr -d '\r\n\t ')
            if echo "$safe_link" | grep -qE '^(http|https|socks5|socks5h)://'; then
                uci set podkop_bot.settings.custom_proxy="$safe_link"; uci_commit_safe podkop_bot
                send_message "$(printf '%s Custom proxy saved.' "$E_OK")" ""
                _handle_bot "bot_settings" "" "" ""
            else
                send_message "$(printf '%s Must start with http:// or socks5://' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"bot_settings\"}]]}"
            fi
        elif [ "$state" = "wait_bind_iface" ]; then
            delete_message "$mid"
            local safe_iface=$(printf "%s" "$text" | tr -d '\r\n')
            if echo "$safe_iface" | grep -q '[[:space:]]'; then
                send_message "$(printf '%s Interface name contains spaces.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"bot_settings\"}]]}"
            elif ! ip link show "$safe_iface" >/dev/null 2>&1; then
                send_message "$(printf '%s Interface <code>%s</code> does not exist.' "$E_ERR" "$safe_iface")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"bot_settings\"}]]}"
            else
                uci set podkop_bot.settings.bind_interface="$safe_iface"; uci_commit_safe podkop_bot
                send_message "$(printf '%s Bound to: %s' "$E_OK" "$safe_iface")" ""
                _handle_bot "bot_settings" "" "" ""
            fi
        fi
        return
    fi

    case "$cmd" in
        "/start"|"/menu"|"main_menu"|"main_menu_new")
            rm -f "$STATE_FILE"
            local _stop_start hostname p_ver active_proxy active_proxy_display sec sec_count sec_str text kb

            _stop_start="{\"text\":\"${E_STP} Stop Podkop\",\"callback_data\":\"ask_cmd_stop\"}"
            pidof sing-box >/dev/null 2>&1 || \
                _stop_start="{\"text\":\"${E_ON} Start Podkop\",\"callback_data\":\"cmd_start\"}"

            hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
            p_ver=$(opkg info podkop 2>/dev/null | grep '^Version:' | cut -d' ' -f2)
            [ -z "$p_ver" ] && p_ver=$(apk info podkop 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^podkop-//')
            # Pass cached proxies to avoid extra clash_request
            local proxies; proxies=$(clash_request "/proxies")
            active_proxy=$(get_active_proxy_name "$proxies")
            active_proxy_display=$(html_escape "$(display_proxy_name_with_tag "$active_proxy")")
            sec=$(get_active_section)
            sec_count=$(uci -q show podkop 2>/dev/null | grep -cE '^podkop\.[^.=]+=section$')

            sec_str=""
            [ "$sec_count" -gt 1 ] && sec_str=$(printf '<b>Section:</b> <code>%s</code>\n' "$sec")

            # NOTE: get_tg_latency intentionally removed from main_menu (was 3s delay per open)
            # Latency is still available in Status and Bot Settings screens.
            text=$(cat <<EOF
<b>${E_RTR} Podkop Manager</b>
<code>────────────────────</code>
<b>Host:</b> ${hostname}
<b>Podkop:</b> ${p_ver:-Unknown} | <b>Bot:</b> v${BOT_VERSION}
${sec_str}<b>Active Route:</b> <code>${active_proxy_display}</code>
<b>Transport:</b> ${LAST_ROUTE_NAME}
<code>────────────────────</code>
EOF
)
            kb="{\"inline_keyboard\":["
            # Mode-aware proxy button: label and target depend on proxy_config_type
            local cur_pct; cur_pct=$(uci -q get podkop.${sec}.proxy_config_type 2>/dev/null || echo "selector")
            local proxy_btn_lbl proxy_btn_cb
            case "$cur_pct" in
                urltest)  proxy_btn_lbl="${E_GLOB} Outbounds";      proxy_btn_cb="proxy_menu" ;;
                url)      proxy_btn_lbl="${E_GLOB} URL Links";      proxy_btn_cb="url_links_menu" ;;
                outbound) proxy_btn_lbl="${E_GLOB} Outbound";       proxy_btn_cb="outbound_info" ;;
                *)        proxy_btn_lbl="${E_GLOB} Outbounds"; proxy_btn_cb="proxy_menu" ;;
            esac
            kb="${kb}[{\"text\":\"${E_STAT} Status\",\"callback_data\":\"cmd_status\"},{\"text\":\"${proxy_btn_lbl}\",\"callback_data\":\"${proxy_btn_cb}\"}],"
            kb="${kb}[{\"text\":\"${E_SET} Settings\",\"callback_data\":\"main_settings_menu\"},{\"text\":\"${E_RST} Reload Podkop\",\"callback_data\":\"ask_reload_podkop\"}],"
            kb="${kb}[{\"text\":\"${E_BOT} Bot Settings\",\"callback_data\":\"bot_settings\"},${_stop_start}],"
            kb="${kb}[{\"text\":\"Info / Updates\",\"callback_data\":\"cmd_info\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_status")
            local hostname lan_ip wan_ip uptime_sys loadavg mem_free os_ver extra_ifs
            local podkop_init_status podkop_autostart podkop_mode
            local sb_state sb_pid sb_ram health_st strategy yacd_en tg_lat sec
            local active_proxy active_proxy_display text kb proxies pub_ip_display

            hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
            os_ver=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "OpenWrt")
            lan_ip=$(uci -q get network.lan.ipaddr || echo "Unknown")

            # FIXED: wan_ip via local routing (no blocking external curl)
            wan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
                | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
            [ -z "$wan_ip" ] && wan_ip=$(uci -q get network.wan.ipaddr 2>/dev/null || echo "Unknown")

            uptime_sys=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);printf "%dd %dh %dm",d,h,m}' /proc/uptime)
            loadavg=$(awk '{printf "%s, %s, %s",$1,$2,$3}' /proc/loadavg)
            mem_free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0")

            extra_ifs=$(ip -4 addr show 2>/dev/null | awk -v icon="${E_NET}" '/inet / {
                iface=$NF; sub(/@.*/, "", iface);
                if(iface ~ /^(tun|tail|awg|wg|zt|zero)/) {
                    ip=$2; sub(/\/.*/, "", ip);
                    if      (iface ~ /^tail/)  label="Tailscale"
                    else if (iface ~ /^zt/)    label="ZeroTier"
                    else if (iface ~ /^awg/)   label="AmneziaWG"
                    else if (iface ~ /^wg/)    label="WireGuard"
                    else if (iface ~ /^tun/)   label="VPN"
                    else                       label=iface
                    printf "%s %s (<code>%s</code>): <code>%s</code>\n", icon, label, iface, ip;
                }
            }')
            # $() strips trailing newlines — restore separator so CPU Load stays on its own line
            [ -n "$extra_ifs" ] && extra_ifs="${extra_ifs}
"

            if /etc/init.d/podkop status 2>&1 | grep -qi "running"; then
                podkop_init_status="${E_OK} RUNNING"
            else
                podkop_init_status="${E_OK} OK (one-shot)"
            fi
            if /etc/init.d/podkop enabled >/dev/null 2>&1; then
                podkop_autostart="${E_OK} ENABLED"
            else
                podkop_autostart="${E_OFF} DISABLED"
            fi

            sec=$(get_active_section)
            podkop_mode=$(uci -q get podkop.${sec}.proxy_config_type || echo "unknown")
            local podkop_mode_lbl
            case "$podkop_mode" in
                selector) podkop_mode_lbl="Selector (manual)" ;;
                urltest)  podkop_mode_lbl="URLTest (auto-fastest)" ;;
                url)      podkop_mode_lbl="URL Connection" ;;
                outbound) podkop_mode_lbl="Outbound Config (LuCI)" ;;
                *)        podkop_mode_lbl="$podkop_mode" ;;
            esac

            if pidof sing-box >/dev/null 2>&1; then sb_state="${E_OK} RUNNING"
            else sb_state="${E_ERR} STOPPED"; fi
            sb_pid=$(pidof sing-box 2>/dev/null || echo "n/a")
            sb_ram="0"
            [ "$sb_pid" != "n/a" ] && \
                sb_ram=$(awk '/VmRSS/{print int($2/1024)}' /proc/"$sb_pid"/status 2>/dev/null || echo "0")

            # Build health summary from SOCKS_STATE_FILE (two TG metrics + SOCKS)
            local _h_tgd _h_tgt _h_socks _h_tgd_icon _h_tgt_icon _h_socks_icon
            _h_tgd=$(grep "^tg_direct=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
            _h_tgt=$(grep "^tg_transport=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
            _h_socks=$(grep "^socks=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
            [ "$_h_tgd" = "ok" ]   && _h_tgd_icon="$E_OK"   || _h_tgd_icon="$E_ERR"
            [ "$_h_tgt" = "ok" ]   && _h_tgt_icon="$E_OK"   || _h_tgt_icon="$E_ERR"
            [ "$_h_socks" = "up" ] && _h_socks_icon="$E_OK" || _h_socks_icon="$E_ERR"
            health_st="${_h_tgd_icon} TG direct: ${_h_tgd:-?} | ${_h_tgt_icon} via SOCKS: ${_h_tgt:-?} | ${_h_socks_icon} SOCKS: ${_h_socks:-?}"
            strategy=$(uci -q get podkop.settings.dns_type || echo "udp")
            yacd_en=$(uci -q get podkop.settings.enable_yacd || echo "0")
            tg_lat=$(get_tg_latency)

            proxies=$(clash_request "/proxies")
            active_proxy=$(get_active_proxy_name "$proxies")
            active_proxy_display=$(html_escape "$(display_proxy_name_with_tag "$active_proxy")")

            # Public IP: read from cache (instant). Background refresh if stale.
            pub_ip_display=$(get_public_ip_display)

            text=$(cat <<EOF
${E_STAT} <b>System & Podkop Status</b>
<code>────────────────────</code>
${E_RTR} <b>${hostname}</b> | ${E_TIME} ${uptime_sys}
<b>OS:</b> ${os_ver}
${E_GLOB} WAN iface: <code>${wan_ip}</code>
${E_GLOB} Public IP: <code>${pub_ip_display}</code>
${E_NET} LAN: <code>${lan_ip}</code>
${extra_ifs}${E_CPU} Load: <code>${loadavg}</code>
${E_RAM} Free RAM: <code>${mem_free} MB</code>
<code>────────────────────</code>
${E_SET} <b>Podkop:</b> ${podkop_init_status}
${E_ON} <b>Autostart:</b> ${podkop_autostart}
${E_SET} <b>Mode:</b> <code>${podkop_mode_lbl}</code>
${E_PRX} <b>Sing-box:</b> ${sb_state}
EOF
)
            [ "$sb_ram" != "0" ] && text=$(printf '%s\n%s <b>Sing-box RAM:</b> %s MB' "$text" "$E_RAM" "$sb_ram")
            text=$(cat <<EOF
${text}
<code>────────────────────</code>
${E_GLOB} <b>Active Proxy:</b> <code>${active_proxy_display}</code>
${E_SCAN} <b>Health:</b> ${health_st}
${E_NET} <b>DNS:</b> ${strategy} | <b>YACD:</b> $([ "$yacd_en" = "1" ] && echo "${E_ON} ON" || echo "${E_OFF} OFF")
${E_SHLD} <b>Bot Route:</b> ${LAST_ROUTE_NAME} (${E_TIME} ${tg_lat})
EOF
)
            kb="{\"inline_keyboard\":[
                [{\"text\":\"${E_SCAN} Runtime Info\",\"callback_data\":\"cmd_runtime\"}],
                [{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"cmd_status\"},{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]
            ]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_runtime")
            local conn_data curr_conn total_dl total_ul dl_fmt ul_fmt text kb
            local proxies selector active_proxy active_proxy_display p_delay_raw p_delay p_type active_leaf

            conn_data=$(clash_request "/connections")
            curr_conn=$(echo "$conn_data" | jq -r '.connections | length // 0' 2>/dev/null)
            total_dl=$(echo "$conn_data" | jq -r '.downloadTotal // 0' 2>/dev/null)
            total_ul=$(echo "$conn_data" | jq -r '.uploadTotal // 0' 2>/dev/null)
            dl_fmt=$(awk "BEGIN{m=$total_dl/1000000;if(m>=1000)printf \"%.2f GB\",m/1000;else printf \"%.2f MB\",m}")
            ul_fmt=$(awk "BEGIN{m=$total_ul/1000000;if(m>=1000)printf \"%.2f GB\",m/1000;else printf \"%.2f MB\",m}")

            proxies=$(clash_request "/proxies")
            selector=$(get_selector_tag "$proxies")
            active_proxy=$(get_active_proxy_name "$proxies")
            active_proxy_display=$(html_escape "$(display_proxy_name "$active_proxy")")

            # Resolve leaf to get accurate type and delay (follows Selector/URLTest chains)
            active_leaf=$(_resolve_leaf "$active_proxy" "$proxies")
            [ -z "$active_leaf" ] && active_leaf="$active_proxy"

            # Try delay on named proxy first, fall back to leaf (mirrors proxy_menu logic)
            p_delay_raw=$(echo "$proxies" | jq -r --arg n "$active_proxy" '.proxies[$n].history[-1].delay // 0' 2>/dev/null)
            [ -z "$p_delay_raw" ] || [ "$p_delay_raw" = "0" ] &&                 p_delay_raw=$(echo "$proxies" | jq -r --arg n "$active_leaf" '.proxies[$n].history[-1].delay // 0' 2>/dev/null)
            [ -z "$p_delay_raw" ] || [ "$p_delay_raw" = "0" ] && p_delay="N/A" || p_delay="${p_delay_raw}ms"
            p_type=$(echo "$proxies" | jq -r --arg n "$active_leaf" '.proxies[$n].type // .proxies[$n].adapterType // "Unknown"' 2>/dev/null)

            # Bot transport summary line for Runtime Info
            local rt_socks_state rt_transport_summary
            rt_socks_state=$(grep "^socks=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
            if [ "$rt_socks_state" = "up" ]; then
                rt_transport_summary="${E_ON} ${LAST_ROUTE_NAME:-unknown}"
            else
                rt_transport_summary="${E_YLW} ${LAST_ROUTE_NAME:-unknown} (SOCKS down)"
            fi

            text=$(cat <<EOF
${E_SCAN} <b>Runtime Info</b>
<code>────────────────────</code>
${E_PRX} <b>Connections:</b> ${curr_conn}
${E_DWN} <b>Downloaded:</b> ${dl_fmt}
${E_UP} <b>Uploaded:</b> ${ul_fmt}
<code>────────────────────</code>
${E_GLOB} <b>Active proxy:</b> <code>${active_proxy_display}</code>
${E_SET} <b>Type:</b> ${p_type} | <b>Delay:</b> ${p_delay}
<b>Selector:</b> <code>${selector}</code>
<code>────────────────────</code>
${E_SHLD} <b>Bot route:</b> ${rt_transport_summary}
EOF
)
            kb="{\"inline_keyboard\":[
                [{\"text\":\"${E_HEALTH} Tunnel Health\",\"callback_data\":\"cmd_tunnel_health\"}],
                [{\"text\":\"${E_TEST} Diagnostics\",\"callback_data\":\"cmd_diagnostics\"}],
                [{\"text\":\"${E_FILE} Configs & Logs\",\"callback_data\":\"cmd_files\"}],
                [{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"cmd_runtime\"},{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_status\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]
            ]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_tunnel_health")
            # Dedicated Tunnel Health screen: system-level tunnel state
            local sec nft_count sb_pid sb_ram sb_state wan_iface proxy_mode
            local last_reload_ts last_reload_str active_cl nft_raw text kb

            sec=$(get_active_section)
            proxy_mode=$(uci -q get podkop.${sec}.proxy_config_type || echo "unknown")
            wan_iface=$(uci -q get podkop.${sec}.outbound_interface 2>/dev/null || echo "auto")

            # nftables podkop rules count
            nft_raw=$(nft list ruleset 2>/dev/null | grep -i podkop | wc -l)
            nft_count="${nft_raw:-0}"

            # sing-box process
            if pidof sing-box >/dev/null 2>&1; then sb_state="${E_OK} RUNNING"
            else sb_state="${E_ERR} STOPPED"; fi
            sb_pid=$(pidof sing-box 2>/dev/null || echo "n/a")
            sb_ram="0"
            [ "$sb_pid" != "n/a" ] && \
                sb_ram=$(awk '/VmRSS/{print int($2/1024)}' /proc/"$sb_pid"/status 2>/dev/null || echo "0")

            # Last reload: prefer bot's own RELOAD_TS_FILE.
            local now last_reload_raw diff_s
            now=$(date +%s)
            last_reload_raw=0
            if [ -f "$RELOAD_TS_FILE" ]; then
                last_reload_raw=$(cat "$RELOAD_TS_FILE" 2>/dev/null || echo "0")
            fi
            if [ "$last_reload_raw" -eq 0 ] && [ "$sb_pid" != "n/a" ]; then
                local sb_start_ticks ticks_per_sec boot_ts
                sb_start_ticks=$(awk '{print $22}' /proc/"$sb_pid"/stat 2>/dev/null || echo "0")
                ticks_per_sec=$(getconf CLK_TCK 2>/dev/null || echo "100")
                boot_ts=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
                last_reload_raw=$((now - boot_ts + sb_start_ticks / ticks_per_sec))
            fi
            if [ "$last_reload_raw" -gt 0 ]; then
                diff_s=$((now - last_reload_raw))
                if   [ "$diff_s" -lt 60 ];   then last_reload_str="${diff_s}s ago"
                elif [ "$diff_s" -lt 3600 ]; then last_reload_str="$((diff_s/60))m ago"
                else                              last_reload_str="$((diff_s/3600))h $((diff_s%3600/60))m ago"; fi
            else
                last_reload_str="Unknown"
            fi

            # Active community lists
            active_cl=$(uci -q show podkop.${sec} 2>/dev/null \
                | grep "^podkop\.${sec}\.community_lists=" \
                | sed "s/^[^']*'//g; s/'$//g; s/' '/, /g" || echo "None")
            [ -z "$active_cl" ] && active_cl="None"

            # Active proxy name from Clash API
            local th_proxies th_active_proxy th_active_display
            th_proxies=$(clash_request "/proxies" 2>/dev/null)
            th_active_proxy=$(get_active_proxy_name "$th_proxies")
            th_active_display=$(html_escape "$(display_proxy_name_with_tag "$th_active_proxy")")
            [ -z "$th_active_display" ] && th_active_display="N/A (Clash API unavailable)"

            # Read structured watchdog state: two TG keys + socks
            local wd_tg_direct="?" wd_tg_transport="?" wd_socks="?"
            if [ -f "$SOCKS_STATE_FILE" ]; then
                wd_tg_direct=$(grep "^tg_direct=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
                wd_tg_transport=$(grep "^tg_transport=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
                wd_socks=$(grep "^socks=" "$SOCKS_STATE_FILE" 2>/dev/null | cut -d= -f2)
            fi
            local tgd_icon tgt_icon socks_icon
            [ "$wd_tg_direct" = "ok" ]    && tgd_icon="$E_OK"  || tgd_icon="$E_ERR"
            [ "$wd_tg_transport" = "ok" ] && tgt_icon="$E_OK"  || tgt_icon="$E_ERR"
            [ "$wd_socks" = "up" ]        && socks_icon="$E_OK" || socks_icon="$E_ERR"

            # Read SOCKS latency probe results
            local probe_ts="" probe_tier1="" probe_fb_text="" probe_age_str="" probe_t3_text=""
            if [ -f "$SOCKS_PROBE_FILE" ]; then
                probe_ts=$(grep "^ts=" "$SOCKS_PROBE_FILE" 2>/dev/null | cut -d= -f2)
                probe_tier1=$(grep "^tier1=" "$SOCKS_PROBE_FILE" 2>/dev/null | cut -d= -f2)
                # Build fallback_socks probe lines
                local _pn=1
                while true; do
                    local _pline
                    _pline=$(grep "^tier2_${_pn}=" "$SOCKS_PROBE_FILE" 2>/dev/null)
                    [ -z "$_pline" ] && break
                    local _plat _purl
                    _plat=$(echo "$_pline" | cut -d= -f2 | awk '{print $1}')
                    _purl=$(echo "$_pline" | grep -oE 'url=[^ ]+' | cut -d= -f2)
                    _purl="${_purl:-tier2_${_pn}}"
                    local _platicon
                    case "$_plat" in timeout|fail) _platicon="$E_ERR" ;; *) _platicon="$E_ON" ;; esac
                    probe_fb_text="${probe_fb_text}${_platicon} tier2_${_pn}: <code>${_plat}</code> <i>${_purl}</i>\n"
                    _pn=$((_pn + 1))
                done
                # tier3: custom_proxy
                local _t3line; _t3line=$(grep "^tier3=" "$SOCKS_PROBE_FILE" 2>/dev/null)
                if [ -n "$_t3line" ]; then
                    local _t3lat _t3url _t3icon
                    _t3lat=$(echo "$_t3line" | cut -d= -f2 | awk '{print $1}')
                    _t3url=$(echo "$_t3line" | grep -oE 'url=[^ ]+' | cut -d= -f2)
                    case "$_t3lat" in timeout|fail) _t3icon="$E_ERR" ;; *) _t3icon="$E_ON" ;; esac
                    probe_t3_text="${_t3icon} tier3 (custom): <code>${_t3lat}</code> <i>${_t3url}</i>\n"
                fi
                if [ -n "$probe_ts" ]; then
                    local probe_age=$(( $(date +%s) - probe_ts ))
                    if   [ "$probe_age" -lt 60 ];   then probe_age_str="${probe_age}s ago"
                    elif [ "$probe_age" -lt 3600 ];  then probe_age_str="$((probe_age/60))m ago"
                    else                                  probe_age_str="$((probe_age/3600))h ago"
                    fi
                fi
            fi
            local t1_icon
            case "${probe_tier1:-?}" in timeout|fail) t1_icon="$E_ERR" ;; "?") t1_icon="$E_YLW" ;; *) t1_icon="$E_ON" ;; esac

            local probe_section=""
            if [ -n "$probe_tier1" ]; then
                probe_section=$(printf '\n<code>────────────────────</code>\n%s <b>Transport Latency</b> <i>(probed %s)</i>\n%s tier1 (Podkop): <code>%s</code>\n%b%b' \
                    "$E_TIME" "${probe_age_str:-unknown}" "$t1_icon" "$probe_tier1" "$probe_fb_text" "$probe_t3_text")
            else
                probe_section=$(printf '\n<code>────────────────────</code>\n%s <b>Transport Latency:</b> <i>not yet probed</i>' "$E_TIME")
            fi

            text=$(cat <<EOF
${E_HEALTH} <b>Tunnel Health</b> [<code>${sec}</code>]
<code>────────────────────</code>
${E_PRX} <b>Sing-box:</b> ${sb_state}
${E_RAM} <b>PID:</b> <code>${sb_pid}</code> | <b>RAM:</b> ${sb_ram} MB
${E_SET} <b>Mode:</b> <code>${proxy_mode}</code>
${E_NET} <b>WAN iface:</b> <code>${wan_iface}</code>
${E_GLOB} <b>Active proxy:</b> <code>${th_active_display}</code>
<code>────────────────────</code>
${tgd_icon} <b>TG direct:</b> <code>${wd_tg_direct:-?}</code> <i>(no proxy)</i>
${tgt_icon} <b>TG via Podkop (tier1):</b> <code>${wd_tg_transport:-?}</code> <i>(primary mixed_proxy — not full bot transport chain)</i>
${socks_icon} <b>SOCKS upstream:</b> <code>${wd_socks:-unknown}</code>
${E_SHLD} <b>Bot transport:</b> <code>${LAST_ROUTE_NAME}</code>
${E_NET} <b>Poll route:</b> <code>${LAST_ROUTE_POLL}</code> | <b>Fast:</b> <code>${LAST_ROUTE_FAST}</code>${probe_section}
<code>────────────────────</code>
${E_FILE} <b>nftables rules (podkop):</b> ${nft_count}
${E_RST} <b>Last reload:</b> ${last_reload_str}
<code>────────────────────</code>
${E_ON} <b>Community Lists:</b>
<code>${active_cl}</code>
EOF
)
            kb="{\"inline_keyboard\":[
                [{\"text\":\"${E_RST} Refresh\",\"callback_data\":\"cmd_tunnel_health\"},{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_runtime\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]
            ]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "bot_settings")
            rm -f "$STATE_FILE"
            local tr st al hi cp bi next_tr tr_disp next_hi text kb tg_lat sec m_port m_ip

            tr=$(uci -q get podkop_bot.settings.transport || echo "auto")
            st=$(uci -q get podkop_bot.settings.startup_notify || echo "1")
            al=$(uci -q get podkop_bot.settings.alert_notify || echo "1")
            hi=$(uci -q get podkop_bot.settings.health_interval || echo "60")
            cp=$(uci -q get podkop_bot.settings.custom_proxy || echo "Not set")
            bi=$(uci -q get podkop_bot.settings.bind_interface || echo "Not set")
            tg_lat=$(get_tg_latency)

            next_tr="socks"; tr_disp="Auto"
            [ "$tr" = "socks" ]  && { next_tr="direct"; tr_disp="Socks5"; }
            [ "$tr" = "direct" ] && { next_tr="auto";   tr_disp="Direct"; }

            # Cycle: 60 → 30 → 120 → 300 → 60
            # 30s shows a confirm warning (high CPU load on weak routers)
            next_hi="30"
            [ "$hi" = "30"  ] && next_hi="120"
            [ "$hi" = "120" ] && next_hi="300"
            [ "$hi" = "300" ] && next_hi="60"

            sec=$(get_active_section)
            m_port=$(uci -q get podkop.${sec}.mixed_proxy_port || echo "2080")
            m_ip=$(get_proxy_ip)

            # Build fallback route chain with active tier highlighted in bold.
            # LAST_ROUTE_FAST holds the current tier key: tier1, tier2_N, tier3, tier4, tier5.
            local tr_chain="" _tier=1 _fb_raw _fb _tier_key _tier_line
            _active_tier="$LAST_ROUTE_FAST"

            _fmt_tier() {
                local _key="$1" _label="$2"
                if [ "$_key" = "$_active_tier" ]; then
                    printf '<b>%s. %s ◀ active</b>' "$_tier" "$_label"
                else
                    printf '%s. %s' "$_tier" "$_label"
                fi
            }

            if [ "$tr" != "direct" ]; then
                _mip_esc=$(html_escape "$m_ip")
                tr_chain=$(_fmt_tier "tier1" "SOCKS5 (${_mip_esc}:${m_port})")
                _tier=$((_tier + 1))
                _fb_raw=$(uci -q show podkop_bot.settings.fallback_socks 2>/dev/null | cut -d= -f2-)
                if [ -n "$_fb_raw" ]; then
                    eval "set -- $_fb_raw"
                    local _fn=1
                    for _fb in "$@"; do
                        _fb_esc=$(html_escape "$_fb")
                        tr_chain="${tr_chain}
$(_fmt_tier "tier2_${_fn}" "Fallback SOCKS (${_fb_esc})")"
                        _tier=$((_tier + 1)); _fn=$((_fn + 1))
                    done
                fi
            fi
            if [ "$cp" != "Not set" ]; then
                _cp_esc=$(html_escape "$cp")
                tr_chain="${tr_chain}
$(_fmt_tier "tier3" "Custom (${_cp_esc})")"
                _tier=$((_tier + 1))
            fi
            if [ "$tr" != "socks" ]; then
                _bi_esc=""; [ "$bi" != "Not set" ] && _bi_esc=" via $(html_escape "$bi")"
                local d_if="$_bi_esc"
                tr_chain="${tr_chain}
$(_fmt_tier "tier4" "Direct${d_if}")"
                _tier=$((_tier + 1))
                tr_chain="${tr_chain}
$(_fmt_tier "tier5" "Emergency IPs")"
            fi
            [ -z "$tr_chain" ] && tr_chain="No valid transports!"

            local now uptime_s uptime_sys last_cmd_str unauth_str
            now=$(date +%s); uptime_s=$((now - BOT_START_TIME))
            uptime_sys=$(awk -v t="$uptime_s" 'BEGIN{d=int(t/86400);h=int((t%86400)/3600);m=int((t%3600)/60);printf "%dd %dh %dm",d,h,m}')

            last_cmd_str="None"
            if [ -f "$LAST_CMD_FILE" ]; then
                local lc_ts lc_usr lc_cmd lc_time
                lc_ts=$(cut -d'|' -f1 "$LAST_CMD_FILE"); lc_usr=$(cut -d'|' -f2 "$LAST_CMD_FILE")
                lc_cmd=$(cut -d'|' -f3- "$LAST_CMD_FILE")
                lc_time=$(awk -v t="$lc_ts" 'BEGIN{print strftime("%Y-%m-%d %H:%M:%S",t)}' 2>/dev/null || echo "$lc_ts")
                last_cmd_str=$(printf '@%s at %s\nCmd: <code>%s</code>' "$lc_usr" "$lc_time" "$lc_cmd")
            fi

            unauth_str="0 attempts"
            if [ -f "$UNAUTH_FILE" ]; then
                local ua_cnt ua_ts ua_usr ua_time
                ua_cnt=$(cut -d'|' -f1 "$UNAUTH_FILE"); ua_ts=$(cut -d'|' -f2 "$UNAUTH_FILE")
                ua_usr=$(cut -d'|' -f3 "$UNAUTH_FILE")
                ua_time=$(awk -v t="$ua_ts" 'BEGIN{print strftime("%Y-%m-%d %H:%M:%S",t)}' 2>/dev/null || echo "$ua_ts")
                unauth_str=$(printf '%s %s attempts\nLast: @%s at %s' "$E_RED" "$ua_cnt" "$ua_usr" "$ua_time")
            fi

            kb="{\"inline_keyboard\":["
            # Hints
            local tr_hint cp_hint=""
            if echo "$cp" | grep -q '^socks5://'; then
                cp_hint="${E_IDEA} <i>Tip: <code>${cp}</code> is a SOCKS proxy — consider moving it to Fallback SOCKS (tier2) for better failover ordering.</i>"
            fi
            case "$tr" in
                auto)   tr_hint="${E_IDEA} <i>Auto: Podkop SOCKS5 → Fallback SOCKS → Custom → Direct → Emergency IPs.</i>" ;;
                socks)  tr_hint="${E_IDEA} <i>Socks5 only: SOCKS tiers only. Bot goes offline if all SOCKS fail.</i>" ;;
                direct) tr_hint="${E_IDEA} <i>Direct: skip all SOCKS. Use when tunnel is intentionally off.</i>" ;;
                *)      tr_hint="" ;;
            esac

            # Keyboard: 3 semantic groups
            local cp_btn bi_btn st_icon al_icon
            [ "$cp" = "Not set" ]                 && cp_btn="{\"text\":\"${E_ADD} Custom Proxy\",\"callback_data\":\"cmd_custom_proxy\"}"                 || cp_btn="{\"text\":\"${E_DEL} Clear Custom Proxy\",\"callback_data\":\"cmd_clear_custom_proxy\"}"
            [ "$bi" = "Not set" ]                 && bi_btn="{\"text\":\"${E_ADD} Bind Iface\",\"callback_data\":\"cmd_bind_iface\"}"                 || bi_btn="{\"text\":\"${E_DEL} Unbind Iface\",\"callback_data\":\"cmd_clear_bind_iface\"}"
            [ "$st" = "1" ] && st_icon="$E_ON" || st_icon="$E_OFF"
            [ "$al" = "1" ] && al_icon="$E_ON" || al_icon="$E_OFF"

            kb="{\"inline_keyboard\":[
                [{\"text\":\"Transport: ${tr_disp}\",\"callback_data\":\"ask_set_tr_menu\"},{\"text\":\"Health: ${hi}s\",\"callback_data\":\"set_bot_hi_${next_hi}\"}],
                [{\"text\":\"${E_NET} Fallback SOCKS\",\"callback_data\":\"fallback_socks_menu\"}],
                [${cp_btn},${bi_btn}],
                [{\"text\":\"${st_icon} Startup Notify\",\"callback_data\":\"toggle_bot_st\"},{\"text\":\"${al_icon} Alert Notify\",\"callback_data\":\"toggle_bot_al\"}],
                [{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]
            ]}"

            text=$(cat <<EOF
${E_BOT} <b>Bot Control Plane</b>
<code>────────────────────</code>
${E_SHLD} <b>Transport Policy:</b> <code>${tr}</code>
${tr_hint}
${E_SHLD} <b>Active Route:</b> <code>${LAST_ROUTE_NAME:-Initializing...}</code>
${E_TIME} <b>TG Latency:</b> ${tg_lat}
<code>────────────────────</code>
<b>Fallback Chain:</b>
${tr_chain}
<code>────────────────────</code>
<b>Overrides:</b>
<b>Custom Proxy:</b> <code>${cp}</code>${cp_hint:+
${cp_hint}}
<b>Bind Interface:</b> <code>${bi}</code>
<code>────────────────────</code>
<b>Bot Uptime:</b> ${uptime_sys}
<b>Started:</b> ${BOT_START_STR}
<code>────────────────────</code>
<b>Last Command:</b>
${last_cmd_str}

<b>Unauthorized Attempts:</b>
${unauth_str}
EOF
)
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "set_bot_tr_"*) uci set podkop_bot.settings.transport="${cmd#set_bot_tr_}"; uci_commit_safe podkop_bot; _handle_bot "bot_settings" "$mid" "" "" ;;

        "ask_set_tr_menu")
            local curr_tr; curr_tr=$(uci -q get podkop_bot.settings.transport || echo "auto")
            local tr_menu_txt; tr_menu_txt=$(printf '%s <b>Transport Policy</b>\n\nCurrent: <code>%s</code>\n\n<b>auto</b> - SOCKS5 first, then Fallback SOCKS, then Direct.\n<b>socks</b> - SOCKS only. Bot goes offline if all SOCKS fail.\n<b>direct</b> - Skip all SOCKS. Use only when tunnel is intentionally off.\n\n%s <b>Warning:</b> switching to a restrictive mode may break connectivity under active RKN blocks.' \
                "$E_SET" "$curr_tr" "$E_WARN")
            send_or_edit "$mid" "$tr_menu_txt" \
                "{\"inline_keyboard\":[[{\"text\":\"Auto\",\"callback_data\":\"ask_set_tr_auto\"},{\"text\":\"Socks only\",\"callback_data\":\"ask_set_tr_socks\"},{\"text\":\"Direct only\",\"callback_data\":\"ask_set_tr_direct\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"bot_settings\"}]]}"
            ;;

        "ask_set_tr_"*)
            local new_tr="${cmd#ask_set_tr_}"
            local curr_tr; curr_tr=$(uci -q get podkop_bot.settings.transport || echo "auto")
            [ "$new_tr" = "$curr_tr" ] && { _handle_bot "bot_settings" "$mid" "" ""; return; }
            local warn_txt
            case "$new_tr" in
                auto)   warn_txt=$(printf '%s Switch to <b>Auto</b> transport?\n\nBot will try: SOCKS5 -\x3e Fallback SOCKS -\x3e Direct -\x3e Emergency IPs.\nSafest mode — recommended.' "$E_OK") ;;
                socks)  warn_txt=$(printf '%s Switch to <b>Socks only</b>?\n\n<b>Bot goes offline if all SOCKS proxies fail.</b>\nUse only to guarantee no direct traffic.' "$E_WARN") ;;
                direct) warn_txt=$(printf '%s Switch to <b>Direct only</b>?\n\n<b>All SOCKS proxies will be bypassed.</b>\nBot connects to Telegram without a tunnel.\nSafe only when podkop is intentionally stopped.' "$E_WARN") ;;
                *)      _handle_bot "bot_settings" "$mid" "" ""; return ;;
            esac
            send_or_edit "$mid" "$warn_txt" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Confirm\",\"callback_data\":\"do_set_tr_${new_tr}\"},{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"bot_settings\"}]]}"
            ;;

        "do_set_tr_"*)
            uci set podkop_bot.settings.transport="${cmd#do_set_tr_}"
            uci_commit_safe podkop_bot
            _handle_bot "bot_settings" "$mid" "" ""
            ;;
        "set_bot_hi_30")
            # 30s interval warning - requires explicit confirmation
            local _hostname; _hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
            local _hi30_txt; _hi30_txt=$(printf '%s <b>Health Interval: 30 seconds</b>\n\n<b>Only for powerful routers</b> (Cortex-A53+, 256MB+ RAM).\n\nOn weak MIPS routers 2 curl probes every 30s may spike CPU.\n\nRouter: <code>%s</code>\n\nProceed?' "$E_WARN" "$_hostname")
            send_or_edit "$mid" "$_hi30_txt" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, set 30s\",\"callback_data\":\"do_set_hi_30\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"bot_settings\"}]]}"
            ;;
        "do_set_hi_30"|"set_bot_hi_"*)
            local _new_hi="${cmd#set_bot_hi_}"
            [ "$cmd" = "do_set_hi_30" ] && _new_hi="30"
            uci set podkop_bot.settings.health_interval="$_new_hi"
            uci_commit_safe podkop_bot
            _handle_bot "bot_settings" "$mid" "" "" ;;
        "toggle_bot_st") toggle_uci_bool "podkop_bot.settings" "startup_notify"; _handle_bot "bot_settings" "$mid" "" "" ;;
        "toggle_bot_al") toggle_uci_bool "podkop_bot.settings" "alert_notify";   _handle_bot "bot_settings" "$mid" "" "" ;;

        "cmd_custom_proxy")
            echo "wait_custom_proxy" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Set Custom Proxy</b>\n\nFormat: <code>http://IP:PORT</code> or <code>socks5://IP:PORT</code>' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"bot_settings\"}]]}"
            ;;
        "cmd_clear_custom_proxy")
            uci delete podkop_bot.settings.custom_proxy 2>/dev/null; uci_commit_safe podkop_bot
            send_or_edit "$mid" "$(printf '%s Cleared.' "$E_OK")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"bot_settings\"}]]}"
            ;;
        "cmd_bind_iface")
            echo "wait_bind_iface" > "$STATE_FILE"
            send_or_edit "$mid" "$(printf '%s <b>Bind Interface</b>\n\nExample: <code>awg0</code>, <code>tailscale0</code>' "$E_EDIT")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"bot_settings\"}]]}"
            ;;
        "cmd_clear_bind_iface")
            uci delete podkop_bot.settings.bind_interface 2>/dev/null; uci_commit_safe podkop_bot
            send_or_edit "$mid" "$(printf '%s Cleared.' "$E_OK")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"bot_settings\"}]]}"
            ;;

        "cmd_diagnostics")
            local text kb
            text=$(printf '%s <b>Diagnostics</b>\n\nAll actions below run active tests.\nOn slow routers they may take 10\xe2\x80\x9330 seconds.' "$E_TEST")
            kb="{\"inline_keyboard\":[
                [{\"text\":\"${E_SCAN} Upstream Health\",\"callback_data\":\"ask_upstream_health\"}],
                [{\"text\":\"${E_GLOB} Global Check\",\"callback_data\":\"ask_run_podkop_tests\"},{\"text\":\"${E_CPU} Internal Diag\",\"callback_data\":\"ask_run_internal_diag\"}],
                [{\"text\":\"${E_LOG} Support Bundle\",\"callback_data\":\"ask_support_bundle\"}],
                [{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_runtime\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]
            ]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "ask_upstream_health")
            local text kb
            text=$(printf '%s <b>Upstream Health</b>\n\nTests all outbound proxies via Clash API.\nSends results as a text file.\n\n<i>May take 10\xe2\x80\x9330 sec on slow routers.</i>' "$E_WARN")
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Run\",\"callback_data\":\"cmd_upstream_health\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_diagnostics\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "ask_run_podkop_tests")
            local text kb
            text=$(printf '%s <b>Global Check</b>\n\nRuns <code>podkop global_check</code> \xe2\x80\x94 tests DNS, routing, connectivity.\nSends results as a text file.\n\n<i>May take 10\xe2\x80\x9330 sec.</i>' "$E_WARN")
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Run\",\"callback_data\":\"cmd_run_podkop_tests\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_diagnostics\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "ask_run_internal_diag")
            local text kb
            text=$(printf '%s <b>Internal Diagnostics</b>\n\nGathers UCI config, routes, nft rules, syslog, bot state.\nSends results as a text file.\n\n<i>~5 sec, light CPU load.</i>' "$E_WARN")
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Run\",\"callback_data\":\"cmd_run_internal_diag\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_diagnostics\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "ask_support_bundle")
            local text kb
            text=$(printf '%s <b>Support Bundle</b>\n\nCollects everything: versions, UCI config (token redacted), routes, nft, interfaces, bot transport state, last 80 syslog lines.\nSends as a single text file.\n\n<i>~5 sec. Share with maintainer when reporting bugs.</i>' "$E_WARN")
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Collect & Send\",\"callback_data\":\"cmd_support_bundle\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_diagnostics\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_upstream_health")
            local uf="/tmp/podkop_upstream.txt"
            send_or_edit "$mid" "$(printf '%s Testing upstream proxies...' "$E_TIME")" ""
            if run_upstream_health_report "$uf"; then api_document "$uf" "Upstream Health"
            else send_message "$(printf '%s Done with failures.' "$E_WARN")" ""; api_document "$uf" "Upstream Health (failures)"; fi
            rm -f "$uf"; delete_message "$mid"; _handle_bot "cmd_diagnostics" "" "" ""
            ;;
        "cmd_run_podkop_tests")
            local tf="/tmp/podkop_global_check.txt"
            send_or_edit "$mid" "$(printf '%s Running Global Check...' "$E_TIME")" ""
            /usr/bin/podkop global_check | sed "s/$(printf '\033')\\[[0-9;]*[a-zA-Z]//g" > "$tf" 2>&1 || \
                echo "ERROR: global_check failed" >> "$tf"
            api_document "$tf" "Podkop Global Check"
            rm -f "$tf"; delete_message "$mid"; _handle_bot "cmd_diagnostics" "" "" ""
            ;;
        "cmd_run_internal_diag")
            local tf="/tmp/podkop_internal_diag.txt"
            send_or_edit "$mid" "$(printf '%s Gathering diagnostics...' "$E_TIME")" ""
            run_internal_diagnostics "$tf"
            api_document "$tf" "Internal Diagnostics" || \
                send_message "$(printf '%s Failed to send.' "$E_ERR")" ""
            rm -f "$tf"; delete_message "$mid"; _handle_bot "cmd_diagnostics" "" "" ""
            ;;

        "cmd_files")
            send_or_edit "$mid" "$(printf '%s <b>Configs & Logs</b>' "$E_FILE")" \
                "{\"inline_keyboard\":[
                    [{\"text\":\"${E_FILE} Podkop Config\",\"callback_data\":\"cmd_get_config\"},{\"text\":\"${E_FILE} Sing-box JSON\",\"callback_data\":\"cmd_get_sb_json\"}],
                    [{\"text\":\"${E_LOG} Syslog\",\"callback_data\":\"cmd_get_log\"}],
                    [{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_runtime\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]
                ]}"
            ;;
        "cmd_get_config")  api_document "/etc/config/podkop"        "Podkop Config" ;;
        "cmd_get_sb_json") api_document "/etc/sing-box/config.json" "Sing-box Config" ;;
        "cmd_get_log")
            logread | grep -iE 'podkop|sing-box' | tail -n 150 > /tmp/podkop_syslog.txt
            api_document "/tmp/podkop_syslog.txt" "Recent Logs"
            rm -f /tmp/podkop_syslog.txt
            ;;

        "cmd_support_bundle")
            local bf="/tmp/podkop_support_bundle.txt"
            send_or_edit "$mid" "$(printf '%s Collecting support bundle...' "$E_TIME")" ""
            local sec; sec=$(get_active_section)
            local hostname; hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
            local p_ver; p_ver=$(opkg info podkop 2>/dev/null | grep '^Version:' | cut -d' ' -f2)
            [ -z "$p_ver" ] && p_ver=$(apk info podkop 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^podkop-//')
            local sb_ver; sb_ver=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
            {
                echo "=== Podkop Support Bundle ==="
                echo "Date: $(date)"
                echo "Host: ${hostname}"
                echo "Bot: v${BOT_VERSION}"
                echo "Podkop: ${p_ver:-unknown}"
                echo "Sing-box: ${sb_ver}"
                echo ""
                echo "=== Active Section ==="
                echo "$sec"
                echo ""
                echo "=== Podkop Status ==="
                /etc/init.d/podkop status 2>&1 || echo "status failed"
                echo ""
                echo "=== Sing-box Process ==="
                if pidof sing-box >/dev/null 2>&1; then
                    local sb_pid; sb_pid=$(pidof sing-box | awk '{print $1}')
                    echo "PID: $sb_pid"
                    awk '/VmRSS/{print "RAM: "int($2/1024)" MB"}' /proc/"$sb_pid"/status 2>/dev/null
                else
                    echo "NOT RUNNING"
                fi
                echo ""
                echo "=== UCI Config (podkop) ==="
                uci show podkop 2>&1
                echo ""
                echo "=== UCI Config (podkop_bot) ==="
                uci show podkop_bot 2>&1 | grep -v "bot_token\|chat_id\|admin_ids"
                echo ""
                echo "=== IP Routes ==="
                ip route show 2>&1 | head -30
                echo ""
                echo "=== IP Rules ==="
                ip rule show 2>&1 | head -20
                echo ""
                echo "=== NFT Rules (podkop) ==="
                nft list ruleset 2>/dev/null | grep -A5 -B1 -i podkop | head -60 || echo "nft not available"
                echo ""
                echo "=== Network Interfaces ==="
                ip -brief addr show 2>&1 | head -20
                echo ""
                echo "=== Public IP Cache ==="
                cat "$PUBIP_CACHE" 2>/dev/null || echo "not cached"
                echo ""
                echo "=== Bot Transport State ==="
                echo "LAST_ROUTE: $LAST_ROUTE"
                echo "LAST_ROUTE_FAST: $LAST_ROUTE_FAST"
                echo "LAST_ROUTE_POLL: $LAST_ROUTE_POLL"
                echo "LAST_ROUTE_NAME: $LAST_ROUTE_NAME"
                echo "RECOVERY_MODE: $RECOVERY_MODE"
                cat "$SOCKS_STATE_FILE" 2>/dev/null && echo "" || echo "(no socks state file)"
                echo ""
                echo "=== Recent Podkop Syslog (last 80 lines) ==="
                logread 2>/dev/null | grep -iE 'podkop|sing-box' | tail -80 || echo "logread failed"
            } > "$bf" 2>&1
            api_document "$bf" "Support Bundle [$(html_escape "$hostname")]"
            rm -f "$bf"
            delete_message "$mid"
            _handle_bot "cmd_diagnostics" "" "" ""
            ;;

        "ask_restart_router_1")
            # First confirmation — button press
            send_or_edit "$mid" \
                "$(printf '%s <b>Restart Router?</b>\n\nThis will reboot <b>%s</b>.\nAll connections will be interrupted for ~60 seconds.\n\n<b>Are you sure?</b>' "$E_WARN" "$(cat /proc/sys/kernel/hostname 2>/dev/null || echo Router)")" \
                "{\"inline_keyboard\":[
                    [{\"text\":\"${E_OK} Yes, continue\",\"callback_data\":\"ask_restart_router_2\"}],
                    [{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_info\"}]
                ]}"
            ;;

        "ask_restart_router_2")
            # Second confirmation — requires typing YES
            echo "wait_restart_router_confirm" > "$STATE_FILE"
            send_or_edit "$mid" \
                "$(printf '%s <b>Final confirmation required.</b>\n\nType <code>YES</code> (uppercase) to confirm router reboot.\nAny other input cancels.' "$E_WARN")" \
                "{\"inline_keyboard\":[
                    [{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_info\"}]
                ]}"
            ;;

        "ask_restart_bot")
            send_or_edit "$mid" \
                "$(printf '%s <b>Restart Bot?</b>\n\nKills all bot processes (main loop + watchdog subshells) and restarts via init.d.\nBot will send a startup notification when back online.' "$E_WARN")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Restart\",\"callback_data\":\"do_restart_bot\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_info\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            ;;

        "do_restart_bot")
            send_message "$(printf '%s <b>Restarting bot...</b>\nStartup notification will confirm when back online.' "$E_RST")" ""
            logger -t podkop-bot "[Restart] Manual restart requested via Telegram"
            kill "$HEALTH_PID" 2>/dev/null
            sleep 1
            _bot_basename=$(basename "$BOT_PATH")
            if [ -f "/etc/init.d/podkop_bot" ]; then
                /etc/init.d/podkop_bot restart
                killall -9 "$_bot_basename" 2>/dev/null || true
            else
                killall -9 "$_bot_basename" 2>/dev/null || true
                sleep 1
                exec "$BOT_PATH"
            fi
            exit 0
            ;;

        "cmd_info")
            local hostname lan_ip p_ver y_en sb_ver text kb
            hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
            lan_ip=$(uci -q get network.lan.ipaddr || echo "Unknown")
            p_ver=$(opkg info podkop 2>/dev/null | grep '^Version:' | cut -d' ' -f2)
            [ -z "$p_ver" ] && p_ver=$(apk info podkop 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^podkop-//')
            sb_ver=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
            y_en=$(uci -q get podkop.settings.enable_yacd || echo "0")
            text=$(cat <<EOF
${E_INFO} <b>System Information</b>

<b>Hostname:</b> ${hostname}
<b>LAN IP:</b> ${lan_ip}
<b>Podkop:</b> ${p_ver:-Unknown}
<b>Sing-box:</b> ${sb_ver:-Unknown}
<b>Bot:</b> v${BOT_VERSION}
<b>YACD:</b> $([ "$y_en" = "1" ] && echo "${E_ON} Enabled - http://${lan_ip}:9090/ui" || echo "${E_OFF} Disabled")
EOF
)
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_RST} Check Podkop Update\",\"callback_data\":\"cmd_check_update\"}],[{\"text\":\"${E_NEW} Check Bot Update\",\"callback_data\":\"cmd_check_update_bot\"}],[{\"text\":\"${E_RST} Restart Bot\",\"callback_data\":\"ask_restart_bot\"}],[{\"text\":\"${E_SKULL} Restart Router\",\"callback_data\":\"ask_restart_router_1\"}],[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "cmd_check_update")
            local p_ver latest text kb
            send_or_edit "$mid" "$(printf '%s Checking GitHub...' "$E_TIME")" ""
            p_ver=$(opkg info podkop 2>/dev/null | grep '^Version:' | cut -d' ' -f2 | cut -d'-' -f1)
            [ -z "$p_ver" ] && p_ver=$(apk info podkop 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^podkop-//' | cut -d'-' -f1)
            latest=$(curl -s --connect-timeout 5 --max-time 10 \
                "https://api.github.com/repos/itdoginfo/podkop/releases/latest" \
                | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
            if [ -z "$latest" ] || [ "$latest" = "null" ]; then
                send_or_edit "$mid" "$(printf '%s Cannot reach GitHub.' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_info\"}]]}"
                return
            fi
            if [ "$p_ver" != "$latest" ] && \
               [ "$(printf '%s\n' "$p_ver" "$latest" | sort -V | tail -n1)" = "$latest" ]; then
                text=$(cat <<EOF
${E_NEW} <b>Update Available!</b>

<b>Current:</b> ${p_ver}
<b>Latest:</b> ${latest}

<i>Runs install.sh from GitHub (no hash verification).</i>
EOF
)
                kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Install\",\"callback_data\":\"do_update_podkop\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_info\"}]]}"
                send_or_edit "$mid" "$text" "$kb"
            else
                send_or_edit "$mid" "$(printf '%s Up to date: %s' "$E_OK" "$p_ver")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_info\"}]]}"
            fi
            ;;

        "do_update_podkop")
            send_or_edit "$mid" "$(printf '%s Downloading update...' "$E_TIME")" ""
            wget -qO /tmp/podkop_update.sh "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
            if grep -q "^#!" /tmp/podkop_update.sh; then
                sh /tmp/podkop_update.sh >/tmp/podkop_update.log 2>&1 &
            else
                send_message "$(printf '%s Downloaded script is invalid.' "$E_ERR")" ""
            fi
            ;;

        # ------------------------------------------------------------------
        # Bot self-update: check version.txt on GitHub, download new script,
        # replace binary atomically, restart via init.d or exec.
        #
        # Safety sequence before replacing binary:
        #   1. Download to temp file and validate (must start with #!)
        #   2. mv (atomic on same filesystem) — no window with missing binary
        #   3. Kill watchdog subshell explicitly (HEALTH_PID)
        #   4. /etc/init.d/podkop_bot restart — procd respawns from new binary
        #      If no init.d: exec $BOT_PATH — replace current process in-place
        #
        # Note: the bot cannot reply AFTER exec — the restart confirmation
        # is sent BEFORE the binary is replaced (send_or_edit → then update).
        # ------------------------------------------------------------------
        "cmd_check_update_bot")
            local remote_ver text kb
            send_or_edit "$mid" "$(printf '%s Checking GitHub...' "$E_TIME")" ""
            remote_ver=$(curl -s --connect-timeout 5 --max-time 8 \
                "https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/version.txt" \
                2>/dev/null | tr -d '\n\r\t ')
            if [ -z "$remote_ver" ] || [ "$remote_ver" = "null" ]; then
                kb="{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_info\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
                send_or_edit "$mid" "$(printf '%s Cannot reach GitHub. Check connectivity.' "$E_ERR")" "$kb"
                return
            fi
            if [ "$remote_ver" = "$BOT_VERSION" ]; then
                kb="{\"inline_keyboard\":[[{\"text\":\"${E_RST} Force Update\",\"callback_data\":\"ask_update_bot_${remote_ver}\"}],[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_info\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
                send_or_edit "$mid" "$(printf '%s Bot is up to date: <b>v%s</b>' "$E_OK" "$BOT_VERSION")" "$kb"
            else
                text=$(printf '%s <b>Bot Update Available!</b>\n\n<b>Installed:</b> v%s\n<b>Available:</b> v%s\n\n<i>The bot will restart automatically after update.\nYou will receive a startup notification when it is back online.</i>' \
                    "$E_NEW" "$BOT_VERSION" "$remote_ver")
                kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Update to v${remote_ver}\",\"callback_data\":\"ask_update_bot_${remote_ver}\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_info\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
                send_or_edit "$mid" "$text" "$kb"
            fi
            ;;

        "ask_update_bot_"*)
            local target_ver="${cmd#ask_update_bot_}" text kb
            text=$(printf '%s <b>Update bot to v%s?</b>\n\nThe bot will download the new version and restart.\nAll active menus will be interrupted.\n\nSection: <code>%s</code>' \
                "$E_WARN" "$target_ver" "$(get_active_section)")
            kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Update & Restart\",\"callback_data\":\"do_update_bot_${target_ver}\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"cmd_info\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        "do_update_bot_"*)
            local target_ver="${cmd#do_update_bot_}"
            local bot_tmp="/tmp/podkop_bot_update.$$"
            local bot_url="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot.sh"
            local kb_err="{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Back\",\"callback_data\":\"cmd_info\"},{\"text\":\"Menu\",\"callback_data\":\"/menu\"}]]}"

            send_or_edit "$mid" "$(printf '%s <b>Downloading bot v%s...</b>' "$E_TIME" "$target_ver")" ""

            if ! curl -s --connect-timeout 5 --max-time 15 -o "$bot_tmp" "$bot_url" 2>/dev/null; then
                rm -f "$bot_tmp"
                send_message "$(printf '%s Download failed. Check connectivity.' "$E_ERR")" "$kb_err"
                return
            fi

            if ! head -1 "$bot_tmp" | grep -q '^#!' || ! grep -q '^BOT_VERSION=' "$bot_tmp"; then
                rm -f "$bot_tmp"
                send_message "$(printf '%s Downloaded file is invalid (not a bot script).' "$E_ERR")" "$kb_err"
                return
            fi

            local new_ver
            new_ver=$(grep '^BOT_VERSION=' "$bot_tmp" | cut -d'"' -f2)
            chmod +x "$bot_tmp"

            send_message \
                "$(printf '%s <b>Bot updating to v%s</b>\nRestarting now — startup notification will confirm when back online.' \
                    "$E_RST" "${new_ver:-$target_ver}")" ""

            mv "$bot_tmp" "$BOT_PATH"
            logger -t podkop-bot "[Self-update] Updated to v${new_ver}. Restarting..."

            # Kill watchdog by saved PID first (clean)
            kill "$HEALTH_PID" 2>/dev/null
            sleep 1
            # Kill any surviving subshells (probe_all_socks_write, check_health forks)
            _bot_basename=$(basename "$BOT_PATH")

            if [ -f "/etc/init.d/podkop_bot" ]; then
                # procd path: tell procd to restart BEFORE killall.
                # init.d restart communicates with procd via ubus synchronously —
                # procd queues the restart independently of this process.
                # Only after ubus call completes do we killall zombies + exit.
                /etc/init.d/podkop_bot restart
                killall -9 "$_bot_basename" 2>/dev/null || true
            else
                # No init.d: kill zombies first, then exec (replaces this process)
                killall -9 "$_bot_basename" 2>/dev/null || true
                sleep 1
                exec "$BOT_PATH"
            fi
            exit 0
            ;;

        "ask_cmd_stop")
            send_or_edit "$mid" "$(printf '%s <b>Stop Podkop?</b>\n\nTunnel will go DOWN. All traffic routing will stop.' "$E_WARN")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Stop\",\"callback_data\":\"do_cmd_stop\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"/menu\"}]]}"
            ;;

        "do_cmd_stop")
            if do_podkop_stop; then
                send_or_edit "$mid" "$(printf '%s <b>Podkop Stopped</b>' "$E_STP")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}"
            else
                send_or_edit "$mid" "$(printf '%s <b>Stop Failed!</b>\nCheck: <code>ps w | grep sing-box</code>' "$E_ERR")" \
                    "{\"inline_keyboard\":[[{\"text\":\"${E_LOG} Logs\",\"callback_data\":\"cmd_get_log\"},{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}"
            fi
            ;;
        "cmd_start")
            /etc/init.d/podkop start
            send_or_edit "$mid" "$(printf '%s <b>Podkop Starting...</b>' "$E_ON")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}"
            ;;
        "ask_reload_podkop")
            send_or_edit "$mid" "$(printf '%s Reload Podkop?' "$E_WARN")" \
                "{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes, Reload\",\"callback_data\":\"do_reload_podkop\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"/menu\"}]]}"
            ;;
        "do_reload_podkop")
            local rc
            send_or_edit "$mid" "$(printf '%s Reloading...' "$E_RST")" ""
            safe_reload_podkop; rc=$?
            case "$rc" in
                0) sleep 1; send_or_edit "$mid" "$(printf '%s Reloaded!' "$E_OK")" \
                       "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}" ;;
                1) send_or_edit "$mid" "$(printf '%s Cooldown active (10s).' "$E_WARN")" \
                       "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}" ;;
                *) send_or_edit "$mid" "$(printf '%s Reload failed!' "$E_ERR")" \
                       "{\"inline_keyboard\":[[{\"text\":\"${E_LOG} Logs\",\"callback_data\":\"cmd_get_log\"},{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}" ;;
            esac
            ;;
    esac
}

# ==============================================================================
# SECTION 10: Main Command Router
# Routes callbacks and text messages to the appropriate sub-handler.
# STATE_FILE intercepts text input for multi-step flows.
# ==============================================================================
handle_command() {
    local cmd="$1" mid="$2" cb_id="$3"

    # State machine: intercept plain text (not callbacks) for multi-step input
    if [ -f "$STATE_FILE" ] && [ -z "$cb_id" ]; then
        local state; state=$(head -n 1 "$STATE_FILE")
        if echo "$cmd" | grep -qE '^/(start|menu)'; then
            rm -f "$STATE_FILE"; _handle_bot "main_menu" "$mid" "" ""; return
        fi
        case "$state" in
            wait_proxy_link)
                _handle_proxy "STATE_INPUT" "$mid" "$cmd" "$state" ;;
            wait_url_link)
                _handle_url_links "STATE_INPUT" "$mid" "$cmd" "$state" ;;
            wait_fully_routed_ip|wait_excl_ip|wait_remote_domain|wait_remote_subnet|\
            wait_user_domain_add|wait_user_domain_del|wait_user_subnet_add|wait_user_subnet_del)
                _handle_lists "STATE_INPUT" "$mid" "$cmd" "$state" ;;
            wait_dns_server|wait_bootstrap_dns)
                _handle_dns "STATE_INPUT" "$mid" "$cmd" "$state" ;;
            wait_custom_proxy|wait_bind_iface|wait_restart_router_confirm)
                _handle_bot "STATE_INPUT" "$mid" "$cmd" "$state" ;;
            wait_fb_socks_add)
                _handle_fallback_socks "STATE_INPUT" "$mid" "$cmd" "$state" ;;
            wait_urltest_url|wait_urltest_interval|wait_urltest_tolerance|\
            wait_dr_server|wait_badwan_ifaces|wait_badwan_delay|\
            wait_mixed_port|wait_outbound_iface|wait_utl_link)
                _handle_section_extras "STATE_INPUT" "$mid" "$cmd" "$state" ;;
        esac
        return
    fi

    case "$cmd" in
        "doc_to_runtime") delete_message "$mid"; _handle_bot "cmd_runtime" "" "" "" ;;
        "delete_msg")     delete_message "$mid" ;;

        proxy_menu|proxy_menu_p_*|px_view_*|do_px_*|do_del_px_*|test_px_*|\
        cmd_proxy_add|ask_del_px_*|do_del_px_confirmed_*|cmd_all_delay_test)
            _handle_proxy "$cmd" "$mid" "" "" ;;

        url_links_menu|url_links_p_*|\
        cmd_url_link_add|ask_del_ul_*|do_del_ul_*|\
        outbound_info)
            _handle_url_links "$cmd" "$mid" "" "" ;;

        sections_menu|set_sec_*)
            _handle_sections "$cmd" "$mid" ;;

        main_settings_menu|advanced_settings|\
        ask_toggle_dl|ask_toggle_quic|ask_toggle_wan|ask_toggle_ntp|ask_toggle_mixed|\
        do_toggle_dl|do_toggle_quic|do_toggle_wan|do_toggle_ntp|do_toggle_mixed|\
        proxy_mode_menu|ask_switch_mode_*|do_switch_mode_*|set_log_*|set_update_int_*|conn_type_menu|do_set_conn_*|ask_toggle_autostart_off|ask_toggle_autostart_on|do_autostart_off|do_autostart_on)
            _handle_settings "$cmd" "$mid" "" "" ;;

        urltest_settings|cmd_set_ut_url|cmd_set_ut_interval|cmd_set_ut_tolerance|\
        urltest_links_menu|urltest_links_p_*|cmd_utl_add|ask_del_utl_*|do_del_utl_*|\
        cmd_clone_sel_to_utl|\
        cmd_set_mixed_port|cmd_set_outbound_iface|\
        domain_resolver_settings|do_toggle_dr|set_dr_type_*|cmd_set_dr_server|\
        badwan_details|cmd_set_bw_ifaces|cmd_set_bw_delay)
            _handle_section_extras "$cmd" "$mid" "" "" ;;

        dns_settings|dns_proto_menu|do_dns_pr_*|cmd_dns_server|cmd_boot_dns|\
        yacd_settings|yacd_secret_menu|\
        ask_toggle_yacd|ask_toggle_yacd_wan|do_toggle_yacd|do_toggle_yacd_wan|\
        ask_yacd_*|do_yacd_*)
            _handle_dns "$cmd" "$mid" "" "" ;;

        community_lists|community_lists_edit|toggle_cl_*|\
        r_dom_edit|r_sub_edit|del_rdom_*|del_rsub_*|\
        fr_ips_edit|del_frip_*|\
        excl_ips_edit|del_excl_*|\
        cmd_add_fr_ip|cmd_add_excl_ip|cmd_add_r_dom|cmd_add_r_sub|\
        user_domains_menu|user_domains_menu_p_*|\
        user_subnets_menu|user_subnets_menu_p_*|\
        cmd_user_add_*|cmd_user_del_*|cmd_user_download_*)
            _handle_lists "$cmd" "$mid" "" "" ;;

        do_cmd_stop|cmd_start|ask_cmd_stop|ask_reload_podkop|do_reload_podkop|\
        cmd_tunnel_health|cmd_support_bundle|\
        cmd_diagnostics|ask_upstream_health|ask_run_podkop_tests|ask_run_internal_diag|ask_support_bundle|\
        cmd_check_update_bot|ask_update_bot_*|do_update_bot_*|\
        ask_restart_bot|do_restart_bot|\
        ask_restart_router_1|ask_restart_router_2)
            _handle_bot "$cmd" "$mid" "" "" ;;

        ask_set_tr_menu|ask_set_tr_*|do_set_tr_*)
            _handle_bot "$cmd" "$mid" "" "" ;;

        fallback_socks_menu|cmd_fb_socks_add|cmd_test_fb_socks|ask_del_fb_*|do_del_fb_*)
            _handle_fallback_socks "$cmd" "$mid" "" "" ;;

        ask_*)
            local action="${cmd#ask_}"
            local action_safe; action_safe=$(html_escape "$action")
            local text; text=$(printf '%s <b>Confirm Action</b>\n\n<code>%s</code>?' "$E_WARN" "$action_safe")
            local kb="{\"inline_keyboard\":[[{\"text\":\"${E_OK} Yes\",\"callback_data\":\"do_${action}\"}],[{\"text\":\"${E_BACK} Cancel\",\"callback_data\":\"/menu\"}]]}"
            send_or_edit "$mid" "$text" "$kb"
            ;;

        *) _handle_bot "$cmd" "$mid" "" "" ;;
    esac
}

# ==============================================================================
# SECTION 11: Startup & Main Event Loop
# ==============================================================================

# ── Singleton guard ────────────────────────────────────────────────────────────
# Kill any orphaned watchdog processes from a previous instance that survived
# SIGKILL (procd can leave subshells running). The watchdog itself does not
# hold the lock so it won't be blocked — only the main loop holds it.
BOT_LOCK_FILE="/tmp/podkop_bot.lock"
BOT_PID_FILE="/tmp/podkop_bot.pid"
if [ -f "$BOT_PID_FILE" ]; then
    _old_pid=$(cat "$BOT_PID_FILE" 2>/dev/null)
    if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
        logger -t podkop-bot "[Startup] Stopping previous instance (PID: ${_old_pid})"
        kill "$_old_pid" 2>/dev/null; sleep 1
        kill -9 "$_old_pid" 2>/dev/null
    fi
fi
printf '%s' "$$" > "$BOT_PID_FILE"
# Also kill any leftover watchdog subshells by BOT_PATH pattern
kill $(pgrep -f "$BOT_PATH" 2>/dev/null | grep -v "^$$\$" | grep -v "^$(cat $BOT_PID_FILE 2>/dev/null)\$") 2>/dev/null || true

# Clean up orphaned temp files from a previous run that was killed mid-cycle
# (SIGKILL bypasses trap — these files are never rm'd by the dying process).
# Only remove files older than 60s to avoid racing with a concurrent startup.
find /tmp -maxdepth 1 -name 'podkop_req.*' -o -name 'podkop_updates.*' \
    -o -name 'podkop_clash.*' -o -name 'podkop_ip[123].*' \
    -o -name 'podkop_pubip.*' -o -name 'podkop_socks_probe.*' \
    2>/dev/null | while IFS= read -r _stale; do
    # mtime check: skip files touched in the last 60s
    _st_mtime=$(stat -c %Y "$_stale" 2>/dev/null || echo 0)
    _st_now=$(date +%s)
    [ $((_st_now - _st_mtime)) -gt 60 ] && rm -f "$_stale"
done

logger -t podkop-bot "=== Podkop Bot v${BOT_VERSION} Starting ==="
# Pre-initialize route key file so watchdog nudge logic works from first cycle.
# Without this, MAIN_ROUTE_KEY_FILE is empty until first api_request_fast succeeds,
# and watchdog sees "unknown" → sends nudge → IPC up resets FAST/POLL → bot does
# full discovery but may land on tier4 (Direct) before tier1 is confirmed reachable.
# Setting "unknown" explicitly ensures nudge fires and triggers SOCKS-first rediscovery.
printf 'unknown' > "$MAIN_ROUTE_KEY_FILE"
printf 'Initializing...' > "$MAIN_ROUTE_FILE"

# Startup notification runs in background subprocess to not block the main loop
send_startup_notification_async() {
    local i=1 hostname p_ver active_proxy startup_txt tg_lat sec

    build_all_caches
    refresh_public_ip_cache &  # Pre-warm public IP cache on startup

    while [ "$i" -le 12 ]; do
        if api_request_fast "getMe" "{}" "5" >/dev/null; then
            load_bot_identity >/dev/null 2>&1
            # Write initial route so watchdog subshell can read it immediately
            _write_main_route "$LAST_ROUTE_FAST" "$LAST_ROUTE_NAME"
            if [ "$(uci -q get podkop_bot.settings.startup_notify || echo "1")" = "1" ]; then
                logger -t podkop-bot "Connected via: ${LAST_ROUTE_NAME} (fast=${LAST_ROUTE_FAST})"
                hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "Router")
                p_ver=$(opkg info podkop 2>/dev/null | grep '^Version:' | cut -d' ' -f2)
            [ -z "$p_ver" ] && p_ver=$(apk info podkop 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^podkop-//')
                active_proxy=$(display_proxy_name_with_tag "$(get_active_proxy_name "")")
                tg_lat=$(get_tg_latency)
                sec=$(get_active_section)
                startup_txt=$(cat <<EOF
${E_BOT} <b>Bot Online</b> v${BOT_VERSION}
<code>────────────────────</code>
<b>Host:</b> ${hostname}
<b>Podkop:</b> ${p_ver:-Unknown}
<b>Active Route:</b> <code>${active_proxy}</code>
<b>Bot Path:</b> ${LAST_ROUTE_NAME} (${E_TIME} ${tg_lat})
<b>Section:</b> <code>${sec}</code>
EOF
)
                reset_chat_context
                send_message "$startup_txt" "{\"inline_keyboard\":[[{\"text\":\"${E_BACK} Menu\",\"callback_data\":\"/menu\"}]]}"
            fi
            break
        fi
        i=$((i + 1)); sleep 10
    done
    exit 0
}

send_startup_notification_async &
start_health_daemon

trap 'kill "$HEALTH_PID" 2>/dev/null; rm -f "$STATE_FILE" "$HEALTH_STATE_FILE" "$SOCKS_STATE_FILE" "$SOCKS_PROBE_FILE" "$SOCKS_REPROBE_TS_FILE" "$ROUTE_CMD_FILE" "$LAST_MENU_MSG_FILE" "$LAST_ALERT_MSG_FILE" "$BOT_USERNAME_FILE" "$BOT_ID_FILE" "$TAG_NAME_CACHE" "$MAIN_ROUTE_FILE" "$MAIN_ROUTE_KEY_FILE" "$BOT_PID_FILE" "/tmp/podkop_bot_last_nudge"; rm -f /tmp/podkop_updates.* /tmp/podkop_req.* /tmp/podkop_clash.* /tmp/podkop_ip[123].* /tmp/podkop_pubip.* /tmp/podkop_bot_update.* 2>/dev/null; rm -rf "$PUBIP_REFRESH_LOCK"; exit' INT TERM QUIT

offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")

# Main long-poll loop. api_poll_long writes result to API_RESPONSE global
# (avoids subshell variable amnesia from response=$(api_poll ...) pattern).
# Uses separate LAST_ROUTE_POLL — does not share state with api_request_fast.
while true; do
    UPDATES_FILE="/tmp/podkop_updates.$$"

    api_poll_long "$offset" "50"
    response="$API_RESPONSE"
    [ -z "$response" ] && sleep 2 && continue

    printf '%s' "$response" > "$UPDATES_FILE"
    items_count=$(jq -r '.result | length' "$UPDATES_FILE" 2>/dev/null)
    if [ -z "$items_count" ] || [ "$items_count" = "null" ] || [ "$items_count" -eq 0 ]; then
        rm -f "$UPDATES_FILE"; continue
    fi

    i=0
    while [ "$i" -lt "$items_count" ]; do
        update=$(jq -c ".result[$i]" "$UPDATES_FILE" 2>/dev/null)
        i=$((i + 1))
        [ -z "$update" ] && continue

        id=$(printf '%s' "$update" | jq -r '.update_id' 2>/dev/null)
        [ -z "$id" ] && continue
        offset=$((id + 1)); echo "$offset" > "$OFFSET_FILE"

        # Single jq call — fields joined with U+001F (Unit Separator, not shell whitespace).
        # @tsv used \t which is whitespace for read, causing field shift when callback_id empty.
        # Fields: chat_id, chat_type, raw_text, callback_id, u_name, user_id,
        #         is_bot_sender, sender_chat_id, sender_chat_type, sender_chat_title,
        #         CALLBACK_MSG_ID, message_thread_id
        _upd_flat=$(printf '%s' "$update" | jq -r '
            [
                (.message.chat.id // .callback_query.message.chat.id // ""),
                (.message.chat.type // .callback_query.message.chat.type // ""),
                (.message.text // .callback_query.data // ""),
                (.callback_query.id // ""),
                (.message.from.username // .callback_query.from.username // ""),
                (.message.from.id // .callback_query.from.id // ""),
                ((.message.from.is_bot // .callback_query.from.is_bot // false) | tostring),
                (.message.sender_chat.id // .callback_query.message.sender_chat.id // ""),
                (.message.sender_chat.type // .callback_query.message.sender_chat.type // ""),
                (.message.sender_chat.title // .callback_query.message.sender_chat.title // ""),
                (.message.message_id // .callback_query.message.message_id // ""),
                (.message.message_thread_id // .callback_query.message.message_thread_id // "")
            ] | join("\u001f")
        ' 2>/dev/null)
        IFS=$(printf '\037') read -r chat_id chat_type _raw_text callback_id u_name user_id \
            is_bot_sender sender_chat_id sender_chat_type sender_chat_title \
            CALLBACK_MSG_ID message_thread_id <<EOF
$_upd_flat
EOF
        text=$(printf '%s' "$_raw_text")
        [ "$message_thread_id" = "null" ] && message_thread_id=""

        [ -z "$BOT_USERNAME" ] && load_bot_identity >/dev/null 2>&1
        [ -z "$BOT_ID" ]       && load_bot_identity >/dev/null 2>&1

        # Authorization check
        if ! is_allowed_actor "$user_id" "$sender_chat_id" "$is_bot_sender" "$ALLOW_ANON_ADMINS"; then
            if [ "$is_bot_sender" != "true" ] && [ -n "$user_id" ] && [ "$user_id" != "null" ]; then
                now=$(date +%s); count=1
                [ -f "$UNAUTH_FILE" ] && count=$(( $(cut -d'|' -f1 "$UNAUTH_FILE") + 1 ))
                echo "${count}|${now}|${u_name:-Unknown}|${user_id}" > "$UNAUTH_FILE"
                logger -t podkop-bot "[Security] Unauthorized: user=@${u_name:-Unknown} id=${user_id} text=${text}"
                safe_u_name=$(html_escape "${u_name:-Unknown}")
                safe_chat_title=$(html_escape "${sender_chat_title:-none}")
                safe_alert_text=$(html_escape "$text")
                alert_txt=$(cat <<EOF
${E_WARN} <b>Unauthorized Access!</b>
<b>User:</b> @${safe_u_name} (ID: <code>${user_id}</code>)
<b>Chat:</b> ${chat_type} | <b>Title:</b> ${safe_chat_title}
<b>Text:</b> <code>${safe_alert_text}</code>
EOF
)
                alert_payload=$(jq -n -c --arg cid "$ADMIN_ID" --arg txt "$alert_txt" \
                    '{chat_id:$cid,text:$txt,parse_mode:"HTML"}')
                api_request "sendMessage" "$alert_payload" >/dev/null
            fi
            continue
        fi

        [ "$chat_type" = "channel" ] && continue

        if is_private_chat "$chat_type"; then
            :
        elif is_group_chat "$chat_type"; then
            if [ -n "$callback_id" ]; then
                :
            else
                text=$(normalize_group_command "$text" "$BOT_USERNAME")
                if text_mentions_bot "$text" "$BOT_USERNAME"; then
                    text=$(strip_bot_mention "$text" "$BOT_USERNAME")
                    text=$(printf '%s' "$text" | sed 's/^ *//; s/ *$//')
                elif is_reply_to_bot "$update" "$BOT_ID"; then
                    :
                else
                    continue
                fi
                [ -z "$text" ] && continue
            fi
        else
            continue
        fi

        if [ -n "$text" ] && [ "$text" != "null" ]; then
            now=$(date +%s)
            safe_text=$(echo "$text" | tr '\n' ' ' | tr '|' '_')
            echo "${now}|${u_name:-Unknown}|${safe_text}" > "$LAST_CMD_FILE"

            set_chat_context "$chat_id" "$CALLBACK_MSG_ID" "$chat_type" "$message_thread_id"

            audit_str="user=@${u_name:-Unknown} id=${user_id:-none}"
            [ -n "$sender_chat_id" ] && [ "$sender_chat_id" != "null" ] && \
                audit_str="${audit_str} sender_chat=${sender_chat_id}(${sender_chat_type:-none})"
            logger -t podkop-bot "Audit: ${audit_str} -> ${text}"

            if [ -n "$callback_id" ]; then
                CB_ANSWER_TEXT=""
                handle_command "$text" "$CALLBACK_MSG_ID" "$callback_id"
                answer_callback "$callback_id" "$CB_ANSWER_TEXT"
                CB_ANSWER_TEXT=""
            else
                # Plain text: pass empty mid so send_or_edit always sends new message
                # (cannot editMessageText on user's own message, only on bot messages)
                handle_command "$text" "" ""
            fi

            reset_chat_context
        fi
    done

    rm -f "$UPDATES_FILE"
done
