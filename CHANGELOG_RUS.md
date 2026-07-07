# История изменений

---

## v0.15.9
- **НОВОЕ: пре-флайт проверка места на overlay перед обновлением (`_pkg_disk_check()`)** — перед обновлением пакетов podkop/podkop-plus проверяет свободное место на `/overlay` (фолбэк на `/`) с порогом 50 МБ. Собственный инсталлятор podkop-plus требует только 15 МБ, но реальный размер sing-box ближе к 50 МБ (больше для `-extended` сборок с доп. протоколами/Tailscale) — на роутерах с малым overlay (например AX3000T, ~60 МБ) апстримная проверка проходит, а opkg/apk может исчерпать место посреди установки, оставив ни рабочего старого, ни нового бинаря sing-box. Теперь бот блокирует обновление с понятным предупреждением вместо деструктивного падения на середине.
- **НОВОЕ: уведомление о самообновлении бота в Daily/Weekly Report и Check Bot Update (`_bot_update_note()`, `_ver_is_newer()`)** — забирает `version.txt`/`highlights.txt` с GitHub main и, если опубликована реально более новая версия, показывает однострочный баннер в шапке отчётов. Использует настоящее сравнение major.minor.patch (`_ver_is_newer()`) вместо сравнения строк на неравенство — защищает от частого кейса, когда рабочая копия `BOT_VERSION` уже опережает опубликованную (версия забампана локально до пуша), что раньше давало ложные "доступно обновление" на версию старше текущей. Тот же фикс применён к кнопке `Check Bot Update`.
- **НОВОЕ: персистентный accumulator недельного трафика (`_traffic_accum_tick()`, `traffic_accum`, `sb_restart_log`)** — дельта трафика в Weekly Report раньше сравнивала один снимок Clash API "до/после"; так как `downloadTotal`/`uploadTotal` обнуляются при каждом рестарте sing-box (watchdog, reload, self-update, миграция — что угодно), любой рестарт за неделю приводил к тому, что отчёт путал сброс счётчика с "первой неделей вообще" и показывал "н/д" вместо реальных цифр — на роутере с неделями аптайма и активным watchdog'ом это происходило практически каждую неделю. Исправлено tick-в-tick accumulator'ом: `_traffic_accum_tick()` выполняется на каждом цикле `health_interval` внутри watchdog-луппа `start_health_daemon()`, копит трафик в `${BOT_DIR}/traffic_accum` и детектит рестарты по тому же сигналу (текущий счётчик Clash меньше предыдущего замера), который раньше ошибочно читался как "первый запуск". Рестарты логируются с таймстампами в `${BOT_DIR}/sb_restart_log` (ротация 8 дней, тот же принцип что `switch_log`), поэтому Weekly Report теперь считает реальные рестарты за настоящие 7 дней вместо приближения через `logread` только за сегодня. `WEEKLY_TRAFFIC_BASE` теперь хранит снимок banked-счётчика вместо сырых тотализаторов Clash.
- **ИСПРАВЛЕНО: устаревший лейбл "sing-box restarts (сегодня)" в Weekly Report** — текст говорил "сегодня", хотя расчёт уже был переведён на 7-дневное окно; лейбл исправлен на "(неделя)".
- **ИСПРАВЛЕНО: устаревший комментарий версии в шапке** — комментарий в шапке скрипта (строка 3) был захардкожен на старую версию, рассинхронизирован с `BOT_VERSION`.

## v0.15.8
- **НОВОЕ: NetShift — полноценный редактор add/delete для `selector_text`/`urltest_text` (`_handle_text_links()`, `_text_links_field()`, `get_text_proxy_links()`)** — эти UCI-опции являются многострочными scalar-значениями (не UCI list), по одной прокси-ссылке на строку, используются `proxy_config_type` selector/urltest в NetShift. Раньше были read-only в боте; теперь поддерживают добавление (валидация протокола, отклонение дублей/пустого ввода, добавление строки) и удаление (line-rejoin, та же дисциплина что уже используется для редактирования `proxy_string` в url-режиме), постраничный просмотр списка (8 на страницу).

