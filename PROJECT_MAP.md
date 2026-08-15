# PROJECT_MAP — `dts`

Pure Perl, core modules only. Three standalone scripts, no shared library, no
build step. See `README.md` for usage.

## Classification

| File | Category | Role |
|---|---|---|
| `dtsgen.pl` | CORE | inventory generator: walks a tree, writes a `.dts` |
| `dts.pl` | CORE | query engine over a `.dts`: duplicates, `rm` scripts, `-update` |
| `mutationstructure.pl` | CORE | diff of two `.dts` → `mv`/`rm` shell plan + projected `.dts` |
| `README.md` | DOC | user-facing documentation |
| `PROJECT_MAP.md` | DOC | this map |
| `CLAUDE.md` | LOCAL | decisions, rationale, traps — git-ignored, not published |
| `t/run-tests.sh`, `t/mkfixtures.sh`, `t/baseline/` | INFRA | test suite and reference plans |
| `LICENSE` | INFRA | MIT, Arnaud Bertrand |
| `.gitignore` | INFRA | keeps `*.dts` and generated plans out of the repo |
| `.claudeignore` | INFRA | keeps inventories out of agent context |
| `*.dts`, `plan.sh`, `tmpuniq.*` | IGNORE | generated data, never committed |

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
| `prescan()` | pre-pass for `--verbose` / `--extern`: walk without reading content |
| `visit()` | recursive walk; returns (type, raw digest, cumulative size) |
| `flush_batch()` | one `sha1sum` exec per batch of 1000 files (`--extern`), matched **by path** |
| `hash_file()`, `emit()`, `utc()` | local hashing and line formatting |
| `stamp()` | mtime → columns 59-75; shared with `--update`'s staleness test |
| `cached()` | `--update`: reuse the stored digest when size and mtime both match |

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
| `descend()`, `score_pair()`, `fuzzy_pairs()` | approximate match, `matched / max(\|S'\|,\|D'\|)` |
| `apply_virtual()`, `rehash_dst()` | advance the destination state between rounds |
| `schedule()` | mv ordering, cycles broken with a temporary name; once per round |
| `walk()`, `utcof()` | projected `.dts` generation (`--new-dts`) |

Planning is a loop: round 1 is the historical planner, then `--fuzzy-dirs`
advances a virtual state and re-runs everything, so files an approximate folder
carried along leave in the next round. Capped at 5 rounds.

## `dts.pl` — shape

Single-pass filter over a `.dts`, one helper (`wanted()`). Global variables and a
`while ($_ = $ARGV[0], /^-/)` option loop, deliberately preserved — it predates
the other two tools by years. Do not modernise without being asked.

## Invariants

- `.dts` columns are fixed: `1` type, `3-16` size, `18-57` sha1, `59-75`
  `epoch.us`, `77-91` UTC, `93+` path. Duplicate key = `1-57`.
- No external `sort` anywhere; the recursive walk orders by construction.
- `mutationstructure.pl` never deletes a file unless an identical copy survives.
- Compare inventories on `cut -c1-57,93-` (directory mtimes are not hashed).

## Testing

`sh t/run-tests.sh` — 8 fixtures, 61 assertions. Each fixture's plan is
**executed for real**, then re-inventoried and diffed against `--new-dts`.
`t/baseline/` holds the committed reference plans of the default mode.

The work directory must stay outside OneDrive (file locks break `mv`); the
default, `$TMPDIR/dts-tests`, already is.
