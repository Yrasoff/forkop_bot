# История изменений

---

## v0.15.2 (текущая)
- **НОВОЕ:** Поддержка NetShift — podkop-evolution переименован в NetShift (`/usr/bin/netshift`, UCI namespace `netshift`). `_detect_podkop_variant()` проверяет `/usr/bin/netshift` до обращения к бинарю `podkop`; конфиг варианта задаёт `PODKOP_UCI=netshift`, `PODKOP_BIN=/usr/bin/netshift`, `PODKOP_GITHUB_REPO=yandexru45/netshift`. Схема UCI идентична evolution (`connection_type`, `proxy_config_type`, `subscription_url`); вся variant-aware логика переиспользуется без изменений. Путь кэша подписки исправлен на `/etc/netshift/subscriptions/<sec>.json`.
- **ИСПРАВЛЕНО:** На Podkop Plus не читалось поле `domain_ip_lists` — актуальный LuCI Plus пишет внешние URL-списки в `domain_ip_lists` («Domain and IP Lists»), а не в `remote_domain_lists`. Бот читал только `remote_domain_lists`, поэтому списки добавленные через LuCI показывались как «No lists configured». Исправлено: на Plus бот читает оба поля (объединяет для отображения) и пишет новые записи в `domain_ip_lists`. На original/evolution/netshift поведение `remote_domain_lists` не изменилось.
- **ИСПРАВЛЕНО:** Флаг `-4` добавлен на прямую ветку `_curl_via_best_socks` — устраняет зависание на AAAA DNS при каждом GitHub-запросе перед переходом на SOCKS. Исправляет зависание проверки обновлений под DNS-редиректом podkop.
- **ИСПРАВЛЕНО:** `-4` на прямых ветках проверки GitHub (`api.github.com`, `raw.githubusercontent.com`) — результат "direct" в Tunnel Health теперь отражает реальную TCP-достижимость, а не таймаут AAAA.
- **НОВОЕ:** Предварительная проверка `_pkg_net_check` — перед запуском `install.sh` при обновлении podkop проверяется доступность сети (IPv4); возвращает "Package network unreachable" вместо молчаливого зависания opkg/apk.
- **НОВОЕ:** Временный редирект `/etc/resolv.conf` на публичный IPv4 DNS при установке podkop — позволяет opkg/apk резолвить хосты без зависания на AAAA; исходный конфиг восстанавливается атомарно через trap.
- **ИСПРАВЛЕНО:** Бесконечная рекурсия в `cmd_status` при разрешении маршрута — `cmd_status` и `/status` теперь отдельные ветки; добавлен счётчик глубины в `_resolve_leaf` против циклических ссылок.
- **UX:** Status — публичный IP скрывается если не резолвится (убран мусорный `· Unavailable`); метка RAM унифицирована; модель устройства перенесена в Runtime Info.
- **UX:** Список Outbounds — каждая кнопка показывает `[idx] ▶/● имя` с задержкой.
- **НОВОЕ:** Интеграция Plus CLI — хелперы `_plus_has_cmd()` (определяет команды через grep диспетчера CLI, а не неполный `show_help`), `_plus_json()`, `_plus_format_sub_meta()` для всех Plus-специфичных вызовов.
- **НОВОЕ:** Интеграция `get_system_info` — версии и наличие обновления (`podkop_latest_version ≠ podkop_version` → "→ X.X.X available") в Status и Maintenance; версии zapret/byedpi при их наличии; fallback на `opkg info` для original/evolution.
- **НОВОЕ:** `get_subscription_metadata` — использование трафика и срок действия (`📊 3.2/50 GB · exp 15.07`) в главном меню для подписочных секций Plus.
- **НОВОЕ:** `get_outbound_link_states` — серверы, отфильтрованные urltest-фильтрами по стране/regex, помечаются `⊘` в списке прокси.
- **НОВОЕ:** Кнопка `close_all_connections` в Runtime Info (только Plus, через `clash_api`).
- **НОВОЕ:** Меню секций Zapret/ByeDPI — статус (запущен, версия), toggle вкл/выкл, редактирование стратегии с предварительной валидацией через `validate_nfqws_strategy_json`/`validate_byedpi_strategy_json`. `section_settings` автоматически редиректит zapret/byedpi-секции в своё меню.
- **НОВОЕ:** Меню URLTest Filters (`🔬 URLTest Filters (country/regex)`) — `urltest_filter_mode`, `detect_server_country`, `urltest_hide_filtered_outbounds`, списки стран и outbounds. Показывает реальные имена исключённых outbounds (первые 3 + счётчик) вместо просто числа.
- **НОВОЕ:** `_utf_postcheck_warn()` — после применения urltest-фильтров проверяет через Clash `/proxies` остались ли серверы в URLTest-группе; предупреждает если фильтр убрал все серверы. Привязан к конкретной секции (не глобальный первый селектор).
- **ИСПРАВЛЕНО:** Все write-хендлеры DPI/urltest (`do_dpi_toggle_*`, `do_utfilter_*`) защищены проверкой `[ "$PODKOP_VARIANT" = "plus" ]` — залипшая старая кнопка на non-Plus не может случайно отключить секцию.
- **НОВОЕ:** Блок GitHub Connectivity в Tunnel Health — проверяет `api.github.com` и `raw.githubusercontent.com` напрямую (через WAN, обходит fakeip) и через SOCKS; показывает `✅ Xms` / `❌ unreachable` для каждого пути.
- **НОВОЕ:** Единая точка входа в диагностику — Runtime Info → одна кнопка `Diagnostics`; хаб `cmd_diagnostics` содержит Tunnel Health+GitHub, Probe, Proxy Latency Test, Internal Diag, Support Bundle.
- **НОВОЕ:** `_in_tg_range()` — glob-проверка принадлежности IP к CIDR-префиксам Telegram (AS62041, все 10 префиксов, граница 95.161.64/20 корректна).
- **НОВОЕ:** `resolve_tg_emergency_ips()` — параллельный DoH-запрос к 1.1.1.1, 8.8.8.8, dns.quad9.net через WAN+`--noproxy`; валидация IP через `_in_tg_range` (защита от DNS-poisoning); обновляет `TG_EMERGENCY_IPS` в памяти каждые 6 часов и при входе в tier5.
- **ИСПРАВЛЕНО:** Определение SOCKS inbound расширено до `mixed|socks|socks5` в `_load_transport_ctx` и `get_proxy_ip`.
- **НОВОЕ:** Модель устройства в Status и Maintenance — читает `device_model` из `get_system_info` (Plus), fallback на `/tmp/sysinfo/model`; значение `"unknown"` от Plus игнорируется в пользу fallback.
- **НОВОЕ:** Reply keyboard — постоянная нижняя клавиатура `🏠 Menu | 📊 Status`; устанавливается один раз за сессию через `install_reply_keyboard_once`; nav escape в state machine (очищает STATE_FILE, выходит в Menu/Status); `/status` как slash-команда.
- **НОВОЕ:** Подтверждение переключения секции — `set_sec_X` показывает "Switch to X? Podkop will reload" перед действием; `do_set_sec_X` выполняет переключение.
- **ИСПРАВЛЕНО:** Watchdog — алерт "Telegram reachable" читает `MAIN_ROUTE_FILE` вместо `LAST_ROUTE_NAME` (в subshell всегда "Initializing…"); пустое/Initializing → "via SOCKS (recovered)".
- **ИСПРАВЛЕНО:** Watchdog — алерт auto-switch: иконка `🔀`, компактный формат `🔀 old → new (urltest)`; дебаунс 120 сек группирует частое переключение в `🔀 Proxy switched ×N in Xm`.
- **ИСПРАВЛЕНО:** Watchdog — `_recovery_ts` подавляет дублирующий алерт "Telegram reachable" в течение 30 секунд после "Primary SOCKS recovered".
- **ИСПРАВЛЕНО:** `cmd_get_config` использует `/etc/config/${PODKOP_UCI}` — был хардкод `/etc/config/podkop`, ломал Config & Logs на Plus.
- **UX:** URL подписки показывается в меню Outbounds для подписочных секций (первые 3 URL, обрезаны до 60 символов).
- **ИСПРАВЛЕНО:** Dispatch URLTest Filters — `urltest_filters_menu` и `do_utfilter_*` правильно роутятся в `_handle_section_extras` (был ошибочно `_handle_settings` → молчаливый no-op).
- **ИСПРАВЛЕНО:** Валидатор протоколов приведён в соответствие с Plus-парсером: `ss, vmess, vless, trojan, hy2, hysteria2, socks, socks4, socks4a, socks5`; `tuic` убран (не поддерживается Plus-парсером).
- **UX:** Экран Routing & Lists переименован — `FR IP → Device → Tunnel (➡️)`, `Excl IP → Device → Bypass (↩️)`, `R-Domain → Domain List URL`, `R-Subnet → Subnet List URL`, `Custom Domains/Subnets → My Domains/Subnets`, `Community Lists → Service Lists`; добавлена легенда "Что направлять в туннель, а что мимо".
- **ИСПРАВЛЕНО:** `section_is_subscription` и `get_section_type` используют `uci show` вместо `uci get` для list-поля `subscription_urls` — BusyBox ash `uci -q get` возвращает пустоту для list-полей.
- **ИСПРАВЛЕНО:** `get_subscription_urls` использует `sed`-парсинг вывода `uci show`; отображение строится через `awk` во избежание потери переменных в subshell ash при `while+pipe`.

