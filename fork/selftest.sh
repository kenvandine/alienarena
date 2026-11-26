#!/usr/bin/env bash
# Tests sync.sh against a tiny made-up upstream and fork, with stand-ins for
# the autotools, the build and the smoke test, so it needs no network, Docker
# or game data. Runs in a few seconds:
#
#   fork/selftest.sh
# The checks are strings eval runs later, so single quotes are on purpose.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
t=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] && echo "kept $t" >&2 || rm -rf "$t"' EXIT
fails=0
runs=0

export GIT_AUTHOR_NAME="Pat Example" GIT_AUTHOR_EMAIL=pat@example.com
export GIT_COMMITTER_NAME="Pat Example" GIT_COMMITTER_EMAIL=pat@example.com
export GIT_CONFIG_GLOBAL=$t/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch master
git config --global uploadpack.allowFilter true
git config --global advice.detachedHead false

check() {
	if eval "$1"; then
		echo "  ok   $2"
	else
		echo "  FAIL $2"
		fails=$((fails + 1))
	fi
}

# The stand-ins.
export REGEN_AUTOTOOLS_CMD='printf "generated from: %s\n" "$(tr "\n" " " <configure.ac)" >configure'
cat >"$t/build.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$2/source"; echo "built"
EOF
cat >"$t/smoke.sh" <<'EOF'
#!/usr/bin/env bash
if [ -e "$2/BROKEN" ]; then echo "found BROKEN"; exit 1; fi
echo "smoke ok"
EOF
chmod +x "$t/build.sh" "$t/smoke.sh"
export BUILD_SH=$t/build.sh SMOKE_SH=$t/smoke.sh
export FORK_URL=file://$t/fork.git UPSTREAM_URL=file://$t/up.git
export STACK_FILE=$t/stack.txt
export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

sync() {
	runs=$((runs + 1))
	rm -rf "$t/work"
	if WORK=$t/work GIT_COMMITTER_NAME="fork sync" GIT_COMMITTER_EMAIL=sync@example.com \
		"$here/sync.sh" >"$t/sync-$runs.log" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	cp "$t/work/summary.md" "$t/summary-$runs.md" 2>/dev/null || true
}

fork() { git -C "$t/fork.git" "$@"; }
at() { fork rev-parse "$1"; }
show() { fork show "$1:$2"; }
regen_of() { printf 'generated from: %s\n' "$(fork show "$1:configure.ac" | tr '\n' ' ')"; }

# Upstream with one release.
git init -q "$t/up"
cd "$t/up"
mkdir -p source data1 m4
printf 'AC_INIT 1.0\ndnl checks\nAC_OUTPUT\n' >configure.ac
printf 'SUBDIRS = source\n' >Makefile.am
printf 'Makefile\n' >Makefile.in
printf 'key one\r\nkey two\r\nkey three\r\n' >source/keys.c
printf 'menu one\nmenu two\nmenu three\nmenu four\nmenu five\nmenu six\nmenu seven\n' >source/menu.c
printf 'cvar one\n' >CVAR.md
printf '#!/bin/sh\nsed "s/^/<p>/" "$1" >"${1%%.md}.html"\n' >convert_md_to_html.sh
printf 'map\n' >data1/map.bsp
sh convert_md_to_html.sh CVAR.md
eval "$REGEN_AUTOTOOLS_CMD"
git add -A
git commit -qm "Alien Arena 1.0"
git tag 1.0
git clone -q --bare "$t/up" "$t/up.git"
git clone -q --bare "$t/up" "$t/fork.git"
fork tag -d 1.0 >/dev/null
git remote add origin "$t/up.git"

# The fork's stack, as Ken would push it.
git clone -q "$t/fork.git" "$t/dev"
cd "$t/dev"
git checkout -qb pad/1-keys
printf 'key one\r\nkey two PAD\r\nkey three\r\n' >source/keys.c
git commit -qam "Make room for pad keys"
git checkout -qb pad/2-linux
printf 'pad\n' >source/in_pad.c
printf 'AC_INIT 1.0\ndnl checks\nAC_ARG_WITH sdl2\nAC_OUTPUT\n' >configure.ac
git add -A
git commit -qm "Read pads with SDL2"
sed -i 's/menu one/menu one PAD/' source/menu.c
git commit -qam "Pads in menus"
git checkout -qb pad/3-menus
printf 'cvar one\ncvar pad\n' >CVAR.md
sed -i 's/menu seven/menu seven PAD/' source/menu.c
git commit -qam "Pad options screen"
git push -q origin pad/1-keys pad/2-linux pad/3-menus
printf '# the stack\npad/1-keys\npad/2-linux   # SDL2\npad/3-menus\n' >"$t/stack.txt"

