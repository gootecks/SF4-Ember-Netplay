#!/usr/bin/env bash
# Wine boundary check: does Winsock loopback / a Windows named pipe inside a
# throwaway Wine prefix reach native macOS processes? (issue #4)
#
#   scripts/macos-engine/loopback/run.sh <path-to-engine-root>   # root contains bin/wine
#
# Uses a scratch prefix under ${TMPDIR}; never touches any Highball bottle.
# Prints RESULT <test> PASS|FAIL <detail> lines; see docs/validation/2026-10-09-m0-report.md.
set -u

ENGINE=$(cd "${1:?usage: run.sh <engine-root>}" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=${TMPDIR:-/tmp}; TMP=${TMP%/}
SCRATCH="$TMP/ember-m0-loopback-$$"
export WINEPREFIX="$SCRATCH/pfx"
export WINEDEBUG=-all
export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml="
# Highball engines keep dylibs in lib/; m0.sh engines keep them in frameworks/.
export DYLD_FALLBACK_FRAMEWORK_PATH="$ENGINE/frameworks"
export DYLD_FALLBACK_LIBRARY_PATH="$ENGINE/frameworks:$ENGINE/lib:${DYLD_FALLBACK_LIBRARY_PATH:-/usr/lib}"
WINE="$ENGINE/bin/wine"
WINESERVER="$ENGINE/bin/wineserver"
PROBE="$SCRATCH/winsock_probe.exe"
BASE=$((41000 + $$ % 2000)) # unique high ports per run
LOG="$SCRATCH/log"
SOCK="$TMP/discord-ipc-0"
PIDS=""

cleanup() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	[ -S "$SOCK" ] && [ -f "$SCRATCH/owns-sock" ] && rm -f "$SOCK"
	WINEPREFIX="$WINEPREFIX" "$WINESERVER" -k 2>/dev/null
	rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM
mkdir -p "$SCRATCH" "$LOG"

# run_bounded <seconds> <outfile> <cmd...>: run in background, kill after timeout.
run_bounded() {
	local secs=$1 out=$2; shift 2
	"$@" >"$out" 2>&1 &
	local pid=$!; PIDS="$PIDS $pid"
	( sleep "$secs"; kill "$pid" 2>/dev/null ) & local killer=$!
	wait "$pid" 2>/dev/null
	kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
}
wine_probe() { local secs=$1 out=$2; shift 2; run_bounded "$secs" "$out" "$WINE" "$PROBE" "$@"; }
bg_wine_probe() { local out=$1; shift; "$WINE" "$PROBE" "$@" >"$out" 2>&1 & PIDS="$PIDS $!"; }
wait_ready() { for _ in $(seq 1 120); do grep -q READY "$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
native_result() { echo "RESULT $1 $2 $3"; }

echo "# engine=$ENGINE host=$(sw_vers -productVersion 2>/dev/null) arch=$(uname -m) date=$(date -u +%FT%TZ)"
"$WINE" --version 2>&1 | sed 's/^/# wine /'

# Build probe
i686-w64-mingw32-gcc -O2 -static "$HERE/winsock_probe.c" -o "$PROBE" -lws2_32 || { echo "HARNESS-ERROR probe build failed"; exit 1; }

# Prefix
WINEARCH=win64 run_bounded 180 "$LOG/wineboot" "$WINE" wineboot -i
WINEPREFIX="$WINEPREFIX" "$WINESERVER" -w
[ -d "$WINEPREFIX/drive_c" ] || { echo "HARNESS-ERROR wineboot failed"; cat "$LOG/wineboot"; exit 1; }

# (a) UDP Wine -> native
P=$((BASE + 1))
nc -u -l 127.0.0.1 "$P" >"$LOG/a.native" 2>/dev/null & NC=$!; PIDS="$PIDS $NC"
sleep 1
wine_probe 60 "$LOG/a.wine" udp-send "$P" 5
sleep 1; kill "$NC" 2>/dev/null
cat "$LOG/a.wine" | grep -E '^RESULT|^local_port'
N=$(grep -c 'ember-m0-udp-' "$LOG/a.native" 2>/dev/null)
if [ "${N:-0}" -gt 0 ]; then native_result udp-wine-to-native PASS "native_received_datagram_lines=$N"; else native_result udp-wine-to-native FAIL "native_received=0 ($(grep -h RESULT "$LOG/a.wine" | tr '\n' ' '))"; fi

# (b) UDP native -> Wine, bidirectional
P=$((BASE + 2))
bg_wine_probe "$LOG/b.wine" udp-echo "$P" 20; W=$!
if wait_ready "$LOG/b.wine"; then
	# nc -u sends 3 lines at 1s spacing and waits for replies
	( for i in 1 2 3; do echo "native-ping-$i"; sleep 1; done ) | nc -u -w 3 127.0.0.1 "$P" >"$LOG/b.native" 2>/dev/null &
	NCP=$!; PIDS="$PIDS $NCP"; wait "$NCP" 2>/dev/null
	sleep 1
fi
kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
grep -E '^RESULT' "$LOG/b.wine"
R=$(grep -c 'native-ping' "$LOG/b.native" 2>/dev/null)
if [ "${R:-0}" -gt 0 ]; then native_result udp-native-to-wine-reply PASS "native_got_echo_lines=$R"; else native_result udp-native-to-wine-reply FAIL "native_echo_lines=0 (wine: $(tr '\n' ' ' <"$LOG/b.wine"))"; fi

# (c) TCP Wine -> native
P=$((BASE + 3))
( echo native-pong | nc -l 127.0.0.1 "$P" >"$LOG/c.native" 2>/dev/null ) & PIDS="$PIDS $!"
sleep 1
wine_probe 60 "$LOG/c.wine" tcp-connect "$P" wine-hello
sleep 1
grep -E '^RESULT' "$LOG/c.wine"
if grep -q wine-hello "$LOG/c.native" 2>/dev/null && grep -q 'RESULT tcp-wine-to-native PASS' "$LOG/c.wine"; then
	native_result tcp-wine-to-native-both-ways PASS "native_received=wine-hello wine_got_reply=native-pong"
else native_result tcp-wine-to-native-both-ways FAIL "native_file=$(tr '\n' ' ' <"$LOG/c.native" 2>/dev/null) wine=$(tr '\n' ' ' <"$LOG/c.wine")"; fi

# (d) TCP native -> Wine listener
P=$((BASE + 4))
bg_wine_probe "$LOG/d.wine" tcp-listen "$P" 25; W=$!
if wait_ready "$LOG/d.wine"; then
	echo native-hello | nc -w 5 127.0.0.1 "$P" >"$LOG/d.native" 2>/dev/null
	sleep 1
fi
kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
grep -E '^RESULT' "$LOG/d.wine"
if grep -q pong "$LOG/d.native" 2>/dev/null; then native_result tcp-native-to-wine-both-ways PASS "native_got_reply=pong"; else native_result tcp-native-to-wine-both-ways FAIL "native_got_nothing wine=$(tr '\n' ' ' <"$LOG/d.wine")"; fi

# (e) Discord: Windows named pipe -> native unix socket $TMPDIR/discord-ipc-0
if [ -e "$SOCK" ]; then
	native_result discord-pipe-to-native-socket FAIL "harness: $SOCK already exists (real Discord?); skipped"
else
	touch "$SCRATCH/owns-sock"
	nc -U -l "$SOCK" >"$LOG/e.native" 2>/dev/null & NCU=$!; PIDS="$PIDS $NCU"
	sleep 1
	wine_probe 60 "$LOG/e.wine" pipe
	kill "$NCU" 2>/dev/null; wait "$NCU" 2>/dev/null
	grep -E '^pipe|^handshake|^RESULT' "$LOG/e.wine"
	if [ -s "$LOG/e.native" ]; then native_result discord-pipe-to-native-socket PASS "native_socket_received_bytes=$(wc -c <"$LOG/e.native" | tr -d ' ')"
	else native_result discord-pipe-to-native-socket FAIL "native_socket_received_bytes=0 ($(grep -h 'RESULT discord' "$LOG/e.wine"))"; fi
	rm -f "$SOCK"
fi
