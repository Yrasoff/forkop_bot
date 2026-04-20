#!/bin/ash

# Installer for podkop_bot — Telegram remote management bot for podkop/sing-box on OpenWrt
# Supports: OpenWrt 23.05 / 24.10 (opkg) and OpenWrt 25.x+ (apk)
# Based on installer pattern from https://github.com/VizzleTF/podkop_autoupdater
#
# CORRECT install command:
#   wget -O /tmp/install_podkop_bot.sh \
#     https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh
#   ash /tmp/install_podkop_bot.sh
#
# INSTALLER_VERSION="1.7.0"
#
# CHANGELOG v1.7.0:
# - NEW:  Option 4 — full uninstall with double confirmation (type "YES" then
#         "REMOVE"). Removes: bot binary, init.d script, /etc/config/podkop_bot
#         (token, chat_id, all settings), all /tmp runtime files.
#         podkop and sing-box are NOT touched. Useful for clean reinstall or
#         permanent removal.
#
# CHANGELOG v1.6.0:
# - FIXED: download_file() now uses --connect-timeout 10 --max-time 30 on curl
#          and -T 15 on wget. BusyBox wget hangs indefinitely without -T when
#          DNS or network is slow/broken (hit in practice on flaky WAN).
# - FIXED: cleanup_bot_runtime_files() list now includes /tmp/podkop_bot_active_section,
#          /tmp/podkop_cl_cache* and /tmp/podkop_pubip_cache.txt — all files the
#          bot creates on first run that carry section/cache state between versions.
# - FIXED: validate_socks_url() now rejects port > 65535 (was only checking
#          digit count, not value). Added awk numeric range check.
# - IMPROVED: pkg_update() failure is now a warning, not a hard die() — on some
#             routers with stale feeds the update fails but the package is already
#             installed. Installer continues with a warning instead of aborting.
#
# CHANGELOG v1.5.0:
# - NEW:  safe_stop_bot now calls cleanup_bot_runtime_files() (Step 5) which
#         removes all /tmp/podkop_bot_* IPC/state files before deploying new binary.
#         Prevents stale route keys, nudge timestamps, socks state from old versions
#         polluting the new bot startup (root cause of 'tir4' mystery).
#
# CHANGELOG v1.4.0:
# - FIXED: vv0.7.14-r1 → v0.7.14-r1: opkg returns version with leading 'v',
#          installer was adding another via "v${PODKOP_VER}". Added sed strip.
# - FIXED: Update flow now shows full summary (version, path, useful commands)
#          instead of bare "Done." + exit 0 before summary block.
#
# CHANGELOG v1.3.0:
# - NEW:  safe_stop_bot(): kill by PID file + killall -9 before binary replacement.
#         Prevents zombie watchdog subshells surviving update.
# - NEW:  podkop presence check with version display before install.
# - NEW:  admin_ids configured via uci add_list (fixes space-separated breakage).
# - NEW:  Fallback SOCKS configuration in interactive setup.
#
# CHANGELOG v1.2.0:
# - NEW:  Detect accidental HTML download (wrong GitHub blob URL) and show correct
#         raw.githubusercontent.com URL with clear error message.
# - NEW:  apk package manager support for OpenWrt 25.x+.
#
# CHANGELOG v1.1.0:
# - NEW:  Update flow: detect existing install, show token/version, offer
#         update-keep-config / reinstall / exit options.
# - NEW:  init.d script download and installation.
# - NEW:  Verbose progress output throughout.

# ── Self-check: detect accidental HTML download (wrong GitHub URL) ─────────────
# Correct:  https://raw.githubusercontent.com/...
# Wrong:    https://github.com/.../blob/main/...  -- downloads HTML page
_first_line=$(head -1 "$0" 2>/dev/null)
case "$_first_line" in
    '<!DOCTYPE'*|'<html'*)
        echo ""
        echo "ERROR: Downloaded HTML page instead of shell script."
        echo "Use the raw URL:"
        echo ""
        echo "  wget -O /tmp/install_podkop_bot.sh \\"
        echo "    https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/install.sh"
        echo "  ash /tmp/install_podkop_bot.sh"
        echo ""
        exit 1
        ;;