---

## v0.15.1

- **НОВОЕ:** `section_settings` и `global_settings` — `advanced_settings` разделён на per-section и global экраны; `advanced_settings` оставлен как redirect для обратной совместимости.
- **НОВОЕ:** Экран `cmd_maintenance` — версии, Check Update, Restart Bot, ссылка на GitHub releases для каждого варианта.
- **НОВОЕ:** `cmd_info` редиректит в `cmd_status`.
- **НОВОЕ:** DNS перемещён в Global Settings; убран из Section Settings.
- **НОВОЕ:** `log_level` убран из UI бота → notice "Use LuCI or SSH".
- **НОВОЕ:** Управление YACD secret/WAN убрано из бота → notice; остался только toggle вкл/выкл.
- **НОВОЕ:** Рефакторинг Status — агрегированный заголовок-диагноз (`✅ работает` / `⚠️ с ограничениями` / `🟡 на fallback` / `❌ требует внимания`); человекочитаемый блок Connectivity; блок Bot route с метками тиров; footer с версиями.
- **НОВОЕ:** Хелперы `_status_severity()` и `format_age()`.
- **ИСПРАВЛЕНО:** `do_switch_mode_*`, `do_set_conn_*`, `do_toggle_mixed` возвращают в `section_settings` (не `global_settings`).
- **ИСПРАВЛЕНО:** `wait_outbound_iface` возвращает в `global_settings`; `wait_vpn_iface` в `section_settings`.
- **ИСПРАВЛЕНО:** Dispatch: `section_settings/global_settings` → `_handle_settings`; `cmd_maintenance` → `_handle_bot`; `dns_settings` → `_handle_dns` (были ошибочно объединены в один блок).

