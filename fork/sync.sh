#!/usr/bin/env bash
# Keeps the fork current with upstream Alien Arena:
#
#  1. master becomes a copy of upstream's master, and upstream's tags are copied.
#  2. Each branch in stack.txt is replayed on the one before it (the first on
#     master), leaving out anything upstream already has, and its generated
#     files (configure, Makefile.in, the HTML docs) are made again.
#  3. The same stack is replayed on upstream's latest release, for the
#     <release>-pad.N tag the snap builds.
#  4. master, every branch and the release build are built and smoke tested.
#  5. Only when all of that passed are the branches and the new tag pushed,
#     all at once.
#
# It writes a Markdown report to $WORK/summary.md, logs and screenshots to
# $WORK/out, and one file per thing that needs a person to $WORK/notices.
# See README.md.
set -euo pipefail

FORK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fork/lib.sh
. "$FORK_DIR/lib.sh"

: "${FORK_URL:?set FORK_URL to the git URL of the fork, with a token in it to push}"
: "${UPSTREAM_URL:=https://github.com/alienarena/alienarena.git}"
: "${WORK:=$PWD/work}"
: "${STACK_FILE:=$FORK_DIR/../stack.txt}"
: "${DRY_RUN:=0}"   # 1: do and test everything, push nothing
: "${TEST:=auto}"   # auto: test only when something changed; always; never
: "${BUILD_SH:=$FORK_DIR/build.sh}"
: "${SMOKE_SH:=$FORK_DIR/smoke.sh}"
: "${GIT_COMMITTER_NAME:=alienarena fork sync}"
: "${GIT_COMMITTER_EMAIL:=fork-sync@users.noreply.github.com}"
export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
STACK_FILE=$(cd "$(dirname "$STACK_FILE")" && pwd)/$(basename "$STACK_FILE")
OUT=$WORK/out
SUMMARY=$WORK/summary.md
NOTICES=$WORK/notices
WHY=$WORK/why
rm -rf "$OUT" "$NOTICES"
mkdir -p "$OUT" "$NOTICES"
: >"$SUMMARY"

declare -A OLD=() NEW=() BASE=() PARENT=() STATE=() RESULT=()
STACK=()
ACTIVE=()   # branches upstream master doesn't have yet
PENDING=()  # branches upstream master has, but its latest release doesn't
CHANGED=0
MASTER_MOVED=0
UP=""
TOP=""
REL_TAG=""
REL_TOP=""
NEW_TAG=""
RELEASED=()
TESTED=()

say() { printf '%s\n' "$*" >>"$SUMMARY"; }

# Adds a note for a person: the first line is the issue title.
notice() {
	local name=$1 title=$2
	shift 2
	{
		printf '%s\n\n' "$title"
		printf '%s\n' "$@"
	} >"$NOTICES/$(slug "$name").md"
	note "$title"
}

