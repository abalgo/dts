#!/usr/bin/perl
# dtsgen.pl v1.1 - signed inventory + Merkle tree hashes, fixed columns
# Columns (1-based): 1 type | 3-16 size | 18-57 sha1 | 59-75 epoch.us
#                    77-91 UTC | 93+ path            (duplicate key = 1-57)
# Types: f file | d directory | l symlink | s special
# Usage: dtsgen.pl [--xdev] [--exclude REGEX]... [--max-size MB]
#                  [--extern] [--batch N] [--verbose] ROOT...
#        dtsgen.pl --check FILE.dts        (presence + size, no hashing)
#        dtsgen.pl --update FILE.dts [--add-missing]
#   --xdev            do not cross mount points
#   --exclude REGEX   skip matching paths (repeatable)
#   --max-size MB     ignore files larger than this
#   --extern          delegate hashing to sha1sum, in batches
#   --batch N         batch size and progress step (default 1000)
#   --verbose         pre-pass, progress, throughput and ETA
#   --check F.dts     verify presence/type/size without hashing; exit 1 on drift
#   --update F.dts    refresh an inventory: roots come from the .dts, entries
#                     whose size AND mtime still match keep their digest, the
#                     others are re-hashed, vanished ones are dropped.
#                     Writes F_new.dts and TmpDeleted.dts (the dropped lines).
#   --add-missing     with --update, also inventory files the .dts never had
#   --help  --version
use strict;
use warnings;
no warnings 'recursion';
use Digest::SHA qw(sha1);
use Time::HiRes qw(stat lstat time);

my $VERSION = 'v1.1';
use Getopt::Long;

my @excl;
my $xdev    = 0;
my $maxmb   = 0;
my $extern  = 0;
my $batchsz = 1000;
my $verbose = 0;
my $check;
my $update;                 # .dts to refresh
my $addmissing = 0;         # also pick up files that are not in it yet

my (%old, %seen);           # path -> cached entry / path -> re-emitted
my @oldorder;               # paths in file order, for the deletion list

sub usage {
    open my $me, '<', $0 or die "$0: $!\n";
    while (<$me>) { next if $. == 1; last unless s/^#\s?//; print }
    close $me;
    exit 0;
}

GetOptions('exclude=s' => \@excl,   'xdev'    => \$xdev,
           'max-size=i'=> \$maxmb,  'extern'  => \$extern,
           'batch=i'   => \$batchsz,'verbose' => \$verbose,
           'check=s'   => \$check,
           'update=s'  => \$update,  'add-missing' => \$addmissing,
           'help'      => sub { usage() },
           'version'   => sub { print "dtsgen.pl $VERSION\n"; exit 0 })
    or die "invalid option (--help)\n";
die "--add-missing only makes sense with --update\n" if $addmissing && !$update;
my $skip = @excl ? do { my $r = join '|', @excl; qr/$r/ } : undef;
my $maxb = $maxmb * 1048576;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';
$| = 1;                     # unbuffered: an interrupt never loses a line

my $ZERO = pack('H*', '0' x 40);
my ($nfile, $ndir, $nskip, $nerr, $next, $nbatch) = (0, 0, 0, 0, 0, 0);
my ($nkept, $nrehash, $nnew, $ngone) = (0, 0, 0, 0);   # --update accounting
my $vol = 0;

my (@files, %pos, %ext);    # pre-pass: file order; digests from sha1sum
my $flushed  = 0;           # index of the first not-yet-hashed file
my $totfile  = 0;           # total file count (empty ones included)
my $totbytes = 0;           # total bytes to read
my $t0;                     # start of phase 2

sub hms {
    my $s = int($_[0] + 0.5);
    return sprintf "%d:%02d:%02d", int($s/3600), int($s/60)%60, $s%60 if $s >= 3600;
    return sprintf "%d:%02d", int($s/60), $s%60;
}

sub go {                    # bytes -> GB or MB
    my $b = $_[0];
    return sprintf "%.1f GB", $b/1073741824 if $b >= 1073741824;
    return sprintf "%.1f MB", $b/1048576;
}

sub utc {
    my @t = gmtime($_[0] || 0);
    sprintf "%04d%02d%02d-%02d%02d%02d",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];
}

