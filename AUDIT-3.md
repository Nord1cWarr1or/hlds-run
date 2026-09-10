# Аудит `hlds_run` — версия `1974500`

| | |
|---|---|
| Объект | `hlds_run`, 457 строк, bash |
| Версия | коммит `1974500` («docs: warn loudly - crashes can move or vanish under -debug») |
| Предыдущие аудиты | `AUDIT.md` (базлайн F1-F12), `AUDIT-2.md` (серия фиксов, находки G1-G8) |
| Дата | 2026-09-10 |
| Режим | только чтение: код не менялся; стенды в `/tmp`, временные файлы удалены |
| Метод | перечитывание файла целиком + прогоны: фальшивый сервер, настоящий core (`gcore`), `SHELL=fish`, ro-каталоги, `POSIXLY_CORRECT`, unwritable `TMPDIR` |
| Окружение | 64-битная ОС + 32-битная glibc (`/usr/lib32/libc_malloc_debug.so.0`), glibc 2.44, `script` с `--output-limit`, `SHELL=/bin/fish` |

Номера строк — по версии `1974500`.

## Сводка

| № | Находка | Severity | Где |
|---|---------|----------|-----|
| G1 | Незаписываемый корень сервера: сервер не стартует, обёртка рапортует crash | средне-высокая | `:196`, `:212-214` |
| G3 | Недоступный `TMPDIR`: пустой launcher → фальшивый краш | низкая-средняя | `:174` |
| G4 | `-c` после позиционного аргумента ломается при `POSIXLY_CORRECT` | низкая | `:212` |
| H1 | Операторский `LD_PRELOAD` молча вырезается из всей обёртки | средняя | `:202-204` |
| H2 | Единственная строка шума остаётся первой строкой хвоста в отчёте | низкая | `:230` |
| H3 | В рестарт-режиме хвост консоли теряется при каждом Ctrl+C | низкая-средняя | `:227-233`, `:418` |
| H4 | Комментарий про `--output-limit` ↔ реальная семантика обрезки | низкая | `:193-195` |
| H5 | `file` — молчаливый отказ (был G6) | низкая | `:263` |
| H6 | 143: отчёта нет (верно), но рестарты идут до «crash-loop» | низкая | `:241` vs `:418` |
| H7 | Мелочи: порядок `chmod 600`, README, пустая md5-строка | низкая | `:404` и др. |

Ключевое: **G2 закрыта по-настоящему** (шум 53 → 1 строка, preload доехал до сервера, хелперы чистые). G1, G3, G4 — приоритет прошлого аудита — **не тронуты** и воспроизводятся один в один.

---

## Изменения с прошлого аудита

Коммиты: `7815ee7` → `9710b61` (реверт) → `132de70` (preload только серверу) → `1974500` (docs).

### G2 — закрыта, механика проверена

```
$ SHELL=/bin/fish ./hlds_run -game valve -binary ./srv -debug -norestart
Heap debugging: /usr/lib32/libc_malloc_debug.so.0 will be preloaded into the server (glibc >= 2.34 requires it).
PRELOAD_IN_SERVER=</usr/lib32/libc_malloc_debug.so.0>      # preload дошёл до сервера
SERVER_SAW_PRELOAD=<>                                      # в хелперы не утёк

$ script -qec './launcher_test' /dev/null                  # launcher без preload
LAUNCHER_ENV_CHECK(): LD_PRELOAD=<>  /  0
$ LD_PRELOAD=… script -qec './launcher_test' /dev/null     # с preload
LAUNCHER_ENV_CHECK(): LD_PRELOAD=</lib64/libc_malloc_debug.so.0>  /  1
```

Шум за прогон: **было 53 → стало 1** (`grep -c 'wrong ELF class'`). Единственная строка — от первого запуска `script` (лаунчер выставляет preload уже внутри, `:176-181`); `script` 64-битный, preload для 32-битного сервера ему не нужен, поэтому устранить полностью нельзя. Остаётся вопрос её места в отчёте — см. **H2**.

В отчёте появилась честная строка: `LD_PRELOAD=… (applied to the server process via launcher)` — подтверждено.

### Подтверждено без изменений