esac
unset _first_line

# ── Constants ──────────────────────────────────────────────────────────────────
BOT_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot.sh"
VERSION_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/version.txt"
BOT_PATH="/usr/bin/podkop_bot"
INIT_PATH="/etc/init.d/podkop_bot"
INIT_URL="https://raw.githubusercontent.com/Medvedolog/podkop_bot/main/podkop_bot_init"
UCI_PKG="podkop_bot"
UCI_SEC="settings"
OS_RELEASE_FILE="/etc/os-release"
TOKEN_DISPLAY_LENGTH=10

# ── Helpers ────────────────────────────────────────────────────────────────────
die()     { echo ""; echo "ERROR: $1"; exit 1; }
info()    { echo "  $1"; }
ok()      { echo "[OK] $1"; }
warn()    { echo "[!!] $1"; }
step()    { echo ""; echo ">>> $1"; }
section() { echo ""; echo "-------------------------------------------"; echo "  $1"; echo "-------------------------------------------"; echo ""; }

download_file() {
    local url="$1" dest="$2"
    # BusyBox wget hangs indefinitely without -T on slow/broken WAN.
    # curl fallback mirrors the same budget: 10s connect, 30s total.
    wget -q -T 15 -O "$dest" "$url" 2>/dev/null \
        || curl -s --connect-timeout 10 --max-time 30 -o "$dest" "$url" 2>/dev/null \
        || die "Failed to download $url — check internet connection."
}

uci_get() { uci -q get "${UCI_PKG}.${UCI_SEC}.${1}" 2>/dev/null; }

# ── Safe bot stop: kills main process AND orphaned watchdog subshells ──────────
# procd sends SIGTERM→SIGKILL to the main loop but watchdog subshells can
# survive as zombies and keep sending duplicate alerts / holding state files.
# Strategy:
#   1. init.d stop  — clean procd shutdown (SIGTERM→SIGKILL on main loop)
#   2. kill by PID file — target the specific main PID written at startup
#   3. killall -9  — catch any remaining processes matching the script name
#   4. Short sleep — let the OS reap zombie entries
safe_stop_bot() {
    local _pid_file="/tmp/podkop_bot.pid"
    local _stopped=0

    # Step 1: procd-managed stop
    if [ -f "$INIT_PATH" ]; then
        printf "  Stopping via init.d... "
        "$INIT_PATH" stop >/dev/null 2>&1
        sleep 1
        echo "done"
        _stopped=1
    fi

    # Step 2: kill by PID file (main loop PID written by bot at startup)
    if [ -f "$_pid_file" ]; then
        _main_pid=$(cat "$_pid_file" 2>/dev/null)
        if [ -n "$_main_pid" ] && kill -0 "$_main_pid" 2>/dev/null; then
            printf "  Killing main PID %s... " "$_main_pid"
            kill "$_main_pid" 2>/dev/null
            sleep 1
            kill -9 "$_main_pid" 2>/dev/null
            echo "done"
        fi
        rm -f "$_pid_file"
    fi

    # Step 3: killall -9 by script name — catches watchdog subshells, any
    #         leftover ash processes running podkop_bot that survived above.
    #         We match on the basename to avoid killing this installer itself.
    _bot_basename=$(basename "$BOT_PATH")
    if killall -0 "$_bot_basename" 2>/dev/null; then
        printf "  Killing remaining '%s' processes... " "$_bot_basename"
        killall -9 "$_bot_basename" 2>/dev/null
        sleep 1
        echo "done"
    fi

    # Step 4: reap zombies via wait (only works for children, best-effort)
    wait 2>/dev/null || true

    # Step 5: clean up all runtime/IPC files from /tmp to prevent stale state
    # from affecting the new version (wrong route keys, stale nudge timestamps, etc.)
    cleanup_bot_runtime_files
}

