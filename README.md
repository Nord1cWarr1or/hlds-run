# hlds-run

**English** | **[Русский](https://github.com/Nord1cWarr1or/hlds-run/blob/main/README.ru.md)**

hlds-run is a bash crash-diagnostics wrapper for the Half-Life dedicated server (`hlds_linux`). It runs the server on a pty, mirrors its console to the operator and a capture file, restarts it after crashes under a crash-loop guard, and on every crash writes a full report: system state, the last 100 console lines and a GDB analysis of the core dump. It is a drop-in replacement for the original Valve `hlds_run` (build 10211 and newer).

## Requirements

- Linux, bash 4+
- `util-linux` `script` ≥ 2.32 — for console capture; without it the wrapper falls back to a plain tty with a warning (`--output-limit` is applied when the installed `script` supports it)
- `gdb` — only for the GDB section of crash reports
- `coredumpctl` — only if `kernel.core_pattern` is a pipe handler (systemd-coredump)
- `file` — to verify a core dump is a real ELF core; if missing, only the mtime check runs and the report says so
- `elfutils` (`eu-stack`) — optional: adds the Build-ID module registry to crash reports; without it that section is skipped

Verified on Debian 11 (glibc 2.31), Debian 13 (glibc 2.44) and Arch Linux, on real servers.

## Installation

Copy the script into the server root — the directory holding `hlds_linux` — and make it executable:

```bash
cp hlds_run /path/to/serverfiles/ && chmod +x /path/to/serverfiles/hlds_run
```

No other files are needed; helpers are created at runtime and deleted after use.

## Quick start

```bash
./hlds_run -game cstrike -debug +map de_dust2
```

The wrapper starts from the server root. A "maximum radar" session — reports, dumps, heap checking and memory fill at once:

```bash
./hlds_run -game cstrike -debug -malloc-check -malloc-perturb +map de_dust2
```

## Usage

Script-owned arguments (never passed to the server):

| Argument | Action | Default |
|----------|--------|---------|
| `-debug` | Core dumps + a full report on every crash; never touches the heap | off |
| `-malloc-check` | glibc heap checking: `MALLOC_CHECK_=3` + `libc_malloc_debug` preload (see Heap debugging) | off |
| `-malloc-perturb` | Allocation fill: `MALLOC_PERTURB_=170` (see Heap debugging) | off |
| `-norestart` | No restart loop; the server exit code is propagated | restart on |
| `-timeout N` | Delay between restarts, seconds (integer ≥ 1) | 10 |
| `-binary <path>` | Another server binary | `./hlds_linux` |
| `-game <game>` | Game type; the directory is checked for existence | `valve` |

Everything else is passed to the server unchanged — same as Valve `hlds_run`.

## Configuration

Tunables live at the top of the script:

| Constant | Meaning | Default |
|----------|---------|---------|
| `TIMEOUT` | Restart delay when `-timeout` is not given | `10` |
| `STREAK_LIMIT` | Quick crashes in a row before the wrapper gives up | `5` |
| `HEALTHY_UPTIME` | Uptime that resets the crash streak, seconds | `300` |
| `GDB` | GDB binary used for report analysis | `gdb` |
| `GAME` / `HL` | Fallbacks for `-game` / `-binary` | `valve` / `./hlds_linux` |

## Restart loop

After a crash the server restarts with a `-timeout` delay. The crash-loop guard stops the wrapper after `STREAK_LIMIT` crashes in a row where each run lived shorter than `HEALTHY_UPTIME` seconds ("Crash-loop detected"). A single crash after long uptime resets the streak. A clean exit (code 0, Ctrl+C/SIGINT, SIGTERM — a normal systemd stop) ends the loop without a report. On an operator stop (130/143) the last ~100 console lines are saved to `server_stop_<date>.log` (mode 600) next to the reports — in any mode, including without `-debug`; stop logs rotate, 3 newest kept.

## Crash report

Written per crash to `crash_report_<date>.txt` in the server root (the name carries milliseconds, so two crashes in one millisecond never overwrite each other). Contents:

- exit code, signal name (`128+N` → SIGSEGV/SIGABRT/…), full start line
- system state: kernel, load average, memory, swap, disks, top processes by CPU and RSS, TCP/UDP sockets, last 50 `dmesg` lines (noise filtered; root-only sections are honestly marked)
- engine environment by an explicit allowlist (`LD_LIBRARY_PATH`, `LD_PRELOAD`, `MALLOC_CHECK_`, `MALLOC_PERTURB_`, `TERM`, `HOME`); `STEAM_*` and `PATH` never reach the report. The file is created with mode 600 — permissions are set before writing, not after
- md5 sums: the server binary, every `.so` in the server root and in `<game>/dlls` — flags binary or mod tampering
- core dump settings: `ulimit -c`, `kernel.core_pattern`
- the last 100 lines of the server stdout+stderr, cleaned of pty `\r`, ANSI colors and `script` annotations
- GDB analysis of the core in a single batch (`-nx`, no user `~/.gdbinit`), C++ values pretty-printed, split into labeled sections — `Stacktrace` (`thread apply all bt full`), `Registers and frame info`, `Stack memory at $sp` (16 words around the stack pointer), `Disassembly` (32 instructions before `$pc`), `Memory mappings`, `Shared libraries`. Known gdb noise is filtered out (`No symbol table info available`, xstate warnings, deleted-`/dev/shm` mapping warnings, the `[New LWP]` roll call, unused `k0-k7` register lines); stripped `?? ()` frames stay — they are the backtrace
- elfutils pass before GDB: `eu-stack -l` records the Build-ID of every loaded module — the one identification that survives stripping (matches exact library versions post-mortem). The section is skipped when `eu-stack` is absent and honestly marked as skipped when it cannot read the dump

## Core dumps

Without `-debug` no core dumps or reports are created; behavior stays untouched, heap layout included. The same holds under `-debug`: observability never touches the heap — only the explicit `-malloc-check` / `-malloc-perturb` change it.

With `-debug`:

- `ulimit -c unlimited` (with a warning if the limit did not rise — container or service limits)
- after analysis the core is renamed to `crash_core.<date>.dmp`; dumps rotate, 3 newest kept
- if `kernel.core_pattern` is a pipe handler (systemd-coredump configured, no file on disk), fresh dumps are exported via `coredumpctl dump hlds_linux` (up to 5 attempts with a pause — systemd processes dumps asynchronously) and removed after analysis
- only dumps created after this server start and passing the ELF-core check (`file`) are analyzed; a `core*` left by an earlier crash or a random `core_*.txt` is ignored with a warning (the same time bound applies to `coredumpctl`)

## Heap debugging (opt-in)

The `-malloc-check` and `-malloc-perturb` flags enable glibc's debug malloc. `-debug` never touches the heap: reports and dumps can be taken without changing server behavior. Both flags add overhead and rearrange the heap — enable them for a diagnostics session, not permanently.

- `-malloc-check` — `MALLOC_CHECK_=3`, strict glibc heap checking: heap corruption produces a loud `abort` instead of quiet fallout. On glibc ≥ 2.34 (Debian 12+, Arch, Ubuntu 22+) it works only with `libc_malloc_debug.so` preloaded — the wrapper finds it via `ldconfig` (the 32-bit one, for the server binary) and passes it as `LD_PRELOAD` to the server process only (through a launcher/`env`; wrapper helpers never see the preload — no `wrong ELF class` noise from 64-bit tools); on older glibc (Debian 11, CentOS) the variable works without a preload. **The debug malloc rearranges the heap:** layout-sensitive corruption fires elsewhere and, in the worst case, disappears entirely (verified on Debian 13: `SteamGameServer_Init` crashes vanished under the preload). A crash that reproduces without `-malloc-check` but not with it is layout-dependent — that alone is a lead
- `-malloc-perturb` — `MALLOC_PERTURB_=170`: fresh allocations are filled with 0xAA, freed memory with ~0xAA (0x55). Makes use-after-free fire almost immediately; adds noticeable overhead to every malloc/free. Works on every glibc, no preload needed

The operator's own `LD_PRELOAD` (e.g. from a systemd unit) is never dropped, in any mode: it is removed from the wrapper's shell scope (so 64-bit helpers stay quiet) and passed to the server — together with the heap-debug library when `-malloc-check` is on; `Operator LD_PRELOAD passed to the server: …` is logged. If its value equals the found heap-debug library, no duplicate is created.

## Console capture

By default the server runs on a pty via `script`: live output goes to the operator's terminal, a copy lands in a hidden typescript in the server directory (on the real filesystem, not tmpfs; the 200 MiB `--output-limit` guards against a spamming console; when the limit is hit, `script` stops writing and the report marks the tail as possibly stale — it is frozen at truncation time, not crash time), from where the report takes the last 100 lines of both streams. The server command is handed to `script` through a temporary launcher file with a `#!/bin/bash` shebang — arguments are always parsed by bash, not by `$SHELL` (dash, fish and others would mangle quoting and Cyrillic). `script -e` preserves the server exit code. Without `script` — plain-tty fallback with a warning. There are no user-facing capture options — deliberate.

Before launch the wrapper probes both places capture needs: `TMPDIR` (the launcher lives there) and the server directory (the typescript lands there). An unwritable server directory only disables capture with a warning — the server runs as usual; an unwritable `TMPDIR` is a hard start error, because the launcher would be empty and the server would never start. In plain-tty mode the probes are skipped: no `TMPDIR` is needed there.

## Files and artifacts

| File | Created | Lifetime |
|------|---------|----------|
| `.caplog.XXXXXX` | every server run | deleted right after the console tail is taken (EXIT-trap fallback) |
| `crash_report_<date>.txt` | every crash | kept, no rotation — by design |
| `crash_core.<date>.dmp` | every analyzed crash | rotated, 3 newest kept |
| `server_stop_<date>.log` | clean operator stop (130/143) | rotated, 3 newest kept |

Reads: the server binary and libraries (md5 sums), `/proc`, core dumps. `STEAM_*` and `PATH` values are never written anywhere.

## Improvements over the original

- **Full crash reports** instead of three commands (`bt`, `info locals`, `frame`) appended to one `debug.log`: signal and exit code, system state (memory, swap, disks, load, dmesg), engine environment, md5 sums of the binary and all `.so`, core dump settings, console tail, full GDB analysis (`thread apply all bt full`, registers, disassembly around `$pc`, mappings, shared libraries)
- **One report per crash** (`crash_report_<date>.txt`) — the original appends everything into a single growing `debug.log`
- **Console capture over a pty**: the operator sees the console live and the report gets the last 100 lines of stdout+stderr (cleaned of `\r` and ANSI codes) — the original captures no console at all
- **systemd-coredump**: when `core_pattern` is a pipe handler, the dump is exported via `coredumpctl`; the original only knows on-disk cores
- **Core dump management**: rename after analysis and rotation (3 newest) — the original never tracks dumps
- **Crash-loop guard**: stops after a streak of fast crashes; the original restarts forever
- **Opt-in heap diagnostics**: `-debug` raises `ulimit -c unlimited` (the original: 2000 blocks) without touching the heap; `-malloc-check`/`-malloc-perturb` enable heap checking separately — observability is not mixed with behavior changes, and heap corruption gives a loud abort only when the operator asked for it
- **Signal decoding** in the report (exit 139 → SIGSEGV and so on)
- **Strict argument parsing**: script-owned flags never leak to the server; a missing value or a non-numeric `-timeout` is an error, not a silently mangled command line as in the original
- **Honest server exit code** (via `script -e`); some old wrappers always exit 0

## Differences from the original Valve hlds_run (10211)

The core — argument parsing, launch, restart loop — is compatible. Not carried over (obsolete Valve plumbing):

- `-pidfile`, `-gdb`, `-debuglog`; `-debuglog` is replaced by per-crash `crash_report_*.txt` files
- `-autoupdate`, `-steamerr`, `-beta` and the `$FORCE` variable (steamcmd auto-update) — update the server separately, with SteamCMD or LinuxGSM
- `-ignoresigint`, `-notrap` — already dead in build 10211 itself (the trap handler is commented out); not ported
- `-help` is absent; this README stands in its place

In the original, crash diagnostics amount to a `bt` command written into a shared `debug.log`; here it is a full system-state report per crash.

## Credits

The Build-ID registry (eu-stack), the stack memory view and the gdb pretty-printing ideas were adopted from [hun1er](https://github.com/hun1er)'s hlds_run variant.

## License

Distributed under the GNU General Public License, version 3. See `LICENSE` for details.

hlds-run is an independent rewrite of the Valve `hlds_run` launcher: it contains no Valve code and is not affiliated with or endorsed by Valve. Half-Life and Valve are trademarks of Valve Corporation.