---

## v0.15.0 - добавлен дектект и частичная поддержка функционала форков - Podkop Plus, Evolution. 

- **НОВОЕ:** `_detect_podkop_variant()` — автодетект original/evolution/plus; устанавливает `PODKOP_VARIANT`, `PODKOP_UCI`, `PODKOP_BIN`, `PODKOP_INIT`, `PODKOP_PKG`, `PODKOP_GITHUB_REPO`, `PODKOP_DISPLAY_NAME`.
- **НОВОЕ:** `set_section_action()` — пишет `action` (Plus) или `connection_type` (original/evolution); маппит `exclusion→direct` для Plus.
- **НОВОЕ:** `get_section_type()`, `_get_wan_interface()`, `section_is_subscription()`, `_variant_has_subscription()`, `get_subscription_cache_path()`.
- **ИСПРАВЛЕНО:** Ложный `direct ✅` — проверка через `--interface WAN --noproxy '*'` для обхода fakeip-маршрутизации.
- **ИСПРАВЛЕНО:** Plus urltest-флаг — читает/пишет `urltest_enabled` вместо `proxy_config_type=urltest`.
- **ИСПРАВЛЕНО:** Запись прокси-ссылок на Plus всегда идёт в `selector_proxy_links` (`urltest_proxy_links`/`proxy_string` — поля только для миграции, стираются Plus при загрузке).
- **ИСПРАВЛЕНО:** При добавлении в `*_text`-списки выставляется `user_domain_list_type=text` / `user_subnet_list_type=text` (оба варианта — поля игнорируются при list_type≠text).
- **ИСПРАВЛЕНО:** `conn_type_menu` показывает `Direct` вместо `Exclusion` на Plus; `do_switch_mode_url/outbound` заблокированы на Plus с уведомлением.

## v0.14.4