cleanup_bot_runtime_files() {
    local _files="
        /tmp/podkop_bot_state
        /tmp/podkop_bot_health_state
        /tmp/podkop_bot_socks_state
        /tmp/podkop_bot_socks_probe
        /tmp/podkop_bot_socks_reprobe_ts
        /tmp/podkop_bot_route_cmd
        /tmp/podkop_bot_last_menu_msg
        /tmp/podkop_bot_last_alert_msg
        /tmp/podkop_bot_username
        /tmp/podkop_bot_id
        /tmp/podkop_bot_tag_name_cache
        /tmp/podkop_bot_main_route
        /tmp/podkop_bot_main_route_key
        /tmp/podkop_bot.pid
        /tmp/podkop_bot_last_nudge
        /tmp/podkop_bot_unauth
        /tmp/podkop_bot_last_cmd
        /tmp/podkop_bot_offset
        /tmp/podkop_bot_active_section
        /tmp/podkop_bot_last_reload_ts
        /tmp/podkop_pubip_cache.txt
    "
    local _removed=0
    for _f in $_files; do
        if [ -f "$_f" ]; then
            rm -f "$_f"
            _removed=$((_removed + 1))
        fi
    done
    # Community list cache (TTL-based, must be invalidated on update)
    rm -f /tmp/podkop_cl_cache.txt /tmp/podkop_cl_cache_ts 2>/dev/null || true
    # Tag/URI caches (section-specific, may be stale after version change)
    rm -f /tmp/podkop_tag_uri_cache.txt /tmp/podkop_uci_links_cache.txt 2>/dev/null || true
    # Remove any leftover temp request files
    rm -f /tmp/podkop_req.* /tmp/podkop_bot_update.* /tmp/podkop_updates.* 2>/dev/null || true
    # Remove pubip refresh lock if somehow stuck
    rm -rf /tmp/podkop_pubip_refresh.lockdir 2>/dev/null || true
    [ "$_removed" -gt 0 ] && info "Cleaned up ${_removed} runtime files from /tmp."
}

# Validate socks5[h]://host:port — format + port must be 1-65535
validate_socks_url() {
    local _url="$1"
    # Basic format check first
    echo "$_url" | grep -qE '^socks5h?://[^:]+:[0-9]{1,5}$' || return 1
    # Extract port and validate numeric range
    local _port; _port=$(echo "$_url" | sed 's|.*:||')
    awk -v p="$_port" 'BEGIN { exit (p >= 1 && p <= 65535) ? 0 : 1 }'
}

# ── Check OS ───────────────────────────────────────────────────────────────────
if ! grep -qE "OpenWrt|immortalwrt|ImmortalWrt" "$OS_RELEASE_FILE" 2>/dev/null; then
    die "This script is designed for OpenWrt / ImmortalWrt only."
fi

echo ""
echo "==========================================="
echo "  podkop_bot installer"
echo "==========================================="

# ── Detect package manager (opkg vs apk) ──────────────────────────────────────
# OpenWrt 23.05 / 24.10  → opkg
# OpenWrt 25.x+          → apk (Alpine Package Keeper)
PKG_MANAGER=""
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    _ver=$(grep "^VERSION_ID=" "$OS_RELEASE_FILE" 2>/dev/null | cut -d'"' -f2)
    _major=$(echo "$_ver" | cut -d'.' -f1)
    if echo "$_major" | grep -qE '^[0-9]+$' && [ "$_major" -ge 25 ] 2>/dev/null; then
        PKG_MANAGER="apk"
    else
        PKG_MANAGER="opkg"
    fi
    unset _ver _major
fi

OWRT_VERSION=$(grep '^VERSION_ID=' "$OS_RELEASE_FILE" 2>/dev/null | cut -d'"' -f2)
echo ""
info "OpenWrt version : ${OWRT_VERSION:-unknown}"
info "Package manager : ${PKG_MANAGER}"
info "Hostname        : $(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"

# ── Check podkop is installed ──────────────────────────────────────────────────
step "Checking podkop..."
PODKOP_OK=0
if [ -f "/usr/bin/podkop" ] || [ -f "/usr/sbin/podkop" ]; then
    PODKOP_OK=1
fi
# Also check via package manager
if [ "$PODKOP_OK" = "0" ]; then
    case "$PKG_MANAGER" in
        apk)  apk info podkop >/dev/null 2>&1 && PODKOP_OK=1 ;;
        opkg) opkg list-installed 2>/dev/null | grep -q "^podkop " && PODKOP_OK=1 ;;
    esac