## v0.15.7
- **ИСПРАВЛЕНО (блокер): `local` в main loop в document handler** — `local _doc_file_id` и все остальные `local` объявления внутри обработчика Upload Bot Script находились в главном event loop (вне функции). В BusyBox ash `local: not in a function` вызывает немедленный выход shell с кодом 2. Итог: каждый входящий update (включая кнопку `🏠 Menu`) попадал в этот обработчик, бот падал, procd делал respawn — бесконечный цикл перезапуска. Исправлено: все `local` удалены, использованы обычные присваивания переменных.
- **ИСПРАВЛЕНО: `/cancel` и `🏠 Menu` теперь выходят из любого состояния STATE_INPUT** — универсальный перехват добавлен в начало блока STATE_INPUT в `handle_command`. Любое состояние (`wait_bot_script_file`, `wait_quiet_hours`, `wait_dr_time` и др.) теперь корректно завершается через `/cancel` или Menu без state-специфической обработки.
- **ИСПРАВЛЕНО: дублирующее сообщение основному админу в `send_to_all_admins`** — сравнение было `[ "$_aid" = "$CHAT_ID" ]`, но основной админ хранится в `$ADMIN_ID`. Если переменные различались, основной админ получал два экземпляра каждого broadcast. Исправлено на `$ADMIN_ID`.
- **ИСПРАВЛЕНО: опечатка `grep -v '^\$'` в фильтрации admin_ids** — обратный слеш перед `$` делал фильтр совпадающим с буквальным `$` вместо пустых строк, что приводило к устаревшим записям в broadcast циклах. Исправлено на `grep -v '^$'` (два места: `send_to_all_admins` и `send_health_alert`).
- **ИСПРАВЛЕНО: очистка temp-файлов после добавления источников IP 4 и 5** — glob `rm -f /tmp/podkop_ip[123].*` не покрывал файлы `f4`/`f5` добавленные для `ipify.org` и `2ip.me`. Изменено на `podkop_ip[1-5].*` в обоих местах (`find` и `rm -f`).
- **ИСПРАВЛЕНО: дублирование цепочки маршрутов в Bot Control Plane** — `tr_hint` для режима `auto` показывал `Auto: Podkop SOCKS5 → Fallback SOCKS → Custom → Direct → Emergency IPs` курсивом, а блок `Fallback Chain` ниже показывал ту же цепочку с реальными адресами. `tr_hint` для `auto` удалён (цепочка уже есть в Route Chain). Для режимов `socks`/`direct` сохранено краткое предупреждение `⚠️`. `Fallback Chain` переименован в `Route Chain`. `tr_hint` теперь выводится только если непустой.
- **НОВОЕ: Upload Bot Script** — кнопка `📤 Upload Bot Script` в Maintenance. Переводит бота в состояние `wait_bot_script_file`, затем принимает `.sh` файл отправленный как документ Telegram. Валидирует shebang, наличие `BOT_VERSION`, синтаксис (`busybox ash -n` + `sh -n`). Проверяет актуальность init.d. При успехе: делает backup текущего бинаря в `.bak`, устанавливает новый, перезапускает. Разработано для тестирования патчей без публикации в GitHub и для роутеров за ISP-блокировками где прямой доступ к GitHub недоступен.
- **НОВОЕ: Тихие часы** — watchdog алерты подавляются в настраиваемом временном диапазоне. Поддерживает overnight диапазоны (23:00–07:00). Хелпер `_is_quiet_hours()` используется в `send_health_alert` и `_send_alert`. Daily Report не подавляется. UCI: `quiet_hours_enabled=0`, `quiet_hours_from=23:00`, `quiet_hours_to=07:00`. Bot Settings: `⚫ Quiet Hours: HH:MM–HH:MM | ⏰ Set Range`. Ввод: `HH:MM-HH:MM` с валидацией regex.
- **НОВОЕ: watchdog-алерт при низкой RAM** — срабатывает при свободной RAM < 30 MB, восстановление при ≥ 40 MB, повтор раз в час при персистентном состоянии. Включает советы (уменьшить количество URLTest outbounds, увеличить `health_interval`, использовать sing-box stable). Проверяется каждые 5 watchdog-циклов. Учитывает toggles `alert_notify` и новый `ram_alert`.
- **НОВОЕ: тоггл `ram_alert` в Bot Settings** — независимый toggle для подавления RAM алертов. По умолчанию: вкл. Полезен на роутерах с перманентно низкой RAM (AX3000T + sing-box-extended).
- **НОВОЕ: тоггл `broadcast_alerts` в Bot Settings** — при включении `send_health_alert` (все watchdog алерты) и `_send_alert` (RAM алерты) отправляются всем `admin_ids` дополнительно к основному CHAT_ID. Добавлен хелпер `send_to_all_admins()`. Daily Report всегда броадкастит независимо от настройки.
- **НОВОЕ: расширение IP detection до 5 параллельных источников** — добавлены `api.ipify.org` и `api.2ip.me` (российский, доступен в Крыму/РФ где ipinfo.io/ifconfig.me могут быть заблокированы). Голосование большинством обновлено с 2-из-3 до 2-из-5. Все запросы параллельные, общее время = самый медленный ответивший.
- **НОВОЕ: проверка актуальности init.d при self-update** — перед установкой нового бинаря проверяет `/etc/init.d/podkop_bot` на наличие маркера `_kill_all_podkop_bot` (добавлен в v0.15.5). Показывает `⚠️ Warning: init.d is outdated` если отсутствует. Не блокирует обновление.


