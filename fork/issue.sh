#!/usr/bin/env bash
# Keeps one open issue per problem on the fork, with gh.
#
#   fork/issue.sh open TITLE BODY_FILE   open it, or comment when the problem changed
#   fork/issue.sh close TITLE [MESSAGE]  close it if it's open
#
# Problems are matched by title. A body's "<!-- signature: ... -->" line (or,
# without one, the body itself minus its Run: link) says whether it changed.
set -euo pipefail

action=$1
title=$2
repo=${GITHUB_REPOSITORY:?}

find_issue() {
	gh issue list --repo "$repo" --state open --limit 200 --json number,title |
		jq -r --arg t "$title" '.[] | select(.title == $t) | .number' | head -n 1
}

fingerprint() {
	local sig
	sig=$(grep -o '<!-- signature: [^>]* -->' || true)
	if [ -n "$sig" ]; then echo "$sig"; else grep -v '^Run: ' | sed '/^$/d'; fi
}

num=$(find_issue)
case $action in
open)
	body=$3
	if [ -z "$num" ]; then
		gh issue create --repo "$repo" --title "$title" --body-file "$body"
		exit 0
	fi
	last=$(gh issue view "$num" --repo "$repo" --json body,comments --jq '(.comments | last | .body) // .body')
	if [ "$(fingerprint <<<"$last")" != "$(fingerprint <"$body")" ]; then
		gh issue comment "$num" --repo "$repo" --body-file "$body"
	else
		echo "issue #$num already says this"
	fi
	;;
close)
	if [ -n "$num" ]; then
		gh issue close "$num" --repo "$repo" --comment "${3:-Fixed: the sync ran clean.}"
	fi
	;;
*)
	echo "usage: $0 open TITLE BODY_FILE | close TITLE [MESSAGE]" >&2
	exit 2
	;;
esac