fi
# Check UCI config exists
if [ "$PODKOP_OK" = "0" ] && uci -q get podkop.settings >/dev/null 2>&1; then
    PODKOP_OK=1
fi

if [ "$PODKOP_OK" = "0" ]; then
    warn "podkop does not appear to be installed on this system."
    warn "podkop_bot requires podkop to function."
    echo ""
    echo "  Install podkop first:"
    echo "    wget -O /tmp/install_podkop.sh https://podkop.net/install"
    echo "    ash /tmp/install_podkop.sh"
    echo ""
    printf "Continue installation anyway? (y/N): "
    read -r CONT_NO_PODKOP
    [ "$CONT_NO_PODKOP" != "y" ] && [ "$CONT_NO_PODKOP" != "Y" ] && \
        die "Installation aborted. Install podkop first."
    warn "Continuing without podkop — bot will start but most features won't work."
else
    PODKOP_VER=""
    case "$PKG_MANAGER" in
        apk)  PODKOP_VER=$(apk info podkop 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
        opkg) PODKOP_VER=$(opkg list-installed 2>/dev/null | grep "^podkop " | awk '{print $3}' | sed 's/^v//') ;;
    esac
    ok "podkop found${PODKOP_VER:+ (v${PODKOP_VER})}."
fi

# ── Package manager wrappers ───────────────────────────────────────────────────
pkg_update() {
    case "$PKG_MANAGER" in
        apk)  apk update >/dev/null 2>&1 ;;
        opkg) opkg update >/dev/null 2>&1 ;;
    esac
}

pkg_is_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apk)  apk info "$pkg" >/dev/null 2>&1 ;;
        opkg) opkg list-installed 2>/dev/null | grep -q "^${pkg} " ;;
    esac
}

pkg_install() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apk)  apk add "$pkg" >/dev/null 2>&1 ;;
        opkg) opkg install "$pkg" >/dev/null 2>&1 ;;
    esac
}

# ── Install dependencies ───────────────────────────────────────────────────────
step "Installing dependencies..."
info "Updating package index..."
if ! pkg_update; then
    warn "Package index update failed — continuing with cached index."
    warn "If dependency install fails below, run 'opkg update' manually and retry."
fi

for pkg in curl jq; do
    if pkg_is_installed "$pkg"; then
        info "$pkg — already installed"
    else
        printf "  Installing %s... " "$pkg"
        if pkg_install "$pkg"; then
            echo "OK"
        else
            echo "FAILED"
            die "Failed to install $pkg. Run 'opkg update' manually and retry."
        fi
    fi
done

# ── Check existing installation ────────────────────────────────────────────────
echo ""
EXISTING_TOKEN=$(uci_get bot_token)
EXISTING_CHAT=$(uci_get chat_id)

