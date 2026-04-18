# Changelog

## v0.13.93

- **FIXED:** Outbounds list regression — all proxies showed "Unknown | N/A" and internal group nodes (main-urltest-out) leaked into the list. Root cause: jq pipeline used `.proxies[$sel].all | to_entries[]` which shifts the context away from the JSON root, making subsequent `.proxies[name]` lookups read from the entry object instead of the root. Fixed by adding `. as $root` at the start of both `total` and `page_tsv` jq expressions, then using `$root.proxies[...]` throughout. Affected Selector and URLTest modes; px_view cards were unaffected as they use separate direct queries.
- **FIXED:** do_px_auto_urltest ("Switch to URLTest auto" button) searched for URLTest group globally across all Clash API proxies, picking the first one found anywhere. In multi-section configs this could activate a URLTest group from a different section (e.g. main instead of antiz). Now scoped to `$root.proxies[$sel].all[]` — only searches within the current selector's members.
- **FIXED:** Single URL mode (proxy_config_type=url) appended new URLs to proxy_string instead of replacing. The UI said "This replaces any existing URL" but the code did `printf '%s\n%s' "$existing" "$safe_link"`. Fixed to `uci set proxy_string="$safe_link"` — strict single-link semantics now match the UI.
- **FIXED:** Outbound Config mode SSH hint had hardcoded `podkop.MAIN.outbound_json=...`. Replaced with `podkop.${sec}.outbound_json=...` so the hint reflects the actual active section name.
- **NEW:** podkop_dns_check() function — tests tunnel health after reload via fakeip DNS probe (nslookup fakeip.podkop.fyi 127.0.0.42, expects 198.18.x.x). Borrowed from podkop_autoupdater (VizzleTF). Now used in do_reload_podkop: after reload shows "✅ Tunnel OK" or "⚠️ Tunnel check failed" instead of just "Reloaded!".
- **FIXED:** cmd_check_update version comparison used sort -V which is not guaranteed on BusyBox. Replaced with numeric field-by-field comparison (split x.y.z, compare each part with -gt/-eq).
- **UX:** Status card (cmd_status) — 🐶 emoji for Podkop line, 📦 for Sing-box, 📨 for Telegram health row, 🐧 before OS. Clock emoji 🕐 removed from uptime and bot route latency. WAN and Public IP merged into one line (Public IP shown only when different from WAN). Telegram health reworded from "TG direct / via SOCKS / SOCKS" to "direct / tunnel / SOCKS".

---

## v0.13.92

- **FIXED:** api_poll_long() recovery path did not call _write_main_route() after successful SOCKS rediscovery. MAIN_ROUTE_FILE and MAIN_ROUTE_KEY_FILE remained stale, causing watchdog to read the old tier and potentially fire false "route degraded" nudges.
- **FIXED:** urltest_group detection in _handle_proxy() used a global jq search across all Clash API proxies, picking the first URLTest node found anywhere — could steal data from a different section (e.g. main) when active section was antiz. Now searches only within .proxies[$selector].all[] members scoped to the active section.
- **FIXED:** sed -nE replaced with POSIX BRE sed -n (no -E flag) in extract_server_port_from_uri(). BusyBox sed on some OpenWrt builds supports -r but not -E.
- **FIXED:** do_restart_bot and do_update_bot used killall -9 $basename after init.d restart, risking killing the newly spawned instance. Replaced with kill -9 $$ (own PID) — only the current process is terminated, new instance is safe.
- **NEW:** Check E in watchdog — bot transport route degradation alerts. Fires when bot route drops to tier4 (Direct) or tier5 (Emergency IPs), with a clear message explaining the situation. Recovery alert fires when route returns to tier1/tier2. Separate from SOCKS alerts.
- **NEW:** Tier1 SOCKS down alert even when tier2 keeps bot reachable. Previously if tier2 fallback was alive, curr_socks_state was reset to "up" and no alert fired — user saw nothing while primary SOCKS was down. Now tracks last_tier1_state separately: fires "Primary SOCKS unavailable, switched to fallback" alert, and "Primary SOCKS recovered" when tier1 comes back.
- **FIXED:** Group nodes (URLTest/Selector/Fallback/LoadBalance) were included in the Outbounds proxy list. sing-box internal routing nodes like main-urltest-out appeared as selectable entries with VLESS type. Now filtered out from display and total count; pagination adjusted accordingly; orig_idx preserved for correct px_view_N callbacks.
- **UX:** Status card (cmd_status) redesigned for mobile readability — each item on its own line, no forced line merges. Changes: 🐧 added before OS, 🐶 replaces ⚙️ for Podkop line, 📦 replaces 🔌 for Sing-box, 📨 replaces 🔍 for Telegram health, ✅ for one-shot done status, 🟢 for sing-box RUNNING. RAM shown inline with | separator.
- **UX:** WAN and Public IP merged — Public IP only shown when different from WAN (NAT). Saves one line when ISP gives white IP.
- **UX:** Clock emoji 🕐 removed from uptime and bot route latency — context makes units clear.
- **UX:** Telegram health line reworded from "TG direct / via SOCKS / SOCKS" to "direct / tunnel / SOCKS" — more intuitive for new users.
- **UX:** URLTest outbounds card title changed to "URLTest Outbounds" (was "Outbound Selector"). Mode hint changed from "Manual: fixed" / "Auto: best ping" to "Pinned manually" / "URLTest: auto-selecting". Auto button renamed "URLTest auto ✓" / "Switch to URLTest auto".

- **FIXED:** Refresh toast (answerCallbackQuery) could silently fail on slow routers. CB_ANSWER_TEXT was set before clash_request but answer_callback was only called after handle_command returned — by then Telegram's ~5s callback query timeout could have already expired, causing a "Bad Request: query is too old" error and no toast shown. Fix: proxy_menu Refresh now calls answer_callback immediately (before clash_request), then sets CB_ANSWER_TEXT="__ANSWERED__" to signal the main loop to skip the second answer call. Toast now reliably appears within milliseconds of the button press.

---

## v0.13.90

- **FIXED:** get_selector_tag() used a greedy fallback that could steal data from a different section. When active section was "antiz" in urltest mode, the fallback searched for ANY Selector-type node in the entire Clash API response (ignoring section scope) and picked the largest one — which happened to be from "main". Result: bot showed main section's proxies and route while the user was in "antiz". Three-part fix: (1) added explicit check for $sec+"-out" tag before falling back; (2) fallback now accepts URLTest nodes in addition to Selector (so urltest-mode sections are found); (3) fallback filtered to only nodes whose key starts with the active section name — cross-section data theft is no longer possible.

- **NEW:** Proxy mode switch guard for URL mode — switching to URL mode without a configured proxy_string no longer reloads podkop (which would crash with "[fatal] Proxy string is not set"). Bot saves the mode to UCI, holds the reload, and enters wait_url_link state immediately. User sends the proxy link in chat; bot saves it and then reloads safely. Cancel button reverts to selector mode without any reload.
- **NEW:** URL mode warning on switch screen — if proxy_string is empty, confirmation screen shows a red warning explaining the link must be provided before reload. If proxy_string is already set, screen shows the current URL.
- **NEW:** Check D (leaf change watchdog) now distinguishes manual vs automatic proxy switches. Tracks Clash API .now field (last manual selector choice) alongside the resolved leaf. If .now changed → alert says "Proxy manually switched" (user action via bot or LuCI). If .now unchanged but leaf changed → alert says "Proxy auto-switched" (URLTest picked a faster server). Prevents confusion when bot reports a switch the user just made themselves.
- **FIXED:** get_active_proxy_name() did not resolve URLTest groups — returned raw tag like "main-urltest-out" instead of the actual active proxy. Was checking only Selector type; now uses _resolve_leaf() which iterates through any chain of Selector/URLTest/Fallback/LoadBalance nodes. Fixes "Active Route: main-urltest-out" in main menu.
- **FIXED:** podkop version display showed two versions concatenated (e.g. "v0.7.10-r1 v0.7.14-r1") on RouteRich and similar custom OpenWrt forks where opkg returns multiple Version: lines for podkop. Fixed by adding tail -1 to all 5 version detection sites — takes only the last (newest) entry.
- **FIXED:** proxy_link counter (used for Clone from Selector button) reported wrong count on some OpenWrt versions where uci show outputs all list items on a single line. grep -c counted lines not items. Replaced with eval "set -- $raw"; count=$# which is format-independent.
- **UX:** proxy_menu card title now reflects actual mode: "Outbound Selector" in selector mode, "URLTest Outbounds" in urltest mode.
- **UX:** URL mode renamed throughout for clarity: main menu button "URL Links" → "Single URL"; card title "URL Links" → "Single URL Proxy"; add button "Add Link" → "Set URL"; prompts updated to reflect single-link semantics.
- **UX:** installer option 4 (Uninstall) added — full removal with double confirmation (type "YES" then "REMOVE"). Removes bot binary, init.d script, /etc/config/podkop_bot, all /tmp runtime files. podkop and sing-box are untouched.

