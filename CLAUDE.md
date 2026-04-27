# CLAUDE.md — правила работы с podkop_bot

Этот файл регулирует поведение Claude при работе с репозиторием podkop_bot.

---

## Основные принципы

- **Изменения только по явному запросу.** Не добавлять "улучшения", кнопки, фичи или рефакторинг без явного задания от владельца.
- **Каждое изменение описывать явно** — что меняется и почему, до применения.
- **Не трогать файлы без запроса** — install.sh, CHANGELOG.md, version.txt, highlights.txt обновляются только когда явно попросили.
- **Версию повышать только по запросу.** Не повышать самостоятельно.

---

## Язык и совместимость

- Строгий **POSIX ash** — работает на BusyBox OpenWrt (ARM/MIPS, 23.05 / 24.10 / 25.x)
- Запрещено: `[[ ]]`, bash-массивы, `$RANDOM`, `local` вне функций, `echo -e`
- `sed` — без флага `-E`, использовать `-r` или BRE паттерны
- `printf` вместо `echo` для строк с переменными
- `tr -d '\n\r\t '` вместо `tr -d '[:space:]'` (BusyBox баг с `[:space:]` на OpenWrt 24.10)
- Проверять синтаксис: `sh -n podkop_bot.sh` перед выдачей файла

---

## Архитектура

### Транспорт бота
- Tier1 всегда через **primary proxy секцию** (`_resolve_primary_section()`) — первая секция с `connection_type=proxy` и `mixed_proxy_enabled=1`
- Активная UI секция (выбранная пользователем в боте) **не влияет** на транспорт бота к Telegram
- Другие секции с `mixed_proxy_enabled=1` автоматически добавляются как fallback tiers

### Кэши
- Строить `build_all_caches` только после валидного `config.json` (`.outbounds | length > 0`)
- Ждать до 10 секунд после `podkop reload` перед построением кэшей
- Lazy getters (`get_uri_by_tag`, `get_selector_link_by_index`) — проверять `-s` (непустой), rebuild на miss

### IPC и файлы
- Все записи в state-файлы через `tmp + mv` (атомарно)
- `HEALTH_STATE_FILE` → `SOCKS_STATE_FILE` через `_write_socks_state()` (включая `tg_sec_*`)
- `MAIN_ROUTE_KEY_FILE` — источник истины для текущего tier, пишется main loop

### Параллелизм
- Фоновые subshell + `wait $pids` — паттерн для множественных curl (DC checks, fallback probes)
- Всегда собирать PID в переменную и делать явный `wait $_pids`

---

## UI правила

- Кнопки добавлять только по запросу
- `← Back` — возврат на шаг назад
- `🏠 Menu` — переход в главное меню (не стрелка)
- Emoji в кнопках через переменные `E_*` или литерал UTF-8 (не через `${E_HOME}` внутри jq — jq не раскрывает shell переменные)
- В jq блоках передавать emoji через `--arg`

---

## Процесс релиза

1. Все изменения накапливаются в рабочем файле `/home/claude/podkop_bot_work.sh`
2. Перед релизом: `sh -n` проверка + code review (GPT / Gemini / DeepSeek)
3. Повышение версии в `BOT_VERSION` и заголовке файла (строка 3)
4. Обновление `version.txt`, `highlights.txt` (одна строка, английский), `CHANGELOG.md`
5. Файлы для пуша: `podkop_bot.sh`, `version.txt`, `highlights.txt`, `CHANGELOG.md`
6. `install.sh` обновляется отдельно только при изменениях в инсталляторе

---

## Схема UCI подкопа (podkop 0.7.14)

Параметры секции которые podkop передаёт через `--argjson` в jq — **пустое значение = jq crash**:

| Параметр | Опасность | Дефолт в боте |
|---|---|---|
| `mixed_proxy_port` | `--argjson listen_port ""` → jq crash | авто: 2080+N |
| `urltest_check_interval` | передаётся в jq | podkop дефолт `3m` |
| `urltest_tolerance` | передаётся в jq | podkop дефолт `50` |

**Правило:** перед любым `toggle_uci_bool` или `uci set` который меняет режим работы подкопа — проверять что все зависимые параметры заданы.

Параметры с безопасными дефолтами в podkop (третий аргумент `config_get`):
- `urltest_check_interval` → `3m`
- `urltest_tolerance` → `50`
- `urltest_testing_url` → `https://www.gstatic.com/generate_204`

Параметры **без дефолтов** (опасные при пустом значении):
- `mixed_proxy_port` — **единственный** UCI параметр без дефолта который идёт в `--argjson listen_port`. Все остальные `--argjson` в podkop либо используют `_normalize_arg()` (безопасно), либо хардкод (`true`/`false`), либо имеют дефолт в `config_get`.
- `proxy_string` — при url mode должен быть непустым (но это строка, не argjson)
- `outbound_json` — при outbound mode должен быть валидным JSON


- OpenWrt BusyBox `tr` может некорректно обрабатывать `[:space:]` — использовать явные символы
- `jq` доступен, `awk` доступен, `python` недоступен
- `mktemp` может не поддерживать `-d` на старых прошивках — проверять `|| return 1`
- `podkop reload` асинхронный — возвращает управление до завершения sing-box
- Clash API: `http://127.0.0.1:9090` с Bearer токеном из UCI `yacd_secret_key`
