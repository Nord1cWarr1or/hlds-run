# Аудит `hlds_run` — серия исправлений F1-F12

| | |
|---|---|
| Объект | `hlds_run`, 421 строка, bash |
| Версия | коммит `2426333` («fix: malloc-debug detection when ldconfig is not in PATH»); серия фиксов F1-F12: `b2801b0`…`2426333` |
| Предыдущий аудит | `AUDIT.md` (коммит `76c4c11`) — базлайн, по которому делалась серия фиксов |
| Дата | 2026-09-10 |
| Режим | только чтение: код не менялся; стенды собирались в `/tmp`, временные файлы удалены |
| Инструменты | `bash -n`, `shellcheck 0.11.0`, стенд с фальшивым сервером, настоящий core через `gdb -ex gcore`, прогоны на живом `script` |
| Окружение | 64-битная ОС + 32-битная glibc (`/usr/lib32/libc_malloc_debug.so.0`), glibc 2.44, util-linux `script` с `--output-limit`, `SHELL=/bin/fish` |

Номера строк — по версии `2426333`.

## Сводка

Одиннадцать из двенадцати находок первого аудита закрыты, причём проверены не чтением, а
прогоном. Серия фиксов, однако, принесла два регресса и три спорных решения.

| № | Находка | Severity | Где |
|---|---------|----------|-----|
| G1 | Незаписываемый корень сервера: сервер не стартует, обёртка крутит фальшивый crash-loop | средне-высокая | `:173`, `:181-183` |
| G2 | `LD_PRELOAD` 32-битной библиотеки шумит во всей сессии и пачкает хвост консоли в отчёте | средняя | `:127` |
| G3 | Недоступный `TMPDIR`: пустой launcher → фальшивый отчёт о краше | низкая-средняя | `:158-159` |
| G4 | `-c` после позиционного аргумента ломается при `POSIXLY_CORRECT` | низкая | `:181` |
| G5 | 143 обрабатывается противоречиво: отчёта нет, рестарты есть | низкая-средняя | `:205` vs `:382` |
| G6 | `file` — жёсткая зависимость с молчаливым отказом | низкая | `:227` |
| G7 | `--output-limit` даёт протухший хвост; комментарий в коде объясняет это неверно | низкая | `:170-176` |
| G8 | Мелочи: порядок `chmod 600`, другое | низкая | `:368` и др. |

## Статус находок первого аудита

| № | Статус | Проверка |
|---|--------|----------|
| F1 | закрыто | сервер завершается кодом 130 в `-norestart` (+`-debug`): «CRASH DETECTED» нет, «Server crashed» нет, отчёт не создан, код выхода 130 проброшен |
| F2 | закрыто механически | `ldconfig -p` → `/usr/lib32/libc_malloc_debug.so.0`, попадает в `LD_PRELOAD`, виден в отчёте; см. **G2** |
| F3 | закрыто | `STEAM_PASSWORD=sekret123` в окружении → 0 вхождений в отчёте; env-секция: `LD_PRELOAD`, `MALLOC_CHECK_=3`, `LD_LIBRARY_PATH=.`, `TERM`, `HOME`; режим файла 600 |
| F4 | закрыто | `SHELL=/bin/fish`, аргументы `+hostname "Мой сервер"`, `+sv_password "pa ss"` доехали целыми и в правильном порядке |
| F5 | частично | лимит применяется, `.caplog` на диске и удаляется; см. **G1**, **G3**, **G7** |
| F6 | закрыто | 5 попыток ~4 с, затем честное предупреждение в логе и в отчёте |
| F7 | закрыто | ELF-проверка пропускает настоящий core; см. **G6** |
| F8 | закрыто | `^[1-9][0-9]*$` |
| F9 | закрыто | ротация на стенде: 6 дампов → 3, сообщение только по факту ротации |
| F10 | закрыто | сообщение условное, дублируется в отчёт и терминал |
| F11 | закрыто | один batch, все пять заголовков в отчёте, реальный бэк-трейс, `-nx` на месте |
| F12 | закрыто | предупреждение про `ulimit -c`, graceful `ss`/`dmesg`, подпись `Binary checksum (./srv)` |

---

## G1. Незаписываемый корень сервера → сервер не стартует, обёртка крутит фальшивый crash-loop

**Severity: средне-высокая.** Регрессия от фикса F5.

```bash
# hlds_run:173 — результат mktemp не проверяется
CAPLOG_FILE=$(mktemp "./.caplog.XXXXXX")
```