if [ -f "$BOT_PATH" ] && [ -n "$EXISTING_TOKEN" ] && [ -n "$EXISTING_CHAT" ]; then
    TOKEN_SHORT=$(printf '%s' "$EXISTING_TOKEN" | cut -c1-${TOKEN_DISPLAY_LENGTH})
    INSTALLED_VER=$(grep '^BOT_VERSION=' "$BOT_PATH" 2>/dev/null | cut -d'"' -f2)
    [ -z "$INSTALLED_VER" ] && INSTALLED_VER="unknown"

    echo "Existing installation detected:"
    echo "  Token    : ${TOKEN_SHORT}..."
    echo "  Chat ID  : $EXISTING_CHAT"
    echo "  Version  : ${INSTALLED_VER}"
    echo ""
    echo "Choose an option:"
    echo "  1) Update script from GitHub, keep config  [default]"
    echo "  2) Reinstall with new settings"
    echo "  3) Exit without changes"
    echo "  4) Uninstall bot completely"
    printf "Enter 1, 2, 3 or 4: "
    read -r CHOICE
    echo ""
    case "$CHOICE" in
        2)
            info "Reinstalling with new settings..."
            ;;
        3)
            ok "Skipped. Existing config preserved."
            exit 0
            ;;
        4)
            # ── Uninstall flow ─────────────────────────────────────────────────
            echo "==========================================="
            echo "  UNINSTALL podkop_bot"
            echo "==========================================="
            echo ""
            echo "This will remove:"
            echo "  - Bot binary       : $BOT_PATH"
            echo "  - Init.d script    : $INIT_PATH"
            echo "  - UCI config       : /etc/config/${UCI_PKG}"
            echo "    (bot_token, chat_id, fallback_socks, all settings)"
            echo "  - All /tmp runtime files"
            echo ""
            echo "podkop itself and its config will NOT be touched."
            echo ""
            printf "Type YES to confirm uninstall: "
            read -r UNINSTALL_CONFIRM1
            if [ "$UNINSTALL_CONFIRM1" != "YES" ]; then
                ok "Uninstall cancelled."
                exit 0
            fi
            echo ""
            printf "Are you sure? Type REMOVE to proceed: "
            read -r UNINSTALL_CONFIRM2
            if [ "$UNINSTALL_CONFIRM2" != "REMOVE" ]; then
                ok "Uninstall cancelled."
                exit 0
            fi
            echo ""
            step "Stopping bot service..."
            safe_stop_bot
            if [ -f "$INIT_PATH" ]; then
                "$INIT_PATH" stop >/dev/null 2>&1
                "$INIT_PATH" disable >/dev/null 2>&1
                rm -f "$INIT_PATH"
                info "Removed $INIT_PATH"
            fi
            step "Removing bot binary..."
            if [ -f "$BOT_PATH" ]; then
                rm -f "$BOT_PATH"
                info "Removed $BOT_PATH"
            fi
            step "Removing UCI config..."
            if uci -q get ${UCI_PKG}.settings >/dev/null 2>&1; then
                uci -q delete ${UCI_PKG} 2>/dev/null || true
                uci commit ${UCI_PKG} 2>/dev/null || true
                rm -f /etc/config/${UCI_PKG} 2>/dev/null || true
                info "Removed /etc/config/${UCI_PKG}"
            fi
            step "Cleaning up runtime files..."
            cleanup_bot_runtime_files
            echo ""
            echo "==========================================="
            echo "  Uninstall complete."
            echo "==========================================="
            echo ""
            echo "podkop and sing-box are untouched and running."
            echo "To reinstall later, run the installer again."
            echo ""
            exit 0
            ;;
        1|*)
            # ── Update flow ────────────────────────────────────────────────────
            step "Checking for updates..."
            REMOTE_VER=$(wget -q -O - "$VERSION_URL" 2>/dev/null | head -1 | tr -d '\r\n\t ')
            [ -z "$REMOTE_VER" ] && \
                REMOTE_VER=$(curl -s "$VERSION_URL" 2>/dev/null | head -1 | tr -d '\r\n\t ')
            [ -z "$REMOTE_VER" ] && REMOTE_VER="unknown"

            echo ""
            echo "  Installed : v${INSTALLED_VER}"
            echo "  Available : v${REMOTE_VER}"
            echo ""

            if [ "$INSTALLED_VER" = "$REMOTE_VER" ] && [ "$REMOTE_VER" != "unknown" ]; then
                echo "Already up to date."
                printf "Update anyway? (y/N): "
                read -r FORCE_UPDATE
                [ "$FORCE_UPDATE" != "y" ] && [ "$FORCE_UPDATE" != "Y" ] && {
                    ok "No changes made."
                    exit 0
                }
            else
                printf "Update v${INSTALLED_VER} -> v${REMOTE_VER}? (Y/n): "
                read -r CONFIRM_UPDATE
                [ "$CONFIRM_UPDATE" = "n" ] || [ "$CONFIRM_UPDATE" = "N" ] && {
                    ok "Update cancelled."
                    exit 0
                }
            fi

            # Stop all bot processes (main loop + watchdog subshells) before
            # replacing the binary — prevents zombie health daemons.
            safe_stop_bot

            # Update main bot script
            printf "  Downloading bot v%s... " "${REMOTE_VER}"
            download_file "$BOT_URL" "$BOT_PATH"
            chmod +x "$BOT_PATH"
            echo "OK"

            # Update init.d script if available in repo
            # Use direct download attempt — wget --spider is unreliable on BusyBox
            _init_tmp=$(mktemp /tmp/podkop_bot_init.XXXXXX)
            if download_file "$INIT_URL" "$_init_tmp" 2>/dev/null && \
               [ -s "$_init_tmp" ] && head -1 "$_init_tmp" | grep -q 'rc.common'; then
                printf "  Updating init.d script... "
                mv "$_init_tmp" "$INIT_PATH"
                chmod +x "$INIT_PATH"
                echo "OK"
            else
                rm -f "$_init_tmp"
                info "init.d script not updated (repo version not available)."
            fi

            ok "Updated to v${REMOTE_VER}."
            echo ""

            # Restart service
            if [ -f "$INIT_PATH" ]; then
                printf "  Starting service... "
                "$INIT_PATH" start >/dev/null 2>&1
                sleep 2
                if "$INIT_PATH" status >/dev/null 2>&1; then
                    echo "OK"
                    ok "Service restarted successfully."
                else
                    echo "UNKNOWN"
                    warn "Service status unclear. Check: logread | grep podkop-bot"
                fi
            else
                info "No init.d script found. Start manually: $BOT_PATH &"
            fi

            echo ""
            echo "==========================================="
            echo "  Update complete!"
            echo "==========================================="
            echo ""
            echo "  Bot script : $BOT_PATH"
            echo "  Version    : v${REMOTE_VER}"
            echo "  Config     : /etc/config/${UCI_PKG}"
            echo ""
            echo "Useful commands:"
            echo "  logread -f | grep podkop-bot          — live logs"
            echo "  /etc/init.d/podkop_bot restart        — restart bot"
            echo "  /etc/init.d/podkop_bot status         — check status"
            echo ""
            echo "GitHub: https://github.com/Medvedolog/podkop_bot"
            exit 0
            ;;
    esac
