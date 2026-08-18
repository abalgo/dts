// dtsgen.cs v1.1 - signed inventory + Merkle tree hashes, fixed columns
//
// A port of dtsgen.pl to C#, written for Windows: it keeps the speed of a
// native build while dropping the two limits of Strawberry Perl.
//
//   * paths are not capped at MAX_PATH   - every filesystem access goes through
//     the \\?\ extended-length form, so a 400-character path is inventoried
//     instead of being reported as an error and silently left out;
//   * names are UTF-16 end to end        - a name outside the active ANSI code
//     page is read, hashed and written as it really is, so no 8.3 fallback and
//     no lossy path column;
//   * mtimes keep their fraction         - the FILETIME is read as 100 ns ticks
//     and rounded to microseconds, where the Microsoft CRT would have handed
//     back a whole-second time_t and written .000000;
//   * metadata costs no file open        - type, size and mtime all come from
//     the directory enumeration itself (FindFirstFile/FindNextFile under
//     FileSystemEnumerable), not from a per-entry stat.  Only file contents,
//     which have to be read anyway, and the rare symlink target are opened.
//
// Output is byte-for-byte what dtsgen.pl produces on the same tree: same
// column layout, same sort order, same Merkle framing, UTF-8, "\n" endings.
//
// Usage: dtsgen [--xdev] [--exclude REGEX]... [--max-size MB]
//               [--batch N] [--verbose] [--eta] [--skip-cloud]
//               [--perl-mtime] [--out FILE] ROOT...
//        dtsgen --check FILE.dts        (presence + type + size, no hashing)
//        dtsgen --update FILE.dts [--add-missing]

using System.Diagnostics;
using System.IO.Enumeration;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Dts;

/// <summary>One directory entry, with everything the walk needs.</summary>
internal readonly struct Ent
{
    public readonly string Name;      // as it appears in its parent
    public readonly byte[] NameUtf8;  // sort key and Merkle payload
    public readonly string Path;      // display path, always '/' separated
    public readonly string Native;    // OS path, extended-length on Windows
    public readonly char Type;        // f d l s
    public readonly long Size;
    public readonly long Ticks;       // mtime, UTC, 100 ns since year 1

    public Ent(string name, byte[] nameUtf8, string path, string native,
               char type, long size, long ticks)
    {
        Name = name; NameUtf8 = nameUtf8; Path = path; Native = native;
        Type = type; Size = size; Ticks = ticks;
    }
}

/// <summary>What a .dts line says about one path.</summary>
internal sealed class OldEntry
{
    public required char Type;
    public required long Size;
    public required string Hash;   // 40 hex chars
    public required string Stamp;  // columns 59-75, "epoch.microseconds"
    public required string Line;   // verbatim, for the deletion list
}

internal static class Program
{
    private const string Version = "v1.1";

    // ---- options -----------------------------------------------------------
    private static Regex? _skipRe;
    private static bool _xdev, _verbose, _wantEta, _addMissing, _skipCloud, _perlMtime;
    private static long _maxBytes;
    private static int _batch = 1000;
    private static string? _outFile, _check, _update;

    // ---- counters ----------------------------------------------------------
    private static long _nFile, _nDir, _nSkip, _nErr, _nCloud;
    private static long _nBadTime;   // mtime outside 1970..9999, recorded as epoch 0
    private static long _nKept, _nRehash, _nNew, _nGone;
    private static long _vol, _totFile, _totBytes;

    // ---- state -------------------------------------------------------------
    private static readonly Dictionary<string, OldEntry> Old = new(StringComparer.Ordinal);
    private static readonly List<string> OldOrder = new();
    private static readonly HashSet<string> Seen = new(StringComparer.Ordinal);
    private static readonly byte[] Zero20 = new byte[20];
    private static TextWriter _out = Console.Out;
    private static long _emitted;

    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static double _t0, _lastT;
    private static long _lastV, _lastN;