Типскрипт переехал из `$TMPDIR` в каталог сервера (ради tmpfs — правильная мотивация), но
каталог сервера вполне может быть недоступен на запись: root-owned `755` при запуске от
непривилегированного пользователя, `ReadOnlyPaths`/`ReadWritePaths` в юните systemd,
ro-remount, NFS. Тогда `mktemp` возвращает пустую строку, и дальше:

```
mktemp: не удалось создать файл по шаблону «./.caplog.XXXXXX»: Отказано в доступе
script: невозможно открыть : Нет такого файла или каталога
[..] - CRASH DETECTED (Exit Code: 1). Generating comprehensive crash report...
./hlds_run: строка 201: crash_report_....txt: Отказано в доступе
chmod: невозможно получить доступ к 'crash_report_....txt'
[..] - Server process crashed (streak 1/5). Restarting in 1 seconds...
```

Проверено отдельно, что `script` с пустым именем файла **дочерний процесс не запускает
вообще** и возвращает 1:

```
$ script -q -e --output-limit 200MiB "" -c 'echo CHILD-STARTED'
script: невозможно открыть : Нет такого файла или каталога
rc=1                      # «CHILD-STARTED» не напечатано
```

Итог: сервер не стартует ни разу, а оператор видит пять «крашей» и «Crash-loop detected» —
диагноз ровно противоположен причине. В рестарт-режиме к этому добавляется четырёхсекундная
пауза `coredumpctl` на каждую фальшивую попытку. Ранее, при типскрипте в `$TMPDIR`, этот класс
отказа был практически невозможен.

**Что делать:** проверять результат `mktemp` и при неудаче откатываться на
`mktemp "${TMPDIR:-/tmp}/.caplog.XXXXXX"` с предупреждением; если и это не удалось — падать
на старте с внятным сообщением, а не изображать краш сервера.

## G2. `LD_PRELOAD` 32-битной библиотеки шумит во всей сессии и пачкает сам отчёт

**Severity: средняя.** Побочный эффект фикса F2.

```bash
# hlds_run:127
export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$mdebug_lib"
```

Переменная выставляется глобально, поэтому её наследует **каждый** 64-битный процесс обёртки:
`script`, bash внутри pty, `md5sum`, `find`, `ps`, `ss`, `dmesg`, `coredumpctl`, `gdb`. Каждый
печатает в stderr:

```
ERROR: ld.so: object '/usr/lib32/libc_malloc_debug.so.0' from LD_PRELOAD cannot be preloaded (wrong ELF class: ELFCLASS32): ignored.
```

Замеры на стенде (64-битная ОС + 32-битная glibc — то есть **штатная** конфигурация HLDS,
где 32-битный сервер работает на 64-битном хосте): **53 строки за один прогон** с одним
запуском сервера. Хуже того, эти строки попадают **внутрь отчёта** — 7-8 штук, в самое ценное
место:

```
--- SERVER OUTPUT (stdout+stderr, last 100 lines) ---
----------------------------------------------------------------------
ERROR: ld.so: object '/usr/lib32/libc_malloc_debug.so.0' from LD_PRELOAD cannot be preloaded (wrong ELF class: ELFCLASS32): ignored.
ERROR: ld.so: object '/usr/lib32/libc_malloc_debug.so.0' from LD_PRELOAD cannot be preloaded (wrong ELF class: ELFCLASS32): ignored.
...
```

Это не только косметика: шум съедает строки хвоста, ради которого хвост и собирается —
в момент краха реального вывода сервера может не хватить. Плюс оператор получает полсотни
«ERROR» в терминал при каждом запуске с `-debug`.

**Что делать:** не выставлять preload в окружении обёртки, а передавать его только серверу —
`export LD_PRELOAD=…` внутри launcher-файла (`hlds_run:159-162`), либо
`exec env LD_PRELOAD=… "$HL" …`. 32-битный сервер preload получит, 64-битные утилиты обёртки —
нет. Фильтрация `cannot be preloaded` при сборке хвоста — лечение симптома, а не причины.

## G3. Недоступный `TMPDIR` → пустой launcher → фальшивый отчёт о краше

**Severity: низкая-средняя.** Тот же корень, что у G1: непроверенный `mktemp`.

```bash
# hlds_run:158-159
LAUNCHER_FILE=$(mktemp)
printf '#!/bin/bash\nexec %q ' "$HL" > "$LAUNCHER_FILE"
```

