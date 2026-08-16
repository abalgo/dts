#!/bin/sh
# Builds the fixture set for mutationstructure.pl.
# Each fixture is a directory holding src/ and dst.orig/.
# All files are > 100 bytes so --minsize (default 100) does not exclude them.
set -e
FIX="$1"
rm -rf "$FIX"
mkdir -p "$FIX"

# deterministic content of a given "identity", >100 bytes
mk() {  # mk <path> <identity>
    mkdir -p "$(dirname "$1")"
    { printf 'content-id:%s\n' "$2"
      i=0; while [ $i -lt 8 ]; do printf 'padding line %d for %s\n' "$i" "$2"; i=$((i+1)); done
    } > "$1"
}

#--- 1. regression: exact merkle move, swap, rotation, surplus copies ---------
F="$FIX/reg"
mk "$F/src/A/one.txt"        one
mk "$F/src/A/two.txt"        two
mk "$F/src/B/three.txt"      three
mk "$F/src/swap/x.txt"       sx
mk "$F/src/swap/y.txt"       sy
mk "$F/src/dup/keeper.txt"   dupe
cp -a "$F/src" "$F/dst.orig"
rm -rf "$F/dst.orig/A" "$F/dst.orig/B" "$F/dst.orig/swap" "$F/dst.orig/dup"
mk "$F/dst.orig/oldname/one.txt"   one      # dir A renamed
mk "$F/dst.orig/oldname/two.txt"   two
mk "$F/dst.orig/B/three.txt"       three    # already in place
mk "$F/dst.orig/swap/x.txt"        sy       # swapped contents
mk "$F/dst.orig/swap/y.txt"        sx
mk "$F/dst.orig/dup/keeper.txt"    dupe
mk "$F/dst.orig/dup/copy1.txt"     dupe     # surplus copy
mk "$F/dst.orig/elsewhere/copy2.txt" dupe   # surplus copy

#--- 2. the large video: dst folder lost a file ------------------------------
F="$FIX/video"
mk "$F/src/2024/Vacances/IMG_001.jpg" v1
mk "$F/src/2024/Vacances/IMG_002.jpg" v2
mk "$F/src/2024/Vacances/IMG_003.jpg" v3
mk "$F/src/2024/Vacances/IMG_004.jpg" v4
mk "$F/src/2024/Vacances/IMG_005.jpg" v5
mk "$F/src/2024/Vacances/movie.mp4"   vbig   # source only
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Camera/IMG_001.jpg" v1
mk "$F/dst.orig/Camera/IMG_002.jpg" v2
mk "$F/dst.orig/Camera/IMG_003.jpg" v3
mk "$F/dst.orig/Camera/IMG_004.jpg" v4
mk "$F/dst.orig/Camera/IMG_005.jpg" v5

#--- 3. the ! file: note.jpg follows Camera but belongs to Divers ------------
F="$FIX/bang"
mk "$F/src/2024/Vacances/IMG_001.jpg" b1
mk "$F/src/2024/Vacances/IMG_002.jpg" b2
mk "$F/src/2024/Vacances/IMG_003.jpg" b3
mk "$F/src/2024/Vacances/IMG_004.jpg" b4
mk "$F/src/2024/Vacances/IMG_005.jpg" b5
mk "$F/src/Divers/note.jpg"           bnote
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Camera/IMG_001.jpg" b1
mk "$F/dst.orig/Camera/IMG_002.jpg" b2
mk "$F/dst.orig/Camera/IMG_003.jpg" b3
mk "$F/dst.orig/Camera/IMG_004.jpg" b4
mk "$F/dst.orig/Camera/IMG_005.jpg" b5
mk "$F/dst.orig/Camera/note.jpg"    bnote   # the ! file
mk "$F/dst.orig/Camera/perso.jpg"   bperso  # the ~ file, dst only

#--- 4. renamed subfolder: content-equal, a subdir differs by name only ------
F="$FIX/subrename"
mk "$F/src/Album/Sub/a.txt" r1
mk "$F/src/Album/Sub/b.txt" r2
mk "$F/src/Album/top.txt"   r3
mk "$F/src/Album/extra.txt" r4          # source only, forces approximate
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Album/OldSub/a.txt" r1
mk "$F/dst.orig/Album/OldSub/b.txt" r2
mk "$F/dst.orig/Album/top.txt"      r3