fi

# ── Download bot script ────────────────────────────────────────────────────────
step "Downloading podkop_bot..."
download_file "$BOT_URL" "$BOT_PATH"
chmod +x "$BOT_PATH"
INSTALLED_VER=$(grep '^BOT_VERSION=' "$BOT_PATH" 2>/dev/null | cut -d'"' -f2)
ok "Downloaded v${INSTALLED_VER:-unknown}: $BOT_PATH"

# ── Bot token ─────────────────────────────────────────────────────────────────
section "Bot configuration"

printf "Telegram bot token (from @BotFather):\n> "
read -r BOT_TOKEN
[ -z "$BOT_TOKEN" ] && die "Bot token cannot be empty."

printf "  Verifying token... "
TG_CHECK=$(curl -s --connect-timeout 8 \
    "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
if ! echo "$TG_CHECK" | grep -q '"ok":true'; then
    echo "FAILED"
    warn "Could not verify token (network issue or invalid token)."
    printf "Continue with this token anyway? (y/N): "
    read -r CONT
    [ "$CONT" != "y" ] && [ "$CONT" != "Y" ] && die "Installation aborted."
else
    BOT_NAME=$(echo "$TG_CHECK" | jq -r '.result.username // "unknown"' 2>/dev/null)
    echo "OK — @${BOT_NAME}"
fi

# ── Chat ID ───────────────────────────────────────────────────────────────────
echo ""
printf "Chat ID or User ID for alerts\n(private chat, group, or supergroup):\n> "
read -r CHAT_ID
[ -z "$CHAT_ID" ] && die "Chat ID cannot be empty."

# ── Additional admin IDs ───────────────────────────────────────────────────────
echo ""
echo "Additional admin User IDs (optional)."
echo "These users can control the bot in addition to the main chat_id."
echo "Example: 123456789 987654321"
printf "(Enter to skip)\n> "
read -r ADMIN_IDS_RAW

# ── Anonymous group admins ─────────────────────────────────────────────────────
echo ""
printf "Allow anonymous group admins to control the bot? (Y/n): "
read -r ANON_ADMINS
ANON_ADMINS_VAL=1
[ "$ANON_ADMINS" = "n" ] || [ "$ANON_ADMINS" = "N" ] && ANON_ADMINS_VAL=0

# ── Fallback SOCKS ────────────────────────────────────────────────────────────
echo ""
echo "-------------------------------------------"
echo "  Fallback SOCKS (optional but recommended)"
echo "-------------------------------------------"
echo ""
echo "If podkop/sing-box stops, the bot loses its primary SOCKS5 tunnel."
echo "Fallback SOCKS entries (tier2) let the bot keep reaching Telegram"
echo "via an independent proxy while the tunnel recovers."
echo ""
echo "Format: socks5h://HOST:PORT  (socks5h resolves DNS through proxy — recommended)"
echo "        socks5://HOST:PORT"
echo ""
echo "Examples:"
echo "  socks5h://192.168.2.10:1080   — another router on LAN running a proxy"
echo "  socks5h://10.0.0.5:18088      — VPS or secondary tunnel"
echo ""
printf "Add fallback SOCKS entries? (y/N): "
read -r ADD_FB
FALLBACK_SOCKS_LIST=""

if [ "$ADD_FB" = "y" ] || [ "$ADD_FB" = "Y" ]; then
    echo ""
    echo "Enter one entry per line. Empty line = done."
    _fb_n=1
    while true; do
        printf "  Entry %d (or Enter to finish): " "$_fb_n"
        read -r _fb_entry
        [ -z "$_fb_entry" ] && break
        if validate_socks_url "$_fb_entry"; then
            FALLBACK_SOCKS_LIST="${FALLBACK_SOCKS_LIST} ${_fb_entry}"
            ok "Added: $_fb_entry"
            _fb_n=$((_fb_n + 1))
        else
            warn "Invalid format. Expected: socks5h://HOST:PORT or socks5://HOST:PORT"
        fi
    done
    _fb_count=$(echo "$FALLBACK_SOCKS_LIST" | tr ' ' '\n' | grep -c '.')
    [ "$_fb_count" -gt 0 ] && ok "$_fb_count fallback SOCKS entry(s) configured." \
                           || info "No valid entries added. Skipping fallback SOCKS."
fi

# ── Write UCI config ───────────────────────────────────────────────────────────
step "Writing UCI config..."

[ -f "/etc/config/${UCI_PKG}" ] || touch "/etc/config/${UCI_PKG}" \
    || die "Cannot create /etc/config/${UCI_PKG} — check filesystem."

uci -q delete "${UCI_PKG}.${UCI_SEC}" 2>/dev/null
uci set "${UCI_PKG}.${UCI_SEC}=settings" \
    || die "uci set failed — check /etc/config/ permissions."

uci set "${UCI_PKG}.${UCI_SEC}.bot_token=${BOT_TOKEN}"
uci set "${UCI_PKG}.${UCI_SEC}.chat_id=${CHAT_ID}"
uci set "${UCI_PKG}.${UCI_SEC}.allow_anonymous_admins=${ANON_ADMINS_VAL}"
uci set "${UCI_PKG}.${UCI_SEC}.transport=auto"
uci set "${UCI_PKG}.${UCI_SEC}.health_interval=60"
uci set "${UCI_PKG}.${UCI_SEC}.alert_notify=1"
uci set "${UCI_PKG}.${UCI_SEC}.startup_notify=1"

# admin_ids: space-separated list → multiple uci add_list calls (safe for spaces/special chars)
# uci set with spaces in value is unreliable — use uci list approach via config file
if [ -n "$ADMIN_IDS_RAW" ]; then
    for _aid in $ADMIN_IDS_RAW; do
        # Validate: admin IDs must be numeric
        if echo "$_aid" | grep -qE '^-?[0-9]+$'; then
            uci add_list "${UCI_PKG}.${UCI_SEC}.admin_ids=${_aid}"
        else
            warn "Skipping invalid admin ID (not numeric): $_aid"
        fi
    done
fi

# fallback_socks: one uci add_list per entry
if [ -n "$FALLBACK_SOCKS_LIST" ]; then
    for _fb in $FALLBACK_SOCKS_LIST; do
        [ -n "$_fb" ] && uci add_list "${UCI_PKG}.${UCI_SEC}.fallback_socks=${_fb}"
    done
fi

uci commit "$UCI_PKG" || die "uci commit failed."
ok "Config written to /etc/config/${UCI_PKG}"

# Show what was written
echo ""
echo "  UCI config summary:"
echo "  ┌─ bot_token  : $(uci_get bot_token | cut -c1-${TOKEN_DISPLAY_LENGTH})..."
echo "  ├─ chat_id    : $(uci_get chat_id)"
_aids=$(uci -q get ${UCI_PKG}.${UCI_SEC}.admin_ids 2>/dev/null || echo "(none)")
echo "  ├─ admin_ids  : ${_aids}"
_fbs=$(uci -q show ${UCI_PKG}.${UCI_SEC}.fallback_socks 2>/dev/null \
    | cut -d= -f2- | tr "'" ' ' | tr '\n' ' ' || echo "(none)")
echo "  ├─ fb_socks   : ${_fbs:-(none)}"
echo "  └─ transport  : auto"

# ── Init script / autostart ────────────────────────────────────────────────────
section "Autostart"

printf "Set up autostart via init.d? (Y/n): "
read -r SETUP_INIT

if [ "$SETUP_INIT" != "n" ] && [ "$SETUP_INIT" != "N" ]; then
    # Try to download init script from repo; validate it looks like an rc.common script
    _init_tmp=$(mktemp /tmp/podkop_bot_init.XXXXXX)
    INIT_OK=0
    printf "  Downloading init.d script... "
    if download_file "$INIT_URL" "$_init_tmp" 2>/dev/null && \
       [ -s "$_init_tmp" ] && head -1 "$_init_tmp" | grep -q 'rc.common'; then
        mv "$_init_tmp" "$INIT_PATH"
        INIT_OK=1
        echo "OK"
    else
        rm -f "$_init_tmp"
        echo "not available — generating locally"
    fi

    if [ "$INIT_OK" = "0" ]; then
        # Generate procd init script — compatible with OpenWrt 23.05 / 24.10 / 25.x+
        cat > "$INIT_PATH" << 'INITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG=/usr/bin/podkop_bot

start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}
INITEOF
        info "Generated minimal procd init script."
    fi

    chmod +x "$INIT_PATH"
    "$INIT_PATH" enable >/dev/null 2>&1
    ok "Autostart enabled: $INIT_PATH"