F1, F3, F4, F6, F7, F8, F9, F10, F11, F12 — перепроверены прогонами, регрессий нет. Подробности в разделе «Проверено — работает как заявлено».

---

## G1. Незаписываемый корень сервера → сервер не стартует, обёртка рапортует краш

**Severity: средне-высокая.** Не исправлено (`AUDIT-2.md` G1), проверено повторно.

```
mktemp: не удалось создать файл по шаблону «./.caplog.XXXXXX»: Отказано в доступе
script: невозможно открыть : Нет такого файла или каталога
[..] - CRASH DETECTED (Exit Code: 1). Generating comprehensive crash report...
[..] - Crash report will be saved to: crash_report_2026-09-10_21-41-14.659937229.txt
[..] - No local core file; core_pattern is a handler - trying 'coredumpctl dump'...
[..] - Warning: coredumpctl dump failed (...)
./hlds_run: строка 237: crash_report_….txt: Отказано в доступе
chmod: невозможно получить доступ к 'crash_report_….txt': Нет такого файла или каталога
WRAPPER_EXIT=1
```

`CAPLOG_FILE=$(mktemp "./.caplog.XXXXXX")` (`:196`) — результат не проверяется; пустое имя →
`script` дочерний процесс не запускает вовсе (проверено отдельно: `script -q -e --output-limit
200MiB "" -c 'echo CHILD-STARTED'` → rc=1, вывод пуст). Сервер не стартует ни разу, оператор
видит «краш» и — в рестарт-режиме — «Crash-loop detected». Диагноз противоположен причине.

**Что делать:** проверять `mktemp`, при неудаче — fallback в `${TMPDIR:-/tmp}` с
предупреждением, при полном провале — явный отказ на старте.

## G3. Недоступный `TMPDIR` → пустой launcher → фальшивый краш

**Severity: низкая-средняя.** Не исправлено, проверено повторно.

```
$ TMPDIR=/tmp/ro3 ./hlds_run -game valve -binary ./srv -debug -norestart
mktemp: не удалось создать файл по шаблону «/tmp/ro3/tmp.XXXXXXXXXX»: Отказано в доступе
[..] - CRASH DETECTED (Exit Code: 123). Generating comprehensive crash report...
mktemp: не удалось создать каталог по шаблону «/tmp/ro3/tmp.XXXXXXXXXX»: Отказано в доступе
WRAPPER_EXIT=123
```

`LAUNCHER_FILE=$(mktemp)` (`:174`) → пусто → `script -qec '""'` → код 123 (fish) / 127 (bash) →
«краш». Тот же корень, что у G1: одна проверка на пустоту закрывает обе находки.

## G4. `-c` после позиционного аргумента при `POSIXLY_CORRECT`

**Severity: низкая.** Не исправлено.

```
$ POSIXLY_CORRECT=1 script -q -e --output-limit 200MiB /tmp/pc3.txt -c 'echo PC-OK'
script: unexpected number of arguments
Try 'script --help' for more information.
rc=1
```

Ветка с лимитом (`:212`) передаёт файл раньше `-c`; `getopt_long` в обычной жизни
переставляет аргументы, но под `POSIXLY_CORRECT` разбор прекращается на позиционном
аргументе. Сервер не стартует → снова «краш» (см. G1). Вторая ветка (`:214`) в правильном
порядке. Правка: `script -q -e "${limit_args[@]}" -c "\"$LAUNCHER_FILE\"" "$CAPLOG_FILE"`.

## H1. Операторский `LD_PRELOAD` молча вырезается из всей обёртки

**Severity: средняя.** Комментарий в коде описывает противоположное поведение.

```bash
# hlds_run:197-204
# Основание комментария: "если оператор сам экспортировал LD_PRELOAD (например,
# следуя инструкциям README), 64-битные хелперы будут печатать ELF-шум…
# обёртка доставляет preload через launcher/env — переменная на уровне шелла избыточна"
if [[ -z "$HEAP_PRELOAD" ]] && [[ -n "$LD_PRELOAD" ]]; then
    unset LD_PRELOAD
fi
```

Условие срабатывает и **без `-debug`** (там `HEAP_PRELOAD` пуст всегда), то есть переменная
вырезается не «как избыточная», а безусловно:

