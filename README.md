# dts — signed filesystem inventories

A small set of Perl tools that build a **content signature of a whole directory tree**,
store it in a plain-text, fixed-column file (`.dts`), and use those files to find
duplicates, verify backups, and replay a reorganisation from one copy of a tree
onto another.

Everything is pure Perl using only core modules. No CPAN, no compiler, no daemon,
no database. A `.dts` file is a text file you can grep, sort, diff, and archive.

---

## Why

If you keep the same photos and documents on a NAS, a laptop and a phone, three
things keep happening:

- the same file ends up in several places and you would like to reclaim the space;
- you reorganise folders on one machine, and the next backup copies everything
  again because the paths changed;
- you want to know whether a backup is still intact without re-reading terabytes.

`dts` answers all three from the same artefact: a signature file per tree.

---

## Format

One line per filesystem entry, fixed columns, space separated:

```
f 00000000000014 5aa1980c4797fd5aa55ad23c0929ddad999b9ec5 1786718555.511523 20260814-144235 d/A/a.txt
d 00000000000027 06621ecf0d9b7cf9d699434f65642e4b25fe9297 1786718555.511523 20260814-144235 d/A
```

| Columns (1-based) | Field |
|---|---|
| 1 | type — `f` file, `d` directory, `l` symlink, `s` special |
| 3–16 | size in bytes, zero-padded (directories: recursive total) |
| 18–57 | SHA-1 |
| 59–75 | mtime, `epoch.microseconds` |
| 77–91 | same mtime as UTC `YYYYMMDD-hhmmss` |
| 93+ | path |

Columns 1–57 (type + size + hash) form the **duplicate key**.

Zero padding is deliberate: it keeps `sort` with no arguments meaningful, so
`grep '^f' all.dts | sort -r` lists your largest duplicates with identical
entries adjacent.

### Directory hashes

Directories carry a **Merkle hash** computed exactly like a Git tree object:

```
sha1("tree " + len + "\0" + concat(sorted("<type> <name>\0" + <raw digest>)))
```

Two directories have the same hash if and only if their entire subtrees are
identical — same contents *and* same names. An empty directory hashes to
`4b825dc642cb6eb9a060e54bf8d69288fbee4904`, the same value Git uses.

Metadata (size, mtime) is deliberately **outside** the hash, so an `rsync`
without `-t` does not make two trees diverge.

---

## Install

```sh
git clone https://github.com/YOURNAME/dts.git
cd dts && chmod +x *.pl
```

Requires Perl 5.10+ with `Digest::SHA`, `Time::HiRes` and `Getopt::Long` — all
core since 2007. `--extern` additionally needs `sha1sum` (GNU coreutils).

Tested on Linux, Termux (Android) and MSYS2 / Git Bash on Windows.

On Termux: `pkg install perl` then `termux-fix-shebang *.pl`, or just call
`perl dtsgen.pl ...`.

---

## Quick start

```sh
# 1. inventory a tree
./dtsgen.pl --exclude '/\.git/' ~/Pictures > pictures.dts

# 2. find duplicate files, largest first
./dts.pl -gt 1 -szmin 1 pictures.dts

# 3. find duplicate *directories* — one mv beats a thousand
./dts.pl -type d -gt 1 pictures.dts

# 4. months later, is the tree still intact? (no hashing)
./dtsgen.pl --check pictures.dts
```

---

## `dtsgen.pl` — build an inventory

```
dtsgen.pl [--xdev] [--exclude REGEX]... [--max-size Mo]
          [--extern] [--batch N] [--verbose] ROOT...
dtsgen.pl --check FILE.dts
```

| Option | Effect |
|---|---|
| `--xdev` | do not cross mount points |
| `--exclude REGEX` | skip matching paths (repeatable) |
| `--max-size Mo` | ignore files larger than this |
| `--extern` | delegate hashing to `sha1sum`, in batches |
| `--batch N` | batch size and progress step (default 1000) |
| `--verbose` | pre-pass, progress, throughput, ETA |
| `--check F.dts` | verify presence, type and size — no hashing; exit 1 on drift |