else
    info "Autostart skipped. Start manually: $BOT_PATH &"
fi

# ── Start now ─────────────────────────────────────────────────────────────────
echo ""
printf "Start the bot now? (Y/n): "
read -r START_NOW
echo ""

if [ "$START_NOW" != "n" ] && [ "$START_NOW" != "N" ]; then
    if [ -f "$INIT_PATH" ]; then
        printf "  Starting via init.d... "
        "$INIT_PATH" start >/dev/null 2>&1
        sleep 2
        if "$INIT_PATH" status >/dev/null 2>&1; then
            echo "OK"
            ok "Bot started via init.d."
        else
            echo "UNKNOWN — falling back to direct start"
            "$BOT_PATH" &
            ok "Bot started directly (PID: $!)."
        fi
    else
        "$BOT_PATH" &
        ok "Bot started (PID: $!)."
    fi
else
    info "Bot not started. Run when ready:"
    info "  /etc/init.d/podkop_bot start"
    info "  # or: $BOT_PATH &"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  Installation complete!"
echo "==========================================="
echo ""
echo "  Bot script : $BOT_PATH"
echo "  Config     : /etc/config/${UCI_PKG}"
echo "  Version    : ${INSTALLED_VER:-unknown}"
echo "  Pkg mgr    : ${PKG_MANAGER}"
echo ""
echo "Useful commands:"
echo "  logread -f | grep podkop-bot          — live logs"
echo "  /etc/init.d/podkop_bot restart        — restart bot"
echo "  /etc/init.d/podkop_bot status         — check status"
echo ""
echo "Edit config:"
echo "  uci show ${UCI_PKG}"
echo "  uci add_list ${UCI_PKG}.${UCI_SEC}.fallback_socks='socks5h://HOST:PORT'"
echo "  uci set ${UCI_PKG}.${UCI_SEC}.health_interval=60"
echo "  uci commit ${UCI_PKG} && /etc/init.d/podkop_bot restart"
echo ""
echo "GitHub: https://github.com/Medvedolog/podkop_bot"
