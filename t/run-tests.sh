#!/bin/sh
# Test suite for mutationstructure.pl.
#
# Follows the convention that found every non-trivial bug in this project:
# build a fixture, inventory both sides, generate the plan, EXECUTE IT FOR
# REAL, re-inventory, and diff `cut -c1-57,93-` against --new-dts.
#
# Usage: sh t/run-tests.sh [workdir]
#
# The work directory MUST NOT sit inside OneDrive: the sync client holds a lock
# on a folder while it uploads it, and `mv` on that folder fails with
# "Permission denied" - intermittently, on a different fixture each run.  The
# default is therefore outside the repository.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=${1:-${TMPDIR:-/tmp}/dts-tests}
FIX="$WORK/fix"
BASE="$HERE/baseline"          # committed: the reference plans of the default mode

FIXTURES="reg video bang subrename fuzzyswap below pingpong dupmove"
pass=0
fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
nok()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# plan + execute + verify the projection.  $1 fixture, $2 tag, rest: options
run() {
    f=$1; tag=$2; shift 2
    w="$FIX/$f/work-$tag"
    rm -rf "$w"; mkdir -p "$w"
    cp -a "$FIX/$f/dst.orig" "$w/dst"
    perl "$REPO/dtsgen.pl" "$FIX/$f/src" > "$w/src.dts"
    perl "$REPO/dtsgen.pl" "$w/dst"      > "$w/dst.dts" 2>/dev/null
    perl "$REPO/mutationstructure.pl" "$@" \
         --out "$w/plan.sh" --new-dts "$w/proj.dts" \
         "$w/src.dts" "$w/dst.dts" 2> "$w/stderr.txt"
    sh "$w/plan.sh" > "$w/exec.log" 2>&1
    perl "$REPO/dtsgen.pl" "$w/dst" > "$w/after.dts" 2>/dev/null
    cut -c1-57,93- "$w/proj.dts"  | sort > "$w/proj.cmp"
    cut -c1-57,93- "$w/after.dts" | sort > "$w/after.cmp"
}

echo "building fixtures..."
sh "$HERE/mkfixtures.sh" "$FIX" > /dev/null
mkdir -p "$BASE"

echo
echo "1. projection is exact (plan executed for real, then re-inventoried)"
for f in $FIXTURES; do
    for mode in off fuzzy; do
        [ "$mode" = fuzzy ] && opt=--fuzzy-dirs || opt=
        if run "$f" "$mode" --remove $opt 2>/dev/null &&
           diff -q "$FIX/$f/work-$mode/proj.cmp" \
                   "$FIX/$f/work-$mode/after.cmp" > /dev/null
        then ok "$f ($mode)"
        else nok "$f ($mode): projection differs from the real re-inventory"
        fi
    done
done

echo
echo "2. every file present on both sides lands where the source puts it"
for f in $FIXTURES; do
    ( cd "$FIX/$f/src" && find . -type f -exec sha1sum {} \; ) | sort > "$WORK/s.txt"
    ( cd "$FIX/$f/work-fuzzy/dst" && find . -type f -exec sha1sum {} \; ) | sort > "$WORK/d.txt"
    n=$(join -j 1 <(awk '{print $1" "$2}' "$WORK/s.txt" | sort) \
                  <(awk '{print $1" "$2}' "$WORK/d.txt" | sort) |
        awk '$2 != $3' | wc -l)
    [ "$n" -eq 0 ] && ok "$f" || nok "$f: $n file(s) at the wrong path"
done

echo
echo "3. --fuzzy-dirs off leaves the plan byte-for-byte unchanged"
for f in $FIXTURES; do
    b="$BASE/$f.plan"
    # absolute paths differ per machine: normalise them so the reference plans
    # can be committed and compared anywhere
    sed -e "s|$FIX|FIX|g" -e 's/work-[a-z0-9]*/work/g' \
        "$FIX/$f/work-off/plan.sh" > "$WORK/now.plan"
    if [ ! -f "$b" ]; then
        cp "$WORK/now.plan" "$b"; ok "$f (baseline recorded)"
    elif diff -q "$b" "$WORK/now.plan" > /dev/null; then ok "$f"
    else nok "$f: the default plan changed"; diff "$b" "$WORK/now.plan" | head -10
    fi
done

echo
echo "4. the safeguard never fires and no plan step fails"
for f in $FIXTURES; do
    for mode in off fuzzy; do
        if grep -q REFUSING "$FIX/$f/work-$mode/stderr.txt" 2>/dev/null
        then nok "$f ($mode): REFUSING to delete fired - planner bug"
        elif [ -s "$FIX/$f/work-$mode/exec.log" ]
        then nok "$f ($mode): the plan wrote to stderr"; head -3 "$FIX/$f/work-$mode/exec.log"
        else ok "$f ($mode)"
        fi
    done
done

