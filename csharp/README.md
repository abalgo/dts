# `dtsgen` in C# — the Windows build

A port of `dtsgen.pl` to C# (.NET 8), written for one situation: **inventorying
a Windows disk**. It produces byte-for-byte the same `.dts` as the Perl
generator, and removes the three things that make the Perl one painful there.

```sh
csharp/dist/dtsgen.exe --verbose --out disk.dts J:/
```

`csharp/dist/dtsgen.exe` is committed and **self-contained**: no .NET runtime to
install, nothing to build, one 11 MB file. Rebuild it with

```sh
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:PublishTrimmed=true \
  -p:EnableCompressionInSingleFile=true -o csharp/dist csharp/dtsgen
```

or just `dotnet build -c Release csharp/dtsgen` for a framework-dependent build
while working on it. A NativeAOT build would be smaller still, but it needs the
MSVC linker on `PATH`.

## What it fixes

| Strawberry Perl | this port |
|---|---|
| a path of 260 characters or more cannot be opened — the entry is **missing** from the inventory | every access goes through the `\\?\` extended form; a 365-character path is inventoried normally |
| a name outside the active ANSI code page comes back mangled and is hashed through its 8.3 short name, so the path column is approximate | UTF-16 end to end, UTF-8 out; the name is written exactly as it is on disk |
| the Microsoft CRT returns a `time_t`, so every mtime is written `.000000` | the FILETIME is read as 100 ns ticks and rounded to microseconds |
| one `lstat` per entry, and `lstat` is expensive on Windows | type, size and mtime all come out of the directory enumeration itself — **no file is opened for metadata** |

Only two things still open a handle: the file contents, which have to be read to
be hashed, and the target of a symlink, which is rare.

MSYS2 Perl has none of the first three problems — it is a Cygwin build using the
wide APIs — but it pays for the emulated `fork`/`lstat` layer, and `Digest::SHA`
gets no hardware acceleration.

## Measured

Same machine, same trees, MSYS2 Perl as the reference:

| Tree | `dtsgen.pl` (MSYS2) | this port |
|---|---|---|
| 2506 small files, 13 dirs | 1.6 s | 0.19 s |
| 4 × 100 MB (hash throughput) | 1.5 s (≈ 275 MB/s) | 0.18 s (≈ 2.2 GB/s) |

`SHA1.HashData` goes through CNG, which uses SHA-NI. That is faster than the
`sha1sum` figures in the main README, so **`--extern` has no reason to exist
here** and is not implemented.

## Conformance

```sh
sh csharp/compare.sh            # the t/ fixtures, both sides
sh csharp/compare.sh /some/tree
```

It uses `csharp/dist/dtsgen.exe`, falling back to the build output; set
`DTSGEN_EXE` to pick another one.

Verified byte-for-byte against `dtsgen.pl` under MSYS2 Perl on: the 11 test
fixtures (22 trees), and a stress tree carrying a name with `!`, non-ANSI names
(`café_日本_🎂.txt`), an empty file, an empty directory, a 365-character path
and 2500 files in one directory. `--update` (both `FILE_new.dts` and
`TmpDeleted.dts`, with the same counters) and `--check` were compared the same
way.

## Options

Same as `dtsgen.pl` — `--exclude`, `--max-size`, `--batch`, `--verbose`,
`--eta`, `--out`, `--check`, `--update`, `--add-missing` — plus:

| Option | Effect |
|---|---|
| `--perl-mtime` | round mtimes the way `Time::HiRes` does |
| `--skip-cloud` | skip OneDrive-style placeholders instead of triggering a download |

`--perl-mtime` exists for comparison only. `Time::HiRes` hands Perl a **double**,
which at current epoch values resolves about 0.25 µs, so its last digit can be
off by one; this port computes microseconds exactly from the ticks. On the
stress tree the two differ on 168 lines out of 2519 — always by ±1 in the last
digit. Use `--perl-mtime` to diff against a Perl-produced `.dts`, and the
default everywhere else.

`--skip-cloud` uses the `Offline` / `RecallOnOpen` / `RecallOnDataAccess`
attributes, which the enumeration already returns — it answers the OneDrive trap
listed in the main README without a single file being opened.

## Deliberate differences

- **`--extern` is not implemented.** Hashing is already faster than `sha1sum`
  here; forking per batch would only slow it down.
- **`--xdev` is a no-op on Windows**, and refused elsewhere. Crossing a volume
  on Windows means going through a mount point, which is a reparse point: those
  are typed `l` and never descended, so the walk cannot leave its volume.
  On Unix, .NET does not expose `st_dev`.
- **Symlink targets** are emitted with `\` rewritten to `/`. The code path is a
  straight port, but it could not be exercised on this machine: Git Bash's
  `ln -s` copies rather than linking, and creating a real NTFS symlink needs
  developer mode or elevation. Treat it as untested.
- A `.dts` line is flushed every 1024 entries rather than one by one. Killing
  the process still leaves a valid file, just up to 1024 lines shorter than the
  Perl one would be.