- **НОВОЕ: Weekly Report** — еженедельный дайджест в Telegram (по умолчанию: воскресенье 09:00, выкл по умолчанию). Отдельно от Daily Report; в день Weekly ежедневный отчёт подавляется. Содержимое: версии (bot ver + mtime + sha256[:8], init.d mtime, podkop + sing-box), стабильность (bot uptime, tunnel uptime, рестарты sing-box, переключения маршрута за неделю из `switch_log`, последний switch с методом и временем, TG-статус), ресурсы (RAM snapshot + min за неделю + кол-во алертов, сбрасывается после отчёта), туннель (режим + активный outbound), дельта трафика за неделю с avg/day (baseline сохраняется после каждого отчёта, пропускается при недоступном Clash API), подписка Plus с предупреждениями при истечении (<7 дней) или превышении трафика (>80%). Снапшот bot config: route, health interval, тихие часы, broadcast alerts, ram alert, daily report. UCI: `weekly_report=0`, `weekly_report_day=7` (ISO: 1=Mon…7=Sun), `weekly_report_time=09:00`. Bot Settings: `⚫ Weekly Report: Sun 09:00 | ⚙️ Set`. Maintenance: `📅 Send Weekly Report Now`. Переживает рестарт бота — дата последней отправки сохраняется в `${BOT_DIR}/weekly_report_last`.
- **НОВОЕ: `switch_log`** — watchdog записывает `ts|method|from|to` при каждом переключении proxy (manual и urltest). Записи старше 8 дней удаляются после каждой записи. Weekly Report читает счётчик за 7 дней и последнюю запись.
- **НОВОЕ: `ram_week` tracking** — watchdog обновляет `min_free_mb|alert_count|last_ts` при каждой проверке RAM. Счётчик алертов инкрементируется при срабатывании. Weekly Report читает и сбрасывает файл.
- **НОВОЕ: baseline трафика для weekly** — `${BOT_DIR}/weekly_traffic_base` хранит `ts|download|upload` после каждого отчёта. Дельта = текущие счётчики − baseline. Baseline обновляется только при ненулевых счётчиках Clash API.

- **ИСПРАВЛЕНО: init.d не обновлялся при само-обновлении бота** — `do_update_bot_` теперь автоматически скачивает и устанавливает свежий `podkop_bot_init` с GitHub когда текущий init.d определяется как устаревший (отсутствуют маркеры `_kill_all_podkop_bot` или `return 0` из v0.15.5+). Старый файл сохраняется в `/etc/init.d/podkop_bot.bak`. При ошибке скачивания показывается предупреждение.
- **НОВОЕ: предупреждение об устаревшем init.d в карточке Maintenance** — показывается один раз за сессию бота (флаг в `${BOT_DIR}/init_warn_shown`) при открытии Maintenance если init.d устарел. Раньше предупреждение было только во время само-обновления, что пользователи пропускали если Telegram был недоступен в тот момент.

## v0.15.6
- **ИСПРАВЛЕНО (OOM-блокер): убран last-resort fallback `sing-box version`** в `get_singbox_version_display()` — запускал полный Go-рантайм (+20-30 MB RSS), мог вызвать OOM-killer на роутерах с 256 MB. Теперь возвращает `"unknown"` без спавна бинаря.
- **ИСПРАВЛЕНО: сломанный `sed` в apk-парсере версии** — `s/ *//)` содержал непарную `)`, давая `sed: unknown option to 's'` в runtime. Исправлено на `s/[[:space:]].*//'`.