При `TMPDIR=/tmp/ro2` без прав на запись:

```
mktemp: не удалось создать файл по шаблону «/tmp/ro2/tmp.XXXXXXXXXX»: Отказано в доступе
[..] - CRASH DETECTED (Exit Code: 123). Generating comprehensive crash report...
```

`LAUNCHER_FILE=""` → `script -qec '""'` → пустая команда → код 123 (fish) / 127 (bash) →
обёртка уверенно пишет «краш» и создаёт отчёт, хотя сервера не было вовсе. Тот же сценарий
достаётся и до `mktemp -d` для systemd-дампа (`hlds_run:241`).

**Что делать:** проверка на пустоту после каждого `mktemp` — одна правка закрывает G1 и G3:
либо осмысленная деградация (fallback в `$TMPDIR`), либо явный отказ на старте.

## G4. `-c` после позиционного аргумента ломается при `POSIXLY_CORRECT`

**Severity: низкая.** Регрессия, внесённая веткой с `--output-limit`.

```bash
# hlds_run:181 — файл передаётся раньше, чем -c
script -q -e "${limit_args[@]}" "$CAPLOG_FILE" -c "\"$LAUNCHER_FILE\""
```

`getopt_long` переставляет аргументы (GNU-расширение) и в обычной жизни всё работает
(проверено: дочерний процесс стартует, код выхода пробрасывается). Но при `POSIXLY_CORRECT=1`
разбор прекращается на первом неопционном аргументе:

```
$ POSIXLY_CORRECT=1 script -q -e --output-limit 200MiB /tmp/pc.txt -c 'echo PC-OK'
script: unexpected number of arguments
Try 'script --help' for more information.
rc=1
$ script -q -e --output-limit 200MiB /tmp/pc.txt -c 'echo PC-OK'   # без переменной
rc=0
```

Сервер не стартует, обёртка снова уходит в «crash-loop» (см. G1).

**Что делать:** переставить `-c` перед позиционным аргументом:
`script -q -e "${limit_args[@]}" -c "\"$LAUNCHER_FILE\"" "$CAPLOG_FILE"`. Во второй ветке
(`-qec "$cmd" "$CAPLOG_FILE"`, `hlds_run:183`) порядок уже правильный.

## G5. 143 обрабатывается противоречиво: отчёта нет, но рестарты есть

**Severity: низкая-средняя.** Политику нужно выбрать осознанно.

```bash
# hlds_run:205 — debugcore считает 143 чистым выходом и не пишет отчёт
if [[ $exitcode -eq 130 || $exitcode -eq 143 ]]; then return; fi

# hlds_run:382 — а рестарт-цикл чистым выходом считает только 0 и 130
if [[ $retval -eq 0 || $retval -eq 130 ]]; then
```

Прогон с сервером, завершающимся кодом 143 (`SIGTERM`):

```
Server process crashed (streak 1/5). Restarting in 1 seconds...
Server process crashed (streak 2/5). ...
[..] - Giving up - fix the cause, then start manually. Last exit code: 143.
```

Ни одного отчёта, ни строчки диагностики — и при этом пять попыток перезапуска и итоговое
«Crash-loop detected». То есть штатная остановка супервизором по `SIGTERM` выглядит как
необъяснимый цикл падений, без улик. README про 143 не говорит вообще (стр. 37-38: «код 0
или Ctrl+C»).

**Что делать:** выбрать одну политику. Либо 143 = чистый выход (`break`, как 130) — логично,
раз это стандартный сигнал остановки; либо 143 = краш, и тогда отчёт должен писаться, а не
глушиться в `debugcore`. Текущее «ни то ни другое» — худший вариант.

## G6. `file` — жёсткая зависимость с молчаливым отказом

**Severity: низкая.** Побочный эффект фикса F7.

```bash
# hlds_run:227
if [[ $core_mtime -lt $since_ts ]] || ! file "$CORE_FILE" 2>/dev/null | grep -qE 'ELF.*(core|coredump)'; then
```

Настоящий core проверку проходит (видел: `file` → `ELF 64-bit LSB core file, x86-64 …`), и в
E2E-прогоне дамп был найден и проанализирован. Но если `file` в системе нет (минимальный
контейнер), то `grep` не получает ввода и всегда возвращает 1, поэтому **любой** дамп
отбрасывается:

```
$ bash -c 'if ! nosuchcmd /etc/hostname 2>/dev/null | grep -qE "ELF.*(core|coredump)"; then echo SKIPPED; fi'
SKIPPED
```

