#!/usr/bin/env bash
# Makes the generated files in TREE again from their sources: configure,
# aclocal.m4, the Makefile.in files and config/config.h.in with the autotools
# upstream uses (in Docker, see autotools.Dockerfile), and CMD.html and
# CVAR.html with upstream's convert_md_to_html.sh.
#
#   fork/regen.sh TREE
#
# REGEN_AUTOTOOLS_CMD replaces the Docker step (the self test uses it).
# REGEN_BASE picks another base image for the Docker step (a mirror).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tree=$(cd "$1" && pwd)
image=${REGEN_IMAGE:-alienarena-fork-autotools:18.04}

if [ -n "${REGEN_AUTOTOOLS_CMD:-}" ]; then
	(cd "$tree" && eval "$REGEN_AUTOTOOLS_CMD")
else
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		docker build -q -t "$image" ${REGEN_BASE:+--build-arg "BASE=$REGEN_BASE"} - <"$here/autotools.Dockerfile"
	fi
	# automake wants every AC_CONFIG_SUBDIRS directory to exist.
	mkdir -p "$tree/data1"
	docker run --rm -v "$tree:/src" -w /src -e "OWNER=$(id -u):$(id -g)" "$image" sh -c '
		aclocal -I m4 && autoconf && autoheader && automake
		rc=$?
		rm -rf autom4te.cache
		find /src -xdev -user 0 -exec chown "$OWNER" {} +
		exit $rc'
fi

for md in CMD.md CVAR.md; do
	if [ -f "$tree/$md" ] && [ -f "$tree/convert_md_to_html.sh" ]; then
		(cd "$tree" && bash convert_md_to_html.sh "$md")
	fi
done