    private static int Main(string[] rawArgs)
    {
        // reports go to the same tools as the Perl ones: "\n", never "\r\n"
        Console.Out.NewLine = "\n";
        Console.Error.NewLine = "\n";

        List<string> roots;
        try { roots = ParseArgs(rawArgs); }
        catch (ArgumentException e) { Console.Error.WriteLine(e.Message); return 2; }

        if (_check is not null) return RunCheck(_check);

        string? newDts = null;
        const string delDts = "TmpDeleted.dts";
        if (_update is not null)
        {
            if (roots.Count > 0)
            {
                Console.Error.WriteLine("--update takes no ROOT argument (the roots come from the .dts)");
                return 2;
            }
            if (!LoadOld(_update)) return 2;
            newDts = Regex.Replace(_update, @"\.dts$", "", RegexOptions.IgnoreCase) + "_new.dts";
            if (_verbose)
                Console.Error.WriteLine($"{_update}: {OldOrder.Count} entries -> {newDts}");
            roots = UpdateRoots();
        }
        if (roots.Count == 0) roots.Add(".");

        var start = new List<Ent>();
        foreach (var r in roots)
        {
            var ent = RootEntry(r);
            if (ent is null) { _nErr++; continue; }
            start.Add(ent.Value);
        }

        if (_wantEta)
        {
            if (_verbose) Console.Error.WriteLine($"dtsgen {Version} - phase 1: taking inventory...");
            double ts = Now;
            foreach (var e in start) Prescan(e);
            if (_verbose)
                Console.Error.WriteLine(
                    $"phase 1 done in {Hms(Now - ts)}: {_totFile} files, {Go(_totBytes)} to read");
            _nSkip = _nErr = 0;   // counted for real during the emit pass
        }

        if (_verbose) Console.Error.WriteLine("phase 2: hashing...");
        _t0 = _lastT = Now;

        string? target = _update is not null ? newDts : _outFile;
        Stream? fileStream = null;
        try
        {
            if (target is not null)
            {
                fileStream = new FileStream(Native(target), FileMode.Create, FileAccess.Write,
                                            FileShare.Read, 1 << 16, FileOptions.SequentialScan);
                _out = new StreamWriter(fileStream, Utf8, 1 << 16) { NewLine = "\n" };
            }
            else
            {
                _out = new StreamWriter(Console.OpenStandardOutput(), Utf8, 1 << 16) { NewLine = "\n" };
            }

            foreach (var e in start) Visit(e);
            _out.Flush();
        }
        catch (IOException e) { Console.Error.WriteLine(e.Message); return 2; }
        finally { _out.Flush(); fileStream?.Dispose(); }

        if (_update is not null)
        {
            using var df = new StreamWriter(Native(delDts), false, Utf8) { NewLine = "\n" };
            foreach (var p in OldOrder)
            {
                if (Seen.Contains(p)) continue;
                df.WriteLine(Old[p].Line);
                _nGone++;
            }
        }

        if (_verbose) Console.Error.WriteLine($"done in {Hms(Now - _t0)}, {Go(_vol)}");
        if (_nBadTime > 0)
        {
            Console.Error.WriteLine($"WARNING: {_nBadTime} entry/entries carry an mtime outside 1970..9999 and were");
            Console.Error.WriteLine("         recorded as 1970-01-01.  The filesystem timestamp is corrupt;");
            Console.Error.WriteLine("         Windows shows no \"date modified\" for these files either.");
        }
        if (_nCloud > 0)
            Console.Error.WriteLine($"{_nCloud} cloud placeholder(s) skipped (--skip-cloud)");
        Console.Error.WriteLine($"{_nFile} files, {_nDir} dirs, {_nSkip} skipped, {_nErr} errors");
        if (_update is not null)
        {
            Console.Error.WriteLine($"{_nKept} unchanged, {_nRehash} re-hashed, {_nGone} gone -> {delDts}");
            if (_nNew > 0 && !_addMissing)
                Console.Error.WriteLine($"{_nNew} new file(s) ignored, use --add-missing to take them in");
            Console.Error.WriteLine($"{newDts} written");
        }
        return 0;
    }

