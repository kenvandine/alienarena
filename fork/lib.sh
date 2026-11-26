# shellcheck shell=bash disable=SC2034
# Shared by the fork scripts. Source it; don't run it.

# The commit the sync job keeps on top of a branch whose changes need the
# generated files remade. It is dropped and made again on every replay.
REGEN_SUBJECT="Regenerate generated files"

# Files upstream commits but nobody edits by hand.
GENERATED=(configure aclocal.m4 Makefile.in source/Makefile.in config/config.h.in CMD.html CVAR.html)

# A branch needs the generated files remade when it changes any of these
# (or the generated files themselves).
REGEN_INPUTS_RE='^(configure\.ac|Makefile\.am|source/Makefile\.am|m4/.*|CMD\.md|CVAR\.md|configure|aclocal\.m4|Makefile\.in|source/Makefile\.in|config/config\.h\.in|CMD\.html|CVAR\.html)$'

# Upstream's release tags (7.72.4).
RELEASE_TAG_RE='^[0-9]+(\.[0-9]+)+$'

log() { printf '\n== %s\n' "$*" >&2; }
note() { printf '   %s\n' "$*" >&2; }
short() { git rev-parse --short=8 "$1"; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

# Pathspecs that leave the generated files out of a diff.
gen_excludes() {
	local f
	for f in "${GENERATED[@]}"; do printf ':(top,exclude)%s\n' "$f"; done
}

# Strips the colour codes and carriage returns the game writes to its console.
plain() { sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g' "$@"; }