При этом в лог уйдёт «newest core* is not a core dump from this server run» — сообщение
неверное по сути, а GDB-анализ молча пропускается. README (стр. 173) `file` в требованиях
перечисляет, так что это осознанная зависимость, но отказ должен быть громким.

**Что делать:** `command -v file >/dev/null` перед проверкой; нет `file` — не фильтровать,
а написать «core type check skipped (file not installed)».

## G7. `--output-limit` даёт протухший хвост, комментарий в коде объясняет это неверно

**Severity: низкая.** Trade-off, который стоит задокументировать явно.

```bash
# hlds_run:170-176
# --output-limit is a runaway-console safety net (util-linux >= 2.32);
# failures to apply it are harmless - the limit is far above the
# ~100 lines the report actually reads.
limit_args=(--output-limit 200MiB)
```

Проверено на живом `script` (лимит 1 КиБ, шумный ребёнок): при достижении лимита запись в
типскрипт **прекращается**, сессия продолжается, в файл дописывается
`Script done on … [<max output size exceeded>]`, а последняя строка может быть обрезана
посередине. Значит у сервера, дошедшего до 200 МБ, в отчёт попадёт хвост **на момент обрезки**,
а не перед крашем — ровно в том сценарии, для которого отчёт и нужен. Комментарий «лимит много
выше тех ~100 строк, которые читает отчёт» неверен: лимит ограничивает **весь** типскрипт
сессии, а не последние строки. Побочно: один write может перескочить лимит (лимит 1 КиБ →
файл 4420 Б), то есть 200 МБ — это «200 МБ плюс один бёрст».

**Что делать:** минимально — детектировать в хвосте маркер `<max output size exceeded>` и
писать в отчёт предупреждение «console capture was truncated, tail may be stale»; плюс
поправить комментарий. Концептуально — вместо pty-типскрипта читать серверный лог
(`log on`/`-condebug` + `tail -F`) с ротацией: тогда хвост всегда актуален.

## G8. Мелочи

- **`chmod 600` после записи** (`:368`): файл отчёта существует с режимом от `umask` (обычно
  644) всё время генерации, закрывается уже постфактум. README (стр. 56) обещает «создаётся
  с правами 600». Надёжнее `umask 077` перед блоком или `install -m 600 /dev/null "$file"`
  до записи.
- **README (стр. 54-55)** перечисляет allowlist отчёта без `LD_PRELOAD`, хотя код его выводит
  (и коммит `4ab5e4e` сделан именно за это).
- **`ss` отсутствует целиком** → отчёт скажет «(unavailable: needs root for -p)`: причина
  неверная, `-p` тут не при чём.
- **Fallback-список 32-битных путей** (`:122`) не покрывает Fedora/RHEL, где 32-битные
  библиотеки лежат в `/usr/lib`. Основной путь через `ldconfig` это скрывает, но при `ldconfig`
  вне PATH и нестандартном layout обёртка скажет «MALLOC_CHECK_ set natively» (то есть
  диагностика кучи не включится).
- **Дубль объявления `LAUNCHER_FILE`** (`:44` и `:149`).
- **shellcheck 0.11.0:** SC2329 (ложное — `cleanup_temp` вызывается через `trap`),
  SC2155 ×2 (`:213`, `:347` — `local x=$(date …)` маскирует статус).

---

## Проверено — работает как заявлено

Полный E2E-прогон на стенде: фальшивый сервер + настоящий core, полученный `gdb -batch
-ex gcore` (идентичный бинарник, поэтому gdb не ругался на несоответствие):

- дамп найден по `core*`, прошёл проверку mtime и ELF-типа, проанализирован и переименован в
  `crash_core.<дата>.dmp`; временных файлов (типскрипт, launcher, командник gdb) не осталось;
- в отчёте все пять подсекций GDB: `=== Stacktrace ===`, `=== Registers and frame info ===`,
  `=== Disassembly (32 instructions before $pc) ===`, `=== Memory mappings ===`,
  `=== Shared libraries ===`; бэк-трейс настоящий (`#0  main () at srv.c:5`), ошибок gdb нет,
  шум `No symbol table info available` отфильтрован;
- ротация: 6 дампов на входе → 3 на выходе, сообщение печатается только по факту;
- отчёт: `Exit Code: 139`, `Stop Signal: SEGV`, подпись `Binary checksum (./srv)` (то есть
  `-binary` учитывается), режим файла 600;