## v0.15.5
- **НОВОЕ (только Plus): карточка Server Instances** — кнопка `🖧 Server Instances` в главном меню (скрыта на original/evolution/netshift). Читает все UCI-секции типа `server` из конфига `podkop-plus` — без зависимости от sing-box config.json или Clash API. Отображает для каждого сервера: протокол (VLESS, VMess, Trojan, Shadowsocks, SOCKS, Hysteria2, MTProto, Tailscale), адрес и порт прослушивания, публичный хост, режим безопасности (Reality/TLS/none) + SNI для VLESS/VMess/Trojan, FakeTLS-домен для MTProto, режим маршрутизации (rules/direct/section→имя). Живая проверка порта через `netstat`/`ss`/`/proc/net/tcp|udp` — покрывает TCP и UDP (hy2/tuic). Статистика соединений из Clash `/connections` показывается при наличии (кол-во соединений, ↓↑ трафик). IP Tailscale определяется из интерфейса `tailscale0`; при недоступности tsnet — заглушка «проверить в LuCI → Server → Share». MTProto secret в MVP не показывается. Легенда статусов: 🟢 порт слушает · 🟡 включено в UCI, порт не обнаружен · ⚫ выключено.
- **ИСПРАВЛЕНО:** Потенциальный дэдлок демона здоровья — `wait "$_last_probe_pid"` перед запуском нового `probe_all_socks_write &` мог заблокировать весь цикл watchdog навсегда, если предыдущий подпроцесс завис в D-state (заблокированный I/O на tmpfs). Исправлено: проверяется `kill -0`; если процесс жив — убивается; затем `wait || true` для неблокирующего пожинания зомби. Демон больше не может зависнуть.
- **ИСПРАВЛЕНО:** `sort_by(.value.all | length)` в `_resolve_urltest_group_for_section` и `_utf_postcheck_warn` — jq-пайплайн падал с ошибкой `null` когда массив `.all` у Selector'а отсутствовал или был пустым. Исправлено: `sort_by((.value.all // []) | length)` — фолбэк на пустой массив.
- **ИСПРАВЛЕНО:** Отсутствовал `html_escape` в `_flush_autoswitch_summary` — имена прокси из подписок с `<`, `>` или `&` вызывали 400 Bad Request от Telegram при алертах переключения URLTest, молча теряя уведомление. Исправлено: `_sw_old_disp` и `_sw_pending_to` экранируются перед вставкой.
- **UX:** Tunnel Health — `TG direct: fail` теперь показывает `(expected — ISP block, tunnel OK)` вместо пугающего `(no proxy)`, когда прямая проверка не прошла, но транспорт тоннеля работает. Нейтральный `(no proxy)` — только когда оба (direct и tunnel) недоступны.
- **ИСПРАВЛЕНО (совместимость):** `stat -c %Y` заменён на `date -r "$file" +%s` при восстановлении стейл-лока и очистке при запуске — `stat -c %Y` требует `CONFIG_FEATURE_STAT_FORMAT`, который скомпилирован в BusyBox не всегда.
- **ПРОИЗВОДИТЕЛЬНОСТЬ:** `is_list_enabled` оптимизирован для рендеринга Community Lists — раньше вызывал `uci show` по разу на каждый тег в цикле (до 25 вызовов подпроцессов, 2-3 секунды на MIPS). Теперь активный список парсится один раз в `_active_cl_str`, принадлежность проверяется через `case " $str " in *" $tag "*)` — O(1) на тег, без подпроцессов.
- **ИСПРАВЛЕНО:** `killall -9 "$(basename $BOT_PATH)"` в `do_restart_bot` и `do_update_bot` (путь без init.d) убивал текущий процесс до того как успевал отработать `exec` — бот умирал вместо перезапуска. Исправлено: `kill -9 -$$` убивает группу процессов (orphaned subshells), не трогая сам текущий процесс.
- **ИСПРАВЛЕНО:** NetShift/Netshift: захардкоженный путь `/etc/sing-box/config.json` заменён на `$SINGBOX_CONFIG_PATH` (задаётся в блоке детекции варианта). Все 18 вхождений заменены. Путь кэша подписок NetShift исправлен с `/etc/netshift/subscriptions/` (флеш) на `/var/run/netshift/subscriptions/` (RAM, как у evolution).
- **ИСПРАВЛЕНО:** grep-команды в логах и диагностике (`logread`, `nft list ruleset`, Support Bundle) теперь фильтруют по `"${PODKOP_PKG}|sing-box"` вместо захардкоженного `podkop|sing-box` — на NetShift правильный syslog-префикс `netshift`, а не `podkop`.
- **ИСПРАВЛЕНО:** Переменная `PODKOP_FAKEIP_DOMAIN` добавлена в блок детекции варианта. `podkop_dns_check` теперь использует `${PODKOP_FAKEIP_DOMAIN:-fakeip.podkop.fyi}` — готово к NetShift если его fakeip-домен отличается.

