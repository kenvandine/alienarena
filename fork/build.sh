#!/usr/bin/env bash
# Builds the client and the dedicated server out of tree, without the data.
#
#   fork/build.sh SOURCE BUILD [configure options...]
#
# The last line it prints says how it went.
set -euo pipefail

src=$(cd "$1" && pwd)
build=$2
shift 2
rm -rf "$build"
mkdir -p "$build"
cd "$build"

if ! "$src/configure" --without-data1pkg "$@" >configure.log 2>&1; then
	tail -n 30 configure.log
	echo "configure failed"
	exit 1
fi
if ! make -C source -j"$(nproc)" >make.log 2>&1; then
	grep -E 'error|Error' make.log | head -n 30 || true
	echo "make failed: $(grep -m1 -E 'error:' make.log || tail -n 1 make.log)"
	exit 1
fi
for bin in alienarena alienarena-ded; do
	[ -x "source/$bin" ] || { echo "no source/$bin after make"; exit 1; }
done
echo "built ${*:-with the default options}, $(grep -c 'warning:' make.log || true) compiler warnings"