```
$ LD_PRELOAD=/does/not/exist.so ./hlds_run -game valve -binary ./srv2 -norestart
SERVER_SAW_PRELOAD=<>            # до сервера не дошла

$ LD_PRELOAD=/lib64/libc_malloc_debug.so.0 ./hlds_run -game valve -binary ./srv2 -norestart
SERVER_SAW_PRELOAD=<>            # и лечебная тоже
```

Живой кейс: старт из systemd с `Environment=LD_PRELOAD=…`, запуск с диагностической или
лечебной библиотекой, обёртка внутри другой обёртки. Сервер получает другое окружение, а в
отчёте (без `-debug` отчёта нет вовсе) об этом ничего. Нюанс: при непустом `HEAP_PRELOAD`
(то есть в `-debug`) ветка не срабатывает и операторский preload сохраняется — поведение
зависит от флага.

**Что делать:** не трогать волю оператора. `unset` оправдан только когда значение совпадает
с найденным `libc_malloc_debug` (шум от самого скрипта); иначе — сохранить и передать серверу,
а факт подмены написать в лог и в отчёт.

## H2. Единственная строка шума остаётся первой строкой хвоста в отчёте

**Severity: низкая.** Остаток G2.

Замер: `noise in single run = 1`, `noise inside report tail = 1`. В отчёте:

```
--- SERVER OUTPUT (stdout+stderr, last 100 lines) ---
----------------------------------------------------------------------
ERROR: ld.so: object '/usr/lib32/libc_malloc_debug.so.0' from LD_PRELOAD cannot be preloaded (wrong ELF class: ELFCLASS32): ignored.
planted core.1365940        <- первая осмысленная строка сервера идёт после шума
```

Строка занимает лучшую позицию в самом ценном фрагменте отчёта. Устраняется фильтром при
сборке хвоста (`:230`): `| grep -v 'from LD_PRELOAD cannot be preloaded'` — одна правка,
тема закрывается полностью.

## H3. В рестарт-режиме хвост консоли теряется при каждом Ctrl+C

**Severity: низкая-средняя.** Диагностическая информация исчезает на самом частом сценарии остановки.

`CONSOLE_TAIL` присваивается только если файл типскрипта существует (`:227-233`), а при 130
цикл делает `break` до чтения хвоста (`:418`):

```
$ ./hlds_run -game valve -binary ./srv130 -debug -timeout 1
[..] - Server stopped by operator (SIGINT). Exiting script.
[..] - Script finished.
reports: 4 (ни одного от этого запуска)
```

Терминал при этом показывает последние строки: `script` при INT/TERM убивает ребёнка сам
(проверено в первом аудите). Минус: последние ~100 строк умирающего сервера нигде не
сохраняются, а в юнит-логе они склеиваются с текстом следующего раунда. Плюс в рестарт-режиме
типскрипт переживает рестарт (удаляется на выходе, `:231`, а не между запусками), поэтому
первая строка шума от `script` попадает в тот же буфер, что и в H2.

**Что делать:** забирать хвост из типскрипта перед `break` (или на входе в следующий
цикл), а сам типскрипт удалять на границе запуска.

## H4. Комментарий про `--output-limit` ↔ реальная семантика обрезки

**Severity: низкая.** Тезис «лимит много выше ~100 строк» из комментария убран (правильно),
но «safety net» всё ещё вводит в заблуждение.

Проверено снова (лимит 1 КиБ, шумный ребёнок): при достижении лимита `script` **прекращает
запись**, добавляет `[<max output size exceeded>]`, сессия продолжается; типскрипт 4395 Б
(один write перескакивает лимит), `FINAL_MARKER` в файл не попал. Значит у сервера, дошедшего
до 200 МБ, отчёт получит хвост **на момент обрезки**, а не перед крахом — ровно в том
сценарии, ради которого хвост и собирается.

**Что делать:** детектировать маркер обрезки и писать в отчёт предупреждение «console capture
was truncated, tail may be stale»; комментарий привести в соответствие.

## H5. `file` — молчаливый отказ

**Severity: низкая.** Было G6, без изменений.

```
$ bash -c 'if ! nosuchcmd /etc/hostname 2>/dev/null | grep -qE "ELF.*(core|coredump)"; then echo "RESULT: core rejected"; fi'
RESULT: core rejected
```

