#!/usr/bin/perl
# mutationstructure.pl v1.1
# Replays the layout of a SOURCE tree onto a DESTINATION tree, using two .dts
# files produced by dtsgen.pl.  Copies nothing, deletes only duplicates:
# emits a shell script for you to review before running it.
#
# Usage: mutationstructure.pl [options] SOURCE.dts DESTINATION.dts
#   --grep REGEX      only consider matching paths
#   --src-root PATH   prefix to strip from source paths      (else inferred)
#   --dst-root PATH   prefix to strip from destination paths (else inferred)
#   --remove          delete destination duplicates that became redundant
#   --minsize N       size floor, default 100 bytes
#   --out FILE        shell script (default: stdout)
#   --new-dts [FILE]  projected .dts of the destination after execution;
#                     without a value, derived from DESTINATION.dts (_new.dts)
#   --verbose         details on stderr
#   --parity-threshold F  minimum approximate match score (default 0.80)
#   --report-mvdir    report directory matches, emit nothing
#   --help  --version
#
# Directory matching, in two stages:
#   1. identical Merkle hash -> certain (contents AND names), subtree consumed
#   2. voting                -> score = matched / max(|S'|,|D'|)
#      where S' and D' only count files that have a counterpart somewhere in
#      the other tree, so a file living on one side only (a large video kept
#      on the NAS but deleted from the phone) does not penalise the match.
use strict;
use warnings;
use Getopt::Long;
use Digest::SHA qw(sha1);

my ($srcroot, $dstroot, $grepstr, $newdts);
my $remove  = 0;
my $minsize = 100;
my $out     = '-';
my $verbose = 0;
my $parity  = 0.80;
my $report  = 0;
my $VERSION = 'v1.1';