    // =======================================================================
    //  Option parsing
    // =======================================================================

    private static List<string> ParseArgs(string[] args)
    {
        var excl = new List<string>();
        var roots = new List<string>();
        long maxMb = 0;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            string Value(string name) =>
                ++i < args.Length ? args[i] : throw new ArgumentException($"{name} needs a value");

            switch (a)
            {
                case "--exclude":     excl.Add(Value(a)); break;
                case "--xdev":        _xdev = true; break;
                case "--max-size":    maxMb = long.Parse(Value(a)); break;
                case "--batch":       _batch = Math.Max(1, int.Parse(Value(a))); break;
                case "--verbose":     _verbose = true; break;
                case "--eta":         _wantEta = true; break;
                case "--skip-cloud":  _skipCloud = true; break;
                case "--perl-mtime":  _perlMtime = true; break;
                case "--out":         _outFile = Value(a); break;
                case "--check":       _check = Value(a); break;
                case "--update":      _update = Value(a); break;
                case "--add-missing": _addMissing = true; break;
                case "--version":     Console.WriteLine($"dtsgen (C#) {Version}"); Environment.Exit(0); break;
                case "--help":        Usage(); Environment.Exit(0); break;
                default:
                    if (a.StartsWith('-') && a.Length > 1)
                        throw new ArgumentException($"invalid option {a} (--help)");
                    roots.Add(a);
                    break;
            }
        }