# columns 59-75.  Shared with --update, which compares the stored stamp against
# the disk one: the comparison must round exactly like the writer, or every
# entry would look stale.
sub stamp {
    my $mtime = $_[0] // 0;
    my $sec = int $mtime;
    my $us  = int(($mtime - $sec) * 1e6 + 0.5);
    if ($us > 999999) { $sec++; $us = 0 }
    return (sprintf("%010d.%06d", $sec, $us), $sec);
}

sub emit {
    my ($type, $raw, $size, $mtime, $path) = @_;
    $size //= 0;
    my ($st, $sec) = stamp($mtime);
    $seen{$path} = 1 if $update;
    printf "%s %014d %s %s %s %s\n",
           $type, $size, unpack('H*', $raw), $st, utc($sec), $path;
}

# sorted listing of one directory: [name, path, type, \@stat]
# used by BOTH the pre-pass and the emit pass -> identical order guaranteed
sub entries {
    my ($dir, $count) = @_;
    my $dh;
    unless (opendir $dh, $dir) {
        warn "opendir: $dir: $!\n"; $nerr++ if $count; return;
    }
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    my @ent;
    for my $n (@names) {
        my $p = $dir eq '/' ? "/$n" : "$dir/$n";
        if ($skip && $p =~ $skip) { $nskip++ if $count; next }
        # --update without --add-missing describes the same set as before: a
        # path the .dts never knew about is not inventoried now
        if ($update && !$addmissing && !$old{$p}) { $nnew++ if $count; next }
        my @s = lstat $p;
        unless (@s) { warn "lstat: $p: $!\n"; $nerr++ if $count; next }
        my $t = -l _ ? 'l' : -d _ ? 'd' : -f _ ? 'f' : 's';
        if ($t eq 'f' && $maxb && $s[7] > $maxb) { $nskip++ if $count; next }
        push @ent, [$n, $p, $t, \@s];
    }
    return @ent;
}

# pre-pass: walk without reading any content, in the exact emit order
sub prescan {
    my ($path, $type, $st, $dev) = @_;
    if ($type eq 'f') {
        $totfile++;
        # a cached entry is neither read nor handed to sha1sum, so it must not
        # inflate the total the ETA is computed from
        return if defined cached($path, $st->[7], $st->[9]);
        $totbytes += $st->[7];
        push @files, $path if $st->[7] > 0;
        if ($verbose && $totfile % 10000 == 0) {
            printf STDERR "  scan... %d files, %s | %s\n", $totfile, go($totbytes), $path;
        }
        return;
    }
    return unless $type eq 'd';
    return if $xdev && defined $dev && $st->[0] != $dev;
    for my $e (entries($path, 0)) {
        prescan($e->[1], $e->[2], $e->[3], $st->[0]);
    }
}

# one sha1sum exec for the next chunk of the list
sub flush_batch {
    my $end = $flushed + $batchsz;
    $end = @files if $end > @files;
    my @p = @files[$flushed .. $end - 1];
    $flushed = $end;
    return unless @p;
    my $pid = open(my $fh, '-|');
    unless (defined $pid) { warn "fork: $!\n"; return }
    unless ($pid) {                                   # child
        open STDERR, '>', '/dev/null';
        exec('sha1sum', '-b', '--', @p);
        exit 127;
    }
    binmode $fh, ':raw';
    while (<$fh>) {
        chomp;
        next unless /^([0-9a-f]{40}) [ *](.*)\z/;
        $ext{$2} = pack('H*', $1);
    }
    close $fh;
    $nbatch++;
}