Symlinks are hashed on their target string and **never followed** — except a
root you name explicitly on the command line, which is followed.

Output is written as it goes and unbuffered: killing the process leaves a valid
partial file, never a truncated line.

### About `--extern`

`Digest::SHA` is portable C without assembly. GNU `sha1sum` links against
OpenSSL, which uses SHA-NI on x86 and the ARMv8 crypto extensions. On hardware
that has them the gap is large:

| Platform | `Digest::SHA` | `sha1sum` |
|---|---|---|
| x86-64, no SHA-NI | 466 MB/s | 747 MB/s |
| MSYS2 (gnulib, no OpenSSL) | 340 MB/s | 422 MB/s |
| Android ARMv8 with crypto ext. | ~230 MB/s | ~1.2 GB/s |

`--extern` closes that gap. On Android it brought CPU time from 2.24 s to
0.63 s on a 588 MB set, matching bare `sha1sum` while doing strictly more work.

It is **not** recommended on MSYS2/Git Bash, where emulated `fork()` costs more
than the hashing it saves.

Correctness does not depend on it: a path that `sha1sum` fails to report — an
unreadable file, or a name containing a newline, which GNU tools escape — simply
falls back to local hashing. Matching is by path, never by line position.

---

## `dts.pl` — query an inventory

```
dts.pl [-eq | -neq | -gt | -lt] [n] [options] FILE.dts...
```

| Option | Effect |
|---|---|
| `-gt n` / `-lt n` / `-eq n` / `-neq n` | entries appearing more/fewer/exactly/not n times |
| `-type f\|d\|l\|s\|a` | entry type to consider (default `f`; `-type d` finds duplicate trees) |
| `-szmin N` | ignore entries smaller than N bytes |
| `-grep S` / `-nogrep S` / `-only S` / `-notonly S` | filter groups by path pattern |
| `-genrm` | emit an `rm` script, first occurrence of each group commented out |
| `-keep S` | keep the copy matching S |
| `-bl` | blank line between groups |
| `-update` | split a `.dts` into still-present and vanished entries |

Two traps worth knowing before running `-genrm`:

- every empty file shares `da39a3ee…` and every empty directory shares
  `4b825dc6…`. Always pass `-szmin 1`.
- Git object stores are already content-addressed and the same blob legitimately
  appears in several repositories. Exclude `.git` at inventory time.

---

## `mutationstructure.pl` — replay a reorganisation

Takes two `.dts` files and emits a **shell script** that reorganises the
destination tree to match the source layout. It never copies anything, and it
only ever deletes duplicates.

```
mutationstructure.pl [options] SOURCE.dts DESTINATION.dts
```

| Option | Effect |
|---|---|
| `--grep REGEX` | only consider matching paths |
| `--src-root` / `--dst-root` | prefix to strip (otherwise inferred) |
| `--remove` | delete destination duplicates that became redundant |
| `--minsize N` | size floor, default 100 bytes |
| `--out FILE` | shell script (default stdout) |
| `--new-dts FILE` | projected `.dts` of the destination after execution |
| `--report-mvdir` | report approximate directory matches, emit nothing |
| `--parity-threshold F` | minimum match score, default 0.80 |

Typical use: you reorganised photos on the NAS and want the phone to follow,
so the next backup does not copy everything again.

```sh
./dtsgen.pl /volume1/backup/phone > nas.dts
./dtsgen.pl --extern ~/storage/shared > phone.dts

./mutationstructure.pl --grep DCIM --remove \
    --out plan.sh --new-dts phone_projected.dts nas.dts phone.dts

less plan.sh          # always read it first
sh plan.sh
./dtsgen.pl --check phone_projected.dts
```