- **FIXED:** ROOT CAUSE of "tir1" watchdog false-positive nudge loop — diagnosed via [RouteWrite] + hex dump debug logs added in v0.13.89. Log showed: route_key_raw='tier1' hex= clean=tir1 Root cause: BusyBox tr on OpenWrt 24.10.x incorrectly treats 'e' (0x65) as a member of the [:space:] character class. Confirmed on Redmi AX6000 (MT7986A, ARM Cortex-A53) running stock OpenWrt 24.10.5 — not platform-specific, likely affects all OpenWrt 24.10.x builds with that BusyBox version. Effect: tr -d '[:space:]' on "tier1" produced "tir1" (dropped 'e'), which did not match the case pattern tier1|tier2_* → watchdog fired IPC nudge every 120s indefinitely, causing continuous RECOVERY_MODE=2 cycles, extra transport resets, and "recover old=unknown" log spam. Fix: replaced ALL tr -d '[:space:]' with tr -d '\n\r\t ' (explicit whitespace chars only). Affects 2 watchdog reads + 5 user input validators + 2 IP fetch cleaners. sed 's/[[:space:]]//g' uses sed's own regex engine (unaffected) and was left unchanged.
- **REMOVED:** [RouteWrite] debug logger from _write_main_route (was added in v0.13.89 for diagnosis, now spammed every API call — removed).
- **REMOVED:** [Watchdog] route_key_raw/hex debug logger (same, now resolved).

- **REFACTORED:** All syslog and Telegram alert messages rewritten for readability. Syslog: internal variable dumps (RECOVERY_MODE, FAST/POLL, method=) replaced with human-readable sentences. Cache lines renamed [Core]. Health summary reformatted as single [Health] line. Watchdog IPC messages now describe actions, not internal mechanics. Telegram alerts: sing-box stop/recover, SOCKS down/recover, proxy switch, TG connectivity — all rewritten to focus on user impact, removing technical terms (tier1, control plane, Scope:) in favour of plain English.

---

## v0.13.89

- **FIXED:** Proxy delete (ask_del_px_*) — root cause identified and fixed. get_selector_link_by_index(tag_idx) assumed "main-N-out" tag == UCI list position N-1. This is false: after any add/remove the tag numbering in sing-box config.json diverges from UCI list order. Wrong index → wrong link → uci del_list silently deleted a DIFFERENT proxy or nothing. Tag index step removed entirely. New approach: always match by server:port from TAG_URI_CACHE (order-independent, unique per outbound). Two fallback levels: (1) grep in UCI_LINKS_CACHE, (2) live uci show scan. Covers all protocol types: vless, hy2, trojan, tuic, ss+auth, ss-no-auth (no @ in URI). Error message now returns to px_view_N instead of proxy_menu.
- **FIXED:** extract_server_port_from_uri() failed on ss no-auth format "ss://host:port" (no @ present). Old regex required @ in URI. New regex handles both: with-auth scheme://user@host:port and no-auth scheme://host:port. Affects all server:port matching.
- **FIXED:** test_px_ (Test button in proxy card) replaced the card with a loading message, causing visual jump: card disappears → reappears. Now sends a separate status message below the card, keeps card visible throughout, deletes status message when done.
- **FIXED:** cmd_all_delay_test same jump issue — already fixed in this version, now also preserves current page number in refresh call.
- **FIXED:** Refresh button (proxy_menu_p_N) appeared frozen for ~10s with no feedback. Now shows inline loading indicator immediately by editing the card to "Refreshing..." before the clash_request call. Also: retry logic on empty response + better error message with Retry button.

---

## v0.13.88

- **FIXED:** clash_request() missing --max-time on all curl calls. connect-timeout 3 only covers TCP handshake; if Clash API accepts connection but hangs on response (sing-box under OOM/high load), watchdog Check D blocked the entire health cycle indefinitely. Added --max-time 10 to all 4 curl invocations (GET+auth, GET, PUT+auth, PUT).
- **FIXED:** Watchdog probe zombie accumulation at long uptime (30d+). probe_all_socks_write runs as background & every PROBE_EVERY cycles (~every 5 min). In BusyBox ash, background subshells stay as zombies until parent calls wait(). Over a month: ~8640 zombies × (3 curl + 1 ash subshell). Fixed: track _last_probe_pid, call wait "$_last_probe_pid" before launching the next probe.
- **FIXED:** refresh_public_ip_cache() temp file leaks under RAM pressure. (a) mktemp for f1/f2/f3 was unchecked — if any failed, lockdir leaked and curl subshells forked into /dev/null. Now each mktemp is checked with explicit rollback (rm previous + rm lockdir). (b) Final mktemp for atomic write also unchecked — same lockdir leak. (c) mv "$tmp" "$PUBIP_CACHE" could fail (full tmpfs) leaving $tmp orphaned. Now: mv || { rm -f "$tmp"; ... }.
- **FIXED:** probe_all_socks_write() unchecked mv — temp file leaked if tmpfs full. Now: mv || rm -f "$_probe_tmp".
- **FIXED:** tier4/tier5 reprobe compound condition bug. Pattern `_try_socks_tiers || { [...] && _try_curl && ROUTE_KEY=tier3 && ... }` is ambiguous in some BusyBox ash versions: the && chain inside {...} after || can fail to assign ROUTE_KEY/ROUTE_NAME before the outer if tests the result. Replaced with explicit if/elif/else + `[ -n "$ROUTE_KEY" ]` guard — unambiguous in all POSIX ash implementations.
- **FIXED:** trap missing glob cleanup for orphaned temp files. Added: /tmp/podkop_updates.* /tmp/podkop_req.* /tmp/podkop_clash.* /tmp/podkop_ip[123].* /tmp/podkop_pubip.* These files are created mid-cycle and not cleaned if bot receives SIGKILL (which bypasses trap).
- **NEW:**   Startup stale temp file cleanup: find+stat sweep of /tmp for all podkop_* temp file patterns older than 60s. Runs once after singleton guard. Removes orphans from previous SIGKILL'd runs without racing against a legitimate concurrent process.

---

## v0.13.87

- **UX:**    Core Settings keyboard redesigned — 2-column layout grouped by theme: Row 1: Conn type + Proxy mode         (core routing behaviour) Row 2: Mixed Proxy toggle + Port       (same entity, same row) Row 3: Outbound iface + DNS            (network routing config) Row 4: URLTest + Domain Resolver       (per-section extras) Row 5: YACD + Autostart               (system-level) Row 6: Disable QUIC + Update interval  (global flags) Row 7: DL via Proxy + Excl. NTP        (global flags) Row 8: Bad WAN toggle + Bad WAN Details (same entity, same row) Row 9: Log level + Back Card body trimmed: separators instead of verbose multi-line hints, all state visible at a glance in one compact block. outbound_iface now read into local var at top of handler (was a mid-keyboard inline local — inconsistent with other vars).

---

## v0.13.86

- **FIXED:** Nudge case uses negative match (tier1|tier2_* = good, everything else = nudge). Previously explicit list (tier4|tier5|fail|unknown) missed stale/typo values like 'tir4' left on disk from old bot versions after killall -9 (no trap). Both baseline nudge and per-cycle nudge updated.
- **FIXED:** installer safe_stop_bot now calls cleanup_bot_runtime_files() which removes all /tmp/podkop_bot_* IPC/state files before deploying new binary. Prevents stale route keys, nudge timestamps, socks state from old versions affecting the new bot's startup behavior.