Нет `file` → отвергается любой дамп, в лог уходит неверное «newest core* is not a core dump
from this server run», GDB-анализ пропускается. Настоящий core проверку проходит (проверено:
дамп найден, проанализирован).

**Что делать:** `command -v file` перед проверкой; нет — не фильтровать, но сказать об этом
в логе и в отчёте.

## H6. 143: отчёта нет — это верно; рестарты до «crash-loop» — нет

**Severity: низкая.** Политика выбрана правильно, но согласованность с рестарт-циклом не доведена.

`debugcore` глушит 143 (`:241`) — согласен с решением: 143 (TERM) это штатная остановка,
отчёт о ней вреден. Но рестарт-цикл (`:418`) чистым выходом считает только 0 и 130:

```
$ timeout 15 ./hlds_run -game valve -binary ./srv143 -debug -timeout 1
[..] - Server process crashed (streak 1/5). Restarting in 1 seconds...
[..] - Server process crashed (streak 2/5). ...
[..] - Giving up - fix the cause, then start manually. Last exit code: 143.
reports: 0, caplog leftovers: 0       # улик нет вовсе
```

Пять перезапусков и «Crash-loop detected» при полной тишине в диагностике. Плюс README
про 143 не говорит. Либо 143 → `break` (как 130), либо явно задокументировать, что 143
считается падением, но отчёта для него не бывает.

## H7. Мелочи

- **`chmod 600` после записи** (`:404`): файл существует с режимом от `umask` (обычно 644)
  всё время генерации; README (стр. 56) обещает «создаётся с правами 600». Надёжнее
  `umask 077` перед блоком или `install -m 600 /dev/null "$CRASH_LOG_FILE"` до записи.
- **README (стр. 54-55)** перечисляет allowlist отчёта без `LD_PRELOAD`, хотя код его выводит
  (и коммит `4ab5e4e` сделан именно за это).
- **Пустая секция md5**: `find . -name '*.so'` без результатов даёт строку
  `d41d8cd98f00b204e9800998ecf8427e  -` (хеш пустого ввода) в «Library checksums».
- **`ss` отсутствует целиком** → отчёт скажет «(unavailable: needs root for -p)»; причина неверная.
- **Fallback-пути 32-битной библиотеки** (`:129`) не покрывают Fedora/RHEL, где 32-битные
  библиотеки в `/usr/lib`.
- **Дубль объявления `LAUNCHER_FILE`** (`:48` и `:165`).
- **shellcheck 0.11.0:** SC2329 (ложное — `cleanup_temp` вызывается через `trap`),
  SC2155 ×2 (`:249`, `:383`).
- **Публикация 64-битной диагностики**: `-debug` даёт preload только 32-битной библиотеки;
  64-битные процессы дампа не получат. Это осознанно (сервер 32-битный), но `LD_PRELOAD`
  в отчёте для 64-битного бинарника `-binary` введёт в заблуждение.

---

## Проверено — работает как заявлено

E2E с настоящим core (идентичный бинарник, получен `gdb -batch -ex gcore`):

- дамп найден по `core*`, прошёл проверку mtime и ELF-типа, проанализирован, переименован в
  `crash_core.2026-09-10_21:41:30.109791204.dmp`; временных файлов не осталось;
- в отчёте все пять подсекций GDB: `=== Stacktrace ===` (стр. 159), `=== Registers and frame
  info ===` (168), `=== Disassembly (32 instructions before $pc) ===` (207),
  `=== Memory mappings ===` (242), `=== Shared libraries ===` (264); бэк-трейс настоящий
  (`#0  main () at srv.c:5`), `No symbol table info available` — 0 вхождений;
- ротация: 6 дампов → 3;
- отчёт: `Exit Code: 139`, `Stop Signal: SEGV`, режим файла 600, подпись `Binary checksum (./srv)`;
- env-allowlist: `HOME`, `TERM`, `MALLOC_CHECK_=3`, `LD_LIBRARY_PATH=.` без пустого элемента,
  явная строка про серверный preload; `STEAM_PASSWORD` не утёк (0 вхождений);
- аргументы с кириллицей и пробелами доезжают целыми при `SHELL=/bin/fish`; launcher-файл с
  bash-shebang снимает зависимость от `$SHELL`;