- **ИСПРАВЛЕНО:** На некоторых прошивках `opkg` возвращает версию с префиксом `v` (например, `v0.7.14-r1`). Пайплайн убирал суффикс `-r1` через `cut -d'-' -f1`, но оставлял `v`, в результате чего получалось `v0.7.14`. При арифметическом сравнении `v0` vs `0` shell выдавал `Illegal number`, `_upd` оставался 0, и бот всегда показывал «Up to date» вне зависимости от реальной версии. Исправлено добавлением `sed 's/^v//'` в пайплайны для `opkg` и `apk`. Аналогичная очистка уже была добавлена в `cmd_check_update` (в v0.14.2), однако отсутствовала в четырёх других точках чтения `p_ver`: `_handle_status` (экран Status), `cmd_info` (экран Info), `cmd_diag` (экспорт диагностики) и уведомление при запуске. Все пять точек теперь унифицированы.
- **ИСПРАВЛЕНО:** `cmd_check_update` вызывал `_curl_socks_fallover` — имя, которого не существует. Единственная curl-обёртка называется `_curl_via_best_socks` (введена в v0.14.3). Вызов немедленно возвращал пустой вывод, `latest` оказывался пустым, и обработчик завершался с «❌ Cannot reach GitHub» без единого сетевого запроса. **Причина возникновения:** в описании задачи для v0.14.4 была опечатка — `_curl_socks_fallover` вместо `_curl_via_best_socks`; код был написан дословно по этому описанию. Исправлено заменой на `_curl_via_best_socks` — как в `cmd_check_update_bot` и скачивании самообновления (строки 6508, 6516, 6581).
- **ИСПРАВЛЕНО:** `do_update_podkop` — три взаимоусиливающих проблемы приводили к вечному зависанию на «Downloading update...» без какой-либо обратной связи: (1) скачивание шло через `wget` напрямую, а не через `_curl_via_best_socks` — при заблокированном `raw.githubusercontent.com` загрузка молча падала; (2) `install.sh` запускался в фоне (`&`) — бот не ждал завершения и никогда не сообщал результат; (3) лог `/tmp/podkop_update.log` писался, но никогда не читался и не отправлялся. Переписано: скачивание через `_curl_via_best_socks` с явным сообщением об ошибке, `install.sh` выполняется синхронно, по завершении отправляются последние 20 строк лога с кодом выхода; при успехе показывается новая установленная версия.

## v0.14.3

- **NEW:** Runtime Info — добавлена строка `⏱ Session: Xh Xm` между блоком трафика и блоком прокси. Показывает время работы текущей сессии sing-box — контекст для цифр Downloaded/Uploaded. Источник тот же что в Tunnel Health: `RELOAD_TS_FILE`, fallback на `/proc/PID/stat`. Без дополнительных curl-запросов.
- **UX:** Bot Settings — кнопка `👤 Admins` перенесена из отдельной строки в нижнюю строку рядом с `🏠 Menu`. Убирает визуальный разрыв между функциональными кнопками (Fallback SOCKS, Custom Proxy, Notify) и служебной навигацией.
- **НОВОЕ:** Фейловер GitHub через SOCKS — проверка версии и самообновление теперь используют `_curl_via_best_socks`: сначала прямое соединение, затем tier1 (Podkop SOCKS), затем каждый tier2_N по порядку. Устраняет ошибку «Cannot reach GitHub» когда raw.githubusercontent.com заблокирован провайдером. Если использовался прокси — маршрут отображается в карточке результата (прямое соединение — молча).
---

## v0.14.2

- **ИСПРАВЛЕНО:** `outbound_interface` — бот читал и писал `podkop.${sec}.outbound_interface` (поле в секции), которое podkop 0.7.x не читает. Реальные поля: `podkop.settings.output_network_interface` (глобальное) и `podkop.settings.enable_output_network_interface`. Исправлено во всех 5 местах: при сохранении выставляется `enable=1`, при сбросе — `enable=0`. Карточка и подсказка помечены `(global)`.
- **ИСПРАВЛЕНО:** `connection_type=vpn` без заданного `interface` — podkop завершался с «VPN interface is not set. Aborted» при reload. Добавлен гард в `do_set_conn_vpn`: если `podkop.${sec}.interface` не задан, бот сохраняет тип в UCI, ставит `wait_vpn_iface` и **держит reload** до ввода имени интерфейса. Симметрично защите `url`-режима. Кнопка «Cancel — revert to Proxy» откатывает без reload.
- **ИСПРАВЛЕНО:** Defense-in-depth при переключении режима прокси — `do_switch_mode_urltest` и `do_switch_mode_selector` теперь повторно проверяют список ссылок **на стадии выполнения** (не только на стадии ask). При пустом списке — «Refused» с контекстными кнопками, reload не выполняется, podkop не падает. Ранее пользователь мог проигнорировать предупреждение и вызвать fatal abort.
- **ИСПРАВЛЕНО:** Сравнение версий podkop (`cmd_check_update`) — GitHub-теги вида `0.7.14-r1` не очищались от суффикса, `[ "14-r1" -gt "10" ]` давал «Illegal number», бот всегда показывал «Up to date» даже при устаревшей версии. Исправлено `| cut -d'-' -f1` для `latest`.
- **ИСПРАВЛЕНО:** После клонирования URLTest→Selector при `_added=0` и `_skipped>0` — сообщение заменено на явное «already up to date» вместо «Cloned 0 links».
- **ИСПРАВЛЕНО:** После смены режима прокси явно удаляются все три кэша перед `safe_reload_podkop` — устаревшие имена прокси больше не отображаются.