---

## v0.13.85

- **FIXED:** tier4 sticky now reprobe SOCKS tiers every 30s (mirrors tier5 mechanism). Previously bot stuck on Direct indefinitely when Telegram accessible directly (TG direct: ok) — sticky tier4 never failed so full discovery never ran. Now shares SOCKS_REPROBE_TS_FILE with tier5 for unified reprobe cadence.
- **FIXED:** Nudge throttled to 120s (was every ~30s watchdog cycle). Continuous nudge caused IPC "up" to reset LAST_ROUTE_FAST=unknown on every cycle, triggering full discovery → recover old=fail new=tier4 loop. Bot could never stabilize.
- **FIXED:** Per-cycle nudge now uses curr_socks_state (current cycle) instead of last_socks_state (previous cycle). Nudge now fires on same cycle tier2 is confirmed alive instead of one cycle later.
- **FIXED:** Watchdog baseline sends IPC "up" immediately if SOCKS is up but bot route is degraded (tier4/tier5/unknown) on first cycle. Previously baseline set last_socks_state=up → no down→up transition ever fired → no IPC up from RECOVERED handler → bot stuck on Direct indefinitely after cold start.
- **FIXED:** Check C (SOCKS probe) now also probes all fallback_socks (tier2_N) when tier1 is down. If any tier2 alive → curr_socks_state=up → nudge fires → bot rediscovers tier2 instead of staying on Direct.
- **FIXED:** api_request_fast no longer zeros RECOVERY_MODE on success — decrements instead. Zeroing caused next api_poll_long to skip SOCKS-first path and land on Direct if tier1 was slow to respond post-recovery.
- **FIXED:** IPC "up" sets RECOVERY_MODE=2 (was 0). RECOVERY_MODE=0 caused _try_all_tiers to miss tier1 on tight connect-timeout and fall through to Direct. With =2, next 2 poll cycles probe SOCKS aggressively.
- **FIXED:** Pre-initialize MAIN_ROUTE_KEY_FILE="unknown" and MAIN_ROUTE_FILE= "Initializing..." at startup before watchdog fork. Without this watchdog read empty file → sent nudge → IPC up reset FAST/POLL → bot landed on Direct before tier1 confirmed reachable.
- **FIXED:** Self-update and do_restart_bot: added killall -9 podkop_bot after init.d restart (sync ubus call) to clean up zombie watchdog subshells. init.d restart is now synchronous (no &) so procd queues restart before killall fires.
- **FIXED:** cmd_status health_st now reads SOCKS_STATE_FILE with icons instead of raw HEALTH_STATE_FILE keys (was showing "tg_direct=ok tg_transport=ok").
- **FIXED:** Bot Settings cp_hint blank line — empty cp_hint no longer leaves blank line between Custom Proxy and Bind Interface (${cp_hint:+ ${cp_hint}}).
- **NEW:**   Restart Bot button in Info (ask_restart_bot / do_restart_bot).
- **NEW:**   Restart Router button in Info with double confirmation: step 1: button press (ask_restart_router_1) step 2: type YES in chat (wait_restart_router_confirm state) Any other input cancels with echo of what was typed.
- **UX:**    Menu button added to all remaining deep screens: cmd_status, cmd_runtime, cmd_tunnel_health, fallback_socks_menu, urltest_settings, domain_resolver_settings, badwan_details, cmd_runtime Back row.
- **UX:**    installer: update flow now shows full summary (version, path, useful commands) instead of bare "Done." line followed by exit 0.
- **UX:**    installer: vv0.7.14-r1 → v0.7.14-r1 (opkg returns version with leading v, installer added another one via "v${PODKOP_VER}").

---

## v0.13.80

- **FIXED:** Watchdog summary log showed "route=Initializing..." permanently because LAST_ROUTE_NAME is a fork-time copy of the parent variable (always stays "Initializing..." in the watchdog subshell). Now reads from MAIN_ROUTE_FILE which is written by the main process on every successful tier resolution.
- **COSMETIC:** Removed duplicate singleton guard comment ("by scriptname" line left over from v0.13.78 rename, sat above the correct "by BOT_PATH pattern" comment). No behavior change.

---

## v0.13.79

- **UX:**    Bot Settings card redesigned into 4 visual blocks with separators: [1] Transport Policy + Active Route + TG Latency [2] Fallback Chain (active tier bold ◀ active) [3] Overrides: Custom Proxy + cp_hint + Bind Interface [4] Uptime + Started / Last Command / Unauthorized Attempts Keyboard restructured into 3 semantic rows: Row 1: Transport | Health Interval Row 2: Fallback SOCKS Row 3: Custom Proxy | Bind Iface Row 4: Startup Notify | Alert Notify Row 5: Menu st/al icons pre-computed into variables (no inline $() in kb string).
- **UX:**    cmd_files (Configs & Logs) now has Menu button alongside Back.
- FIX:   Singleton guard comment updated: "by scriptname" → "by BOT_PATH pattern".

---

## v0.13.78

- **FIXED:** Broken reply_markup JSON in Diagnostics (cmd_diagnostics, ask_upstream_health, ask_run_podkop_tests, ask_run_internal_diag, ask_support_bundle) and Bot self-update (cmd_check_update_bot, ask_update_bot_*, do_update_bot_* error branches). Unescaped {"inline_keyboard":...} as literal shell arg caused Telegram to reject all requests silently (no keyboard rendered). Fixed by using kb="{\"inline_keyboard\":...}" variable pattern throughout.
- **FIXED:** Self-update wget without timeout replaced with curl --connect-timeout 5 --max-time 8/15. wget -qO- on OpenWrt hangs indefinitely without -T flag.
- **FIXED:** Singleton guard: pgrep -f "podkop_bot" → pgrep -f "$BOT_PATH" to avoid matching unrelated processes. Less greedy, more precise.
- **UX:**    Menu button added to all Diagnostics screens (hub + 4 ask_* confirms) and Bot self-update screens (check, ask, error branches).
- **UX:**    cp_hint spacing: explicit newline between cp_hint and Bind Interface line prevents visual merge when hint is non-empty.

---

## v0.13.77

- **FIXED:** Source of truth for route key in watchdog — architectural cleanup. Root cause: MAIN_ROUTE_FILE holds human-readable names ("Podkop (SOCKS5:...)"), not tier keys. grep -oE 'tier[0-9_]+' on it always returned empty. SOCKS_STATE_FILE.route= was written by watchdog from stale subshell LAST_ROUTE. Both fallbacks in per-cycle nudge therefore read wrong/stale data.

  Fix: new MAIN_ROUTE_KEY_FILE (/tmp/podkop_bot_main_route_key) written by main process at every successful tier resolution via _write_main_route() helper. _write_main_route(key, name) atomically updates both KEY and NAME files. All tier resolution points updated: tier1..tier5 sticky + full discovery + tier5 reprobe + api_request_fast recovery path.

  Per-cycle nudge now reads MAIN_ROUTE_KEY_FILE directly — no grep heuristics, no stale var, no fallback chain needed.

  _write_socks_state() drops route= and route_name= fields (were stale subshell copies). SOCKS_STATE_FILE now contains: tg, tg_direct, tg_transport, socks, last_ok only. Tunnel Health and rt_socks_state reads unaffected (use socks= key).

  MAIN_ROUTE_KEY_FILE added to trap cleanup.

---

## v0.13.76

- **FIXED:** BOT_PATH not declared — self-update mv/exec expanded to empty string. Added: BOT_PATH=$(readlink -f "$0" || echo "/usr/bin/podkop_bot") near BOT_VERSION. readlink -f resolves symlinks at runtime, fallback matches installer default path.
- **FIXED:** Per-cycle watchdog nudge read stale LAST_ROUTE from subshell scope (fork-time copy, never updated). Now reads from MAIN_ROUTE_FILE (written by main process on every successful tier resolution) with fallback to route= key in SOCKS_STATE_FILE. Both are file-based IPC, same pattern as ROUTE_CMD_FILE already used for watchdog→main comms.
- **FIXED:** html_escape() missing double-quote escaping. URLs in remote_domain/ subnet list <a href="..."> cards could contain " and break HTML parse mode → Telegram 400. Added: -e 's/"/\&quot;/g'
- **UX:**    Tunnel Health "TG via SOCKS" renamed to "TG via Podkop (tier1)" with note "(primary mixed_proxy — not full bot transport chain)". Prevents confusion: this metric only probes tier1, not tier2_N/tier3.