- **НОВОЕ (только Plus): отображение версии Zapret2 в Maintenance** — строка `Zapret2:` теперь показывается в карточке Maintenance рядом с Zapret и ByeDPI, когда Plus CLI сообщает `zapret2_installed=1`. Версия читается напрямую из `/opt/zapret2/nfq2/nfqws2 --version` (не экспортируется через `get_system_info`); фолбэк на `installed` если бинарь ничего не вернул.
- **ИСПРАВЛЕНО:** Self-update и ручной рестарт (`do_update_bot_`, `do_restart_bot`) теперь выполняют полный скан `/proc` перед рестартом — убивают все выжившие процессы `podkop_bot` (orphaned subshells из предыдущих циклов рестарта) кроме текущего PID. Раньше убивались только `HEALTH_PID` и своя process-group; subshells от более старых циклов, которые `init restart` procd не чистит, выживали и вызывали дублирующий polling Telegram API (409 конфликты) и дублирующие watchdog-алерты.
- **НОВОЕ: Ежедневный отчёт** — опциональное сообщение, отправляемое раз в сутки в настраиваемое время (по умолчанию `08:00`, выключено). Включает: имя хоста + модель устройства, uptime/RAM/CPU, WAN IP + внешний IP + флаг страны, статус TG direct/tunnel, активный outbound + задержка, количество правил nftables, версии podkop/sing-box, трафик ↓↑ + активные соединения, транспортный tier бота, трафик и срок подписки (только Plus). Включается и время настраивается в Bot Settings → toggle `Daily Report` + `⏰ Report time`. Ручная отправка: Maintenance → `📊 Send Daily Report Now`.
- **УЛУЧШЕНО: Ежедневный отчёт** — полный редизайн. Теперь читает из кешей watchdog (`SOCKS_STATE_FILE`, `PUBIP_CACHE`, `SOCKS_PROBE_FILE`, `last_switch`) вместо живых сетевых запросов. Содержимое: hostname + сокращённая модель устройства (убраны вендор/Router), uptime + load (одна строка), RAM, WAN/LAN IP, внешний IP + флаг страны, статус TG direct/tunnel (одна строка), виртуальные адаптеры (Tailscale/WireGuard/ZeroTier), режим секции (`URLTest`/`Selector`/`Subscription` + имя секции), активный outbound с флагом страны и человекочитаемым именем, время и метод последнего переключения (✋ вручную / 🤖 urltest), количество рестартов sing-box (исправлено: значение печаталось дважды), трафик ↓↑ + соединения + период uptime sing-box, маршрут транспорта бота + резервные каналы, блок подписки Plus (URL с вырезанными секретами, трафик/срок через `get_subscription_metadata` + `_plus_format_sub_meta`). Функция защищена `mkdir`-локом от двойной отправки при одновременном плановом и ручном запуске.
- **ИСПРАВЛЕНО (OOM): `get_singbox_version_display` больше не запускает бинарь sing-box** — раньше вызывался `sing-box version` который поднимает полный Go-рантайм (+20–30 MB RSS). На роутерах с 256 MB (AX3000T и аналогичных) это вызывало OOM-killer, особенно в hot path карточки Maintenance. Заменено трёхуровневым чтением из пакетного менеджера: (1) state-файл `/etc/podkop-plus/sing-box-version` (podkop-plus пишет его после каждой установки — работает для внерепозиторных бинарей вроде sing-box-extended); (2) `opkg list-installed` (OpenWrt 24.10); (3) `apk list --installed` (OpenWrt 25.x). Запуск бинаря сохранён только как последний резерв. `SB_VER_CACHE` (`${BOT_DIR}/singbox_version`) кеширует результат между открытиями карточек; сбрасывается после `do_update_podkop`.
- **ИСПРАВЛЕНО (OOM): Support Bundle** — тоже вызывал `sing-box version` напрямую. Заменён на `get_singbox_version_display`.
- **ИСПРАВЛЕНО (OOM): карточка Maintenance** — дублирующий вызов `sb_ver=$(get_singbox_version_display)` после уже выполненного `[ -z "$sb_ver" ]`. Лишний вызов удалён.
- **ИСПРАВЛЕНО: Daily Report `printf '%b'`** — заменён на прямой `send_message "$_text"`. Флаг `%b` интерпретирует backslash-последовательности в пользовательских данных (URL подписок, строки маршрута, hostname) что могло исказить текст сообщения.
- **ИСПРАВЛЕНО: рендеринг переносов в Server Instances** — откат сломанного `tr '\n' '\n'` (несовместимого с ash) обратно на `printf '%b'`. Все пользовательские данные в `_text` Server Instances проходят через `html_escape` перед вставкой, поэтому `%b` здесь безопасен. Предыдущий "фикс" приводил к тому что карточка на мобильном рендерилась одной сломанной строкой.
## v0.15.4
- **ИСПРАВЛЕНО:** `cleanup_bot_runtime_files()` в установщике не удалял `podkop_bot.pid` — single-instance lock, который бот пишет при старте. После обновления стейл-файл выживал; при следующем запуске бот мог увидеть свой старый PID и отказаться стартовать с сообщением «another instance running». Исправлено: в список очистки добавлены оба файла — `bot.pid` и `podkop_bot.pid`.
- **ИСПРАВЛЕНО:** `--action status` в unattended-режиме возвращал `running: false`, если бот был запущен напрямую (не через init.d) — проверка состояния звала только `"$INIT_PATH" status`. Теперь добавлен фолбэк: читается lock-файл `podkop_bot.pid` и проверяется живость PID — `running: true` возвращается корректно независимо от способа запуска.
- **ИСПРАВЛЕНО:** В unattended-режиме при `--action install/update`, когда init.d не смог поднять бота и срабатывал прямой запуск фолбэком, установщик всегда выходил с кодом 18 (`service start failed`) — даже если процесс реально жил. Теперь ждёт 2 секунды и проверяет `/proc/$pid`: выходит с 0 (с предупреждением о degraded-режиме) если процесс работает, и с 18 — только если он реально мёртв.
- **ИСПРАВЛЕНО:** `podkop_bot_init` (репозиторный init-скрипт и локально генерируемый фолбэк): `_kill_all_podkop_bot()` при раннем выходе чистил только `podkop_bot.pid`, оставляя `bot.pid` (используется `safe_stop_bot` установщика) как стейл-файл. Теперь удаляются оба.
- **ИСПРАВЛЕНО (критично):** Удаление ручной ссылки на прокси молча не срабатывало на Podkop Plus, если секция была в режиме URLTest. Plus хранит все ручные ссылки в `selector_proxy_links` независимо от режима — `urltest_proxy_links` это legacy-поле, которое Plus сам мигрирует и удаляет (`migrate_0_7_17_8_urltest_link` + `podkop_uci_delete_option`, подтверждено в бинаре Plus). Обработчик удаления в боте выбирал `_del_key` по режиму секции, целясь в `urltest_proxy_links` на Plus URLTest-секциях — ссылка визуально пропадала из списка, но оставалась в UCI. Теперь удаление на Plus всегда целится в `selector_proxy_links`; для original/evolution/netshift выбор по режиму сохранён.
- **НОВОЕ:** Кнопка `+ Add` теперь показывается рядом с `✏️ Edit Subscription URL` на subscription-секциях Plus. Подтверждено в LuCI-исходниках Plus: `selector_proxy_links` зависит только от `action=proxy`, не от наличия подписки — ручные ссылки и серверы из подписки сосуществуют и тестируются URLTest вместе. Защита от ручного добавления на subscription-секциях теперь действует только для не-Plus вариантов, где подписка остаётся эксклюзивной.
- **ИСПРАВЛЕНО:** Модель устройства на карточке Maintenance теперь использует ту же логику, что и Status — приоритет полной строки из `/tmp/sysinfo/model`, откат на Plus CLI `.device_model` только если файл пуст. Раньше Maintenance доверял значению CLI первым, а оно часто содержит лишь короткое имя вендора, а не полную модель.