echo "1. First run: tags copied, generated files made, release tag"
sync
check '[ $rc = 0 ]' "sync passed"
check 'fork rev-parse -q --verify refs/tags/1.0 >/dev/null' "upstream's tag copied"
check '[ "$(at pad/1-keys)" = "$(git rev-parse pad/1-keys)" ]' "pad/1-keys untouched"
check '[ "$(fork log -1 --format=%s pad/2-linux)" = "Regenerate generated files" ]' "pad/2-linux got a regen commit"
check '[ "$(show pad/2-linux configure)" = "$(regen_of pad/2-linux)" ]' "pad/2-linux's configure matches its configure.ac"
check '[ "$(fork log -1 --format=%an pad/2-linux)" = "Pat Example" ]' "the regen commit is the branch author's"
check '[ "$(show pad/3-menus CVAR.html)" = "$(printf "<p>cvar one\n<p>cvar pad")" ]' "pad/3-menus's CVAR.html remade"
check 'fork merge-base --is-ancestor pad/2-linux pad/3-menus' "pad/3-menus sits on pad/2-linux"
check '[ "$(fork rev-parse "1.0-pad.1^{tree}")" = "$(fork rev-parse "pad/3-menus^{tree}")" ]' "1.0-pad.1 is the top of the stack"
first_tips="$(at pad/1-keys) $(at pad/2-linux) $(at pad/3-menus)"

echo "2. Nothing changed"
sync
check '[ $rc = 0 ]' "sync passed"
check '[ "$(at pad/1-keys) $(at pad/2-linux) $(at pad/3-menus)" = "$first_tips" ]' "no branch moved"
check '[ -z "$(fork tag -l "1.0-pad.2")" ]' "no new tag"
check 'grep -q "Nothing changed" "$t/work/summary.md"' "said nothing changed"

echo "3. Upstream releases 1.1, then commits more"
cd "$t/up"
printf 'AC_INIT 1.1\ndnl checks\nAC_OUTPUT\n' >configure.ac
eval "$REGEN_AUTOTOOLS_CMD"
printf 'key one\r\nkey two\r\nkey three\r\nkey four\r\n' >source/keys.c
git commit -qam "Alien Arena 1.1"
git tag 1.1
sed -i 's/menu four/menu four NEW/' source/menu.c
git commit -qam "Work after 1.1"
git push -q origin master 1.1
sync
check '[ $rc = 0 ]' "sync passed"
check '[ "$(at master)" = "$(git rev-parse master)" ]' "master mirrored"
check 'fork rev-parse -q --verify refs/tags/1.1 >/dev/null' "1.1 copied"
check 'fork merge-base --is-ancestor master pad/1-keys' "pad/1-keys on the new master"
check '[ "$(show pad/2-linux configure)" = "$(regen_of pad/2-linux)" ]' "pad/2-linux's configure remade for 1.1"
check 'show pad/2-linux configure | grep -q "AC_INIT 1.1 dnl checks AC_ARG_WITH sdl2"' "pad/2-linux's configure.ac merged"
check '[ "$(fork rev-list --count master..pad/3-menus)" = 6 ]' "six commits on master (4 patches, 2 regens)"
check 'fork merge-base --is-ancestor 1.1 1.1-pad.1' "1.1-pad.1 is built on 1.1"
check '! fork merge-base --is-ancestor master 1.1-pad.1' "1.1-pad.1 leaves out the work after 1.1"
check 'fork show 1.1-pad.1:source/menu.c | grep -q "menu one PAD" && ! fork show 1.1-pad.1:source/menu.c | grep -q NEW' "1.1-pad.1 has the patches and not the later work"

echo "4. Ken adds a commit to the top branch"
cd "$t/dev"
git fetch -q origin
git checkout -q -B pad/3-menus origin/pad/3-menus
printf 'cvar one\ncvar pad\ncvar pad2\n' >CVAR.md
git commit -qam "Another pad option"
git push -q origin pad/3-menus
sync
check '[ $rc = 0 ]' "sync passed"
check '[ "$(fork log -1 --format=%s pad/3-menus)" = "Regenerate generated files" ]' "regen commit back on top"
check '[ "$(fork log --format=%s master..pad/3-menus | grep -c "^Regenerate")" = 2 ]' "one regen commit each for pad/2 and pad/3"
check 'show pad/3-menus CVAR.html | grep -q "cvar pad2"' "CVAR.html remade"
check 'fork rev-parse -q --verify refs/tags/1.1-pad.2 >/dev/null' "1.1-pad.2 tagged"

echo "5. Upstream changes the line pad/1-keys changes"
cd "$t/up"
printf 'key one\r\nkey 2\r\nkey three\r\nkey four\r\n' >source/keys.c
git commit -qam "Rename key two"
git push -q origin master
before="$(at pad/1-keys) $(at pad/2-linux) $(at pad/3-menus)"
sync
check '[ $rc != 0 ]' "sync stopped"
check 'grep -q "conflicts" "$t/work/summary.md" && grep -q "source/keys.c" "$t/work/summary.md"' "summary names the conflict and the file"
check 'grep -q "signature: conflict-pad/1-keys" "$t/work/summary.md"' "summary has a signature"
check '[ "$(at master)" = "$(git rev-parse master)" ]' "master still mirrored"
check '[ "$(at pad/1-keys) $(at pad/2-linux) $(at pad/3-menus)" = "$before" ]' "no branch pushed"
git revert --no-edit HEAD >/dev/null
git push -q origin master