---

## v0.13.75

- **FIXED:** Transport tier return logic — bot now reliably comes back to tier1 after podkop/sing-box recovers. Three-part fix: 1. IPC "up" now also clears SOCKS_REPROBE_TS_FILE → tier5 reprobe fires immediately on next _route_request, not after 30s timer. 2. Per-cycle watchdog nudge: every health cycle, if socks=up AND sing-box running AND bot route=tier4/tier5/fail, sends IPC "up" to main loop. Replaces the previous PROBE_EVERY-only nudge (was up to ~5 min lag). 3. Removed duplicate IPC "up" from PROBE_EVERY block (now per-cycle).
- **UX:**    Scope line added to all 7 watchdog alert types: TG reachable/unreachable: "Scope: bot control plane" sing-box STOPPED: "Scope: data plane DOWN + bot transport resetting" sing-box RECOVERED: "Scope: data plane restored — bot returning to tier1" Bot SOCKS DOWN: "Scope: bot control plane — podkop data routing unaffected" Bot SOCKS RECOVERED: "Scope: bot control plane — returning to tier1" Proxy switched: "Scope: outbound selection only — no service interruption" Consistent one-line clarifier: operator sees immediately what broke and whether user traffic is affected.

---

## v0.13.74

- **FIXED:** TG health semantics in Tunnel Health — split into two independent metrics. check_health() now probes TWO paths and writes TWO keys to HEALTH_STATE_FILE: tg_direct=ok|fail    — raw curl, no proxy (expected fail under RKN) tg_transport=ok|fail — curl via primary mixed_proxy SOCKS (Podkop tier1) Returns 0 (success) if either path works. _write_socks_state() reads both keys from HEALTH_STATE_FILE and forwards them to SOCKS_STATE_FILE (keeps tg= for backward compat). Watchdog: updated grep to use [ tg_direct=ok ] || [ tg_transport=ok ] instead of pattern matching on "Connected|via SOCKS" string.
- **UX:**    Tunnel Health now shows two TG lines: "TG direct: ok|fail (no proxy)" "TG via SOCKS: ok|fail (Podkop tier1)" Under RKN: direct=fail, SOCKS=ok — both visible, no false alarm. "fail" on TG direct no longer triggers confusion because label is honest.

---

## v0.13.73

- **UX:**    Runtime Info split: heavy tests moved to new Diagnostics screen. Runtime Info now shows: connections, traffic, active proxy, selector, type/delay, bot route summary. Keyboard: Tunnel Health | Diagnostics | Configs & Logs | Refresh | Back. No heavy actions on this screen.
- **NEW:**   cmd_diagnostics — dedicated hub for all active test operations: Upstream Health, Global Check, Internal Diagnostics, Support Bundle. Intro text explains these are active tests that may take 10-30 sec.
- **NEW:**   ask_* confirm screens before every heavy action: ask_upstream_health, ask_run_podkop_tests, ask_run_internal_diag, ask_support_bundle. Each shows what the action does, estimated time, and Run / Cancel buttons. Consistent with existing ask_*/do_* pattern.
- **UX:**    Back navigation from all heavy actions now returns to cmd_diagnostics instead of cmd_runtime (upstream_health, global_check, internal_diag, support_bundle).
- **FIXED:** html_escape applied to human_name in Outbound Selector list text. URI fragment user-names with <>&  could break Telegram HTML parse mode.
- **FIXED:** html_escape applied to _fb, cp, bi, m_ip in Bot Settings tr_chain. After removing <code> wrapper these values render as raw HTML.

---

## v0.13.72

- **NEW:**   Bot self-update from Telegram menu (cmd_check_update_bot). Info screen now has two update buttons: podkop and bot separately. cmd_check_update_bot: fetches version.txt from GitHub, compares with BOT_VERSION, shows diff or "up to date" with force-update option. ask_update_bot_<ver>: confirm screen before applying. do_update_bot_<ver>: downloads to /tmp/podkop_bot_update.PID, validates shebang + BOT_VERSION present, atomic mv to BOT_PATH, kills HEALTH_PID (watchdog), then init.d restart or exec fallback. Sends confirmation message BEFORE restart (last message before down).
- **FIXED:** Installer: safe_stop_bot() added — kills main PID from pid file AND runs killall -9 podkop_bot before replacing binary during update. Prevents zombie watchdog subshells that survived procd SIGKILL.

---

## v0.13.71

- **FIXED:** ZeroTier/Tailscale interface line in Status merged with CPU Load line. $() subshell strips trailing newlines from awk output, so extra_ifs lost its trailing \n. Now explicitly appended when extra_ifs non-empty.
- **FIXED:** Tunnel Health "TG reach: fail" misleading when bot works via SOCKS. check_health() now tries direct curl first, then SOCKS fallback. HEALTH_STATE_FILE writes "Connected", "via SOCKS", or "Disconnected". Watchdog grep updated to match both "Connected" and "via SOCKS". Tunnel Health label renamed "TG direct" with "(fail under RKN is normal)" hint so users understand the distinction between direct and SOCKS reach.

---

## v0.13.70

- **FIXED:** routing_excluded_ips wrote to per-section UCI (podkop.<sec>.routing_excluded_ips) but podkop reads it from podkop.settings.routing_excluded_ips (global setting). All 5 references corrected. Card header now shows [global] with note.
- **FIXED:** url_proxy_links UCI key does not exist in podkop. proxy_config_type=url uses proxy_string (multiline textarea, one URL per line). get_url_proxy_links() rewritten to read proxy_string. _handle_url_links add/delete fully rewritten: add appends line to proxy_string, delete rebuilds proxy_string without target line, empty = uci delete.
- **NEW:**   proxy_mode_menu — full 4-mode selector (url/selector/urltest/outbound). Previously Mode button only toggled selector<->urltest. Now opens a menu with all modes; active mode shown with checkmark. ask_switch_mode_ expanded with correct warning text for each mode. proxy_mode_menu added to dispatch routing.
- **UX:**    Active proxy in Outbound Selector list: bold name + E_PLAY icon. Inactive proxies show latency icon only (no active_mark clutter).
- **UX:**    Bot Settings Fallback Route chain: active tier highlighted in bold with "◀ active" marker. Removed <code> wrapper so HTML renders. Active tier determined from LAST_ROUTE_FAST variable.

---

## v0.13.69

- **FIXED:** ZeroTier interfaces (zt<hex>, e.g. zt3jnfoa3b) were not shown in Status — pattern matched "zero" but ZeroTier uses "zt" prefix. Added "zt" to the interface filter regex.
- **UX:**    Extra VPN interfaces now show human-readable labels: Tailscale, ZeroTier, AmneziaWG, WireGuard, VPN (tun*) Format: "🌐 Tailscale (tailscale0): 100.x.x.x"

---

## v0.13.68

- **FIXED:** Alert flood — root cause was two bot instances running simultaneously. procd sends SIGTERM then SIGKILL, but watchdog subshell can survive. New singleton guard at startup: reads BOT_PID_FILE, kills stale instance + its subshells, writes own PID. Prevents duplicate watchdog processes each sending independent leaf-change alerts.
- **FIXED:** "Bot route: Initializing..." persisted because MAIN_ROUTE_FILE was only written on tier resolution, but watchdog starts in parallel and fires Check D before main loop resolves first route. Fix: write MAIN_ROUTE_FILE immediately after first successful api_request_fast at startup, before watchdog is forked.

---

## v0.13.67