A generated plan looks like this — one `mv` for a whole subtree, thanks to the
Merkle hash:

```sh
cd 'sim/phone/DCIM' || exit 1
mkdir -p '2024/Vacances'
# --- repertoires ---
mv -n 'Old' 'Divers'
# --- fichiers ---
mv -n 'Camera/IMG_001.jpg' '2024/Vacances/IMG_001.jpg'
# --- doublons (1) ---
rm -f 'Camera/note_copie.jpg'
# --- menage ---
rmdir 'Camera' 2>/dev/null || true
```

### Safety rules

- **A file is never deleted unless an identical copy survives elsewhere in the
  destination tree.** The surviving copy is tracked explicitly, not inferred
  from a count.
- Files present on only one side are never touched.
- Files below `--minsize` are excluded from both moves and deletions.
- Empty directories are excluded from matching — they all share one hash.
- A target already occupied by different content produces a commented-out line
  with the reason, not a move.
- Name swaps and rotations are detected and routed through a temporary name.
- `mv -n` is used as a last-resort guard.

### The projected `.dts`

`--new-dts` writes what the destination inventory *will* be, with all directory
hashes recomputed — so you do not have to re-hash the tree after the move. This
has been verified byte-for-byte against a real re-inventory on every test case,
including swaps and three-way rotations.

One caveat: directory **mtimes** in the projection keep their old values, since
the real ones are assigned by the kernel at `mv` time. They are not part of the
Merkle hash, so comparisons are unaffected — but compare on `cut -c1-57,93-`
rather than whole lines.

### Approximate directory matching (report only)

A directory that gained or lost a file no longer matches by Merkle hash, even
though it is clearly "the same folder" — a large video kept on the NAS but
deleted from the phone, for instance.

`--report-mvdir` scores candidate pairs by voting: every file matched between
the two sides is one vote, and

```
score = matched / max(|S'|, |D'|)
```

where `S'` and `D'` count only files that have a counterpart *somewhere* in the
other tree — so a file that exists on one side only does not penalise the match.

```
[0.83] Camera  ->  2024/Vacances
       5 communs / max(5,6)   (min : 1.00)
       + 5 fichiers votent : IMG_001.jpg, IMG_002.jpg, IMG_003.jpg, ...
       ~ perso.jpg : suit le dossier, absent de la source
       ! note.jpg : suit le dossier alors qu'il releve de Divers/note.jpg
```

The `!` lines are the ones to watch: files that would be carried along by the
move although they belong somewhere else.

**This is currently a reporting mode only.** Approximate matches are not wired
into the planner yet, because moving them safely requires a relocation pass for
those `!` files. Use it to calibrate the threshold on your own data.

---

## Known limitations

- **Case-insensitive filesystems** (NTFS, Android shared storage) preserve case
  but ignore it for lookup. `Foo` and `foo` are one file yet produce different
  tree hashes — relevant only when comparing a `.dts` across such a boundary.
- **Sub-second mtimes** are microseconds, not nanoseconds: an IEEE double cannot
  hold nine fractional digits at current epoch values. Android shared storage
  and MTP/FAT copies report `.000000`, which is accurate rather than missing —
  it is a useful provenance signal.
- **Paths containing a newline** break the line-oriented format. Detect them at
  inventory time.
- **OneDrive placeholders** cannot be reliably identified from Perl; opening one
  triggers a download. Use `--exclude`.
- `--extern` and `--verbose` keep the ordered file list in memory: a few MB for
  100k files, around 100 MB for several million.

---

## Credits

`dts.pl` was originally written by **Arnaud Bertrand** to manage signature
databases of files burned on CD, and predates the rest of this repository by a
long while. `dtsgen.pl` and `mutationstructure.pl` were written to replace the
`find | xargs sha1sum | paste` pipeline it used to be fed with.

## License

MIT — see [LICENSE](LICENSE).
