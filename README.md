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
git clone https://github.com/abalgo/dts.git
cd dts && chmod +x *.pl
```

Requires Perl 5.10+ with `Digest::SHA`, `Time::HiRes` and `Getopt::Long` — all
core since 2007. `--extern` additionally needs `sha1sum` (GNU coreutils).

Tested on Linux, Termux (Android), MSYS2 / Git Bash and Strawberry Perl on
Windows.

On Windows, prefer MSYS2: its Perl is a Cygwin build that uses the wide Win32
APIs, so long paths and non-ANSI names simply work. Strawberry Perl is faster
but hits both limits — see *Known limitations*. Under PowerShell, always write
the inventory with `--out`, never with `>`.

For Windows there is also a **C# build of the generator** in `csharp/`, which
has neither limit and hashes about eight times faster than MSYS2 Perl. Its
output is byte-for-byte the same `.dts`. See [csharp/README.md](csharp/README.md).

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
          [--extern] [--batch N] [--verbose] [--eta] [--out FILE] ROOT...
dtsgen.pl --check FILE.dts
dtsgen.pl --update FILE.dts [--add-missing]
```

| Option | Effect |
|---|---|
| `--xdev` | do not cross mount points |
| `--exclude REGEX` | skip matching paths (repeatable) |
| `--max-size Mo` | ignore files larger than this |
| `--extern` | delegate hashing to `sha1sum`, in batches |
| `--batch N` | batch size and progress step (default 1000) |
| `--verbose` | progress and throughput on stderr |
| `--eta` | extra pre-pass for the totals, so progress can show `x/total` and a time remaining |
| `--out FILE` | write the inventory to a file instead of stdout |
| `--check F.dts` | verify presence, type and size — no hashing; exit 1 on drift |
| `--update F.dts` | refresh an inventory in place of re-hashing everything |
| `--add-missing` | with `--update`, also take in files the `.dts` never had |

`--eta` is not free: knowing the totals up front means walking the whole tree a
second time with `lstat`. On Windows and MSYS2, where `lstat` is expensive, that
can double the total runtime. `--extern` implies it, since it needs the file
list anyway.

Use `--out` under PowerShell: its `>` redirection writes UTF-16 and would
corrupt the `.dts`.

Symlinks are hashed on their target string and **never followed** — except a
root you name explicitly on the command line, which is followed.

Output is written as it goes and unbuffered: killing the process leaves a valid
partial file, never a truncated line.

### `--update` — refresh an inventory without re-reading everything

```sh
./dtsgen.pl --update phone.dts --add-missing
```

The roots come from the `.dts`, so no `ROOT` argument is given. Every file whose
**size and mtime both still match** keeps its recorded digest and is not read at
all; any drift on either field means the file is re-hashed. Vanished entries are
dropped. Directory hashes and mtimes are always recomputed — a directory hash
depends on entries that may have gone.

Two files are written, and the input `.dts` is left untouched:

| File | Contents |
|---|---|
| `FILE_new.dts` | the refreshed inventory |
| `TmpDeleted.dts` | the lines that were dropped, verbatim |

Without `--add-missing` the refreshed inventory describes **the same set of
paths as before**, minus what disappeared: a file the `.dts` never knew about
stays out, and the run reports how many were ignored. With `--add-missing` the
result is byte-for-byte what a full `dtsgen.pl` run would produce — that
equality is what the test suite checks.

Running `--update` twice changes nothing the second time.

Two things worth knowing before trusting the output:

- **If the volume is not mounted**, every entry looks vanished: `FILE_new.dts`
  comes out near-empty and `TmpDeleted.dts` holds the whole inventory. Nothing is
  lost — your original `.dts` is untouched — but check the counts before
  replacing it. A missing root is reported as an error, not silently.
- Without `--add-missing`, a directory whose contents are **all** new is
  inventoried as empty, with the empty-tree hash. It is the rule working as
  specified, but the line reads as if the folder were empty on disk.

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
| `-grep E` / `-nogrep E` / `-only E` / `-notonly E` | filter groups by match expression |
| `-genrm` | emit an `rm` script, first occurrence of each group commented out |
| `-keep E` | keep the copy matching E |
| `-rmonly E` | emit an `rm` script, but uncomment only what matches E |
| `-keeppriority E[,E...]` | rules choosing which copy survives (repeatable) |
| `-rmpriority E[,E...]` | rules choosing which copy goes first (repeatable) |
| `-priorityfile F` | rules read from a file (default `./dts.priority`) |
| `-nopriorityfile` | ignore `./dts.priority` |
| `-showprio` | annotate the output with the computed score |
| `-bl` | blank line between groups |
| `-update` | split a `.dts` into still-present and vanished entries |

