#!/bin/bash
# Integration tests for hlds_run, driven by the fake server tests/fake_hlds.
#
#   tests/run.sh [path/to/hlds_run] [test-letters]     e.g. tests/run.sh ./hlds_run AC
#
# Needs: bash, util-linux script, coreutils, procps (pgrep/pkill); tmux for J-L
# (skipped without it). Slow part:
# test C pushes 260 MiB through the pty (seconds to a minute).
# TEST_SHELL picks $SHELL for `script` (default fish if installed, else bash):
# script re-parses its -c command through $SHELL.
#
# Everything runs in a private work directory with its own TMPDIR: the
# wrapper sweeps stale hlds-run.* directories at start, and a shared /tmp
# would expose a live server's capture directory to these runs.

# shellcheck disable=SC2016,SC2034,SC2086,SC2012,SC2217 # chk() evals single-quoted checks (vars used there); field splitting in starttime(); ls over our own test files
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(readlink -f "${1:-$HERE/../hlds_run}")
ONLY=${2:-}
[[ -x "$W" ]] || { echo "wrapper not found: $W"; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hlds-run-tests.XXXXXX") || exit 2
HELPERS=()
trap 'for p in "${HELPERS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/srv/valve" "$WORK/tmp"
cp "$HERE/fake_hlds" "$WORK/srv/fake_hlds"; chmod +x "$WORK/srv/fake_hlds"
export TMPDIR="$WORK/tmp"
if [[ -n "${TEST_SHELL:-}" ]]; then export SHELL="$TEST_SHELL"
elif command -v fish >/dev/null; then SHELL=$(command -v fish); export SHELL
else export SHELL=/bin/bash; fi
cd "$WORK/srv" || exit 2

pass=0; fail=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
clean() { rm -f crash_report_* finished op.log core core.* crash_core.* 2>/dev/null; }
want() { [[ -z "$ONLY" || "$ONLY" == *"$1"* ]]; }
oplog() { tr -d '\r' < op.log; }
# Our readers only: the wrapper's capture `tail` runs with exactly this argv.
readers() { pgrep -u "$(id -u)" -f '^tail -n 100$'; }
starttime() { local s; s=$(cat "/proc/$1/stat") || return 1; s=${s##*) }; set -- $s; echo "${20}"; }

echo "wrapper: $W"; echo "SHELL:   $SHELL"; echo "TMPDIR:  $TMPDIR"

if want A; then echo "A: clean exit"; clean
	FAKE_MODE=exit0 timeout 60 "$W" -binary ./fake_hlds -game valve -norestart +hostname "Sky  сервер" "a'b\"c" > op.log 2>&1; rc=$?
	chk "rc=0 ($rc)" '[ $rc -eq 0 ]'
	chk "operator console complete (line 300)" 'oplog | grep -qx "line 300"'
	chk "no crash report" '! ls crash_report_* >/dev/null 2>&1'
	chk "args with spaces/Cyrillic/quotes intact" 'oplog | grep -qxF "ARG4=[Sky  сервер]" && oplog | grep -qxF "ARG5=[a'"'"'b\"c]"'
	chk "server SIGPIPE not ignored ($(oplog | grep -o "SIGIGN=.*"))" '(( (16#$(oplog | sed -n "s/^SIGIGN=//p") & 0x1000) == 0 ))'
	chk "no extra fds in server ($(oplog | grep -o "FDS=.*"))" 'oplog | grep -qx "FDS="'
	chk "clean-exit message" 'oplog | grep -q "shut down cleanly"'
	chk "private directory removed" '[ -z "$(ls -A "$TMPDIR")" ]'
fi

if want B; then echo "B: crash (SIGSEGV) with -debug"; clean
	FAKE_MODE=segv timeout 120 "$W" -binary ./fake_hlds -game valve -norestart -debug > op.log 2>&1; rc=$?
	r=$(ls crash_report_* 2>/dev/null | head -1)
	chk "rc=139 ($rc)" '[ $rc -eq 139 ]'
	chk "crash report written" '[ -n "$r" ]'
	chk "report has the console tail (line 150, line 60)" 'grep -qx "line 150" "$r" && grep -qx "line 60" "$r"'
	chk "report has only the tail (no line 40)" '! grep -qx "line 40" "$r"'
	chk "no script annotations in report" '! grep -q "Script started\|Script done" "$r"'
fi

if want C; then echo "C: console > 200 MiB (260 MiB) - no output limit"; clean
	s=$(date +%s)
	FAKE_MODE=spam:260 timeout 600 "$W" -binary ./fake_hlds -game valve -norestart > /dev/null 2> op.log & wp=$!
	maxrss=0
	while kill -0 $wp 2>/dev/null; do
		for p in $(readers); do r=$(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null); [ "${r:-0}" -gt $maxrss ] && maxrss=$r; done
		sleep 0.5
	done
	wait $wp; rc=$?
	chk "rc=0 ($rc), $(( $(date +%s) - s ))s" '[ $rc -eq 0 ]'
	chk "server not killed (ran to the end)" '[ -f finished ]'
	chk "reader memory bounded (max RSS ${maxrss} KB)" '[ $maxrss -gt 0 ] && [ $maxrss -lt 20000 ]'
fi

if want D; then echo "D: capture reader dies mid-run"; clean
	FAKE_MODE=longrun:4 timeout 60 "$W" -binary ./fake_hlds -game valve -norestart -debug > op.log 2>&1 & wp=$!
	sleep 1.5; killed=$(readers | xargs -r kill 2>/dev/null; echo $?)
	wait $wp; rc=$?
	chk "reader killed" '[ "$killed" -eq 0 ]'
	chk "rc=0 ($rc) - not a crash, no restart" '[ $rc -eq 0 ]'
	chk "server ran to the end" '[ -f finished ]'
	chk "operator console continues (tick 40)" 'oplog | grep -qx "tick 40"'
	chk "no false crash report" '! ls crash_report_* >/dev/null 2>&1'
fi

if want E; then echo "E: operator LD_PRELOAD reaches the server"; clean
	lib=$(ls /usr/lib/libc_malloc_debug.so.0 /usr/lib/x86_64-linux-gnu/libc_malloc_debug.so.0 /lib/x86_64-linux-gnu/libc_malloc_debug.so.0 2>/dev/null | head -1)
	if [[ -z "$lib" ]]; then echo "  SKIP (no 64-bit libc_malloc_debug.so.0)"; else
		LD_PRELOAD=$lib FAKE_MODE=exit0 timeout 60 "$W" -binary ./fake_hlds -game valve -norestart > op.log 2>&1; rc=$?
		chk "rc=0, PRELOAD=[$lib]" '[ $rc -eq 0 ] && oplog | grep -qxF "PRELOAD=[$lib]"'
		chk "no wrong-ELF-class noise" '! oplog | grep -q "cannot be preloaded"'
	fi
fi

if want F; then echo "F: crash-loop guard"; clean
	FAKE_MODE=segv timeout 120 "$W" -binary ./fake_hlds -game valve -timeout 1 > op.log 2>&1; rc=$?
	chk "gives up after 5 crashes, rc=1 ($rc)" '[ $rc -eq 1 ] && oplog | grep -q "Crash-loop detected: 5"'
	chk "every run captured (FAKE START x5)" '[ "$(oplog | grep -c "^FAKE START")" -eq 5 ]'
fi

if want G; then echo "G: reader dies, then the server crashes"; clean
	FAKE_MODE=longsegv:3 timeout 90 "$W" -binary ./fake_hlds -game valve -norestart -debug > op.log 2>&1 & wp=$!
	sleep 1.2; readers | xargs -r kill 2>/dev/null; wait $wp; rc=$?
	r=$(ls crash_report_* 2>/dev/null | head -1)
	chk "rc=139 ($rc), report written" '[ $rc -eq 139 ] && [ -n "$r" ]'
	chk "report says the tail is missing" 'grep -q "capture reader ended early" "$r"'
	n=$(oplog | grep -c -i -E "write|pipe|канал")
	chk "write error not spammed ($n line(s))" '[ "$n" -le 2 ]'
fi

if want H; then echo "H: stale private directory sweep"; clean
	mk() { mkdir -p "$TMPDIR/hlds-run.$1"; touch "$TMPDIR/hlds-run.$1/caplog.x"; }
	old() { touch -d '2 hours ago' "$TMPDIR/hlds-run.$1"; }
	sleep 300 > /dev/null 2>&1 < /dev/null & live=$!; HELPERS+=("$live")
	# Stands in for an older wrapper's `script`, which names its launcher in
	# argv for the whole run. Two commands: a lone one would make bash exec
	# sleep and lose the path from the command line.
	bash -c 'sleep 300; :' "$TMPDIR/hlds-run.legacyused/launcher.x" > /dev/null 2>&1 < /dev/null & legacy_owner=$!; HELPERS+=("$legacy_owner")
	true & dead=$!; wait $dead
	mk deadowner;    echo "$dead 12345" > "$TMPDIR/hlds-run.deadowner/owner"; old deadowner
	mk liveowner;    echo "$live $(starttime $live)" > "$TMPDIR/hlds-run.liveowner/owner"; old liveowner
	mk pidreused;    echo "$live 1" > "$TMPDIR/hlds-run.pidreused/owner"; old pidreused
	mk badowner;     echo "garbage" > "$TMPDIR/hlds-run.badowner/owner"; old badowner
	mk legacyused;   old legacyused
	mk legacyunused; old legacyunused
	mk legacyfresh
	sleep 0.3
	FAKE_MODE=exit0 timeout 60 "$W" -binary ./fake_hlds -game valve -norestart > op.log 2>&1; rc=$?
	has() { [ -d "$TMPDIR/hlds-run.$1" ]; }
	chk "rc=0 ($rc)" '[ $rc -eq 0 ]'
	chk "kept: live owner (old mtime)" 'has liveowner'
	chk "kept: no owner, named in a live cmdline (older wrapper)" 'has legacyused'
	chk "kept: no owner, fresh (neighbor just starting)" 'has legacyfresh'
	chk "swept: dead owner" '! has deadowner'
	chk "swept: PID reused (start time differs)" '! has pidreused'
	chk "swept: malformed owner file" '! has badowner'
	chk "swept: no owner, old, unreferenced" '! has legacyunused'
	chk "sweep logged (4 dirs)" 'oplog | grep -q "Swept 4 stale"'
	pkill -P "$legacy_owner" 2>/dev/null; kill "$live" "$legacy_owner" 2>/dev/null; wait "$live" "$legacy_owner" 2>/dev/null
	rm -rf "$TMPDIR"/hlds-run.*
fi

if want I; then echo "I: own directory carries an owner file"; clean
	FAKE_MODE=longrun:2 timeout 60 "$W" -binary ./fake_hlds -game valve -norestart > op.log 2>&1 & wp=$!
	sleep 0.8
	o=$(cat "$TMPDIR"/hlds-run.*/owner 2>/dev/null | head -1); opid=${o%% *}; ost=${o#* }
	chk "owner = live wrapper PID + its start time ($o)" '[ -n "$opid" ] && [ "$(starttime "$opid")" = "$ost" ] && tr "\0" " " < /proc/$opid/cmdline | grep -q hlds_run'
	wait $wp
	chk "directory removed after exit" '[ -z "$(ls -A "$TMPDIR")" ]'
fi

# J-M: stopping. tmux kill-session (LinuxGSM stop) must take the server down
# with the wrapper; a console "quit" must still reach the server.
procs() { pgrep -f "^/bin/bash (\./fake_hlds|$W) .*\+tag $1\$"; }
gone_within() { local i; for i in $(seq 1 $(( $2 * 10 ))); do [ -z "$(procs "$1")" ] && return 0; sleep 0.1; done; return 1; }
TSOCK="hlds-run-tests-$$"
# exec: the wrapper must be the session leader of the pane, as under
# LinuxGSM - the kernel sends the hangup SIGHUP only to the session leader.
tmux_run() { tmux -L "$TSOCK" new-session -d -s t -x 200 -y 50 "cd '$WORK/srv' && exec env TMPDIR='$2' FAKE_MODE=console:60 '$W' -binary ./fake_hlds -game valve +tag $1"; }
if command -v tmux >/dev/null; then trap 'tmux -L "$TSOCK" kill-server 2>/dev/null; for p in "${HELPERS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT; fi

if want J; then echo "J: tmux kill-session stops the server (capture mode)"; clean
	if ! command -v tmux >/dev/null; then echo "  SKIP (no tmux)"; else
		tag=J$$; tmux_run $tag "$TMPDIR"; sleep 2
		chk "server and wrapper running" '[ "$(procs $tag | wc -l)" -eq 2 ]'
		tmux -L "$TSOCK" kill-session -t t
		chk "all gone within 5 s after kill-session" 'gone_within $tag 5'
		chk "no restart afterwards" 'sleep 2; [ -z "$(procs $tag)" ]'
		pkill -f "\+tag $tag\$" 2>/dev/null; sleep 0.5; rm -rf "$TMPDIR"/hlds-run.*
	fi
fi

if want K; then echo "K: tmux kill-session stops the server (plain tty mode)"; clean
	if ! command -v tmux >/dev/null; then echo "  SKIP (no tmux)"; else
		tag=K$$; tmux_run $tag "$WORK/no-such-dir"; sleep 2
		chk "server and wrapper running" '[ "$(procs $tag | wc -l)" -eq 2 ]'
		tmux -L "$TSOCK" kill-session -t t
		chk "all gone within 5 s after kill-session" 'gone_within $tag 5'
		pkill -f "\+tag $tag\$" 2>/dev/null; sleep 0.5
	fi
fi

if want L; then echo "L: console command reaches the server (quit = clean stop)"; clean
	if ! command -v tmux >/dev/null; then echo "  SKIP (no tmux)"; else
		tag=L$$; tmux_run $tag "$TMPDIR"; sleep 2
		tmux -L "$TSOCK" send-keys -t t quit ENTER
		chk "server got quit and exited" 'gone_within $tag 5 && grep -qx QUIT-OK finished'
		tmux -L "$TSOCK" kill-server 2>/dev/null
		pkill -f "\+tag $tag\$" 2>/dev/null; sleep 0.5; rm -rf "$TMPDIR"/hlds-run.*
	fi
fi

if want M; then echo "M: SIGTERM to the wrapper stops the server at once"; clean
	tag=M$$
	FAKE_MODE=console:60 "$W" -binary ./fake_hlds -game valve +tag $tag > op.log 2>&1 < /dev/null & wp=$!
	sleep 1.5; t0=$(date +%s%N)
	kill -TERM $wp; wait $wp; rc=$?
	ms=$(( ($(date +%s%N) - t0) / 1000000 ))
	chk "rc=143 ($rc)" '[ $rc -eq 143 ]'
	chk "wrapper exited within 3 s (${ms} ms)" '[ $ms -lt 3000 ]'
	chk "server gone" 'gone_within $tag 2'
	chk "stop logged" 'oplog | grep -q "Received SIGTERM - stopping the server"'
	chk "private directory removed" '[ -z "$(ls -A "$TMPDIR")" ]'
fi

clean
echo "== TOTAL: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ]