echo "6. Upstream merges pad/1-keys (squashed, its own message)"
printf 'key one\r\nkey two PAD\r\nkey three\r\nkey four\r\n' >source/keys.c
git commit -qam "Pad keys from Ken"
git push -q origin master
sync
check '[ $rc = 0 ]' "sync passed"
check 'grep -q "in upstream master, not yet in 1.1" "$t/work/summary.md"' "pad/1-keys reported as in upstream master"
check '[ -z "$(ls "$t/work/notices")" ]' "no notice yet: 1.1 doesn't have it"
check 'grep -q "1.1-pad.2 is current" "$t/work/summary.md"' "the 1.1 build still has pad/1-keys, so 1.1-pad.2 stands"
check '[ "$(fork merge-base master pad/2-linux)" = "$(at master)" ]' "pad/2-linux now sits on master"
check '[ "$(fork rev-list --count master..pad/2-linux)" = 3 ]' "pad/2-linux has its own two commits and a regen"

echo "7. A patch commits configure by hand, then upstream releases 1.2 with pad/1-keys"
cd "$t/dev"
git fetch -q origin
git checkout -q -B pad/2-linux origin/pad/2-linux
printf 'AC_INIT 1.1\ndnl checks\nAC_ARG_WITH sdl2\nAC_ARG_ENABLE pads\nAC_OUTPUT\n' >configure.ac
printf 'hand made\n' >configure
git commit -qam "Pads switch"
git push -q origin pad/2-linux
cd "$t/up"
printf 'AC_INIT 1.2\ndnl checks\nAC_OUTPUT\n' >configure.ac
eval "$REGEN_AUTOTOOLS_CMD"
git commit -qam "Alien Arena 1.2"
git tag 1.2
git push -q origin master 1.2
sync
check '[ $rc = 0 ]' "sync passed"
check '[ "$(show pad/2-linux configure)" = "$(regen_of pad/2-linux)" ]' "configure conflict settled and remade"
check 'show pad/2-linux configure.ac | grep -q "AC_INIT 1.2"' "configure.ac has upstream's 1.2"
check 'fork rev-parse -q --verify refs/tags/1.2-pad.1 >/dev/null' "1.2-pad.1 tagged"
check 'ls "$t/work/notices" | grep -q merged-pad-1-keys' "a notice to take pad/1-keys out of the stack"
check 'grep -q "in upstream 1.2" "$t/work/summary.md"' "pad/1-keys reported as in 1.2"

echo "8. A change that fails the tests"
sed -i '/^pad\/1-keys/d' "$t/stack.txt"
cd "$t/dev"
git fetch -q origin
git checkout -q -B pad/3-menus origin/pad/3-menus
echo oops >BROKEN
git add BROKEN
git commit -qm "Something broken"
git push -q origin pad/3-menus
sync
check '[ $rc != 0 ]' "sync stopped"
check 'grep -q "smoke test failed" "$t/work/summary.md"' "summary says the smoke test failed"
check '[ -z "$(fork tag -l "1.2-pad.2")" ]' "no tag for the broken stack"

echo "9. Dry run"
git rm -q BROKEN
git commit -qm "Fix it"
git push -q origin pad/3-menus
before=$(at pad/3-menus)
DRY_RUN=1 sync
check '[ $rc = 0 ]' "sync passed"
check '[ "$(at pad/3-menus)" = "$before" ] && [ -z "$(fork tag -l "1.2-pad.2")" ]' "pushed nothing"
check 'grep -q "Dry run" "$t/work/summary.md"' "summary says what it would have pushed"

echo "10. Upstream releases 1.3 with every patch, and the stack is emptied"
cd "$t/up"
git fetch -q "$t/fork.git" pad/3-menus
git read-tree -u --reset FETCH_HEAD
git commit -qm "Controller support from Ken"
git tag 1.3
git push -q origin master 1.3
printf '# nothing left\n' >"$t/stack.txt"
sync
check '[ $rc = 0 ]' "sync passed"
check '[ "$(fork rev-parse "1.3-pad.1^{tree}")" = "$(fork rev-parse "1.3^{tree}")" ]' "1.3-pad.1 is plain 1.3, so the snap keeps getting releases"

echo
if [ "$fails" = 0 ]; then
	echo "All checks passed."
else
	echo "$fails check(s) failed. Logs: rerun with KEEP=1 to keep $t" >&2
	if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept $t" >&2; fi
	exit 1
fi
