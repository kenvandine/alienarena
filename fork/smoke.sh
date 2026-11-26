#!/usr/bin/env bash
# Smoke tests a build: the dedicated server loads a map, then the client starts
# under Xvfb, gets into the same map, keeps running and draws it. A client built
# with SDL2 also gets a virtual controller (fork/vpad.c), whose Y button and
# left stick it has to see. Logs and a screenshot go to OUT.
#
#   fork/smoke.sh BINDIR SOURCE DATA OUT
#
# BINDIR holds alienarena and alienarena-ded, SOURCE is the tree they were built
# from (for arena/), DATA a checkout with data1/. The last line it prints says
# how it went.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fork/lib.sh
. "$here/lib.sh"

bin=$(cd "$1" && pwd)
src=$(cd "$2" && pwd)
data=$(cd "$3" && pwd)
mkdir -p "$4"
out=$(cd "$4" && pwd)
map=${SMOKE_MAP:-dm-deathray}
load_secs=${SMOKE_LOAD_SECS:-180}
settle_secs=${SMOKE_SETTLE_SECS:-10}

game=$(mktemp -d)
PIDS=()
cleanup() {
	local p
	for p in "${PIDS[@]}"; do stop "$p"; done
	rm -rf "$game"
}
trap cleanup EXIT

ln -s "$data/data1" "$game/data1"
ln -s "$src/arena" "$game/arena"
mkdir -p "$game/home"
export XDG_DATA_HOME=$game/home
cd "$game"

# Starts the command in its own session, through script(1) because the game
# only logs (and the dedicated server only runs) with a terminal.
start() {
	local log=$1
	shift
	setsid script -qfec "$(printf '%q ' "$@")" "$log" </dev/null >/dev/null 2>&1 &
	PID=$!
	PIDS+=("$PID")
}

stop() {
	kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || true
	for _ in 1 2 3 4 5; do kill -0 "$1" 2>/dev/null || break; sleep 1; done
	kill -KILL -- "-$1" 2>/dev/null || true
	wait "$1" 2>/dev/null || true
}

# Waits until LOG matches REGEX; fails when PID ends or SECS pass.
wait_for() {
	local log=$1 pid=$2 secs=$3 re=$4 i
	for ((i = 0; i < secs; i++)); do
		if [ -f "$log" ] && plain "$log" | grep -Eq "$re"; then return 0; fi
		kill -0 "$pid" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

failed() {
	local log=$1
	shift
	if [ -f "$log" ]; then
		echo "--- last lines of $(basename "$log")"
		plain "$log" | tail -n 25
	fi
	echo "$*"
	exit 1
}

loaded='Loaded [0-9]+ entities'

start "$out/dedicated.log" "$bin/alienarena-ded" +set dedicated 1 +map "$map"
ded=$PID
wait_for "$out/dedicated.log" "$ded" 60 "$loaded" ||
	failed "$out/dedicated.log" "the dedicated server didn't load $map"
stop "$ded"

Xvfb -displayfd 5 -screen 0 1280x720x24 -nolisten tcp 5>"$game/display" 2>"$out/xvfb.log" &
PIDS+=("$!")
for _ in $(seq 50); do [ -s "$game/display" ] && break; sleep 0.2; done
[ -s "$game/display" ] || failed "$out/xvfb.log" "Xvfb didn't start"
DISPLAY=":$(head -n 1 "$game/display")"
export DISPLAY

# With SDL2 in the build, a virtual controller presses Y and pushes the left
# stick forward once the client is in the map.
pad=
client_env=()
# shellcheck disable=SC2046 # pkg-config prints several flags
if ldd "$bin/alienarena" | grep -q libSDL2 &&
	cc -shared -fPIC -o "$game/vpad.so" "$here/vpad.c" $(pkg-config --cflags --libs sdl2) -ldl \
		>"$out/vpad-build.log" 2>&1; then
	pad=yes
	mkdir -p "$game/home/cor-games/arena"
	printf 'set pad_debug 1\nbind PAD_Y "echo virtual pad: Y"\n' >"$game/home/cor-games/arena/autoexec.cfg"
	printf '0 button 3 1\n200 button 3 0\n500 axis 1 -32767\n3000 axis 1 0\n' >"$game/vpad.txt"
	client_env=(env "LD_PRELOAD=$game/vpad.so" "VPAD_SCRIPT=$game/vpad.txt" "VPAD_GO=$game/go")
fi

# shellcheck disable=SC2086 # SMOKE_CLIENT_ARGS is several words
start "$out/client.log" "${client_env[@]}" "$bin/alienarena" +set vid_fullscreen 0 +set gl_mode -1 \
	+set vid_width 1280 +set vid_height 720 +set s_initsound 0 +set allow_download 0 \
	${SMOKE_CLIENT_ARGS:-} +map "$map"
client=$PID
wait_for "$out/client.log" "$client" "$load_secs" 'entered the game' ||
	failed "$out/client.log" "the client didn't get into $map"
if [ -n "$pad" ]; then
	touch "$game/go"
	wait_for "$out/client.log" "$client" 30 'virtual pad: Y' ||
		failed "$out/client.log" "the client didn't take the virtual controller's Y button"
	wait_for "$out/client.log" "$client" 30 'pad: move 0\.00 1\.00' ||
		failed "$out/client.log" "the client didn't move with the virtual controller's left stick"
fi
sleep "$settle_secs"
kill -0 "$client" 2>/dev/null || failed "$out/client.log" "the client quit or crashed after loading $map"
import -display "$DISPLAY" -window root "$out/client.png"
light=$(convert "$out/client.png" -colorspace Gray -format '%[fx:mean]' info:)
awk -v l="$light" 'BEGIN { exit !(l > 0.03) }' ||
	failed "$out/client.log" "the client's screen is blank (mean brightness $light)"
stop "$client"
echo "the dedicated server loaded $map and the client played it${pad:+ with a virtual controller} (screen brightness $light)"