- **Установщик v2.0.0** — полная переработка, выпущена в составе v0.15.4:
  - **НОВОЕ: режим `--unattended`** (`--action install|update|uninstall|status|check`, `--config <json>`). Lock-файл предотвращает параллельные запуски. Спроектирован как rpcd-бэкенд для luci-app-podkop-bot — без TTY-взаимодействия, структурированные exit-коды (0 успех, 10 lock, 11 не OpenWrt, 12 отсутствует поле, 13 плохой JSON, 14 установка зависимостей не удалась, 15 скачивание не удалось, 16 запись UCI не удалась, 17 токен отклонён, 18 запуск сервиса не удался), `--action status` выводит машиночитаемый JSON.
  - **НОВОЕ: автодетект варианта podkop** (original / evolution / netshift / plus) по пути бинаря, UCI-fingerprint (`action=` vs `connection_type=`, Plus-only поля) и метаданным пакетного менеджера. Определённый вариант показывается в pre-flight сводке и используется для выбора правильных UCI-полей при поиске SOCKS tier1.
  - **ИСПРАВЛЕНО: `_get_socks_endpoints()` переписан** для поддержки всех 4 вариантов. Раньше проверялась только legacy-схема `connection_type=proxy` — на любом Plus-установке tier1 всегда возвращал пустоту, и при первой установке с заблокированным GitHub у инсталлера не было SOCKS-транспорта (fallback_socks ещё не существует на чистой установке).
  - **НОВОЕ: двуязычный UI** (English / Russian). Язык определяется по порядку: флаг `--lang` → поле `"lang"` в unattended-конфиге → интерактивный выбор → дефолт `en`. Все подсказки, предупреждения и сводки проходят через `msg()` вместо захардкоженных английских строк.
  - **НОВОЕ: пользовательский bootstrap-прокси** для первичных установок, когда GitHub недоступен и SOCKS через podkop ещё не настроен. Запрашивается интерактивно (пропускается в unattended-режиме); применяется временно через переменные окружения (`http_proxy`, `https_proxy`, `all_proxy`) только на время работы установщика — ничего не пишется в UCI или системные файлы. SOCKS-прокси отклоняется до установки curl (apk/opkg поддерживают только HTTP-прокси).
  - **НОВОЕ: staged, rollback-safe обновление** — скрипт бота скачивается в `/tmp/podkop_bot.new`, валидируется (shebang + синтаксис-проверка `ash -n`), текущий бинарь бэкапится, затем атомарно заменяется. Если новая версия не запускается — предыдущий бинарь автоматически восстанавливается и сервис перезапускается.
  - **НОВОЕ: `download_file_optional()`** — не-фатальное скачивание init.d-скрипта. Сбой больше не убивает установщик в середине обновления (бинарь бота уже заменён к тому моменту); вместо этого генерируется локальный procd init-скрипт.
  - **НОВОЕ: расширенная финальная сводка** — определённый вариант podkop, версии podkop/sing-box, пути всех файлов, блок «Рекомендуемые настройки» с объяснением зачем нужен Mixed Proxy и как вписывается YACD, с точными путями в LuCI.
  - **НОВОЕ: `_validate_downloaded_script()`** — проверяет скачанные shell-скрипты перед использованием (shebang + `ash -n`), ловит HTML-страницы с ошибками и обрезанные скачивания, которые curl/wget считают успешными.
  - **ИСПРАВЛЕНО: unattended uninstall** пропускает двойное интерактивное подтверждение YES/REMOVE — предполагается что luci-app уже подтвердил у пользователя в своём UI.
  - **ИСПРАВЛЕНО: раздельные trap-обработчики** для EXIT / INT (130) / TERM (143); `umask 077` + `chmod 600` на конфиг-файл — токен бота никогда не доступен всем пользователям.
  - **ИСПРАВЛЕНО: тихий режим `--action status`** — `exec 1>/dev/null` перед всеми «шумными» шагами детекции, stdout восстанавливается на fd 3 только для финального JSON — ничего не протекает в пайплайн вызывающей стороны.