Two traps worth knowing before running `-genrm`:

- every empty file shares `da39a3ee…` and every empty directory shares
  `4b825dc6…`. Always pass `-szmin 1`.
- Git object stores are already content-addressed and the same blob legitimately
  appears in several repositories. Exclude `.git` at inventory time.

### Match expressions

Everywhere an expression is expected — `-grep`, `-nogrep`, `-only`, `-notonly`,
`-keep`, `-rmonly`, `-keeppriority`, `-rmpriority` — you can write more than a
bare pattern:

| Form | Meaning |
|---|---|
| `f:/re/flags` | regex on the **basename** |
| `p:/re/flags` | regex on the **whole path** |
| `/re/flags` | same as `f:/re/flags` |
| `!` `&&` `\|\|` `( )` | negation, conjunction, disjunction, grouping |
| flags | `i` `m` `s` `x`, as in Perl |

Any non-alphanumeric character may serve as the delimiter, except `(` and `)`,
which are reserved for grouping — handy when the pattern itself contains
slashes: `p:|/tmp/|`, `f:#\.jpg$#`. The paired delimiters `{}`, `[]` and `<>`
nest, so `p:{/(a|b)/}` needs no escaping.

A string that does not start with `/`, `!`, `(`, `f:` or `p:` is taken literally
as a regex on the basename, so `-grep jpg` keeps working exactly as before.

```sh
./dts.pl -gt 1 -szmin 1 -grep '/\.jpg$/ && f:/^20/ && !p:/mk_/' pictures.dts
```

### Choosing which copy survives

With `-genrm`, the first entry of each group is the one kept. Priority rules let
you decide instead: every entry is scored, and in each group of duplicates the
**highest score survives** while the others are removed.

```sh
./dts.pl -gt 1 -szmin 1 -genrm \
    -keeppriority 'p:|/NAS/photos/|,f:/^IMG_/' \
    -rmpriority   'f:/ - copie\b/i,p:{/(Downloads|Corbeille)/}' pictures.dts
```

Rules are tried in order and the first one that matches fixes the score;
anything unmatched scores 0. Rules given earlier therefore win:

| Source | Scores |
|---|---|
| `-keeppriority` | 1000, 999, 998 … |
| `-keep` | after the `-keeppriority` rules |
| `[keeppriority]` in the file | 800, 799 … |
| nothing matched | 0 |
| `[rmpriority]` in the file | −800, −799 … |
| `-rmpriority` | −1000, −999 … |

The command line always outranks the file. An entry protected by `-rmonly` is
never removed, whatever its score.

Rules you reuse belong in a **priority file** — `./dts.priority` by default,
read if it exists, skipped silently otherwise:

```
[keeppriority]
p:|/important/|i
f:/^IMG_/ || f:/^DSC_/

[rmpriority]
f:/ - copie\b/i || f:/ \(\d+\)\./
p:{/(Corbeille|Downloads)/}
```

One expression per line, most important first; blank lines and `#` comments are
ignored. `-priorityfile F` reads another file (and fails if it is missing),
`-nopriorityfile` ignores the default one. See `dts.priority.example`.

`-showprio` shows the score and the rule that produced it on each line, so you
can check a rule set before running the script. It is meant to be **read**, not
executed nor fed back to `dts.pl`: it breaks the column format.

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
| `--new-dts [FILE]` | projected `.dts` of the destination; without a value, derived from `DESTINATION.dts` → `DESTINATION_new.dts` |
| `--report-mvdir` | report approximate directory matches, emit nothing |
| `--parity-threshold F` | minimum match score, default 0.80 |
| `--fuzzy-dirs` | act on approximate matches instead of only reporting them |

Typical use: you reorganised photos on the NAS and want the phone to follow,
so the next backup does not copy everything again.

```sh
./dtsgen.pl /volume1/backup/phone > nas.dts
./dtsgen.pl --extern ~/storage/shared > phone.dts

./mutationstructure.pl --grep DCIM --remove \
    --out plan.sh --new-dts nas.dts phone.dts

less plan.sh          # always read it first
sh plan.sh
./dtsgen.pl --check phone_new.dts     # --new-dts with no value -> phone_new.dts
```

A generated plan looks like this — one `mv` for a whole subtree, thanks to the
Merkle hash:

