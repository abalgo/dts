# PROJECT_MAP — `dts`

Pure Perl, core modules only. Three standalone scripts, no shared library, no
build step. See `README.md` for usage.

## Classification

| File | Category | Role |
|---|---|---|
| `dtsgen.pl` | CORE | inventory generator: walks a tree, writes a `.dts` |
| `csharp/dtsgen/Program.cs` | CORE | C# port of the generator for Windows; byte-identical output |
| `dts.pl` | CORE | query engine over a `.dts`: duplicates, `rm` scripts, `-update` |
| `mutationstructure.pl` | CORE | diff of two `.dts` → `mv`/`rm` shell plan + projected `.dts` |
| `README.md` | DOC | user-facing documentation |
| `PROJECT_MAP.md` | DOC | this map |
| `dts.priority.example` | DOC | documented sample of a `dts.pl` priority file |
| `CLAUDE.md` | LOCAL | decisions, rationale, traps — git-ignored, not published |
| `t/run-tests.sh`, `t/mkfixtures.sh`, `t/baseline/` | INFRA | test suite and reference plans |
| `t_matching.pl` | INFRA | unit tests of the `dts.pl` expression parser and priority rules |
| `csharp/compare.sh` | INFRA | conformance: C# output vs `dtsgen.pl`, byte for byte |
| `csharp/dist/dtsgen.exe` | INFRA | committed self-contained build (11 MB, no runtime needed) |
| `csharp/README.md` | DOC | what the C# port fixes, what it measures, what differs |
| `LICENSE` | INFRA | MIT, Arnaud Bertrand |
| `.gitignore` | INFRA | keeps `*.dts` and generated plans out of the repo |
| `.claudeignore` | INFRA | keeps inventories out of agent context |
| `*.dts`, `plan.sh`, `tmpuniq.*` | IGNORE | generated data, never committed |
| `dts.priority` | IGNORE | per-directory rules, read by `dts.pl` if present |

## Data flow

```
tree ──dtsgen.pl──> source.dts ─┐
                                ├─mutationstructure.pl──> plan.sh + dest_new.dts
tree ──dtsgen.pl──> dest.dts ───┘

any .dts ──dts.pl──> duplicate report / rm script / updated .dts
```

## `dtsgen.pl` — entry points

| Sub | Purpose |
|---|---|
| `entries()` | sorted listing of one directory; used by **both** passes, so order is identical by construction |
| `prescan()` | pre-pass for `--eta` / `--extern`: walk without reading content |
| `visit()` | recursive walk; returns (type, raw digest, cumulative size) |
| `flush_batch()` | one `sha1sum` exec per batch of 1000 files (`--extern`), matched **by path** |
| `hash_file()`, `emit()`, `utc()` | local hashing and line formatting |
| `stamp()` | mtime → columns 59-75; shared with `--update`'s staleness test |
| `cached()` | `--update`: reuse the stored digest when size and mtime both match |

`--verbose` alone prints progress and rates; totals and ETA need `--eta`, which
pays for a second `lstat` walk (implied by `--extern`, which needs the list
anyway). `--out FILE` avoids PowerShell's UTF-16 `>` redirection.