## v0.15.3.fix1
- **ИСПРАВЛЕНО:** Ложный «TG tunnel: fail» в Tunnel Health при живом боте — проба A2 вычисляла свой IP/порт через сырой `network.lan.ipaddr` и использовала синтаксис curl `--socks5-hostname`, расходясь с реальным путём поллинга. Теперь вызывает `_load_transport_ctx` напрямую (резолвит фактический listen-адрес sing-box из `config.json`) и использует тот же синтаксис `-x socks5h://`, что и `_try_socks_tiers`.
- **ИСПРАВЛЕНО:** `detect_server_country` (Plus) трактовался как boolean (`toggle_uci_bool`, дефолт `"0"`), хотя на деле это 3-значный режим (`flag_emoji` | `country_is`, дефолт `flag_emoji`) со своей UCI-миграцией. Запись `0`/`1` приводила к тому, что Plus тихо мигрировал значение обратно при reload. Заменено на `do_utfilter_cycle_dc` — циклически переключает `disabled → flag_emoji → country_is → disabled`, причём `disabled` пишется через `uci delete` (никогда `=0`). Callback переименован синхронно в 3 точках (кнопка, обработчик, whitelist диспетчера).
- **ИСПРАВЛЕНО:** `download_lists_via_proxy=1` без заданного `download_lists_via_proxy_section` ломает старт подписок/списков на Plus (`subscription_bootstrap_download_section_is_ready` возвращает 1, фатальная запись в лог). `do_toggle_dl` теперь блокирует включение флага на Plus без уже заданной секции, показывает предупреждение вместо этого.
- **ИСПРАВЛЕНО:** Проба прямой связи с Telegram использовала 3 захардкоженных IP дата-центров с фиксированным порогом `≥2`. Теперь использует существующий в боте `TG_EMERGENCY_IPS` (динамический список, обновляемый через DoH) с порогом большинства (`_dc_ok*2 >= _dc_total`), который работает для списка любого размера. Жёсткая подпись «2/3 DC» убрана из карточки Tunnel Health.
- **UX:** Разделители в карточке Status теперь обёрнуты в теги `<code>` (как в Tunnel Health / Routing & Lists) — устраняет баг рендеринга на мобильном клиенте, где «голые» строки-разделители `─────` могли переноситься на две визуальные строки на узких экранах.