---

## v0.14.1

- **КРИТИЧЕСКИЙ ФИКС:** `eval "set -- $(uci_list_clean \"$var\")"` — все 33 вхождения этого паттерна заменены на двухшаговый `{ _ucl=$(uci_list_clean "$var"); eval "set -- $_ucl"; }`. Встроенная форма `$(...)` вызывала ошибку `sh: eval: Syntax error: Unterminated quoted string` в ash при любом UCI-списке, содержащем значения в одинарных кавычках (а все списки `*_proxy_links` именно так и выглядят). Сбой eval аварийно завершал весь subshell с кодом 2, что приводило к: (1) `build_tag_name_cache` не заполнялся → пустые имена прокси в Outbounds, алертах, уведомлении о запуске; (2) subshell `send_startup_notification_async` умирал до отправки уведомления; (3) добавление/удаление/подсчёт прокси молча падало в режиме URLTest.
- **ИСПРАВЛЕНО:** Порядок инициализации при запуске — `ACTIVE_SECTION_FILE` теперь создаётся **до** запуска `send_startup_notification_async &` и `start_health_daemon`. Раньше кэши строились для `main` (дефолтный фоллбек) даже когда основная секция пользователя имела другое имя.
- **ИСПРАВЛЕНО:** Бесконечный цикл обновления — после консолидации файлов в `BOT_DIR` путь к `OFFSET_FILE` изменился с `/tmp/podkop_bot_offset` на `/tmp/podkop_bot/offset`. При первом старте новый путь не существовал → offset сбрасывался в 0 → Telegram повторно доставлял старые обновления, включая callback `do_update_bot_0.14.1` → бот скачивал себя и перезапускался снова и снова. Исправлено двумя защитами: (1) при старте проверяется наличие файла по старому пути и он копируется в новый, если нового ещё нет; (2) обработчик `do_update_bot_` теперь проверяет совпадение скачанной версии с текущей `BOT_VERSION` и прерывает обновление с сообщением "Already running vX" — за исключением кнопки **Force Update**, которая использует callback `do_update_bot_force_VERSION` для обхода защиты.
- **РЕФАКТОРИНГ:** Все 27 постоянных runtime-файлов консолидированы в директорию `BOT_DIR="/tmp/podkop_bot"` (создаётся через `mkdir -p`). Команда `trap` упрощена до `rm -rf "$BOT_DIR"` вместо перечисления 15 файлов по именам. Устраняет хаос во временной директории `/tmp` и делает очистку атомарной.

---

## v0.14.0