```sh
cd 'sim/phone/DCIM' || exit 1
mkdir -p '2024/Vacances'

# --- directories ---
mv -n 'Old' 'Divers'

# --- files ---
mv -n 'Camera/IMG_001.jpg' '2024/Vacances/IMG_001.jpg'

# --- duplicates (1) ---
rm -f 'Camera/note_copie.jpg'

# --- cleanup (harmlessly fails if not empty) ---
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

### Approximate directory matching

A directory that gained or lost a file no longer matches by Merkle hash, even
though it is clearly "the same folder" — a large video kept on the NAS but
deleted from the phone, for instance.

`--report-mvdir` scores candidate pairs by voting on their **direct children**.
Each child contributes one digest — a file its content hash, a subdirectory its
own directory hash, never its contents — and

```
score = matched / max(|S'|, |D'|)
```

where `S'` and `D'` count only children whose digest exists *somewhere* in the
other tree, so content living on one side only does not penalise the match.

The digest used here is a **content hash**: the same construction as the Merkle
hash but with names left out, so a folder whose files were all renamed still
matches. It is computed on the fly from the `.dts` — no format change, and
nothing to re-hash.

A pair is rejected when one side is an ancestor of the other (the move could not
be executed: in the destination tree the target is the source's own parent), when
the destination directory already has a counterpart at the same relative path, or
when either side has fewer than two comparable children — a single child scores
either 0 or 1 and carries no useful resolution.

```
[0.83] Camera  ->  2024/Vacances
       5 matched / max(5,6)   (min: 1.00)
       + 5 files vote: IMG_001.jpg, IMG_002.jpg, IMG_003.jpg, ...
       ~ perso.jpg : follows the folder, absent from source
       ! note.jpg : follows the folder though it belongs to Divers/note.jpg
```

Why direct children rather than the whole subtree: counting every descendant
lets a directory compete with its own child, since it contains everything the
child does plus more. On a real 82k-file inventory that produced pairs like
`Android/media → Android` at 0.98 — the parent borrowing the evidence of an
alignment that was already correct. Direct-children scoring mirrors what the
Merkle hash already does, where a subdirectory enters its parent as a single
entry rather than being flattened into it.

The `!` lines are the ones to watch: files that would be carried along by the
move although they belong somewhere else.

`--report-mvdir` emits nothing. Use it to calibrate `--parity-threshold` on your
own data, then pass `--fuzzy-dirs` to act on the matches.

#### `--fuzzy-dirs`

Off by default: without it the plan is exactly what it has always been.

With it, an accepted pair becomes a real directory move — one `mv` instead of a
thousand — and the planner then **runs again on the resulting layout**, so the
files the folder dragged along are sorted out:

```sh
mv -n 'Camera' '2024/Vacances'   # fuzzy 0.83

# --- files (round 2) ---
mv -n '2024/Vacances/note.jpg' 'Divers/note.jpg'
```

The `!` file is relocated to where the source puts it; the `~` file, which
exists only on the destination side, stays with its neighbours — that is the
point of tolerating an imperfect match. The score is printed next to the move so
it is visible at review time.

Rounds repeat until nothing moves, capped at five (a warning is printed if the
cap is hit). A folder pair that was only approximate in one round is often exact
in the next, once its stray files have left.

---

## Known limitations

- **Nesting differences are not folded into one move.** When the same content
  sits one level deeper on one side (`X/{f}` versus `X/sub/{f}`), no directory
  move is possible — the target would be the source's own parent — so the files
  are moved individually and the emptied folder is `rmdir`'d. Correct, just not
  compact.
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
- `--extern` keeps the ordered file list in memory: a few MB for 100k files,
  around 500 MB for several million. `--eta` counts and measures without
  keeping the list.
- **Windows, Strawberry Perl only** — both limits come from the ANSI Win32 APIs
  it is built against, and neither exists under MSYS2:
  - a path of 260 characters or more cannot be opened. Such entries are
    reported as `TOO LONG`, counted, and **missing from the inventory**; a final
    warning says so. Without admin rights, `subst X: "J:\deep\prefix"` and
    inventory `X:/` instead.
  - a name holding a character outside the active code page cannot be opened
    either. The file is hashed through its 8.3 short name so its content is
    still signed, but the path column is approximate — such a `.dts` will not
    compare cleanly with one produced on Linux, MSYS2 or Android. Counted and
    warned about at the end.
- **Mixing Cygwin and Strawberry inventories**: Cygwin reads the NTFS timestamp
  and reports microseconds, the Microsoft CRT reports `.000000`. `--update`
  compares whole seconds whenever either side lacks the fraction, so a `.dts`
  stays usable across both — at the cost of not detecting a sub-second rewrite
  in that case.

---

## Credits

`dts.pl` was originally written by **Arnaud Bertrand** to manage signature
databases of files burned on CD, and predates the rest of this repository by a
long while. `dtsgen.pl` and `mutationstructure.pl` were written to replace the
`find | xargs sha1sum | paste` pipeline it used to be fed with.

## License

MIT — see [LICENSE](LICENSE).