# --update: a file whose size AND mtime still match the .dts keeps its digest,
# which is the whole point - nothing is read.  Any drift on either field means
# the content is re-hashed.  Directories and symlinks are always recomputed:
# a directory hash depends on entries that may have gone, and readlink is free.
sub cached {
    my ($path, $size, $mtime) = @_;
    return undef unless $update;
    my $o = $old{$path} or return undef;
    return undef unless $o->{type} eq 'f';
    return undef unless $o->{size} == $size;
    return undef unless $o->{stamp} eq (stamp($mtime))[0];
    return pack 'H*', $o->{hash};
}

sub hash_file {
    my ($path) = @_;
    if ($extern) {
        my $i = $pos{$path};
        flush_batch() while defined $i && $flushed <= $i;
        my $raw = delete $ext{$path};
        if (defined $raw) { $next++; return $raw }
    }
    return eval { Digest::SHA->new(1)->addfile($path, 'b')->digest };
}

# returns (type, raw digest, cumulative size); empty list if skipped/failed
sub visit {
    my ($path, $type, $st, $dev) = @_;
    my ($sdev, $size, $mtime) = @$st[0, 7, 9];

    if ($type eq 'l') {
        my $t = readlink $path;
        unless (defined $t && length $t) { warn "readlink: $path: $!\n"; $nerr++; return }
        my $raw = sha1('link ' . length($t) . "\0" . $t);
        emit('l', $raw, length($t), $mtime, $path);
        return ('l', $raw, 0);                        # a symlink takes no space
    }
    if ($type eq 'd') {
        return if $xdev && defined $dev && $sdev != $dev and ++$nskip;
        my ($payload, $tot) = ('', 0);
        for my $e (entries($path, 1)) {
            my ($t, $raw, $sz) = visit($e->[1], $e->[2], $e->[3], $sdev);
            next unless defined $raw;
            $payload .= "$t $e->[0]\0$raw";
            $tot     += $sz;
        }
        my $raw = sha1('tree ' . length($payload) . "\0" . $payload);
        emit('d', $raw, $tot, $mtime, $path);
        $ndir++;
        return ('d', $raw, $tot);
    }
    if ($type eq 'f') {
        my $raw = cached($path, $size, $mtime);
        my $read = !defined $raw;
        if ($read) {
            $raw = hash_file($path);
            $nrehash++ if $update;
        }
        else { $nkept++ }
        unless (defined $raw) { warn "read: $path: $@"; $nerr++; return }
        emit('f', $raw, $size, $mtime, $path);
        $nfile++;
        $vol += $size if $read;             # only what was actually read
        if ($verbose && $nfile % $batchsz == 0) {
            my $el  = time() - $t0;
            my $eta = '';
            if ($el > 1 && $vol > 0 && $totbytes > $vol) {
                my $rate = $vol / $el;
                $eta = sprintf ", %.0f MB/s, ETA %s",
                       $rate / 1048576, hms(($totbytes - $vol) / $rate);
            }
            printf STDERR "  ... %d/%d files, %s/%s%s\n",
                   $nfile, $totfile, go($vol), go($totbytes), $eta;
        }
        return ('f', $raw, $size);
    }
    emit('s', $ZERO, 0, $mtime, $path);
    return ('s', $ZERO, 0);
}

#--- --check: does the .dts still describe the disk? (size only) -------------
if (defined $check) {
    open my $cf, '<', $check or die "$check: $!\n";
    binmode $cf, ':raw';
    my ($n, $miss, $bad, $typ) = (0, 0, 0, 0);
    while (<$cf>) {
        s/\r?\n\z//;
        next if length($_) < 93;
        my $t = substr($_, 0, 1);
        my $sz = substr($_, 2, 14) + 0;
        my $p  = substr($_, 92);
        $n++;
        my @s = lstat $p;
        unless (@s) { print "MISSING  $p\n"; $miss++; next }
        my $r = -l _ ? 'l' : -d _ ? 'd' : -f _ ? 'f' : 's';
        if ($r ne $t) { print "TYPE $t->$r  $p\n"; $typ++; next }
        next unless $t eq 'f';
        if ($s[7] != $sz) { printf "SIZE %d->%d  %s\n", $sz, $s[7], $p; $bad++ }
    }
    close $cf;
    warn "$n entries: $miss missing, $typ type changed, $bad size changed\n";
    exit($miss || $bad || $typ ? 1 : 0);
}