- **ИСПРАВЛЕНО:** `_load_transport_ctx` — `tier1` (транспорт бота до Telegram) теперь всегда использует **основную секцию прокси** (`connection_type=proxy` + `mixed_proxy_enabled=1`), а не активную секцию в UI. Раньше переключение активной секции на `awg_main` (WARP/VPN) приводило к тому, что бот использовал порт 2081 для собственного транспорта, ломая соединение.
- **НОВОЕ:** `_load_transport_ctx` автоматически добавляет эндпоинты `mixed_proxy` других секций в качестве дополнительных fallback-тиров. Каждая секция с `mixed_proxy_enabled=1` и отличающимся портом добавляется в `_t_fb_socks` после явно заданных `fallback_socks` — ручная настройка не требуется.
- **ИСПРАВЛЕНО:** `check_health` A2 теперь использует основную секцию прокси для проверки `tier1` — то же исправление, что и для контекста транспорта.
- **НОВОЕ:** `check_health` A3 проверяет `mixed_proxy` каждой секции независимо — результаты записываются как `tg_sec_<имя>=ok|fail`. Сводный `tg_tier2` считается `ok`, если хотя бы одна секция проходит проверку.
- **НОВОЕ:** Tunnel Health — блок **"Активные исходящие по секциям"**: задержки и доступность Telegram для всех секций podkop одновременно в режиме чтения. Не нужно переключать секции — всё видно сразу.
- **НОВОЕ:** Tunnel Health — строки доступности TG для каждой секции (например, `✅ TG via awg_main: ok`) на основе независимых проверок.
- **ИСПРАВЛЕНО:** `do_toggle_mixed` — включение Mixed Proxy, когда `mixed_proxy_port` не задан в UCI, приводило к ошибке `jq: invalid JSON` и краху генерации конфига sing-box. Бот теперь автоматически назначает первый свободный порт начиная с 2080, сканируя все секции на наличие занятых портов.
- **ИСПРАВЛЕНО:** `do_toggle_mixed` — при падении `podkop reload` после переключения пользователь видит явное сообщение с подсказкой выполнить `logread` вместо молчаливого возврата в настройки.
- **ИСПРАВЛЕНО:** Подтверждена основная причина из исходников podkop 0.7.14: `configure_section_mixed_proxy()` вызывает `config_get mixed_proxy_port` без значения по умолчанию — это единственный `--argjson`-параметр без дефолта, все остальные используют `_normalize_arg()` или хардкод.
- **НОВОЕ:** Управление администраторами прямо в боте (Bot Settings → 👤 Admins): добавление/удаление User ID, переключатель anonymous group admins, экран Bot Info & Invite с инструкцией по добавлению в группу.
- **НОВОЕ:** `do_update_bot_` — кнопка **Force Update** (`do_update_bot_force_VERSION`) принудительно переустанавливает текущую версию, обходя защиту от повторного обновления.
- **ИСПРАВЛЕНО:** `build_uci_links_cache` — читал всегда только `selector_proxy_links` независимо от режима. В режиме URLTest кэш был всегда пустым → удаление прокси не работало, показывало "Cannot resolve link". Теперь читает нужный список в зависимости от `proxy_config_type`.
- **ИСПРАВЛЕНО:** `do_del_px_confirmed_` — аналогичный баг при удалении: всегда писал в `selector_proxy_links`. Теперь тоже учитывает режим.

---

## v0.13.99

- **ИСПРАВЛЕНО:** Проверка прямого подключения к TG (`TG direct`) теперь использует `--resolve` для обхода DNS и прямого подключения к IP-адресам дата-центров Telegram (149.154.167.220, 149.154.167.51, 91.108.56.190) — требуется ответ от 2 из 3 ДЦ. Ранее разрешение имён происходило через DNS, который мог вернуть IP-адреса CDN/Cloudflare — ложноположительный результат при блокировках РКН.
- **НОВОЕ:** `check_health` A3: проверяет первый резервный SOCKS (`tier2_1`) на доступность Telegram API — результат отображается как tier2 ✅/❌ в меню Status и Tunnel Health. Скрыто, если резервные прокси не настроены.
- **UX:** Status и Tunnel Health — индикаторы `tunnel` и `SOCKS` объединены в единый `tunnel SOCKS5`. Зелёный = транспорт ок + SOCKS работает, жёлтый = транспорт ок но порт SOCKS недоступен, красный = ошибка транспорта.
- **НОВОЕ:** Защита от отключённого `mixed_proxy` в Probe — показывает понятную ошибку вместо N/A.
- **НОВОЕ:** Проверка доступности Clash API в Probe — подсказка "Enable YACD", если Clash API недоступен.
- **НОВОЕ:** Активная секция при запуске инициализируется из первой настроенной секции podkop (не хардкод `main`).
- **ИСПРАВЛЕНО:** Публичный IP показывает `N/A` вместо `?` при двойном NAT или отсутствии связи.
- **НОВОЕ:** Кнопка `Test Fallback` добавлена на верхний уровень Bot Settings рядом с Fallback SOCKS.
- **UX:** Все кнопки навигации в меню теперь показывают 🏠 — устраняет путаницу между "← Back" (шаг назад) и "🏠 Menu" (главное меню).

---

## v0.13.98