- **FIXED:** Proxy names with flag emojis showed as raw xNN bytes. BusyBox printf does not support xNN escapes in %b. url_decode() rewritten to use awk (hex->octal conversion) + printf octal escapes, which works correctly on all OpenWrt variants for multi-byte UTF-8.
- **FIXED:** "Bot route: Initializing..." in Proxy switched alerts. Watchdog is a subshell and cannot see parent LAST_ROUTE_NAME updates. New MAIN_ROUTE_FILE (/tmp/podkop_bot_main_route): main process writes current route name there on every successful tier resolution (all sticky + full discovery paths). Check D reads from this file.
- **FIXED:** Proxy switched alert spam during URLTest failover (every few secs). Added 60s debounce: leaf-change alert fires at most once per minute. Rapid consecutive switches (e.g. URLTest probing dead servers) are logged but only the first triggers an alert per 60s window.

---

## v0.13.66

- **FIXED:** "Proxy switched" alert showed "From: main-urltest-out" (URLTest group tag) instead of the actual leaf proxy. Root cause: at watchdog startup URLTest .now is empty, so _resolve_leaf returned the group itself as last_leaf baseline. Fix: after _resolve_leaf, check the resolved node's type — if it's still a group (Selector/URLTest/ Fallback/LoadBalance), discard it and keep last_leaf unchanged. Only fully-resolved leaf proxies are stored as last_leaf.
- **FIXED:** "Bot route: Initializing..." in Proxy switched alert. Watchdog runs as a subshell and cannot see LAST_ROUTE_NAME from the parent process. Fix: _write_socks_state() now writes route_name= to SOCKS_STATE_FILE. Check D reads it via grep before sending the alert.

---

## v0.13.65

- **NEW:**   Bot Control Plane card now shows "Active Route" — the tier currently used by the bot to reach Telegram. Placed between Transport Policy and Fallback Route list so the operator immediately sees whether the bot is on tier1 (Podkop SOCKS5), tier2_N (Fallback SOCKS), tier4 (Direct), tier5 (Emergency IP) or still Initializing. No extra API calls needed — reads LAST_ROUTE_NAME which is always current.

---

## v0.13.64

- **FIXED:** Podkop version showed "Unknown" on OpenWrt 25.x (apk). All 5 version detection sites now try opkg first, fall back to apk. apk package name format: "podkop-0.7.x" -> strips "podkop-" prefix.
- **FIXED:** Main menu button showed "URL Test" in urltest mode instead of "Outbounds". Now consistent: selector/urltest both show "Outbounds".
- **FIXED:** Alert "Tunnel upstream DOWN/RECOVERED" was misleading — implied the VPN tunnel for router traffic was affected. Renamed to "Bot SOCKS upstream DOWN/RECOVERED" to clarify this is the bot's own transport path to Telegram, not the podkop/sing-box tunnel.

---

## v0.13.63

- **NEW:**   URLTest mode: Auto (best ping) button in Outbound Selector. Selector .now pointing at URLTest group = auto mode (sing-box picks fastest). Selector .now pointing at a leaf proxy = manual/fixed. Card header shows "| Auto: best ping" or "| Manual: fixed" hint. Auto button: grayed with checkmark when already auto, active button when manual is fixed — one tap returns to URLTest auto selection. Handler do_px_auto_urltest: PUT /proxies/selector with URLTest group name, detected via .proxies[*].type == "URLTest".
- **FIXED:** display_proxy_name now checks TAG_NAME_CACHE (built from all UCI link lists including urltest_proxy_links) before server:port fallback. URLTest outbound names now show #fragment human names (DE Senko -11d) instead of raw sing-box tags (main-4-out).

---

## v0.13.62

- **FIXED:** URLTest outbound names showed raw sing-box tags (main-4-out, main-urltest-out) instead of human names from #fragment in URI. Root cause: TAG_URI_CACHE (from sing-box config.json) has no
         #fragment; UCI_LINKS_CACHE only included selector_proxy_links. Fix: new TAG_NAME_CACHE (/tmp/podkop_tag_name_cache.txt) built from ALL UCI link lists (selector + urltest + url). Matches tag by server:port from TAG_URI_CACHE, stores tag=Human Name. display_proxy_name() now checks TAG_NAME_CACHE as step 2, before falling back to [type] server:port or raw tag.
- **FIXED:** build_all_caches() now includes build_tag_name_cache(). Section switch, link add/delete all trigger full cache rebuild. Lazy-init in get_selector_link_by_index unchanged (UCI only).

---

## v0.13.61

- **FIXED:** /start and text commands after clearing chat history returned no response. send_or_edit with user's message_id tried to edit user message (impossible) → silent fail. Plain text now passes empty mid so send_or_edit always sends a new bot message. Also fixes second admin /start in a fresh private chat.
- **FIXED:** Bot could stay on tier5 (Emergency IP) indefinitely even after fallback_socks recovered. tier5 sticky never probed SOCKS tiers while tier5 itself worked. Now: every 30s, tier5 sticky path tries _try_socks_tiers first. On success: switches back immediately. Timestamp tracked in SOCKS_REPROBE_TS_FILE (atomic, no watchdog dep).
- **FIXED:** Watchdog now sends IPC "up" every PROBE_EVERY cycles (default 5min) when LAST_ROUTE is tier4/tier5. Forces route reset so next request runs full discovery. Complements tier5 reprobe for tier4 case.

---

## v0.13.60

- **FIXED:** api_request_fast (button presses, sendMessage, editMessage) did not respect RECOVERY_MODE. After podkop stop, FAST route stuck on tier5 sticky and never probed tier2_N even when fallback SOCKS recovered. RECOVERY_MODE was only checked in api_poll_long (getUpdates). Fix: api_request_fast now probes SOCKS tiers first when RECOVERY_MODE>0, same as api_poll_long. On success: sets LAST_ROUTE_FAST, clears RECOVERY_MODE. This ensures button presses resume via fallback SOCKS as soon as a tier2_N becomes available after tunnel restart. NOTE:    In the test log, tier2_1 (192.168.2.238:18088) was genuinely down for ~2 minutes after podkop stop (xray was restarting). The bot correctly used Emergency IP during that window. Once tier2_1 recovered, the bot will now switch back via this fix.

---

## v0.13.59