#--- --update: refresh an existing .dts instead of walking named roots -------
my ($newdts, $deldts) = (undef, 'TmpDeleted.dts');
if (defined $update) {
    die "--update takes no ROOT argument (the roots come from the .dts)\n"
        if @ARGV;
    open my $uf, '<', $update or die "$update: $!\n";
    binmode $uf, ':raw';
    while (<$uf>) {
        s/\r?\n\z//;
        next if length($_) < 93;
        my $p = substr($_, 92);
        next if $old{$p};                        # duplicate path: keep the first
        $old{$p} = { type  => substr($_,  0,  1),
                     size  => substr($_,  2, 14) + 0,
                     hash  => substr($_, 17, 40),
                     stamp => substr($_, 58, 17),
                     line  => $_ };
        push @oldorder, $p;
    }
    close $uf;
    die "$update: no usable line\n" unless @oldorder;

    ($newdts = $update) =~ s/\.dts\z//i;
    $newdts .= '_new.dts';
    warn sprintf("%s: %d entries -> %s\n", $update, scalar @oldorder, $newdts)
        if $verbose;
}

my @roots = @ARGV ? @ARGV : ('.');
if (defined $update) {
    # a root is an entry whose parent the .dts does not carry
    @roots = grep {
        my $i = rindex($_, '/');
        $i <= 0 || !$old{ substr($_, 0, $i) };
    } @oldorder;
}
my @start;
for my $r (@roots) {
    $r =~ s{/+$}{} unless $r eq '/';
    my @s = stat $r;                    # an explicitly named root IS followed
    unless (@s) { warn "stat: $r: $!\n"; $nerr++; next }
    push @start, [$r, (-d _ ? 'd' : -f _ ? 'f' : 's'), \@s];
}

if ($extern || $verbose) {
    warn "dtsgen $VERSION - phase 1: taking inventory...\n" if $verbose;
    my $ts = time();
    prescan(@$_[0, 1, 2], $_->[2][0]) for @start;
    $pos{ $files[$_] } = $_ for 0 .. $#files;
    warn sprintf("phase 1 done in %s: %d files, %s to read\n",
                 hms(time() - $ts), $totfile, go($totbytes)) if $verbose;
    ($nskip, $nerr) = (0, 0);           # counted for real during the emit pass
}

warn "phase 2: hashing...\n" if $verbose;
$t0 = time();

my $outfh;
if (defined $update) {                  # emit() writes to the selected handle
    open $outfh, '>', $newdts or die "$newdts: $!\n";
    binmode $outfh, ':raw';
    select $outfh;
    $| = 1;
}

visit(@$_[0, 1, 2], $_->[2][0]) for @start;

if (defined $update) {
    select STDOUT;
    close $outfh or die "$newdts: $!\n";
    open my $df, '>', $deldts or die "$deldts: $!\n";
    binmode $df, ':raw';
    for my $p (@oldorder) {             # original order, original lines
        next if $seen{$p};
        print $df $old{$p}{line}, "\n";
        $ngone++;
    }
    close $df or die "$deldts: $!\n";
}

warn sprintf("done in %s, %s\n", hms(time() - $t0), go($vol)) if $verbose;
warn "$nfile files", ($extern ? " ($next via sha1sum, $nbatch batches)" : ""),
     ", $ndir dirs, $nskip skipped, $nerr errors\n";
if (defined $update) {
    warn "$nkept unchanged, $nrehash re-hashed, $ngone gone -> $deldts\n";
    warn "$nnew new file(s) ignored, use --add-missing to take them in\n"
        if $nnew && !$addmissing;
    warn "$newdts written\n";
}