- **ИСПРАВЛЕНО:** `get_active_proxy_name()` возвращена к выдаче только тега/leaf из Clash API — в режиме `url` она возвращала человекочитаемое имя, что ломало сравнение тегов по всему UI. Добавлена `get_active_proxy_display()` для контекстов отображения.
- **ИСПРАВЛЕНО:** Single URL Proxy — статус показывал 🔴 Offline при задержке 0 (не проверено). Изменено на 🟡 Untested.
- **ИСПРАВЛЕНО:** Single URL Proxy — кнопка удаления показывала иконку пинга вместо корзины.
- **ИСПРАВЛЕНО:** Навигация Probe из Single URL — кнопки Cancel/Back возвращали в Diagnostics вместо `url_links_menu`.
- **ИСПРАВЛЕНО:** Кнопка действия в результатах Probe в режиме `url` — показывала "Switch Proxy" вместо "Set New URL".
- **ИСПРАВЛЕНО:** Status, Runtime Info, Tunnel Health, Probe — переведены на `get_active_proxy_display()` для консистентного отображения имени в режиме `url`.
- **ИСПРАВЛЕНО:** Состояние гонки кэша — `build_all_caches` больше не вызывается перед `safe_reload_podkop` при добавлении/удалении прокси. Кэш на устаревшем `config.json` давал пустые кэши и сырые теги `main-N-out` вместо имён.
- **ИСПРАВЛЕНО:** `safe_reload_podkop` ждёт до 10 секунд валидного `config.json` перед построением кэшей.
- **ИСПРАВЛЕНО:** Состояние гонки кэша при холодном старте — `send_startup_notification_async` ждёт валидного `config.json` перед `build_all_caches`.
- **ИСПРАВЛЕНО:** `get_uri_by_tag`, `get_selector_link_by_index` — проверка через `-s` (непустой файл) вместо `-f`; пересборка на промахе.
- **ИСПРАВЛЕНО:** `display_proxy_name` — перед пересборкой `TAG_NAME_CACHE` проверяет актуальность `TAG_URI_CACHE`.

---

## v0.13.97

- **КРИТИЧЕСКИЙ ФИКС:** Добавление прокси всегда писало в `selector_proxy_links` независимо от режима. В URLTest/Selector новый прокси попадал не в тот список → podkop выдавал невалидный JSON → `[fatal] Sing-box configuration is invalid`. Туннель падал, прокси "исчезали". Исправлено: определяется `proxy_config_type` и запись идёт в правильный список.
- **ИСПРАВЛЕНО:** Single URL — кнопка "Назад" возвращала в `advanced_settings` вместо `proxy_menu`.
- **НОВОЕ:** Single URL — показывает имя активного прокси, задержку и вердикт, как в Selector/URLTest.
- **НОВОЕ:** Single URL — кнопка Probe Active Outbound, когда прокси активен.
- **ИСПРАВЛЕНО:** `px_view` — Share Link обрезался до `#`, удаляя фрагмент с именем прокси.

---

## v0.13.96

- **НОВОЕ:** `probe_geo` — Cloudflare cdn-cgi/trace как второй источник гео, независимый от ipapi.co. Карточка показывает три источника: GeoIP, Cloudflare, Google.
- **УДАЛЕНО:** Проверка подмены DNS — ненадёжна при архитектуре podkop/sing-box (fake-IP, FakeTLS, stubby).
- **ИСПРАВЛЕНО:** Проверка Claude.ai перенесена на `api.anthropic.com/v1/models` (возвращает 401 = доступен, против ложного 200 от status.anthropic.com).
- **НОВОЕ:** Gemini добавлен в `probe_services`.
- **НОВОЕ:** `version.txt` включает строку с краткими highlights для карточки обновления.

---

## v0.13.95

- **НОВОЕ:** Двухэтапный тест пропускной способности в Probe: 32 КБ для детекта паттерна блокировки 16 КБ (РКН), затем 1 МБ для точного замера скорости.
- **ИСПРАВЛЕНО:** Проверка Claude.ai на `claude.ai/login` вместо `status.anthropic.com` (статус-страница давала ложный 200).
- **ИСПРАВЛЕНО:** Проверка подмены DNS: `nslookup` запрашивает upstream DNS провайдера; добавлены `198.18.*`/`198.19.*` (fake-IP podkop) в фильтр; фоллбек на DoH через прокси если провайдер блокирует прямой DoH.
- **НОВОЕ:** Карточка обновления бота показывает "Что нового" из CHANGELOG.md.
- **ИСПРАВЛЕНО:** `uci_list_clean` — `echo` заменён на `printf '%s\n'`.
- **ИСПРАВЛЕНО:** `probe_throughput` — парсинг усилен против частичного вывода curl при RST/таймауте.

---

## v0.13.94