sub usage {
    open my $me, '<', $0 or die "$0: $!\n";
    while (<$me>) { next if $. == 1; last unless s/^#\s?//; print }
    close $me;
    exit 0;
}

GetOptions('src-root=s' => \$srcroot, 'dst-root=s' => \$dstroot,
           'grep=s'     => \$grepstr, 'remove'     => \$remove,
           'minsize=i'  => \$minsize, 'out=s'      => \$out,
           'new-dts:s'  => \$newdts,  'verbose'    => \$verbose,
           'parity-threshold=f' => \$parity,
           'report-mvdir'       => \$report,
           'help'       => sub { usage() },
           'version'    => sub { print "mutationstructure.pl $VERSION\n"; exit 0 })
    or die "invalid option (--help)\n";
my ($SRC, $DST) = @ARGV;
die "usage: $0 [options] SOURCE.dts DESTINATION.dts\n" unless defined $DST;
if (defined $newdts && $newdts eq '') {      # --new-dts without a value
    ($newdts = $DST) =~ s/\.dts\z//i;
    $newdts .= '_new.dts';
}
my $RE = defined $grepstr ? qr/$grepstr/ : undef;

my $EMPTYTREE = sha1("tree 0\0");                 # shared by every empty dir

#--- reading -----------------------------------------------------------------
sub read_dts {
    my ($f) = @_;
    open my $fh, '<', $f or die "$f: $!\n";
    binmode $fh, ':raw';
    my @e;
    while (<$fh>) {
        s/\r?\n\z//;
        next if length($_) < 93;
        push @e, { type  => substr($_,  0,  1),
                   size  => substr($_,  2, 14) + 0,
                   hash  => substr($_, 17, 40),
                   stamp => substr($_, 58, 17),
                   path  => substr($_, 92) };
    }
    close $fh;
    die "$f: no usable line\n" unless @e;
    return \@e;
}

#--- root detection: explicit > --grep anchor > common prefix ----------------
sub common_prefix {
    my @l = map { [ split m{/}, $_, -1 ] } @_;
    return '' unless @l;
    my @c = @{ shift @l };
    for my $x (@l) {
        my $i = 0;
        $i++ while $i < @c && $i < @$x && $c[$i] eq $x->[$i];
        @c = @c[0 .. $i-1];
        return '' unless @c;
    }
    return join '/', @c;
}

sub detect_root {
    my ($ent, $explicit, $label) = @_;
    if (defined $explicit) { $explicit =~ s{/+\z}{}; return $explicit }
    if ($RE) {                                    # highest matching segment
        my @cand;
        for my $e (@$ent) {
            next unless $e->{path} =~ $RE;
            my @seg = split m{/}, $e->{path}, -1;
            for my $i (0 .. $#seg) {
                next unless $seg[$i] =~ $RE;
                push @cand, join('/', @seg[0 .. $i-1]);
                last;
            }
        }
        if (@cand) {
            my $r = common_prefix(@cand);
            warn "$label root inferred from --grep: '$r'\n" if $verbose;
            return $r;
        }
    }
    my $r = common_prefix(map { $_->{path} } @$ent);
    warn "$label root inferred from common prefix: '$r'\n" if $verbose;
    return $r;
}

sub rel {
    my ($p, $r) = @_;
    return $p if $r eq '';
    return ''  if $p eq $r;
    return index($p, "$r/") == 0 ? substr($p, length($r) + 1) : undef;
}

sub depth { my $n = ($_[0] =~ tr{/}{}); return $_[0] eq '' ? -1 : $n }

sub covered {                                     # rel under a consumed subtree
    my ($rel, $set) = @_;
    my $p = $rel;
    while (1) {
        return 1 if $set->{$p};
        my $i = rindex($p, '/');
        last if $i < 0;
        $p = substr($p, 0, $i);
    }
    return 0;
}

#--- indexing --------------------------------------------------------------
my $src = read_dts($SRC);
my $dst = read_dts($DST);
$srcroot = detect_root($src, $srcroot, 'source');
$dstroot = detect_root($dst, $dstroot, 'destination');

my (%srcdir, %dstdir, %srcfile, %dstfile);        # rel -> entry
my (%sdh, %ddh, %sfk, %dfk);                      # hash/key -> [rel...]
my %dstall;                                       # rel -> 1, actual occupancy

for my $e (@$dst) {
    my $r = rel($e->{path}, $dstroot);
    next unless defined $r && length $r;
    $e->{rel} = $r;
    $dstall{$r} = 1;
}

for my $pair ([$src, $srcroot, \%srcdir, \%srcfile, \%sdh, \%sfk],
              [$dst, $dstroot, \%dstdir, \%dstfile, \%ddh, \%dfk]) {
    my ($ent, $root, $dh, $fh, $byh, $byk) = @$pair;
    for my $e (@$ent) {
        my $r = rel($e->{path}, $root);
        next unless defined $r && length $r;
        $e->{rel} = $r;
        next if $RE && $e->{path} !~ $RE;
        if ($e->{type} eq 'd') {
            next if $e->{hash} eq unpack('H*', $EMPTYTREE);
            next if $e->{size} < $minsize;
            $dh->{$r} = $e;
            push @{ $byh->{ $e->{hash} } }, $r;
        }
        elsif ($e->{type} eq 'f') {
            next if $e->{size} < $minsize;
            $fh->{$r} = $e;
            push @{ $byk->{ $e->{size} . ':' . $e->{hash} } }, $r;
        }
    }
}

#--- planning -----------------------------------------------------------
my @moves;                                        # {from, to, kind}
my (%usedsrc, %useddst);                          # consumed subtrees
my %taken;                                        # destination rel already claimed

# 1) directories, shallowest first
for my $r (sort { depth($a) <=> depth($b) || $a cmp $b } keys %srcdir) {
    next if covered($r, \%usedsrc);
    my $h = $srcdir{$r}{hash};
    next unless @{ $sdh{$h} } == 1;               # ambiguous on the source side
    my $cands = $ddh{$h} or next;
    if (grep { $_ eq $r } @$cands) {              # already in the right place
        $usedsrc{$r} = $useddst{$r} = 1;
        next;
    }
    my ($pick) = grep { !covered($_, \%useddst) } sort @$cands;
    next unless defined $pick;
    push @moves, { from => $pick, to => $r, kind => 'd' };
    $usedsrc{$r} = 1;
    $useddst{$pick} = 1;
    $taken{$r} = 1;
}

# 2) remaining files
for my $r (sort keys %srcfile) {
    next if covered($r, \%usedsrc);
    my $k = $srcfile{$r}{size} . ':' . $srcfile{$r}{hash};
    next unless @{ $sfk{$k} } == 1;               # source-side uniqueness only
    my $cands = $dfk{$k} or next;
    my @free = grep { !covered($_, \%useddst) } sort @$cands;
    next unless @free;
    my ($keep) = grep { $_ eq $r } @free;         # already in place?
    if (defined $keep) {
        $useddst{$keep} = 1;
        $taken{$r} = 1;
    }
    else {
        $keep = $free[0];
        push @moves, { from => $keep, to => $r, kind => 'f' };
        $useddst{$keep} = 1;
        $taken{$r} = 1;
    }
}

#--- approximate directory matching (voting) ---------------------------------
# descendant file keys of every directory
sub descend {
    my ($files) = @_;
    my %d;
    for my $r (keys %$files) {
        my $k = $files->{$r}{size} . ':' . $files->{$r}{hash};
        my $c = $r;
        while ((my $i = rindex($c, '/')) > 0) {
            $c = substr($c, 0, $i);
            push @{ $d{$c} }, $k;
        }
        push @{ $d{''} }, $k;
    }
    return \%d;
}

sub score_pair {
    my ($sk, $dk) = @_;                # two key lists
    my (%cnt, $common);
    $cnt{$_}++ for @$sk;
    for my $k (@$dk) { if (($cnt{$k} // 0) > 0) { $cnt{$k}--; $common++ } }
    my $sp = grep { $dfk{$_} } @$sk;   # present somewhere in destination
    my $dp = grep { $sfk{$_} } @$dk;   # present somewhere in source
    my $mx = $sp > $dp ? $sp : $dp;
    my $mn = $sp < $dp ? $sp : $dp;
    return ($common // 0, $sp, $dp, $mx ? ($common // 0) / $mx : 0,
                                    $mn ? ($common // 0) / $mn : 0);
}

my $sdesc = descend(\%srcfile);
my $ddesc = descend(\%dstfile);

my %cand;                              # "S\0D" -> 1
for my $k (keys %sfk) {
    my $dr = $dfk{$k} or next;
    next if @{ $sfk{$k} } > 20 || @$dr > 20;      # key too common: skip
    for my $s (@{ $sfk{$k} }) {
        for my $d (@$dr) {
            my ($a, $b) = ($s, $d);
            while (1) {                           # the pair and all its ancestors
                my $i = rindex($a, '/'); my $j = rindex($b, '/');
                last if $i <= 0 || $j <= 0;
                $a = substr($a, 0, $i); $b = substr($b, 0, $j);
                last if $a eq $b;                 # already in the same place
                $cand{"$a\0$b"} = 1;
            }
        }
    }
}

my @pairs;
for my $c (keys %cand) {
    my ($s, $d) = split /\0/, $c, 2;
    next if covered($s, \%usedsrc) || covered($d, \%useddst);
    next unless $sdesc->{$s} && $ddesc->{$d};
    my ($common, $sp, $dp, $sc, $scmin) = score_pair($sdesc->{$s}, $ddesc->{$d});
    next unless $sc >= $parity;
    push @pairs, { s => $s, d => $d, n => $common, sp => $sp, dp => $dp,
                   score => $sc, smin => $scmin };
}
# shallowest first: a single mv covers more
@pairs = sort { depth($a->{s}) <=> depth($b->{s})
             || $b->{score} <=> $a->{score}
             || $a->{s} cmp $b->{s} } @pairs;

my (@accepted, %psrc, %pdst);
for my $p (@pairs) {
    next if covered($p->{s}, \%psrc) || covered($p->{d}, \%pdst);
    next if $psrc{ $p->{s} } || $pdst{ $p->{d} };
    push @accepted, $p;
    $psrc{ $p->{s} } = $pdst{ $p->{d} } = 1;
}

if ($report) {
    printf "=== approximate directory matches (threshold %.2f) ===\n", $parity;
    printf "source root      : '%s'\ndestination root : '%s'\n\n",
           $srcroot, $dstroot;
    unless (@accepted) { print "no pair above threshold.\n"; exit 0 }
    for my $p (@accepted) {
        printf "[%.2f] %s  ->  %s\n", $p->{score}, $p->{d}, $p->{s};
        printf "       %d matched / max(%d,%d)   (min: %.2f)\n",
               $p->{n}, $p->{sp}, $p->{dp}, $p->{smin};
        my %srckey;
        $srckey{ $srcfile{$_}{size} . ':' . $srcfile{$_}{hash} }++
            for grep { index($_, $p->{s} . '/') == 0 } keys %srcfile;
        my (@vote, @stay, @elsewhere);
        for my $r (sort grep { index($_, $p->{d} . '/') == 0 } keys %dstfile) {
            my $k = $dstfile{$r}{size} . ':' . $dstfile{$r}{hash};
            my $n = substr($r, length($p->{d}) + 1);
            if (($srckey{$k} // 0) > 0) { $srckey{$k}--; push @vote, $n }
            elsif (my $sr = $sfk{$k})   { push @elsewhere, [$n, $sr->[0]] }
            else                        { push @stay, $n }
        }
        printf "       + %d files vote: %s%s\n", scalar(@vote),
               join(', ', @vote[0 .. ($#vote > 2 ? 2 : $#vote)]),
               (@vote > 3 ? ", ..." : '') if @vote;
        print  "       ~ $_ : follows the folder, absent from source\n" for @stay;
        printf "       ! %s : follows the folder though it belongs to %s\n",
               $_->[0], $_->[1] for @elsewhere;
        print "\n";
    }
    printf "%d pair(s) accepted out of %d candidate(s) above threshold.\n",
           scalar(@accepted), scalar(@pairs);
    print "No mv emitted: --report-mvdir is a reporting mode.\n";
    exit 0;
}

#--- mv ordering: free targets first, cycles broken with a temporary name ----
my (@plan, @conflict);
{
    my %occ = %dstall;
    delete $occ{ $_->{to} } for grep { 0 } @moves;   # nothing to pre-free
    $moves[$_]{id} = $_ for 0 .. $#moves;
    my %isfrom = map { $_->{from} => $_ } @moves;
    my @pend = @moves;
    my $tmp  = 0;
    while (@pend) {
        my (@next, $progress);
        for my $m (@pend) {
            if (!$occ{ $m->{to} }) {
                push @plan, $m;
                delete $occ{ $m->{from} };
                $occ{ $m->{to} } = 1;
                $progress = 1;
            }
            elsif ($isfrom{ $m->{to} }) { push @next, $m }   # waiting
            else { push @conflict, $m }                      # held by a third party
        }
        @pend = @next;
        next if $progress;
        last unless @pend;
        my $m = shift @pend;                      # cycle: break it with a temp
        my $t = ".mutation_tmp_" . $tmp++;
        push @plan, { from => $m->{from}, to => $t, kind => $m->{kind},
                      tmp => 1, id => $m->{id} };
        delete $occ{ $m->{from} };
        delete $isfrom{ $m->{from} };
        push @pend, { from => $t, to => $m->{to}, kind => $m->{kind},
                      tmp => 1, id => $m->{id} };
        $isfrom{$t} = 1;
        $occ{$t} = 1;
    }
}

#--- moves that actually completed (a step reaches the final target) ---------
my %done;
for my $p (@plan) {
    next unless defined $p->{id};
    $done{ $p->{id} } = 1 if $p->{to} eq $moves[ $p->{id} ]{to};
}
my @real = map { $moves[$_] } grep { $done{$_} } 0 .. $#moves;

# 3) surplus copies: global pass, including under a moved directory
sub finalrel {
    my ($r) = @_;
    for my $m (@real) {
        return $m->{to} if $r eq $m->{from};
        return $m->{to} . substr($r, length $m->{from})
            if index($r, $m->{from} . '/') == 0;
    }
    return $r;
}

my @extra;
for my $k (keys %sfk) {
    next unless @{ $sfk{$k} } == 1;               # source-side uniqueness only
    my $target = $sfk{$k}[0];
    my $cands  = $dfk{$k} or next;
    next unless @$cands > 1;
    my @f = map { [ $_, finalrel($_) ] } sort @$cands;
    my ($keep) = grep { $_->[1] eq $target } @f;
    $keep = $f[0] unless $keep;                   # aucun ne tombe juste : on garde le 1er
    push @extra, map { $_->[0] } grep { $_->[0] ne $keep->[0] } @f;
}

#--- deletion safeguard --------------------------------------------------
my @rm;
if ($remove) {
    my %doomed = map { $_ => 1 } @extra;
    for my $x (@extra) {
        my $e = $dstfile{$x} or next;
        next if $e->{size} < $minsize;
        my $k = $e->{size} . ':' . $e->{hash};
        my @surv = grep { !$doomed{$_} } @{ $dfk{$k} };
        unless (@surv) {                          # must never happen
            warn "REFUSING to delete $x: no copy would survive\n";
            next;
        }
        push @rm, $x;
    }
}

#--- writing the script ------------------------------------------------------
sub q1 { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }
sub parent { my $i = rindex($_[0], '/'); return $i < 0 ? '' : substr($_[0], 0, $i) }

my $fh;
if ($out eq '-') { $fh = \*STDOUT } else { open $fh, '>', $out or die "$out: $!\n" }
binmode $fh, ':raw';

printf $fh "#!/bin/sh\n# generated by mutationstructure.pl\n"
         . "#   source      : %s   (root '%s')\n"
         . "#   destination : %s   (root '%s')\n"
         . "#   filter      : %s   min size : %d\n"
         . "# REVIEW BEFORE RUNNING.\n\nset -e\ncd %s || exit 1\n\n",
    $SRC, $srcroot, $DST, $dstroot,
    (defined $grepstr ? $grepstr : '(none)'), $minsize, q1($dstroot);

my %mk;
for my $m (@plan) {
    my $p = parent($m->{to});
    next if $p eq '' || $mk{$p}++ || $dstall{$p};
    print $fh "mkdir -p ", q1($p), "\n";
}
print $fh "\n" if %mk;

for my $k ('d', 'f') {
    my @s = grep { $_->{kind} eq $k } @plan;
    next unless @s;
    print $fh $k eq 'd' ? "# --- directories ---\n" : "\n# --- files ---\n";
    print $fh "mv -n ", q1($_->{from}), " ", q1($_->{to}), "\n" for @s;
}

if (@rm) {
    print $fh "\n# --- duplicates (", scalar(@rm), ") ---\n";
    print $fh "rm -f ", q1($_), "\n" for sort @rm;
}

my %rd;
$rd{ parent($_->{from}) } = 1 for @plan;
$rd{ parent($_) } = 1 for @rm;
delete $rd{''};
if (%rd) {
    print $fh "\n# --- cleanup (harmlessly fails if not empty) ---\n";
    print $fh "rmdir ", q1($_), " 2>/dev/null || true\n"
        for sort { depth($b) <=> depth($a) || $b cmp $a } keys %rd;
}

if (@conflict) {
    print $fh "\n# --- SKIPPED: target already holds something else ---\n";
    print $fh "# mv ", q1($_->{from}), " ", q1($_->{to}), "\n" for @conflict;
}
close $fh unless $out eq '-';

#--- projected .dts ------------------------------------------------------------
if (defined $newdts) {
    my %map = map { $_->{from} => $_->{to} } @real;   # old rel -> new rel
    my %gone = map { $_ => 1 } @rm;

    my (%leaf, %dirmt, %all);
    for my $e (@$dst) {
        my $r = $e->{rel};
        my $full = $e->{path};
        if (defined $r && length $r) {
            next if $gone{$r};
            my $n = $r;
            for my $from (sort { length($b) <=> length($a) } keys %map) {
                if ($r eq $from) { $n = $map{$from}; last }
                if (index($r, "$from/") == 0) {
                    $n = $map{$from} . substr($r, length $from); last;
                }
            }
            $full = $dstroot eq '' ? $n : "$dstroot/$n";
        }
        if ($e->{type} eq 'd') { $dirmt{$full} = $e->{stamp} }
        else                   { $leaf{$full}  = $e }
        $all{$full} = 1;
    }

    my %orig = map { $_->{path} => 1 } @$dst;     # original roots of the .dts
    my %istop;
    for my $p (keys %orig) {
        my $i = rindex($p, '/');
        $istop{$p} = 1 if $i <= 0 || !$orig{ substr($p, 0, $i) };
    }
    my %kids;                                     # rebuild the tree
    for my $p (keys %all) {
        my $c = $p;
        until ($istop{$c}) {
            my $i = rindex($c, '/');
            last if $i <= 0;
            my $d = substr($c, 0, $i);
            $kids{$d}{ substr($c, $i + 1) } = 1;
            $all{$d} = 1;
            $c = $d;
        }
    }
    my @tops = sort grep { $all{$_} } keys %istop;

    open my $nf, '>', $newdts or die "$newdts: $!\n";
    binmode $nf, ':raw';
    walk($nf, \%leaf, \%dirmt, \%kids, $_) for @tops;
    close $nf;
    warn "$newdts written\n" if $verbose;
}

sub walk {
    my ($nf, $leaf, $dirmt, $kids, $p) = @_;
    if (my $e = $leaf->{$p}) {
        printf $nf "%s %014d %s %s %s %s\n", $e->{type}, $e->{size}, $e->{hash},
               $e->{stamp}, utcof($e->{stamp}), $p;
        return ($e->{type}, pack('H*', $e->{hash}),
                $e->{type} eq 'f' ? $e->{size} : 0);
    }
    my ($pay, $tot) = ('', 0);
    for my $n (sort keys %{ $kids->{$p} || {} }) {
        my ($t, $d, $s) = walk($nf, $leaf, $dirmt, $kids, $p eq '' ? $n : "$p/$n");
        next unless defined $d;
        $pay .= "$t $n\0$d";
        $tot += $s;
    }
    my $d  = sha1('tree ' . length($pay) . "\0" . $pay);
    my $st = $dirmt->{$p} // '0000000000.000000';
    printf $nf "d %014d %s %s %s %s\n", $tot, unpack('H*', $d), $st, utcof($st), $p;
    return ('d', $d, $tot);
}

sub utcof {
    my @t = gmtime(int $_[0]);
    sprintf "%04d%02d%02d-%02d%02d%02d",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];
}

warn sprintf("%d mv (%d dirs, %d files), %d rm, %d conflicts\n",
     scalar(@plan), scalar(grep { $_->{kind} eq 'd' } @plan),
     scalar(grep { $_->{kind} eq 'f' } @plan), scalar(@rm), scalar(@conflict));