- **UX:**    Renamed "Proxy Selector" to "Outbounds" / "Outbound Selector" throughout UI. Aligns with sing-box native terminology. Callback names (proxy_menu, cmd_proxy_add etc.) unchanged — only user-visible labels updated. No state/UCI changes. Affected: main menu button, card title, add prompts, URLTest screen. Display of proxy names (from #fragment in URI) unchanged — already works for all protocols (vless/hy2/ss/trojan/vmess/tuic).

---

## v0.13.58

- **FIXED:** Check A comment said "via full fallback cascade" but check_health() uses direct curl, not bot transport stack. Corrected to "direct reachability" — no behavior change, semantic fix only.
- **NEW:**   Proxy switched alert adds Mode (proxy_config_type) and Bot route. e.g. "Section: main | Mode: urltest / Bot route: Podkop (SOCKS5:...)"
- **NEW:**   sing-box RECOVERED now symmetric with STOPPED: PID, Section, Proxy (last known leaf), Bot route at recovery time.

---

## v0.13.57

- **FIXED:** SOCKS alert had double clash_request call (nested get_selector_tag inside another clash_request). Replaced with last_leaf variable already populated by Check D — zero extra curl calls.
- **FIXED:** Check D (leaf tracking) runs every cycle using a single clash_request to localhost:9090 — fast, no TG API calls. Baseline set on first read, no false alarm at startup.

---

## v0.13.56

- **NEW:**   Verbose watchdog alerts — all 3 types enriched with context: SOCKS DOWN/UP: primary endpoint, active proxy, bot route, fallback tier availability from last SOCKS_PROBE_FILE. sing-box STOPPED: section, last active proxy, bot route. sing-box RECOVERED: PID, section. TG unreachable: bot route, SOCKS state. TG reachable: bot route.
- **NEW:**   Proxy leaf change tracking (Check D in watchdog). Per-cycle snapshot of selector.now -> resolved leaf. Alert fires when sing-box auto-switches proxy (URLTest/Selector change). Format: [Host] 🎯 Proxy switched / From: X / To: Y / Section: Z Does not fire at startup — baseline set on first successful read.

---

## v0.13.55

- **FIXED:** do_del_fb debug logging removed (served its purpose in 0.13.54). do_del_fb handler is now clean: find by idx, del_list by value, verify, rebuild if del_list failed. ROOT CAUSE was in 0.13.54: "do_del_*" wildcard in proxy dispatch intercepted do_del_fb_* before it reached _handle_fallback_socks.

---

## v0.13.54

- **FIXED:** ROOT CAUSE of fallback SOCKS delete never working. dispatch pattern "do_del_*" in proxy block matched ALL do_del_ commands including do_del_fb_N, do_del_ul_N, do_del_utl_N. They all silently went to _handle_proxy which has no handler for them and returned without doing anything. Fixed: changed "do_del_*" to "do_del_px_*" — the only actual proxy deletion pattern. do_del_ul_* and do_del_utl_* already have their own dispatch entries further down.

---

## v0.13.53

- **FIXED:** probe_socks_latency and _probe_fast returned 0ms for dead proxies. curl returns time_total even on connection refused (fast fail ~0ms). Now checks HTTP response code: only 204 = alive, else "timeout". Dead proxies now correctly show "timeout" with red icon.
- **FIXED:** probe_socks_latency same issue — watchdog telemetry also showed 0ms as green in Tunnel Health Transport Latency section.
- **DEBUG:** do_del_fb now logs idx, total, value being deleted, and state after deletion to syslog. Also tries del_list by value first, then falls back to full rebuild if del_list failed (verification via grep after commit). This will reveal the root cause.

---

## v0.13.52

- **FIXED:** tier5 (Emergency IP) missing from sticky case in _route_request. After finding tier5, LAST_ROUTE_FAST=tier5 was set but next call found no matching case -> logged "sticky=tier5 miss" and ran full discovery every time. Infinite churn in log. Now tier5 sticky path skips SOCKS tiers and tries direct then emergency IPs directly.
- **FIXED:** sing-box stop did not send IPC down to main loop. Only sent alert. Result: LAST_ROUTE_FAST stayed tier1, sticky probed dead SOCKS every call, then fell to tier5 Emergency IP. Now: watchdog writes "down" to ROUTE_CMD_FILE on sing-box stop (triggers RECOVERY_MODE=4 + route reset). On sing-box recover, writes "up" (triggers route rediscovery). This is the root cause of bot being unresponsive after podkop stop.

---

## v0.13.51

- **FIXED:** Fallback SOCKS delete — after uci rebuild, called fallback_socks_menu with empty mid causing send_message instead of edit. Now passes "$mid" so existing card is updated in-place.
- **FIXED:** Fallback SOCKS add — redundant "Added." toast before menu refresh caused two separate messages. Removed toast, menu refreshes directly.
- **FIXED:** cmd_test_fb_socks used probe_socks_latency (8s timeout per endpoint). With 4 endpoints = up to 32s hang. Replaced with inline _probe_fast() using 3s connect / 5s max per endpoint. Max wait now ~20s for 4 tiers.

---

## v0.13.50

- **FIXED:** Fallback SOCKS delete did not work. uci del_list by value is unreliable on some OpenWrt builds. Now rebuilds the list: uci delete the whole key, then uci add_list for all entries except the deleted index. Reliable on all OpenWrt versions.
- **FIXED:** Duplicate check treated socks5:// and socks5h:// as different endpoints. Now normalizes to host:port before comparison.
- **NEW:**   "Test All" button in Fallback SOCKS menu — probes tier1 (Podkop) and all tier2_N via gstatic 204, shows latency per endpoint. cmd_test_fb_socks handler uses probe_socks_latency().

---

## v0.13.49

- **FIXED:** Proxy list and button format restored to original readable style. List: [idx] icon Name | Type | Delay — same as before. Button: human name only (no "· Type" suffix added in 0.13.48). The · separator was unnecessary and made buttons wider.

---

## v0.13.48

- **FIXED:** TSV update parsing caused field shift when callback_id empty. @tsv uses \t (shell whitespace) so consecutive empty fields collapse: user_id received "false" (is_bot value) -> auth failed. Switched to join("\u001f") + IFS=$(printf '\037') read. U+001F (Unit Separator) is never shell whitespace, empty fields safe.
- **FIXED:** Proxy Selector buttons showed "main-2-outHysteria20" (no separator). Button label now "Name · Type" with middle dot separator.
- **FIXED:** Proxy list showed "[0] 🔴 main-1-out | VLESS | 0 | | N/A" — extra pipe from empty delay. New format: [00] 🔴  N/A   main-1-out Delay left-padded to 5 chars in <code> for vertical column alignment.

---

## v0.13.47

- **FIXED:** ask_cmd_stop had no handler body in _handle_bot — button pressed but no confirmation dialog appeared. Added case with "Stop Podkop?" confirm / cancel screen before do_cmd_stop executes.
- **FIXED:** [Watchdog] SOCKS probe ok logged every cycle (~13s = 270 lines/hr). Now logs only on state change (ok->fail or fail->ok). Per-cycle spam suppressed. SOCKS fail always logged regardless.
- **NEW:**   Summary log every PROBE_EVERY cycles (default 5 min): [Watchdog] status: socks=up sb=running route=Podkop (SOCKS5:...) Replaces ok-spam with periodic health snapshot.

---

## v0.13.46

- **UX:**    Replaced all 17 <code>---...---</code> separators with <code>────────────────────</code> (20x U+2500 box-drawing). Monospace dashes (32 chars) wrapped to 2 lines on mobile; box-drawing at 20 chars fits single line on all screen widths.

---

## v0.13.45

- **NEW:**   Hostname prefix in all watchdog alerts for multi-router supergroup. All 4 alert types now start with [hostname]: [Router] sing-box STOPPED/RECOVERED [Router] ALERT: Bot SOCKS upstream DOWN/RECOVERED [Router] TG Connectivity: ... Hostname read once at watchdog startup from /proc/sys/kernel/hostname. Set per-router via: uci set system.@system[0].hostname=MyRouter

---

## v0.13.44

- **FIXED:** probe_all_socks_write() now includes tier3 (custom_proxy) in latency probe if set. Full transport picture: tier1 + tier2_N + tier3. Tunnel Health section renamed "Transport Latency" to reflect scope.
- **FIXED:** SOCKS_PROBE_FILE write is now atomic: tmp file + mv, same pattern as PUBIP_CACHE. Prevents partial reads by Tunnel Health display.
- **VERIFIED:** No stray trailing ' in printf format strings. All new strings from v0.13.38-43 end correctly with ' \\ (format close + line continuation). ChatGPT review was incorrect on this point.

---

## v0.13.43

- **NEW:**   mixed_proxy_port editor in Core Settings. Button shows current port, text input with 1024-65535 validation, reload on change. With confirmation via separate ask/do flow (port change requires reload — user sees "Applying..." before return).
- **NEW:**   outbound_interface editor in Core Settings. Shows current value (auto if unset), text input for UCI iface name, empty = delete (reset to auto). Reload on change.
- **NEW:**   URLTest Proxy Links editor (urltest_links_menu). Paginated list, add with protocol validation (same as selector_proxy_links), delete with confirmation. Accessible from URLTest Settings screen. Uses get_urltest_proxy_links() helper (eval "set --" pattern, handles = in URLs correctly).
- **NEW:**   get_urltest_proxy_links() — mirrors get_url_proxy_links() for the urltest_proxy_links UCI list key.

---

## v0.13.42

- **NEW:**   probe_socks_latency() — measures round-trip latency through any SOCKS endpoint using single HTTP probe to gstatic 204. Returns "Xms" or "timeout". No side effects on transport state.
- **NEW:**   probe_all_socks_write() — probes tier1 (Podkop SOCKS) and all tier2_N (fallback_socks list) in sequence, writes structured results to SOCKS_PROBE_FILE (/tmp/podkop_bot_socks_probe). Format: ts=<epoch>  tier1=<ms>  tier2_1=<ms> url=<endpoint>  ... Runs in background (&) to avoid blocking watchdog cycle.
- **NEW:**   Watchdog calls probe_all_socks_write every 5 health cycles (default every 5 minutes at 60s interval). Configurable via PROBE_EVERY. First probe runs at cycle 5 (not on startup) to avoid boot load.
- **NEW:**   Tunnel Health screen shows SOCKS Latency section with per-tier results: tier1 + all fallback_socks entries with icons and "probed Xm ago" timestamp. Shows "not yet probed" before first probe cycle.
- **FIXED:** socks5h:// now accepted in Fallback SOCKS validator (v0.13.41).

---

## v0.13.41

- **FIXED:** Fallback SOCKS validator rejected socks5h:// protocol. socks5h:// is critical under RKN: DNS resolves through the proxy tunnel instead of locally (prevents DNS poisoning/blocking). Regex changed from ^socks5:// to ^socks5h?:// to accept both. Error message updated to show both formats and explain the difference.

---

## v0.13.40

- **FIXED:** ask_set_tr_menu / ask_set_tr_* / do_set_tr_* were caught by the generic ask_* catchall in the main router before reaching _handle_bot. Result: pressing "Transport: Auto" showed "Confirm Action set_tr_menu?" instead of the transport selector screen. Fixed by adding explicit dispatch entries before the ask_* fallthrough.
- **FIXED:** delete_message() called with empty string mid caused jq error: "string ("") cannot be parsed as a number". Happened after cmd_upstream_health / cmd_run_podkop_tests which call _handle_bot "cmd_runtime" "" "" "" (empty mid on return path). Added guard: [ -z "$1" ] return 0; numeric check before jq call.
- **UX:**    Bot Settings shows a migration hint when custom_proxy is a socks5:// URL, suggesting to move it to Fallback SOCKS (tier2) for correct failover ordering. The Fallback SOCKS button is directly below.

---

## v0.13.39

- **NEW:**   Support Bundle (cmd_support_bundle) — one button in Runtime Info collects and sends a single .txt file containing: hostname/versions, active section, podkop/sing-box status, full UCI config (bot_token/chat_id redacted), ip route/rule, nft podkop rules, network interfaces, public IP cache, bot transport state (LAST_ROUTE_FAST/POLL/RECOVERY_MODE, SOCKS_STATE_FILE contents), last 80 lines of podkop syslog. Sends via api_document, returns to Runtime Info on completion. Does not duplicate or replace existing individual export buttons (Podkop Config, Sing-box JSON, Syslog, Upstream Health, etc.)

## v0.13.38 — P1 LuCI Coverage

- **NEW:**   Mixed Proxy toggle (mixed_proxy_enabled) in Core Settings. Shows current port, ask/confirm before toggle, reloads on change.
- **NEW:**   URLTest Settings screen (urltest_testing_url, urltest_check_interval, urltest_tolerance) — editable per-section via text input with format validation. Accessible from Core Settings button.
- **NEW:**   Domain Resolver per-section screen (domain_resolver_enabled, domain_resolver_dns_type, domain_resolver_dns_server). Toggle, cycle DNS type (udp/doh/dot), set server via text input.
- **NEW:**   Bad WAN Details screen — expands existing toggle with badwan_monitored_interfaces (space-separated, text input) and badwan_reload_delay (seconds, validated). Toggle button reuses do_toggle_wan so main Core Settings stays in sync.
- **NEW:**   Routing Excluded IPs (routing_excluded_ips) in Routing & Lists. Same UX as Fully Routed IPs: list, add/remove with validation, reload on change. excl_ips_edit / del_excl_* / cmd_add_excl_ip.
- **NEW:**   _handle_section_extras() — new handler for URLTest/DR/BadWAN. STATE_INPUT dispatch covers 6 new wait_ states.

---

## v0.13.37

- **FIXED:** flock FD 200 replaced with FD 9 in uci_commit_safe() and safe_reload_podkop(). FD 200 is non-standard and causes sh -n (dash) parse failure. FD 9 is conventional for advisory locks.
- **FIXED:** cmd_dns_server had unescaped JSON as third arg to send_or_edit. Shell parsed closing " of printf string as end of arg, leaving inline_keyboard JSON unquoted — Telegram rejected with 400. Fixed with proper backslash-escaped JSON and multiline call.
- **FIXED:** Delete buttons in url_links_menu and fallback_socks_menu used literal "X" instead of ${E_DEL}. Now consistent with rest of UI.
- **FIXED:** api_document() did not respect transport policy for fallback_socks and custom_url tiers. In "direct" mode these SOCKS tiers were still attempted. Restructured into policy != "direct" / policy != "socks" blocks matching the semantics of _try_all_tiers().
- **PERF:**  Main loop update parsing: replaced 12 separate jq forks per update with a single jq @tsv call + shell read. On MIPS routers this eliminates ~11 process spawns per button tap (~0.5-1s latency saved). Text field newlines preserved via printf '%b' on @tsv-encoded value.

---

## v0.13.36

- **FIXED:** Transport Policy change (Auto/Socks/Direct) was applied instantly on button tap with no confirmation. Switching to "socks" or "direct" under active RKN blocks could permanently break bot connectivity (bot loses Telegram and can't recover without physical access). Fix:   Three-step confirmation flow: 1. "Transport: Auto" button -> ask_set_tr_menu (mode selector screen) 2. User picks Auto/Socks only/Direct only -> ask_set_tr_<mode> (confirmation screen with mode-specific risk warning) 3. Confirm -> do_set_tr_<mode> (apply + return to Bot Settings) If new mode == current mode, skips confirmation and returns directly. "socks" and "direct" show E_WARN + explicit consequence description. "auto" shows E_OK (safe choice, still requires confirm for symmetry).

---

## v0.13.35

- **FIXED:** Missing local declarations — variables leaked into global scope: * run_upstream_health_report(): added leaf_n to local list. Was assigned in the while-read loop but not scoped, risking pollution across calls. * cmd_status case: added pub_ip_display to local list. Read from cache and used in heredoc text but declared globally. * cmd_runtime case: added active_leaf to local list. Assigned via _resolve_leaf() call but not scoped, could bleed into next handler.

---

## v0.13.34

- **FIXED:** refresh_public_ip_cache() lockfile used $$ which in a background subshell (&) always returns the PARENT process PID, not the subshell. If the subshell died (OOM kill, segfault), kill -0 $lock_pid would succeed forever (parent is alive) — permanent lock until bot restart. Fix:   Replaced file-based lock with atomic mkdir lock. mkdir is a single POSIX syscall with link(2) semantics — either succeeds or fails atomically, no race. Lock is a directory (PUBIP_REFRESH_LOCK now ends in .lockdir) so rm -rf cleans it. Added 5-minute stale-lock timeout: if lockdir mtime > 300s old, it is force-removed and re-acquired (covers crash/OOM scenario without leaking the lock forever). trap updated to use rm -rf for the lockdir on bot exit.

---

## v0.13.33

- **FIXED:** Critical architectural bug — watchdog subshell cannot modify parent process variables. In v0.13.28 watchdog wrote LAST_ROUTE_FAST="unknown" and RECOVERY_MODE=4 directly, but as a subshell ( ... )& it only changed its own copy. Main polling loop never saw the reset. Fix:   IPC via ROUTE_CMD_FILE (/tmp/podkop_bot_route_cmd). Watchdog writes "down" or "up" to the file instead of modifying vars. _route_request() reads the file at the top of every call (both api_request_fast and api_poll_long paths), acts on it immediately, then deletes the file. One file = one atomic signal per event. On "down": LAST_ROUTE_FAST/POLL/LAST_ROUTE="unknown", RECOVERY_MODE=4. On "up":   same reset + RECOVERY_MODE=0 (tier1 rediscovery on next poll).
- **FIXED:** Dead code in cmd_tunnel_health: wd_route and wd_last_ok were parsed from SOCKS_STATE_FILE but never used in the output template. Removed the two grep calls and the variable declarations.
- **NEW:**   ROUTE_CMD_FILE constant + added to trap cleanup.

---

## v0.13.32

- **FIXED:** api_document() declared twice (regression from P1 overhaul merge). Old 4-tier version (lines ~880-941) that wrote to global LAST_ROUTE was silently overwriting the new isolated version (LAST_ROUTE_DOC). Deleted the old duplicate. Only the new version (line ~601) remains.
- **FIXED:** _route_request() tier2_* sticky path: for-loop iterator variable retained last value when break never fired (index out of range). Fixed by using separate _item iterator + _fb="" result variable, only assigned on successful break. Prevents stale fallback_socks endpoint being used after list shrinks below cached tier index. Same fix applied consistently (get_tg_latency already used correct pattern with explicit _fb_url="" reset inside loop body).
- **FIXED:** Stray spaces inside case pattern in handle_command() router: "set_update_int_*|        conn_type_menu" cleaned to proper pipe- delimited pattern without embedded whitespace.

---

## v0.13.31

- **FIXED:** Health alert / menu interleaving. When watchdog sends an alert (sing-box down, SOCKS down, TG connectivity change), the alert message pushed the active menu card up in chat. Next user action edited the buried card — user saw stale menu below the alert. Fix:   send_message() now captures and saves the sent msg_id to LAST_MENU_MSG_FILE. send_health_alert() (new helper wrapping watchdog sendMessage calls) saves the alert msg_id to LAST_ALERT_MSG_FILE. send_or_edit() compares the two: if alert is newer than menu, it deletes the buried menu card and sends a fresh one at the current chat position (below the alert), then clears LAST_ALERT_MSG_FILE so subsequent edits work normally.
- **FIXED:** refresh_public_ip_cache() bare wait replaced with explicit PID wait (p1/p2/p3) — same pattern as cmd_all_delay_test fix.

---

## v0.13.30

- **FIXED:** refresh_public_ip_cache() bare wait replaced with explicit PID wait. Three curl PIDs (p1/p2/p3) now collected before wait, then waited with "wait $p1 $p2 $p3". Prevents hang if function call context ever inherits background processes from outer shell. Mirrors the same fix previously applied to cmd_all_delay_test.
- **VERIFIED:** No local declarations in global while-loop scope (main poll loop starts at line 3831+). Unauthorized-access block and audit block use bare assignments — correct for global scope in POSIX ash.

---

## v0.13.29

- **FIXED:** get_tg_latency() tier2_* now resolves actual fallback SOCKS endpoint by index from UCI list instead of incorrectly using custom_proxy. Previously tier2_N fast-route showed wrong latency or Timeout when bot was actually running on a fallback SOCKS, not custom_proxy.
- **FIXED:** api_document() sticky-path comment removed — function intentionally uses full cascade (no sticky) for multipart uploads. LAST_ROUTE_DOC is set for diagnostics only and does not affect FAST/POLL routing.
- **FIXED:** Bot Settings tr_hint updated to reflect actual tier order: Podkop SOCKS -> Fallback SOCKS (tier2_N) -> Custom -> Direct -> Emergency. Previous hint omitted fallback_socks tiers entirely.

## v0.13.28 — P1 Transport Overhaul

- **NEW:**   api_request_fast() — dedicated fast path for sendMessage/edit/ answerCB/deleteMessage: connect-timeout 2s sticky/3s full, max 8s.
- **NEW:**   api_poll_long() — dedicated poll path for getUpdates: connect- timeout 3s sticky/4s full, max 65s. Never shares state with fast.
- **NEW:**   LAST_ROUTE_FAST / LAST_ROUTE_POLL / LAST_ROUTE_DOC — split route tracking. api_document() no longer poisons fast/poll route state.
- **NEW:**   Tier 2_N: UCI list fallback_socks (podkop_bot.settings.fallback_socks) tried in order between Podkop SOCKS and custom_proxy. Old tiers renumbered: tier3=custom, tier4=direct, tier5=emergency.
- **NEW:**   RECOVERY_MODE counter (0-4): after All transports FAILED, next 4 poll cycles aggressively probe SOCKS tiers before falling to direct.
- **NEW:**   probe_socks_upstream() — 3 probe endpoints (gstatic x2 + cloudflare). Reduces false "SOCKS down" from single-endpoint block.
- **NEW:**   Anti-flap hysteresis 2/2 for both SOCKS and TG alerts: alert fires only after 2 consecutive same-state probes.
- **NEW:**   Structured SOCKS_STATE_FILE (tg/socks/route/last_ok key=value). Tunnel Health screen reads and displays split TG/SOCKS state.
- **NEW:**   Fallback SOCKS manager in Bot Settings: add/view/remove entries (UI: Bot Settings -> Fallback SOCKS button).
- **FIXED:** check_health() uses direct curl, not bot's own transport stack, to avoid interfering with LAST_ROUTE_FAST/POLL during checks.
- **FIXED:** Tunnel Health shows Poll/Fast route keys separately.
- **FIXED:** startup notify uses api_request_fast, logs fast route on connect.

---

## v0.13.27

- **FIXED:** Separator lines wrapped in <code>...</code> tags so Telegram renders them in monospace font - dashes are now uniform width and visually span the full message width alongside bold/emoji content. All 13 heredoc separators + 1 inline printf separator updated.

---

## v0.13.26

- **STYLE:** Separator lines extended to 32 dashes (was 21) to visually span full message width in Telegram proportional font alongside emoji content. Covers all 13 heredoc separators + 1 inline printf separator.

---

## v0.13.25

- **FIXED:** url_proxy_links parsing hardened - replaced heuristic "grep | cut -d= | tr -d '" with get_url_proxy_links() helper using eval "set --" on UCI shell-quoted output. Correctly handles = signs inside URLs (base64 padding in vless/vmess, query params). Affected: url_links_menu list load, ask_del_ul_*, do_del_ul_*, and duplicate check on add.
- **NEW:**   get_url_proxy_links() helper function (mirrors build_uci_links_cache pattern already proven for selector_proxy_links).
- **STYLE:** ASCII separator lines extended from 14 to 21 dashes for better visual separation in Telegram messages.

---

## v0.13.24

- **NEW:**   proxy_config_type=url (URL Connection) full support in bot: view list of links, add new link, remove by index, reload on change. Proxy menu button switches label to "URL Links" in this mode.
- **NEW:**   proxy_config_type=outbound (Outbound Config) shows info screen: warns user to use LuCI/console for JSON editing, links to LuCI.
- **FIXED:** main_menu "Proxy Selector" button is now mode-aware: shows "Proxy Selector" (selector), "URL Test" (urltest), "URL Links" (url), "Outbound" (outbound) so user always sees current mode.
- **FIXED:** Status screen Mode: field shows human-readable label instead of raw UCI value.

---

## v0.13.23

- **FIXED:** Header/CHANGELOG version synced to BOT_VERSION (was stuck at 0.13.21)
- **FIXED:** Tunnel Health keyboard had spurious "Menu" button (duplicate nav); now shows only Refresh + Back, consistent with other detail screens
- **FIXED:** Last reload reads sing-box process start time from /proc/PID/stat when RELOAD_TS_FILE is absent (covers LuCI/console reloads, not just bot)
- **NEW:**   Connection Type selector (proxy/vpn/block/exclusion) in Core Settings
- **NEW:**   Active proxy line added to Tunnel Health from Clash API
- **FIXED:** ASCII hygiene - em-dashes replaced with ASCII hyphens in runtime strings (logger lines, verdict text, bot HTML output)

---

## v0.13.21

- **FIXED:** cmd_all_delay_test hung forever (wait without args caught HEALTH_PID) Now uses explicit per-PID wait loop, max 10 concurrent clash_request
- **FIXED:** build_uci_links_cache reverted to eval "set --" (uci get N broken on BusyBox)
- **FIXED:** remote_domain_lists / remote_subnet_lists display reverted to eval
- **FIXED:** wan_ip removed blocking curl to api.ipify.org in cmd_status (was 4s delay) Replaced with ip route + uci get network.wan.ipaddr (instant)
- **FIXED:** get_tg_latency removed from main_menu (was 3s delay every open)
- **NEW:**   Tunnel Health screen (from Runtime Info) - nftables rules, sing-box RAM, last reload time, section mode, active community lists, WAN iface
- **NEW:**   proxy_config_type switch (selector <-> urltest) with mandatory confirm
- **NEW:**   user_domains_text line editor: view paginated, add line, remove by index
- **NEW:**   user_subnets_text line editor: same as domains
- **NEW:**   Sections menu: active section shown in header only (no spinning button)