## v0.15.3 hotfix
- **ИСПРАВЛЕНО (критично):** Экран Outbounds не открывался — при рефакторинге keyboard-блока `proxy_menu` в if/else потеряна одна закрывающая `]` в обеих ветках (`}]}"` вместо `}]]}"` ). `jq --argjson kb` падал молча, `payload` был пустым, карточка не отправлялась совсем.
- **НОВОЕ:** `_validate_kb()` — guard перед `send_message` и `edit_message`: проверяет JSON клавиатуры через `jq -e` перед передачей в `--argjson`; при невалидном JSON пишет в лог `[UI] Invalid reply_markup JSON (cmd=...)` и отправляет карточку без кнопок вместо молчаливого провала. `bash -n` / `busybox ash -n` такие ошибки не ловят.

---

## v0.15.3
- **НОВОЕ:** Замена URL подписки — кнопка `✏️ Edit Subscription URL` в `proxy_menu` для subscription-секций (заменяет `+ Add`, который не имеет смысла для автоматически управляемых списков серверов). Двухшаговый flow: ввод нового URL → карточка подтверждения со сравнением старого и нового → Confirm применяет, Cancel возвращает без изменений.
- **НОВОЕ:** Plus: заменяет все записи list-поля `subscription_urls` через `uci delete` + `uci add_list`; Evolution/NetShift: заменяет одиночный `subscription_url` через `uci set`. Поддерживает формат `URL | User-Agent` — trim удаляет только пробелы по краям, внутренние пробелы сохраняются.
- **НОВОЕ:** Защита `cmd_proxy_add` для subscription-секций — залипшая старая кнопка `+ Add` редиректит на `Edit Subscription URL` с пояснением вместо открытия формы добавления outbound-а, предотвращая случайную порчу subscription-управляемых секций.
- **НОВОЕ:** Хелпер `section_display_kind()` — возвращает `subscription` если `section_is_subscription()` истинно, независимо от результата `get_section_type()`. Обеспечивает корректный display-label для секций с одновременно заданными `subscription_urls` и `urltest_enabled=1`.
- **ИСПРАВЛЕНО:** Проверка состояния `pending_sub_url_*` перенесена до `rm -f "$STATE_FILE"` — pending URL, хранящийся во второй строке STATE_FILE, больше не теряется если пользователь отправит текст пока открыта карточка подтверждения. Подтверждение корректно работает после случайного ввода.
- **ИСПРАВЛЕНО:** `do_confirm_sub_url_*` проверяет заголовок STATE_FILE (`pending_sub_url_<sec>`) перед чтением URL из второй строки — залипшая старая кнопка Confirm из предыдущей сессии не может применить чужой URL.
- **ИСПРАВЛЕНО:** Отображение subscription URL в `proxy_menu`, в prompt `cmd_edit_sub_url` и в карточке подтверждения теперь проходит через `html_escape` — символ `&` в query string больше не вызывает ошибку Telegram HTML parse.
- **ИСПРАВЛЕНО:** Экранирование JSON-клавиатуры в уведомлении unsupported-variant в `cmd_edit_sub_url` и в предупреждении `pending_sub_url_*` — неэкранированные фигурные скобки передавали невалидный JSON в `jq --argjson` во время выполнения (не обнаруживается `sh -n`).
- **UX:** Карточка Status — добавлены разделители между блоками (`─────────────────────`): System / Podkop / Telegram / Bot; добавлена строка LAN IP (`🏠 LAN: <ip>`); футер сокращён до `bot vX.Y.Z` — устранено двойное отображение версий.
- **UX:** Карточка Routing & Lists — `Service Lists` переименован в `Community Lists` (как в LuCI); `Domain List URLs` → `External Domain Lists`; `Subnet List URLs` → `External Subnet Lists`; кнопки: `+ Domain List URL` → `+ Add Domain List URL`, `+ Device → Tunnel` → `+ Device to Tunnel`, `Edit Tunnel Devices` → `Tunnel Devices`, `+ Device → Bypass` → `+ Device to Bypass`, `Edit Bypass Devices` → `Bypass Devices`.
- **UX:** Карточка Routing & Lists (только Plus) — поля `rule_set` и `rule_set_with_subnets` теперь отображаются со списком URL и счётчиком записей. Только чтение; указание редактировать через `LuCI → Podkop → Conditions`. Скрыто на non-Plus вариантах.

---

## v0.15.2
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
