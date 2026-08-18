#!/bin/sh
# Conformance check: the C# port must produce byte-for-byte what dtsgen.pl
# produces on the same tree.  Run it under a Perl that reports microsecond
# mtimes and UTF-8 names - MSYS2/Cygwin on Windows, or any Unix.  Strawberry
# Perl cannot be the reference: it is precisely what the port replaces.
#
# Usage: sh csharp/compare.sh [tree]...
#        (no argument: builds the t/ fixtures and compares every side)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
EXE=${DTSGEN_EXE:-}
for c in "$HERE/dist/dtsgen.exe" \
         "$HERE/dtsgen/bin/Release/net8.0/dtsgen.exe" \
         "$HERE/dtsgen/bin/Release/net8.0/dtsgen"; do
    [ -n "$EXE" ] || { [ -x "$c" ] && EXE="$c"; }
done
WORK=${TMPDIR:-/tmp}/dts-cs
pass=0; fail=0

[ -x "$EXE" ] || { echo "build it first: dotnet build -c Release $HERE/dtsgen"; exit 2; }
rm -rf "$WORK"; mkdir -p "$WORK"

cmpone() {   # $1 tree to inventory
    p="$WORK/p.dts"; c="$WORK/c.dts"
    perl "$REPO/dtsgen.pl" "$1" > "$p" 2>/dev/null || true
    # --perl-mtime reproduces Time::HiRes' double rounding; without it the port
    # is exact and the last microsecond digit may legitimately differ
    "$EXE" --perl-mtime --out "$c" "$1" 2>/dev/null || true
    if cmp -s "$p" "$c"
    then pass=$((pass+1)); printf '  ok    %s (%s lines)\n' "$1" "$(wc -l < "$p")"
    else fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; diff "$p" "$c" | head -6
    fi
}

if [ $# -gt 0 ]; then
    for t in "$@"; do cmpone "$t"; done
else
    sh "$REPO/t/mkfixtures.sh" "$WORK/fix" > /dev/null
    cd "$WORK"
    for f in reg video bang subrename fuzzyswap below pingpong dupmove nested chain chainsibs; do
        cmpone "fix/$f/src"
        cmpone "fix/$f/dst.orig"
    done
fi

printf '%d identical, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