#--- 5. fuzzy pair containing a swap ----------------------------------------
F="$FIX/fuzzyswap"
mk "$F/src/New/x.txt"    s1
mk "$F/src/New/y.txt"    s2
mk "$F/src/New/z.txt"    s3
mk "$F/src/New/only.txt" s4             # source only, forces approximate
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Old/x.txt" s2           # x and y exchanged
mk "$F/dst.orig/Old/y.txt" s1
mk "$F/dst.orig/Old/z.txt" s3

#--- 6. below threshold: score 0.5 ------------------------------------------
F="$FIX/below"
mk "$F/src/Target/p1.txt" t1
mk "$F/src/Target/p2.txt" t2
mk "$F/src/Other/p3.txt"  t3
mk "$F/src/Other/p4.txt"  t4
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Mixed/p1.txt" t1
mk "$F/dst.orig/Mixed/p2.txt" t2
mk "$F/dst.orig/Mixed/p3.txt" t3
mk "$F/dst.orig/Mixed/p4.txt" t4

#--- 7. mutual pull: two folders each holding a file that belongs to the other
F="$FIX/pingpong"
for n in 1 2 3 4; do mk "$F/src/A/f$n.txt" "a$n"; done
mk "$F/src/A/x.txt" xx
for n in 5 6 7 8; do mk "$F/src/B/f$n.txt" "a$n"; done
mk "$F/src/B/y.txt" yy
mkdir -p "$F/dst.orig"
for n in 1 2 3 4; do mk "$F/dst.orig/P/f$n.txt" "a$n"; done
mk "$F/dst.orig/P/y.txt" yy          # belongs to B
for n in 5 6 7 8; do mk "$F/dst.orig/Q/f$n.txt" "a$n"; done
mk "$F/dst.orig/Q/x.txt" xx          # belongs to A

#--- 8. surplus copy sitting under a directory the plan moves ----------------
F="$FIX/dupmove"
for n in a b c d; do mk "$F/src/Photos/$n.jpg" "p$n"; done
mkdir -p "$F/dst.orig"
for n in a b c d; do mk "$F/dst.orig/Old/$n.jpg" "p$n"; done
mk "$F/dst.orig/Old/dup/a.jpg" pa    # duplicate, travels with the folder

#--- 9. a folder whose match is its own ancestor -----------------------------
# The source has no "media" level, so dst Android/media and src Android hold
# the same entries and hash alike: the planner used to emit
# `mv Android/media Android`, which cannot run, and the consumed subtree then
# hid the files from the file pass, leaving them behind for good.
F="$FIX/nested"
for n in 1 2 3 4 5; do mk "$F/src/Android/clip$n.mp3" "n$n"; done
mkdir -p "$F/dst.orig"
for n in 1 2 3 4 5; do mk "$F/dst.orig/Android/media/clip$n.mp3" "n$n"; done

#--- 10. single-child chain: the vote cannot resolve, and must not pretend to --
# Every directory holds exactly one child, so matched/max is 0 or 1 and the 0.80
# threshold filters nothing.  Names differ on both the file and the folders, so
# no Merkle hash matches either: without `$mn > 1` the diagonal gets in and the
# whole chain is claimed on the strength of a single child.
F="$FIX/chain"
mk "$F/src/Chain/A/B/one.txt" c1
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Chain/P/Q/two.txt" c1        # same content, every name differs

#--- 11. the same chain with siblings: now the vote has something to say ------
# Three children, all renamed.  Merkle cannot match (names are in the hash) but
# the content hash can, which is the point of voting on chash: a folder whose
# files were all renamed is still recognised.
F="$FIX/chainsibs"
mk "$F/src/Chain/A/B/one.txt"   s1
mk "$F/src/Chain/A/B/two.txt"   s2
mk "$F/src/Chain/A/B/three.txt" s3
mkdir -p "$F/dst.orig"
mk "$F/dst.orig/Chain/P/Q/xx.txt" s1
mk "$F/dst.orig/Chain/P/Q/yy.txt" s2
mk "$F/dst.orig/Chain/P/Q/zz.txt" s3

echo "fixtures built in $FIX"
ls "$FIX"