- **НОВОЕ:** Probe Active Outbound — полная диагностика через текущий активный прокси без переключения: гео (ipapi.co + Google), доступность сервисов (YouTube, Telegram API, ChatGPT, Discord), тест пропускной способности с детектом блокировок РКН.
- **НОВОЕ:** Детект паттернов РКН: `ok` / `throttled` / `block16k` / `blocked` с пояснительным текстом.
- **НОВОЕ:** Проверка Telegram API через активный прокси — определяет российские VDS с заблокированным `api.telegram.org`.
- **НОВОЕ:** Контекстные кнопки по результату: Switch Proxy / Test All / Bot Settings.
- **НОВОЕ:** Кулдаун 2 минуты между запусками Probe.
- **UX:** Probe добавлен первым пунктом в Diagnostics.
- **UX:** Исправлено слияние секции и Active Route в главном меню при >1 секции.

---

## v0.13.93

- **ИСПРАВЛЕНО:** Регрессия в списке Outbounds — все прокси показывали "Unknown | N/A". Причина: `jq` терял контекст корня JSON при `to_entries[]`. Исправлено через `. as $root`.
- **ИСПРАВЛЕНО:** `do_px_auto_urltest` искала URLTest глобально — могла захватить группу из другой секции. Ограничена членами активной секции.
- **ИСПРАВЛЕНО:** URL mode `proxy_string` — добавлял вместо замены. Исправлено на `uci set`.
- **ИСПРАВЛЕНО:** Подсказка Outbound Config содержала хардкод `podkop.MAIN` — заменено на `podkop.${sec}`.
- **НОВОЕ:** `podkop_dns_check()` — проверка туннеля через fakeip DNS-пробу после перезагрузки.
- **ИСПРАВЛЕНО:** Сравнение версий в `cmd_check_update` — `sort -V` заменён на покомпонентное числовое сравнение.

---

## v0.13.92

- **ИСПРАВЛЕНО:** Путь восстановления в `api_poll_long()` не вызывал `_write_main_route()` после успешного переоткрытия SOCKS.
- **ИСПРАВЛЕНО:** `urltest_group` искался глобально — мог захватить данные другой секции.
- **ИСПРАВЛЕНО:** `sed -nE` → `sed -n` (BRE) в `extract_server_port_from_uri()`.
- **ИСПРАВЛЕНО:** `do_restart_bot`/`do_update_bot` — `killall -9 $basename` заменён на `kill -9 $$`.
- **НОВОЕ:** Check E в watchdog — алерты при деградации маршрута бота до tier4/tier5 и при восстановлении.
- **НОВОЕ:** Алерт о падении SOCKS tier1 даже когда tier2 сохраняет работоспособность бота.
- **ИСПРАВЛЕНО:** Групповые узлы (URLTest/Selector) отфильтрованы из списка Outbounds.
- **ИСПРАВЛЕНО:** Toast-уведомление кнопки Refresh теперь надёжно появляется — `answer_callback` вызывается до `clash_request`.
- **UX:** Карточка статуса переработана: 🐶 для Podkop, 📦 для Sing-box, 📨 для Telegram health.

---

## v0.13.90

- **ИСПРАВЛЕНО:** `get_selector_tag()` — жадный фоллбек мог украсть данные из другой секции. Три исправления: явная проверка `$sec+"-out"`, поддержка URLTest в фоллбеке, фильтрация по имени активной секции.
- **НОВОЕ:** Защита при переключении в URL-режим без `proxy_string` — reload удерживается до получения ссылки.
- **НОВОЕ:** Check D в watchdog различает ручное и автоматическое переключение прокси: "Proxy manually switched" vs "Proxy auto-switched".
- **ИСПРАВЛЕНО:** `get_active_proxy_name()` не разрешал URLTest-группы — возвращал `main-urltest-out`.
- **ИСПРАВЛЕНО:** Версия podkop показывала двойную строку на RouteRich — добавлен `tail -1`.
- **ИСПРАВЛЕНО:** ОСНОВНАЯ ПРИЧИНА цикла "tir1" — BusyBox `tr` в OpenWrt 24.10.x некорректно обрабатывает букву `e` как член `[:space:]`. Все `tr -d '[:space:]'` заменены на `tr -d '\n\r\t '`.
- **UX:** Режим URL переименован везде: "URL Links" → "Single URL", "Add Link" → "Set URL".
- **UX:** Опция 4 в инсталляторе — полное удаление с двойным подтверждением.