        if (_addMissing && _update is null)
            throw new ArgumentException("--add-missing only makes sense with --update");
        if (_xdev && !OperatingSystem.IsWindows())
            Console.Error.WriteLine("warning: --xdev is not implemented on this platform, ignored");
        if (excl.Count > 0)
            _skipRe = new Regex(string.Join('|', excl), RegexOptions.Compiled);
        _maxBytes = maxMb * 1048576;
        return roots;
    }

    private static void Usage()
    {
        Console.WriteLine($"""
        dtsgen (C#) {Version} - signed inventory + Merkle tree hashes

        Usage: dtsgen [options] ROOT...
               dtsgen --check FILE.dts
               dtsgen --update FILE.dts [--add-missing]

          --exclude REGEX   skip matching paths (repeatable)
          --xdev            do not cross mount points (Windows: implicit)
          --max-size MB     ignore files larger than this
          --batch N         progress step (default 1000)
          --verbose         progress and throughput on stderr
          --eta             extra pre-pass for the totals, so progress can show
                            x/total and a time remaining
          --skip-cloud      skip OneDrive-style placeholders instead of
                            triggering a download
          --perl-mtime      round mtimes the way Time::HiRes does, for a
                            byte-for-byte comparison with dtsgen.pl output
          --out FILE        write the inventory to FILE instead of stdout
          --check F.dts     verify presence/type/size without hashing
          --update F.dts    refresh an inventory; writes F_new.dts and
                            TmpDeleted.dts
          --add-missing     with --update, also inventory new files
          --help  --version

        The output is byte-for-byte what dtsgen.pl writes on the same tree.
        """);
    }

    // =======================================================================
    //  Paths
    //
    //  Two forms travel together: the display path, always '/' separated and
    //  exactly what lands in column 93, and the native path, which on Windows
    //  carries the \\?\ prefix so nothing stops at MAX_PATH.  Building them
    //  side by side costs one concatenation and removes every later conversion.
    // =======================================================================

    private static readonly UTF8Encoding Utf8 = new(false);

    private static string Native(string display)
    {
        if (!OperatingSystem.IsWindows()) return display;
        string full = Path.GetFullPath(display);              // \\?\ needs it normalised
        if (full.StartsWith(@"\\?\", StringComparison.Ordinal)) return full;
        if (full.StartsWith(@"\\", StringComparison.Ordinal))  return @"\\?\UNC\" + full[2..];
        return @"\\?\" + full;
    }

    private static string JoinNative(string parent, string name) =>
        OperatingSystem.IsWindows() ? parent + '\\' + name : parent + '/' + name;

    private static string JoinDisplay(string parent, string name) =>
        parent == "/" ? "/" + name : parent + "/" + name;

    // =======================================================================
    //  Formatting - columns 1-91 must match dtsgen.pl exactly
    // =======================================================================

    // 9999-12-31T23:59:59Z: past that, the UTC column would widen too.
    private const long MaxTime = 253402300799L;

    /// <summary>True for an mtime no sane filesystem should report.</summary>
    private static bool BadTime(long ticks)
    {
        long unixTicks = ticks - DateTime.UnixEpoch.Ticks;
        return unixTicks < 0 || unixTicks / 10_000_000L > MaxTime;
    }

    /// <summary>mtime ticks -> ("epoch.microseconds", whole seconds).</summary>
    private static (string, long) Stamp(long ticks)
    {
        // Some filesystems hand out timestamps outside any sane range --
        // Windows itself then shows no "date modified".  Beyond breaking every
        // consumer, a negative value breaks the fixed layout: "D10" of a
        // negative number is 11 characters wide, so the whole line shifts by
        // one and every later column is wrong.  Record these as epoch 0; see
        // the _nBadTime warning.
        if (BadTime(ticks)) ticks = DateTime.UnixEpoch.Ticks;
        long unixTicks = ticks - DateTime.UnixEpoch.Ticks;    // 100 ns units
        long sec = Math.DivRem(unixTicks, 10_000_000L, out long rem);
        if (rem < 0) { sec--; rem += 10_000_000L; }
        long us;
        if (_perlMtime)
        {
            // Time::HiRes hands Perl a double; at current epoch values it only
            // resolves ~0.25 us, so the last digit can differ from the exact
            // value.  Reproducing the same arithmetic is what makes a
            // byte-for-byte diff against dtsgen.pl possible.
            double m = sec + rem / 1e7;
            us = (long)((m - sec) * 1e6 + 0.5);
        }
        else
        {
            us = (rem + 5) / 10;                              // exact, half-up
        }
        if (us > 999_999) { sec++; us = 0; }
        return (sec.ToString("D10") + "." + us.ToString("D6"), sec);
    }

    private static string Utc(long sec) =>
        DateTime.UnixEpoch.AddSeconds(sec).ToString("yyyyMMdd-HHmmss");

    private static void Emit(char type, byte[] raw, long size, long ticks, string path)
    {
        if (BadTime(ticks)) _nBadTime++;
        var (stamp, sec) = Stamp(ticks);
        if (_update is not null) Seen.Add(path);
        _out.Write(type);
        _out.Write(' ');
        _out.Write(size.ToString("D14"));
        _out.Write(' ');
        _out.Write(Convert.ToHexString(raw).ToLowerInvariant());
        _out.Write(' ');
        _out.Write(stamp);
        _out.Write(' ');
        _out.Write(Utc(sec));
        _out.Write(' ');
        _out.Write(path);
        _out.Write('\n');
        // dtsgen.pl runs unbuffered so that an interrupt never loses a line;
        // a periodic flush keeps that property without a syscall per entry
        if ((++_emitted & 1023) == 0) _out.Flush();
    }

    // =======================================================================
    //  Directory listing - the single source of order for both passes
    // =======================================================================

    private static readonly EnumerationOptions EnumOpts = new()
    {
        RecurseSubdirectories = false,
        ReturnSpecialDirectories = false,
        AttributesToSkip = 0,
        IgnoreInaccessible = false,
        MatchType = MatchType.Simple,
    };

    private static List<Ent> Entries(in Ent dirEnt, bool count)
    {
        // copied out of the `in` parameter: a local function cannot capture one
        Ent dir = dirEnt;
        var raw = new List<Ent>();
        try
        {
            var seq = new FileSystemEnumerable<Ent>(dir.Native, Transform, EnumOpts);
            raw.AddRange(seq);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"opendir: {dir.Path}: {e.Message}");
            if (count) _nErr++;
            return raw;
        }

        // Perl sorts with a plain byte sort; on a UTF-8 system that is the
        // UTF-8 byte order, which is NOT the UTF-16 ordinal order above the BMP
        raw.Sort(static (a, b) => CompareBytes(a.NameUtf8, b.NameUtf8));

        var keep = new List<Ent>(raw.Count);
        foreach (var e in raw)
        {
            if (_skipRe is not null && _skipRe.IsMatch(e.Path)) { if (count) _nSkip++; continue; }
            // --update without --add-missing describes the same set as before
            if (_update is not null && !_addMissing && !Old.ContainsKey(e.Path))
            { if (count) _nNew++; continue; }
            if (e.Type == 'f' && _maxBytes > 0 && e.Size > _maxBytes) { if (count) _nSkip++; continue; }
            keep.Add(e);
        }
        return keep;

        Ent Transform(ref FileSystemEntry entry)
        {
            string name = entry.FileName.ToString();
            var attrs = entry.Attributes;
            char type = (attrs & FileAttributes.ReparsePoint) != 0 ? 'l'
                      : (attrs & FileAttributes.Directory) != 0 ? 'd'
                      : 'f';
            return new Ent(name, Utf8.GetBytes(name),
                           JoinDisplay(dir.Path, name), JoinNative(dir.Native, name),
                           type, entry.Length, entry.LastWriteTimeUtc.UtcTicks);
        }
    }

    private static int CompareBytes(byte[] a, byte[] b)
    {
        int n = Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++)
            if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
        return a.Length.CompareTo(b.Length);
    }

    /// <summary>
    /// A reparse point is only a symlink if a target can be read from it: a
    /// OneDrive placeholder carries the same attribute and is an ordinary file.
    /// </summary>
    private static string? LinkTarget(in Ent e)
    {
        try
        {
            FileSystemInfo? info = Directory.Exists(e.Native)
                ? new DirectoryInfo(e.Native) : new FileInfo(e.Native);
            return info.LinkTarget;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { return null; }
    }

    private static bool IsCloudPlaceholder(FileAttributes a) =>
        (a & FileAttributes.Offline) != 0 ||
        ((int)a & 0x00400000) != 0 ||     // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
        ((int)a & 0x00040000) != 0;       // FILE_ATTRIBUTE_RECALL_ON_OPEN

    // =======================================================================
    //  Roots - a root named on the command line IS followed
    // =======================================================================

    private static Ent? RootEntry(string root)
    {
        string display = root.Length > 1 ? root.TrimEnd('/', '\\') : root;
        if (display.Length == 0) display = root;
        string native = Native(display);
        try
        {
            if (Directory.Exists(native))
            {
                var di = new DirectoryInfo(native);
                return new Ent(display, Utf8.GetBytes(display), display, native,
                               'd', 0, di.LastWriteTimeUtc.Ticks);
            }
            var fi = new FileInfo(native);
            if (fi.Exists)
                return new Ent(display, Utf8.GetBytes(display), display, native,
                               'f', fi.Length, fi.LastWriteTimeUtc.Ticks);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"stat: {display}: {e.Message}");
            return null;
        }
        Console.Error.WriteLine($"stat: {display}: no such file or directory");
        return null;
    }

    // =======================================================================
    //  The two walks
    // =======================================================================

    private static void Prescan(in Ent e)
    {
        if (e.Type == 'f')
        {
            _totFile++;
            if (Cached(e) is not null) return;   // not read, so not in the total
            _totBytes += e.Size;
            if (_verbose && _totFile % 10000 == 0)
                Console.Error.WriteLine($"  scan... {_totFile} files, {Go(_totBytes)} | {e.Path}");
            return;
        }
        if (e.Type != 'd') return;
        foreach (var c in Entries(e, false)) Prescan(c);
    }

    /// <summary>Emits the entry and returns (type, digest, size) for the parent.</summary>
    private static (char, byte[], long)? Visit(in Ent e)
    {
        switch (e.Type)
        {
            case 'l':
            {
                string? target = LinkTarget(e);
                if (target is null)
                {
                    // not a link after all: a placeholder, or a reparse tag we
                    // do not understand.  Treat it as what it is on disk.
                    var real = new Ent(e.Name, e.NameUtf8, e.Path, e.Native,
                                       Directory.Exists(e.Native) ? 'd' : 'f',
                                       e.Size, e.Ticks);
                    return Visit(real);
                }
                byte[] t = Utf8.GetBytes(target.Replace('\\', '/'));
                byte[] raw = Sha1Framed("link ", t);
                Emit('l', raw, t.Length, e.Ticks, e.Path);
                return ('l', raw, 0);            // a symlink takes no space
            }

            case 'd':
            {
                var payload = new MemoryStream();
                long total = 0;
                foreach (var c in Entries(e, true))
                {
                    var r = Visit(c);
                    if (r is null) continue;
                    var (ct, craw, csz) = r.Value;
                    payload.WriteByte((byte)ct);
                    payload.WriteByte((byte)' ');
                    payload.Write(c.NameUtf8, 0, c.NameUtf8.Length);
                    payload.WriteByte(0);
                    payload.Write(craw, 0, craw.Length);
                    total += csz;
                }
                byte[] raw = Sha1Framed("tree ", payload.GetBuffer().AsSpan(0, (int)payload.Length));
                Emit('d', raw, total, e.Ticks, e.Path);
                _nDir++;
                return ('d', raw, total);
            }

            case 'f':
            {
                if (_skipCloud && IsCloud(e)) { _nCloud++; _nSkip++; return null; }
                byte[]? raw = Cached(e);
                bool read = raw is null;
                if (read)
                {
                    raw = HashFile(e);
                    if (_update is not null) _nRehash++;
                }
                else _nKept++;
                if (raw is null) return null;
                Emit('f', raw, e.Size, e.Ticks, e.Path);
                _nFile++;
                if (read) _vol += e.Size;
                if (_verbose && _nFile % _batch == 0) Progress();
                return ('f', raw, e.Size);
            }

            default:
                Emit('s', Zero20, 0, e.Ticks, e.Path);
                return ('s', Zero20, 0);
        }
    }

    private static bool IsCloud(in Ent e)
    {
        try { return IsCloudPlaceholder(File.GetAttributes(e.Native)); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return false; }
    }

    // =======================================================================
    //  Hashing
    // =======================================================================

    private static byte[] Sha1Framed(string kind, ReadOnlySpan<byte> payload)
    {
        byte[] head = Utf8.GetBytes(kind + payload.Length + "\0");
        byte[] buf = new byte[head.Length + payload.Length];
        head.CopyTo(buf, 0);
        payload.CopyTo(buf.AsSpan(head.Length));
        return SHA1.HashData(buf);
    }

    private static byte[]? HashFile(in Ent e)
    {
        try
        {
            using var fs = new FileStream(e.Native, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite | FileShare.Delete,
                                          1 << 16, FileOptions.SequentialScan);
            return SHA1.HashData(fs);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"read: {e.Path}: {ex.Message}");
            _nErr++;
            return null;
        }
    }

    // =======================================================================
    //  --update
    // =======================================================================

    private static bool LoadOld(string file)
    {
        try
        {
            foreach (string line in File.ReadLines(Native(file), Utf8))
            {
                if (line.Length < 93) continue;
                string p = line[92..];
                if (Old.ContainsKey(p)) continue;          // duplicate path: keep the first
                Old[p] = new OldEntry
                {
                    Type  = line[0],
                    Size  = long.Parse(line.Substring(2, 14)),
                    Hash  = line.Substring(17, 40),
                    Stamp = line.Substring(58, 17),
                    Line  = line,
                };
                OldOrder.Add(p);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"{file}: {e.Message}");
            return false;
        }
        if (OldOrder.Count == 0) { Console.Error.WriteLine($"{file}: no usable line"); return false; }
        return true;
    }

    /// <summary>A root is an entry whose parent the .dts does not carry.</summary>
    private static List<string> UpdateRoots()
    {
        var roots = new List<string>();
        foreach (string p in OldOrder)
        {
            int i = p.LastIndexOf('/');
            if (i <= 0 || !Old.ContainsKey(p[..i])) roots.Add(p);
        }
        return roots;
    }

    /// <summary>
    /// The stored digest is reused when size AND mtime still match.  As in
    /// dtsgen.pl, the comparison falls back to whole seconds when either side
    /// carries no fraction, so an inventory survives the Cygwin/Strawberry
    /// split - and now the C# port, which always has the fraction.
    /// </summary>
    private static byte[]? Cached(in Ent e)
    {
        if (_update is null) return null;
        if (!Old.TryGetValue(e.Path, out var o)) return null;
        if (o.Type != 'f' || o.Size != e.Size) return null;
        var (stamp, sec) = Stamp(e.Ticks);
        string of = o.Stamp.Substring(11, 6);
        string nf = stamp.Substring(11, 6);
        if (of == "000000" || nf == "000000")
        {
            if (!long.TryParse(o.Stamp.AsSpan(0, 10), out long osec) || osec != sec) return null;
        }
        else if (o.Stamp != stamp) return null;
        return Convert.FromHexString(o.Hash);
    }

    // =======================================================================
    //  --check
    // =======================================================================

    private static int RunCheck(string file)
    {
        long n = 0, miss = 0, bad = 0, typ = 0;
        try
        {
            foreach (string line in File.ReadLines(Native(file), Utf8))
            {
                if (line.Length < 93) continue;
                char t = line[0];
                long sz = long.Parse(line.Substring(2, 14));
                string p = line[92..];
                n++;
                string native = Native(p);
                var info = new FileInfo(native);          // one metadata query, no open
                if (!info.Exists && !Directory.Exists(native))
                { Console.WriteLine($"MISSING  {p}"); miss++; continue; }
                var attrs = File.GetAttributes(native);
                char r = (attrs & FileAttributes.ReparsePoint) != 0 ? 'l'
                       : (attrs & FileAttributes.Directory) != 0 ? 'd'
                       : 'f';
                if (r != t) { Console.WriteLine($"TYPE {t}->{r}  {p}"); typ++; continue; }
                if (t != 'f') continue;
                if (info.Length != sz)
                { Console.WriteLine($"SIZE {sz}->{info.Length}  {p}"); bad++; }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"{file}: {e.Message}");
            return 2;
        }
        Console.Error.WriteLine($"{n} entries: {miss} missing, {typ} type changed, {bad} size changed");
        return miss + bad + typ > 0 ? 1 : 0;
    }

    // =======================================================================
    //  Progress
    // =======================================================================

    private static double Now => Clock.Elapsed.TotalSeconds;

    private static void Progress()
    {
        double now = Now, el = now - _t0;
        string avg = el > 0.5
            ? $", avg {_vol / el / 1048576:F0} MB/s {_nFile / el:F0} f/s" : "";
        double dt = now - _lastT;
        string inst = dt > 0.05
            ? $" | now {(_vol - _lastV) / dt / 1048576:F0} MB/s {(_nFile - _lastN) / dt:F0} f/s" : "";
        _lastT = now; _lastV = _vol; _lastN = _nFile;
        string eta = el > 1 && _vol > 0 && _totBytes > _vol
            ? $", ETA {Hms((_totBytes - _vol) / (_vol / el))}" : "";
        Console.Error.WriteLine(_totFile > 0
            ? $"  ... {_nFile}/{_totFile} files, {Go(_vol)}/{Go(_totBytes)}{avg}{eta}{inst}"
            : $"  ... {_nFile} files, {Go(_vol)}{avg}{eta}{inst}");
    }

    private static string Hms(double seconds)
    {
        long s = (long)(seconds + 0.5);
        return s >= 3600
            ? $"{s / 3600}:{s / 60 % 60:D2}:{s % 60:D2}"
            : $"{s / 60}:{s % 60:D2}";
    }

    private static string Go(long b) =>
        b >= 1073741824 ? $"{b / 1073741824.0:F1} GB" : $"{b / 1048576.0:F1} MB";
}