The C# port in `csharp/dtsgen/` mirrors this file sub for sub (`Entries`,
`Prescan`, `Visit`, `Cached`, `Stamp`, `Emit`), so the two can be read side by
side. It drops `--extern` (CNG hashing already beats `sha1sum`) and adds
`--perl-mtime` (reproduce `Time::HiRes`' double rounding, for diffing) and
`--skip-cloud`. `sh csharp/compare.sh` pins the byte-for-byte equality.

Windows, Strawberry Perl only: a path over `MAX_PATH` is reported as `TOO LONG`
rather than `ENOENT`, a name outside the active code page is hashed through its
8.3 short name (the path column is then approximate), and both are counted and
warned about at the end. `cached()` falls back to whole seconds when either side
carries a `.000000` fraction, so a `.dts` survives the Cygwin/Strawberry split.

`--update` reuses the ordinary walk with `cached()` plugged in, so a refreshed
inventory cannot drift from a generated one; `--add-missing` makes the two
byte-identical. Writes `FILE_new.dts` and `TmpDeleted.dts`.

## `mutationstructure.pl` — entry points

| Sub | Purpose |
|---|---|
| `read_dts()` | parse a `.dts` by fixed columns |
| `detect_root()`, `common_prefix()`, `rel()` | derive tree roots and relative paths |
| `index_side()`, `index_dst()` | build the lookup tables; re-run once per round |
| `plan_dirs_exact()`, `plan_files()` | the two historical planning passes |
| `chash()`, `child_index()` | content hash (names excluded) of every direct child |
| `score_pair()`, `fuzzy_pairs()` | approximate match on direct children, `matched / max(\|S'\|,\|D'\|)` |
| `related()` | refuse a pair where one path sits inside the other |
| `apply_virtual()`, `rehash_dst()` | advance the destination state between rounds |
| `schedule()` | mv ordering, cycles broken with a temporary name; once per round |
| `walk()`, `utcof()` | projected `.dts` generation (`--new-dts`) |

Planning is a loop: round 1 is the historical planner, then `--fuzzy-dirs`
advances a virtual state and re-runs everything, so files an approximate folder
carried along leave in the next round. Capped at 5 rounds.

## `dts.pl` — shape and entry points

Two-pass filter over a `.dts` (count keys, then emit), with `wanted()` deciding
what enters the pass. Global variables and a `while ($_ = $ARGV[0], /^-/)` option
loop, deliberately preserved — it predates the other two tools by years. Do not
modernise without being asked. Long option names are matched **before** the loop,
each with `next`, so `-keeppriority` is not swallowed by the `-keep` prefix.

| Sub | Purpose |
|---|---|
| `wanted()` | is the line kept (type, `-szmin`) |
| `mx_is_expr()` | bare string (basename regex) or expression? — backwards compatibility |
| `mx_tokenize()` | string → tokens; free delimiters, paired `{} [] <>` nest |
| `mx_or()`, `mx_and()`, `mx_not()` | recursive descent, `\|\|` < `&&` < `!` / `()` / term |
| `mx_build()`, `mx_compile()` | tokens → closure; `mx_compile` also handles the bare form |
| `mx_rules()` | split on commas → list of `[label, closure]` |
| `matching()` | `1` if the expression matches, cached per expression string |
| `load_priority_file()` | `dts.priority`: `[keeppriority]` / `[rmpriority]` sections |
| `add_rules()`, `priority()` | build the ordered rule table; score a path, first match wins |

Match expressions serve `-grep`, `-nogrep`, `-only`, `-notonly`, `-keep`,
`-rmonly`, `-keeppriority` and `-rmpriority`: `f:/re/flags` on the basename,
`p:/re/flags` on the whole path, `!`, `&&`, `||`, `()`.

Priority scoring picks the survivor of each duplicate group for `-genrm`:
command line `-keeppriority` (1000 down), then the file's `[keeppriority]`
(800 down), then `-rmpriority` (-1000 up), then `[rmpriority]` (-800 up);
default 0, highest score kept, `-rmonly` still protects an entry. `-showprio`
annotates the output — for reading only, it breaks the column format.

## Invariants

- `.dts` columns are fixed: `1` type, `3-16` size, `18-57` sha1, `59-75`
  `epoch.us`, `77-91` UTC, `93+` path. Duplicate key = `1-57`.
- No external `sort` anywhere; the recursive walk orders by construction.
- `mutationstructure.pl` never deletes a file unless an identical copy survives.
- Compare inventories on `cut -c1-57,93-` (directory mtimes are not hashed).

## Testing

`sh t/run-tests.sh` — 11 fixtures, 150 assertions. Each fixture's plan is
**executed for real**, then re-inventoried and diffed against `--new-dts`.
`t/baseline/` holds the committed reference plans of the default mode.

The work directory must stay outside OneDrive (file locks break `mv`); the
default, `$TMPDIR/dts-tests`, already is.

`perl t_matching.pl` — 57 unit tests, instant, no fixtures. It `eval`s the
expression part of `dts.pl` between two cuts anchored on **code**, not on
comment wording, and dies if the anchor disappears. `dts.pl` is looked up next
to the script, so it runs from anywhere; section 8 of `t/run-tests.sh` runs it
in a scratch directory and folds its totals in.