report() {
	local b
	if [ ${#STACK[@]} -gt 0 ]; then
		say ""
		say "| Branch | State | Tip | Test |"
		say "|---|---|---|---|"
		for b in "${STACK[@]}"; do
			say "| \`$b\` | ${STATE[$b]:-not reached} | ${NEW[$b]:+$(short "${NEW[$b]}")} | ${RESULT[$b]:-} |"
		done
	fi
	if [ ${#TESTED[@]} -gt 0 ]; then
		say ""
		say "Tested: ${TESTED[*]}"
	fi
	if [ -n "${GITHUB_RUN_ID:-}" ]; then
		say ""
		say "Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
	fi
}

# Stops the run: nothing more is pushed. SIGNATURE names the problem, so the
# issue it goes to is only updated when the problem changes.
fail() {
	local sig=$1
	shift
	say ""
	say "**Stopped:** $*"
	report
	say ""
	say "<!-- signature: $sig -->"
	printf '\nerror: %s\n' "$*" >&2
	exit 1
}

setup_repo() {
	REPO=$WORK/repo
	if [ ! -d "$REPO/.git" ]; then
		log "Cloning the fork (history only; files come when needed)"
		git clone -q --filter=blob:none --no-checkout "$FORK_URL" "$REPO"
	fi
	cd "$REPO"
	git remote set-url origin "$FORK_URL"
	git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
	git remote set-url upstream "$UPSTREAM_URL"
	# Upstream's new commits come with their files (not lazily, like the fork's),
	# so they can be pushed to the fork.
	git config --unset remote.upstream.promisor || true
	git config gc.auto 0
	log "Fetching the fork and upstream"
	git fetch -q --prune --no-tags origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
	git fetch -q --prune --no-tags upstream '+refs/heads/master:refs/remotes/upstream/master' '+refs/tags/*:refs/upstream-tags/*'
}

# master is a copy of upstream's; it moves on its own, whatever happens to the stack.
mirror() {
	local fork t
	local -a refs=()
	UP=$(git rev-parse refs/remotes/upstream/master)
	TOP=$UP
	fork=$(git rev-parse -q --verify refs/remotes/origin/master || true)
	log "Upstream master is $(short "$UP"): $(git show -s --format=%s "$UP")"
	if [ "$fork" != "$UP" ]; then
		if [ -n "$fork" ] && ! git merge-base --is-ancestor "$fork" "$UP"; then
			fail master-diverged "The fork's master has commits upstream's doesn't (it's at $(short "$fork")). master must stay a copy of upstream: move those commits to a branch, then put master back with \`git push --force origin $(short "$UP"):master\`."
		fi
		refs+=("$UP:refs/heads/master")
		MASTER_MOVED=1
		say "- master: ${fork:+$(short "$fork") → }$(short "$UP") ($(git show -s --format=%s "$UP"))"
	else
		say "- master: $(short "$UP"), same as upstream"
	fi
	for t in $(git for-each-ref --format='%(refname:lstrip=2)' refs/upstream-tags); do
		if ! git rev-parse -q --verify "refs/tags/$t" >/dev/null; then
			refs+=("refs/upstream-tags/$t:refs/tags/$t")
			git update-ref "refs/tags/$t" "refs/upstream-tags/$t"
			say "- new upstream tag: $t"
		elif [ "$(git rev-parse "refs/tags/$t")" != "$(git rev-parse "refs/upstream-tags/$t")" ]; then
			note "tag $t differs between upstream and the fork; leaving the fork's"
		fi
	done
	if [ ${#refs[@]} -gt 0 ]; then
		if [ "$DRY_RUN" = 1 ]; then
			note "dry run: not pushing master or tags"
		else
			log "Pushing master and upstream's tags to the fork"
			git push -q origin "${refs[@]}"
		fi
	fi
}

read_stack() {
	local b rest
	[ -f "$STACK_FILE" ] || return 0
	while read -r b rest; do
		[ -n "$b" ] || continue
		git rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null ||
			fail "missing-$b" "stack.txt lists \`$b\`, but the fork has no branch by that name."
		STACK+=("$b")
	done < <(sed 's/#.*//' "$STACK_FILE")
}

# Does TREEISH already have the changes BASE..TIP makes (merged as is,
# squashed or applied by hand)? Generated files don't count.
has_changes() {
	local treeish=$1 base=$2 tip=$3 patch=$WORK/own.patch idx=$WORK/check.index
	local -a ex
	mapfile -t ex < <(gen_excludes)
	git diff --binary "$base" "$tip" -- . "${ex[@]}" >"$patch"
	[ -s "$patch" ] || return 1
	rm -f "$idx"
	GIT_INDEX_FILE=$idx git read-tree "$treeish" &&
		GIT_INDEX_FILE=$idx git apply --cached --check -R "$patch" 2>/dev/null
}

# Copies commit ORIG onto PARENT with tree TREE, keeping its author and message.
copy_commit() {
	local orig=$1 tree=$2 parent=$3 an ae ad
	an=$(git show -s --format=%an "$orig")
	ae=$(git show -s --format=%ae "$orig")
	ad=$(git show -s --format=%ad --date=raw "$orig")
	git cat-file commit "$orig" | sed '1,/^$/d' |
		GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=$ae GIT_AUTHOR_DATE=$ad \
			GIT_COMMITTER_DATE=$(git show -s --format=%cd --date=raw "$parent") \
			git commit-tree "$tree" -p "$parent"
}

# Prints TREE with FILES as they are in commit SRC.
take_files() {
	local tree=$1 src=$2 idx=$WORK/take.index f entry
	shift 2
	rm -f "$idx"
	GIT_INDEX_FILE=$idx git read-tree "$tree" || return 1
	for f in "$@"; do
		entry=$(git ls-tree "$src" -- "$f")
		if [ -n "$entry" ]; then
			GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "$(awk '{print $1 "," $3}' <<<"$entry"),$f" || return 1
		else
			GIT_INDEX_FILE=$idx git update-index --force-remove -- "$f" || return 1
		fi
	done
	GIT_INDEX_FILE=$idx git write-tree
}

ensure_worktree() {
	local wt=$1
	shift
	if [ ! -e "$wt/.git" ]; then
		rm -rf "$wt"
		git worktree prune
		git worktree add -q --no-checkout --detach "$wt"
		git -C "$wt" sparse-checkout set --no-cone "$@"
	fi
}

# Prints COMMIT with the generated files made again from its sources, as a new
# commit on top, or COMMIT itself when nothing changes.
regen_commit() {
	local c=$1 name=$2 wt=$WORK/regen-tree tree f
	local -a present=()
	ensure_worktree "$wt" '/*' '!/data1/'
	git -C "$wt" checkout -q -f --detach "$c" || return 1
	git -C "$wt" clean -q -fdx
	note "$name: making the generated files again"
	if ! "$FORK_DIR/regen.sh" "$wt" >"$OUT/regen-$(slug "$name").log" 2>&1; then
		echo "Making the generated files failed for $name (see regen-$(slug "$name").log)." >"$WHY"
		return 1
	fi
	for f in "${GENERATED[@]}"; do
		if [ -e "$wt/$f" ] || git -C "$wt" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then present+=("$f"); fi
	done
	git -C "$wt" add -A -- "${present[@]}"
	tree=$(git -C "$wt" write-tree)
	git -C "$wt" reset -q
	if [ "$tree" = "$(git rev-parse "$c^{tree}")" ]; then
		echo "$c"
		return 0
	fi
	printf '%s\n\n%s\n%s\n%s\n' "$REGEN_SUBJECT" \
		"configure, aclocal.m4, the Makefile.in files and config/config.h.in, made with" \
		"autoconf 2.69 and automake 1.15.1 as upstream's are, and CMD.html and" \
		"CVAR.html from convert_md_to_html.sh." |
		GIT_AUTHOR_NAME=$(git show -s --format=%an "$c") GIT_AUTHOR_EMAIL=$(git show -s --format=%ae "$c") \
			GIT_AUTHOR_DATE=$(git show -s --format=%ad --date=raw "$c") \
			GIT_COMMITTER_DATE=$(git show -s --format=%cd --date=raw "$c") \
			git commit-tree "$tree" -p "$c"
}

# Replays NAME's own commits, BASE..TIP, onto ONTO and prints the new tip.
# Commits whose parent hasn't changed are kept as they are, so a branch that is
# already up to date comes out the same. The "Regenerate generated files"
# commit is left out and made again at the end when the branch needs one.
# Conflicts only in generated files are settled by taking ONTO's, since they're
# remade anyway. On any other conflict it writes why to $WHY and fails.
replay() {
	local base=$1 tip=$2 onto=$3 name=$4
	local cur=$onto c parent tree out rc subject
	local -a commits upstreamed conflicted others
	if [ -n "$(git rev-list --merges "$base..$tip")" ]; then
		echo "\`$name\` has merge commits. Keep the stack's branches straight: rebase rather than merge." >"$WHY"
		return 1
	fi
	mapfile -t commits < <(git rev-list --reverse "$base..$tip")
	mapfile -t upstreamed < <(git cherry "$onto" "$tip" "$base" | sed -n 's/^- //p')
	for c in "${commits[@]}"; do
		subject=$(git show -s --format=%s "$c")
		[ "$subject" != "$REGEN_SUBJECT" ] || continue
		if [ ${#upstreamed[@]} -gt 0 ] && printf '%s\n' "${upstreamed[@]}" | grep -qx "$c"; then
			note "$name: leaving out $(short "$c") ($subject): upstream has it"
			continue
		fi
		parent=$(git rev-parse "$c^")
		if [ "$parent" = "$cur" ]; then
			cur=$c
			continue
		fi
		out=$(git merge-tree --write-tree --name-only --no-messages --merge-base="$parent" "$cur" "$c") && rc=0 || rc=$?
		tree=$(head -1 <<<"$out")
		if [ "$rc" = 1 ]; then
			mapfile -t conflicted < <(tail -n +2 <<<"$out" | sed '/^$/d' | sort -u)
			# Only generated files can be settled by taking upstream's; configure.ac and the .am files can't.
			mapfile -t others < <(printf '%s\n' "${conflicted[@]}" | grep -Fxv -f <(printf '%s\n' "${GENERATED[@]}") || true)
			if [ ${#others[@]} -gt 0 ]; then
				{
					echo "\`$name\`: $(short "$c") \"$subject\" conflicts with $(short "$onto") in:"
					echo
					printf -- '- %s\n' "${others[@]}"
				} >"$WHY"
				return 1
			fi
			note "$name: $(short "$c") conflicts only in generated files (${conflicted[*]}); taking upstream's, they get made again"
			tree=$(take_files "$tree" "$cur" "${conflicted[@]}") || return 1
		elif [ "$rc" != 0 ]; then
			echo "git merge-tree failed on \`$name\` at $(short "$c")." >"$WHY"
			return 1
		fi
		if [ "$tree" = "$(git rev-parse "$cur^{tree}")" ]; then
			note "$name: leaving out $(short "$c") ($subject): nothing left of it"
			continue
		fi
		cur=$(copy_commit "$c" "$tree" "$cur") || return 1
	done
	if [ "$(git show -s --format=%s "$tip")" = "$REGEN_SUBJECT" ] && [ "$(git rev-parse "$tip^")" = "$cur" ]; then
		cur=$tip
	elif git diff --name-only "$onto" "$cur" | grep -Eq "$REGEN_INPUTS_RE"; then
		cur=$(regen_commit "$cur" "$name") || return 1
	fi
	echo "$cur"
}

rebase_stack() {
	local parent=$UP prev="" prev_old="" b old base new mb where
	for b in "${STACK[@]}"; do
		old=$(git rev-parse "refs/remotes/origin/$b")
		OLD[$b]=$old
		base=$(git merge-base "$old" "$UP")
		if [ -n "$prev_old" ]; then
			if git merge-base --is-ancestor "$prev_old" "$old"; then
				base=$prev_old
			else
				# Not on the branch before it any more: start from wherever it
				# last left that branch or master, whichever is later.
				mb=$(git merge-base "$old" "$prev_old")
				git merge-base --is-ancestor "$mb" "$base" || base=$mb
				note "$b doesn't sit on $prev's tip; replaying what it has since $(short "$base")"
			fi
		fi
		BASE[$b]=$base
		prev=$b
		prev_old=$old
		if has_changes "$UP" "$base" "$old"; then
			NEW[$b]=$old
			if [ -n "$REL_TAG" ] && ! has_changes "refs/upstream-tags/$REL_TAG" "$base" "$old"; then
				STATE[$b]="in upstream master, not yet in $REL_TAG"
				PENDING+=("$b")
				note "$b: upstream master has it; still building it into $REL_TAG-pad tags until upstream releases it"
			else
				where="upstream${REL_TAG:+ $REL_TAG}"
				STATE[$b]="in $where"
				notice "merged-$b" "\`$b\` is in $where" \
					"Everything \`$b\` changes is in $where, so the sync job leaves the branch as it is and stacks the branches after it on what comes before." \
					"" \
					"Take \`$b\` out of stack.txt on the fork-tools branch, then delete the branch when you're ready."
			fi
			continue
		fi
		log "Replaying $b"
		if ! new=$(replay "$base" "$old" "$parent" "$b"); then
			STATE[$b]="conflict"
			fail "conflict-$b-$(short "$UP")" "$(cat "$WHY")

Nothing was pushed. Rebase the stack by hand (README.md, \"When the job stops\"), push it, and the next run carries on."
		fi
		NEW[$b]=$new
		PARENT[$b]=$parent
		if [ "$new" = "$old" ]; then
			STATE[$b]="up to date"
		else
			STATE[$b]="replayed on $(short "$parent")"
			CHANGED=1
		fi
		ACTIVE+=("$b")
		parent=$new
	done
	TOP=$parent
}

latest_release() {
	local t
	git for-each-ref --format='%(refname:lstrip=2)' refs/upstream-tags | grep -E "$RELEASE_TAG_RE" | sort -V |
		while read -r t; do
			if git merge-base --is-ancestor "refs/upstream-tags/$t" "$UP"; then echo "$t"; fi
		done | tail -1
}

# The same stack on upstream's latest release, for the <release>-pad.N tag:
# the branches upstream master doesn't have, and the ones it has but the
# release doesn't. Once there have been pad tags, a release that has every
# patch gets one too, so whatever follows them (the snap) keeps getting
# releases.
release_stack() {
	local rel cur b new last n
	RELEASED=()
	[ -n "$REL_TAG" ] || return 0
	if [ $((${#ACTIVE[@]} + ${#PENDING[@]})) -eq 0 ] && [ -z "$(git tag -l '*-pad.*')" ]; then
		return 0
	fi
	rel=$(git rev-parse "refs/upstream-tags/$REL_TAG^{commit}")
	if [ "$rel" = "$UP" ]; then
		REL_TOP=$TOP
		RELEASED=("${ACTIVE[@]}")
	else
		log "Replaying the stack on $REL_TAG"
		cur=$rel
		for b in "${STACK[@]}"; do
			if printf '%s\n' "${PENDING[@]}" | grep -qxF -- "$b"; then
				new=$(replay "${BASE[$b]}" "${OLD[$b]}" "$cur" "$b on $REL_TAG") || new=""
			elif printf '%s\n' "${ACTIVE[@]}" | grep -qxF -- "$b"; then
				new=$(replay "${PARENT[$b]}" "${NEW[$b]}" "$cur" "$b on $REL_TAG") || new=""
			else
				continue
			fi
			if [ -z "$new" ]; then
				notice "release-$REL_TAG" "The patches don't apply to $REL_TAG" \
					"The branches are fine on master, but replaying them on upstream's release $REL_TAG stopped, so there's no new $REL_TAG-pad tag for the snap:" \
					"" "$(cat "$WHY")" "" \
					"This usually means a patch needs something upstream added after $REL_TAG. It sorts itself out at upstream's next release."
				say "- No release build: the stack doesn't apply to $REL_TAG"
				REL_TAG=""
				return 0
			fi
			cur=$new
			RELEASED+=("$b")
		done
		REL_TOP=$cur
	fi
	last=$(git tag -l "$REL_TAG-pad.*" | sort -V | tail -1)
	if [ -n "$last" ] && [ "$(git rev-parse "$last^{tree}")" = "$(git rev-parse "$REL_TOP^{tree}")" ]; then
		say "- Release build: $last is current"
		return 0
	fi
	n=${last##*-pad.}
	NEW_TAG="$REL_TAG-pad.$((${n:-0} + 1))"
	say "- New release build, once the tests pass: $NEW_TAG ($REL_TAG with ${RELEASED[*]:-no patches left on top})"
}

# Builds COMMIT (with and without SDL2 when configure offers the choice) and
# smoke tests the first build. Prints why on failure.
test_commit() {
	local label=$1 commit=$2 s dir v name args first=""
	local -a variants
	s=$(slug "$label")
	dir=$OUT/$s
	mkdir -p "$dir"
	log "Testing $label ($(short "$commit"))"
	git -C "$SRC_WT" checkout -q -f --detach "$commit"
	git -C "$SRC_WT" clean -q -fdx
	if "$SRC_WT/configure" --help 2>/dev/null | grep -Eq -- '--with(\(out\))?-sdl2'; then
		variants=("sdl2 --with-sdl2" "no-sdl2 --without-sdl2")
	else
		variants=("default")
	fi
	for v in "${variants[@]}"; do
		read -r name args <<<"$v"
		# shellcheck disable=SC2086
		if ! "$BUILD_SH" "$SRC_WT" "$WORK/build/$s-$name" $args >"$dir/build-$name.log" 2>&1; then
			echo "build ($name) failed: $(tail -1 "$dir/build-$name.log")"
			return 1
		fi
		cp "$WORK/build/$s-$name/configure.log" "$dir/configure-$name.log" 2>/dev/null || true
		cp "$WORK/build/$s-$name/make.log" "$dir/make-$name.log" 2>/dev/null || true
		note "$(tail -1 "$dir/build-$name.log")"
		first=${first:-$name}
	done
	if ! "$SMOKE_SH" "$WORK/build/$s-$first/source" "$SRC_WT" "$DATA_WT" "$dir" >"$dir/smoke.log" 2>&1; then
		echo "smoke test failed: $(tail -1 "$dir/smoke.log")"
		return 1
	fi
	note "$(tail -1 "$dir/smoke.log")"
	echo "built and smoke tested"
}

run_tests() {
	local b why
	SRC_WT=$WORK/src
	DATA_WT=$WORK/data
	ensure_worktree "$SRC_WT" '/*' '!/data1/'
	ensure_worktree "$DATA_WT" '/data1/'
	log "Checking out upstream's game data"
	git -C "$DATA_WT" checkout -q -f --detach "$UP"
	if ! why=$(test_commit master "$UP"); then
		fail "upstream-$(short "$UP")" "Upstream master doesn't pass here: $why. The stack wasn't tested or pushed."
	fi
	TESTED+=(master)
	for b in "${ACTIVE[@]}"; do
		if ! why=$(test_commit "$b" "${NEW[$b]}"); then
			RESULT[$b]=$why
			fail "test-$b-$(short "${NEW[$b]}")" "\`$b\` $why. Nothing was pushed."
		fi
		RESULT[$b]=$why
		TESTED+=("$b")
	done
	if [ -n "$NEW_TAG" ] && [ "$REL_TOP" != "$TOP" ]; then
		if ! why=$(test_commit "$NEW_TAG" "$REL_TOP"); then
			fail "test-$NEW_TAG-$(short "$REL_TOP")" "The release build $NEW_TAG $why. Nothing was pushed."
		fi
		TESTED+=("$NEW_TAG")
	fi
}

push_all() {
	local b msg
	local -a leases=() refs=()
	for b in "${ACTIVE[@]}"; do
		if [ "${NEW[$b]}" != "${OLD[$b]}" ]; then
			leases+=("--force-with-lease=refs/heads/$b:${OLD[$b]}")
			refs+=("${NEW[$b]}:refs/heads/$b")
		fi
	done
	if [ -n "$NEW_TAG" ]; then
		msg="Alien Arena $REL_TAG with the controller patches"$'\n\n'
		[ ${#RELEASED[@]} -gt 0 ] || msg="Alien Arena $REL_TAG, which has all the controller patches"$'\n'
		for b in "${RELEASED[@]}"; do msg+="$b $(short "${NEW[$b]}")"$'\n'; done
		git tag -f -a -m "$msg" "$NEW_TAG" "$REL_TOP" >/dev/null
		refs+=("refs/tags/$NEW_TAG")
	fi
	if [ ${#refs[@]} -eq 0 ]; then
		say "- Nothing to push"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		say "- Dry run, so not pushed: ${refs[*]#*:}"
		return 0
	fi
	log "Pushing ${refs[*]#*:}"
	if ! git push -q --atomic origin "${leases[@]}" "${refs[@]}"; then
		fail "push" "Pushing failed. If a branch moved while the job ran, the next run picks it up."
	fi
	say "- Pushed: ${refs[*]#*:}"
}

main() {
	say "## Fork sync, $(date -u '+%Y-%m-%d %H:%M UTC')"
	say ""
	setup_repo
	mirror
	read_stack
	REL_TAG=$(latest_release)
	if [ ${#STACK[@]} -gt 0 ]; then
		rebase_stack
	else
		say "- stack.txt lists no branches yet"
	fi
	release_stack
	case $TEST in
	always) run_tests ;;
	never) note "not testing (TEST=never)" ;;
	*)
		if [ "$MASTER_MOVED" = 1 ] || [ "$CHANGED" = 1 ] || [ -n "$NEW_TAG" ]; then
			run_tests
		else
			say "- Nothing changed, so nothing was tested"
		fi
		;;
	esac
	push_all
	report
	log "Done"
}

main "$@"