- классификация: 130 → чистый выход без отчёта в обоих режимах; 139 → отчёт; код выхода
  сервера пробрасывается (`script -e`) — `WRAPPER_EXIT=139`;
- детект `--output-limit` через `script --help` + `pipefail` работает (ветка выбирается верно);
- graceful `ss`/`dmesg`, предупреждение про `ulimit -c`, ретраи `coredumpctl` (~4 с),
  `gdb -nx` — на месте.

## Приоритеты

1. **G1 + G3** — проверка результата `mktemp`; одна правка закрывает «сервер вообще не
   стартует» и «фальшивые краши с отчётами».
2. **H1** — не вырезать операторский `LD_PRELOAD` молча (комментарий описывает обратное).
3. **H2** — фильтр одной строки `ld.so` при сборке `CONSOLE_TAIL`.
4. **H6, H4, H5** — политика 143, предупреждение об обрезке захвата, проверка наличия `file`.
5. **H3, H7** — хвост при Ctrl+C, доки и косметика.

## Приложение: как воспроизводилось

Стенд: каталог с `valve/`, фальшивый `srv` (печатает `LD_PRELOAD`/`MALLOC_CHECK_`/argv, при
`PLANT=1` копирует `/tmp/fakecore3` в `core.<pid>` и выходит 139), рядом копия `hlds_run`.

```bash
# G2/H2: шум и его попадание в отчёт
SHELL=/bin/fish ./hlds_run -game valve -binary ./srv -debug -norestart 2>&1 | grep -c 'wrong ELF class'   # 1
grep -c 'wrong ELF class' crash_report_*.txt                                                              # 1

# G2: preload доходит до сервера, но не до хелперов
grep -E 'PRELOAD_IN_SERVER|SERVER_SAW_PRELOAD' ...     # сервер видит, хелперы нет
script -qec './launcher_test' /dev/null                # launcher без preload: LD_PRELOAD пуст
LD_PRELOAD=… script -qec './launcher_test' /dev/null   # с preload: виден и в script, и в launcher

# H1: операторский preload молча вырезается
LD_PRELOAD=/does/not/exist.so ./hlds_run -game valve -binary ./srv2 -norestart | grep SERVER_SAW   # пусто
LD_PRELOAD=/lib64/libc_malloc_debug.so.0 ./hlds_run … -norestart | grep SERVER_SAW                 # пусто

# G1 / G3 / G4
mkdir -p /tmp/a3ro/valve && cd /tmp/a3ro && chmod 555 . && ./hlds_run … -debug -norestart   # сервер не стартует
mkdir /tmp/ro3 && chmod 555 /tmp/ro3 && TMPDIR=/tmp/ro3 ./hlds_run … -debug -norestart      # CRASH (Exit Code: 123)
POSIXLY_CORRECT=1 script -q -e --output-limit 200MiB /tmp/pc3.txt -c 'echo PC-OK'; echo $?   # rc=1

# H6: 143
printf '#!/bin/bash\nexit 143\n' > srv143 && chmod +x srv143
timeout 15 ./hlds_run -game valve -binary ./srv143 -debug -timeout 1   # 5 рестартов, 0 отчётов

# H3: хвост при Ctrl+C
./hlds_run -game valve -binary ./srv130 -debug -timeout 1 | grep -E 'stopped|finished'   # отчёта нет

# H5: отсутствие file
bash -c 'if ! nosuchcmd /etc/hostname 2>/dev/null | grep -qE "ELF.*(core|coredump)"; then echo rejected; fi'

# H4: семантика --output-limit
SHELL=/bin/bash script -q -e --output-limit 1KiB /tmp/lim3.txt -c '<шумный цикл>; echo FINAL_MARKER'
# файл 4395 Б, последняя строка «[<max output size exceeded>]», FINAL_MARKER отсутствует

# E2E с настоящим core
gdb -q -batch -ex 'break main' -ex run -ex 'gcore /tmp/fakecore3' -ex kill --args ./srv
PLANT=1 ./hlds_run -game valve -binary ./srv -debug -norestart
grep -n '^=== ' crash_report_*.txt      # пять секций GDB

# статические проверки
bash -n hlds_run
shellcheck -s bash hlds_run
```