echo
echo "5. determinism: two runs produce the same plan"
for f in $FIXTURES; do
    run "$f" d1 --remove --fuzzy-dirs
    run "$f" d2 --remove --fuzzy-dirs
    a=$(sed 's/work-[a-z0-9]*/w/g' "$FIX/$f/work-d1/plan.sh" | sha1sum)
    b=$(sed 's/work-[a-z0-9]*/w/g' "$FIX/$f/work-d2/plan.sh" | sha1sum)
    [ "$a" = "$b" ] && ok "$f" || nok "$f: two runs disagree"
done

echo
echo "6. expected shape of the fuzzy plans"
mv_count() { grep -c '^mv -n' "$FIX/$1/work-$2/plan.sh" 2>/dev/null || echo 0; }
# the large video: one directory move replaces five file moves
[ "$(mv_count video fuzzy)" -eq 1 ] && ok "video: a single mv" \
    || nok "video: expected 1 mv, got $(mv_count video fuzzy)"
# the ! file: the folder moves, then note.jpg is relocated to Divers/
grep -q "^mv -n 'Camera' '2024/Vacances'" "$FIX/bang/work-fuzzy/plan.sh" \
    && grep -q "^mv -n '2024/Vacances/note.jpg' 'Divers/note.jpg'" \
             "$FIX/bang/work-fuzzy/plan.sh" \
    && ok "bang: folder moved, then the ! file relocated" \
    || nok "bang: the ! file was not relocated"
# below threshold: no directory move at all
grep -q '^# --- directories' "$FIX/below/work-fuzzy/plan.sh" \
    && nok "below: a directory move was emitted under the threshold" \
    || ok "below: no directory move under the threshold"
# swap inside a fuzzy pair: routed through a temporary name
grep -q 'mutation_tmp' "$FIX/fuzzyswap/work-fuzzy/plan.sh" \
    && ok "fuzzyswap: swap routed through a temporary" \
    || nok "fuzzyswap: no temporary name, the swap would clobber"
# a surplus copy under a moved folder is deleted at its post-move path
grep -q "^rm -f 'Photos/dup/a.jpg'" "$FIX/dupmove/work-fuzzy/plan.sh" \
    && ok "dupmove: duplicate removed at its post-move path" \
    || nok "dupmove: the rm does not use the post-move path"

echo
echo "7. dtsgen.pl --update"
U="$WORK/upd"
rm -rf "$U"; mkdir -p "$U"
( cd "$U"
  mkf() { mkdir -p "$(dirname "$1")"; printf 'id:%s\npad pad pad pad pad pad\n' "$2" > "$1"; }
  mkf tree/a/one.txt one
  mkf tree/a/two.txt two
  mkf tree/b/three.txt three
  mkf tree/keep.txt keep
  mkdir -p tree/emptydir
  perl "$REPO/dtsgen.pl" tree > base.dts 2>/dev/null
  sleep 1
  mkf tree/a/two.txt CHANGED          # content drift
  touch tree/keep.txt                 # mtime-only drift
  rm tree/b/three.txt                 # vanished
  mkf tree/b/added.txt added          # new
  perl "$REPO/dtsgen.pl" --update base.dts > up.log 2>&1
)
# the refreshed inventory must not invent entries the .dts never had
if grep -q 'added.txt' "$U/base_new.dts"
then nok "--update: picked up a new file without --add-missing"
else ok  "--update: new files ignored by default"
fi
# the vanished entry leaves, and lands in the deletion list
if grep -q 'three.txt' "$U/base_new.dts"
then nok "--update: a vanished file survived"
elif grep -q 'three.txt' "$U/TmpDeleted.dts"
then ok  "--update: vanished file dropped and listed in TmpDeleted.dts"
else nok "--update: vanished file is in neither file"
fi
# only the drifting files are re-read
# one.txt untouched; two.txt content-changed and keep.txt mtime-touched are
# both re-read; three.txt is gone
if grep -q '1 unchanged, 2 re-hashed, 1 gone' "$U/up.log"
then ok  "--update: mtime and size decide what is re-hashed"
else nok "--update: unexpected accounting"; grep -E 'unchanged' "$U/up.log"
fi
# the strong one: with --add-missing the result must equal a fresh inventory
( cd "$U"
  rm -f base_new.dts TmpDeleted.dts
  perl "$REPO/dtsgen.pl" --update base.dts --add-missing > /dev/null 2>&1
  perl "$REPO/dtsgen.pl" tree > fresh.dts 2>/dev/null
)
if diff -q "$U/base_new.dts" "$U/fresh.dts" > /dev/null
then ok  "--update --add-missing: byte-identical to a fresh dtsgen.pl run"
else nok "--update --add-missing: differs from a fresh run"
     diff "$U/fresh.dts" "$U/base_new.dts" | head -10
fi
# running it again must change nothing
( cd "$U"
  cp base_new.dts idem.dts
  perl "$REPO/dtsgen.pl" --update idem.dts --add-missing > /dev/null 2>&1
)
if diff -q "$U/idem_new.dts" "$U/idem.dts" > /dev/null
then ok  "--update: idempotent"
else nok "--update: a second run drifts"
fi
# --add-missing alone is refused
if perl "$REPO/dtsgen.pl" --add-missing > /dev/null 2>&1
then nok "--add-missing without --update was accepted"
else ok  "--add-missing without --update is refused"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