- env-секция по allowlist, `LD_LIBRARY_PATH=.` без пустого элемента, `STEAM_PASSWORD` не утёк
  (0 вхождений при 0 ожидаемых);
- аргументы с кириллицей и пробелами доезжают целыми при `SHELL=/bin/fish` — launcher-файл
  с bash-shebang реально снимает зависимость от `$SHELL`;
- классификация сигналов: 130 → «чистый выход» без отчёта в обоих режимах, 139 → отчёт;
  код выхода сервера пробрасывается (`script -e`);
- детект `--output-limit` через `script --help` + `pipefail` не сломан (проверено: ветка
  выбирается верно, лимит применяется);
- ротация дампов, `-nx` у gdb, ретраи `coredumpctl`, graceful `ss`/`dmesg`, предупреждение
  про `ulimit -c` — на месте.

## Приоритеты

1. **G1 + G3** — проверка результата `mktemp`. Одна правка закрывает и «сервер вообще не
   стартует», и «фальшивые краши с отчётами». Самый дорогой по последствиям дефект серии.
2. **G2** — убрать `LD_PRELOAD` из окружения обёртки в launcher: 53 строки шума за прогон и
   замусоренный хвост консоли в отчёте.
3. **G5** — зафиксировать политику по 143 (сейчас ни чистый выход, ни краш) и отразить её
   в README.
4. **G4, G6, G7** — мелкие защиты, каждая в 1-3 строки плюс правка комментариев.
5. **G8** — доки и косметика.

## Приложение: как воспроизводилось

Стенд: каталог с `valve/`, фальшивый `srv` (печатает argv, при `PLANT=1` копирует
`/tmp/fakecore` в `core.<pid>` и выходит 139), рядом копия `hlds_run`.

```bash
# G1: незаписываемый корень сервера
mkdir -p /tmp/srvro/valve && cp hlds_run /tmp/srvro/ && cd /tmp/srvro && chmod 555 .
./hlds_run -game valve -binary ./fakesrv -debug -norestart   # сервер не стартует, «краш» на код 1

# почему: script с пустым именем файла не запускает ребёнка
script -q -e --output-limit 200MiB "" -c 'echo CHILD-STARTED'; echo $?   # 1, вывод пуст

# G2: сколько шума
./hlds_run -game valve -binary ./srv -debug -norestart 2>&1 | grep -c 'wrong ELF class'   # 53
grep -c 'wrong ELF class' crash_report_*.txt                                              # 7-8

# G3: недоступный TMPDIR
mkdir /tmp/ro2 && chmod 555 /tmp/ro2
TMPDIR=/tmp/ro2 ./hlds_run -game valve -binary ./srv -debug -norestart   # «CRASH DETECTED (Exit Code: 123)»

# G4: POSIXLY_CORRECT
POSIXLY_CORRECT=1 script -q -e --output-limit 200MiB /tmp/pc.txt -c 'echo PC-OK'; echo $?  # rc=1

# G5: сервер, завершающийся по SIGTERM
FAKE_CODE=143 ./hlds_run -game valve -binary ./fakesrv2 -debug -timeout 1   # 5 рестартов, отчёта нет

# G6: отсутствие file
bash -c 'if ! nosuchcmd /etc/hostname 2>/dev/null | grep -qE "ELF.*(core|coredump)"; then echo SKIPPED; fi'

# G7: семантика --output-limit
SHELL=/bin/bash script -q -e --output-limit 1KiB /tmp/lim.txt -c '<шумный цикл>...'
# файл 4420 Б (перескок больше лимита), последняя строка обрезана, «<max output size exceeded>»

# E2E с настоящим core
gdb -q -batch -ex 'break main' -ex run -ex 'gcore /tmp/fakecore' -ex kill --args ./srv
file /tmp/fakecore            # ELF 64-bit LSB core file, x86-64
PLANT=1 ./hlds_run -game valve -binary ./srv -debug -norestart
grep -n '^=== ' crash_report_*.txt      # пять секций GDB

# статические проверки
bash -n hlds_run
shellcheck -s bash hlds_run

# формат ldconfig (какую библиотеку выберет awk)
ldconfig -p | grep malloc_debug
#   libc_malloc_debug.so.0 (libc6,x86-64) => /usr/lib/libc_malloc_debug.so.0
#   libc_malloc_debug.so.0 (libc6)        => /usr/lib32/libc_malloc_debug.so.0   <- выбирается эта
```
