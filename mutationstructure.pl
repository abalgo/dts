#!/usr/bin/perl
# mutationstructure.pl v1.2
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
#   --fuzzy-dirs      act on approximate matches: move the folder, then
#                     relocate the files it carried along but that belong
#                     elsewhere.  Off by default; without it the plan is
#                     exactly what it has always been.
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
my $fuzzy   = 0;
my $VERSION = 'v1.2';

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
           'fuzzy-dirs'         => \$fuzzy,
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

$_->{rel} = rel($_->{path}, $srcroot) for @$src;
$_->{rel} = rel($_->{path}, $dstroot) for @$dst;

# Rebuilt from {rel} and {hash}, both of which the virtual rounds rewrite, so
# this runs once per round rather than once per program.
sub index_side {
    my ($ent, $dh, $fh, $byh, $byk) = @_;
    %$dh = (); %$fh = (); %$byh = (); %$byk = ();
    for my $e (@$ent) {
        my $r = $e->{rel};
        next unless defined $r && length $r;
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

sub index_dst {
    %dstall = ();
    for my $e (@$dst) {
        $dstall{ $e->{rel} } = 1 if defined $e->{rel} && length $e->{rel};
    }
    index_side($dst, \%dstdir, \%dstfile, \%ddh, \%dfk);
}

index_side($src, \%srcdir, \%srcfile, \%sdh, \%sfk);
index_dst();

#--- planning -----------------------------------------------------------
my @moves;                                        # {from, to, kind} of one round
my (%usedsrc, %useddst);                          # consumed subtrees, per round
my %taken;                                        # destination rel already claimed

# 1) directories, shallowest first
sub plan_dirs_exact {
    for my $r (sort { depth($a) <=> depth($b) || $a cmp $b } keys %srcdir) {
        next if covered($r, \%usedsrc);
        my $h = $srcdir{$r}{hash};
        next unless @{ $sdh{$h} } == 1;           # ambiguous on the source side
        my $cands = $ddh{$h} or next;
        if (grep { $_ eq $r } @$cands) {          # already in the right place
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
}

# 2) remaining files
sub plan_files {
    for my $r (sort keys %srcfile) {
        next if covered($r, \%usedsrc);
        my $k = $srcfile{$r}{size} . ':' . $srcfile{$r}{hash};
        next unless @{ $sfk{$k} } == 1;           # source-side uniqueness only
        my $cands = $dfk{$k} or next;
        my @free = grep { !covered($_, \%useddst) } sort @$cands;
        next unless @free;
        my ($keep) = grep { $_ eq $r } @free;     # already in place?
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

my $npairs = 0;                        # candidates above threshold, last call

# Scores every candidate pair against the CURRENT index, so a later round sees
# the post-move state.  Returns the accepted pairs, shallowest first.
sub fuzzy_pairs {
    my $sdesc = descend(\%srcfile);
    my $ddesc = descend(\%dstfile);

    my %cand;                          # "S\0D" -> 1
    for my $k (keys %sfk) {
        my $dr = $dfk{$k} or next;
        next if @{ $sfk{$k} } > 20 || @$dr > 20;  # key too common: skip
        for my $s (@{ $sfk{$k} }) {
            for my $d (@$dr) {
                my ($a, $b) = ($s, $d);
                while (1) {                       # the pair and all its ancestors
                    my $i = rindex($a, '/'); my $j = rindex($b, '/');
                    last if $i <= 0 || $j <= 0;
                    $a = substr($a, 0, $i); $b = substr($b, 0, $j);
                    last if $a eq $b;             # already in the same place
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
        my ($common, $sp, $dp, $sc, $scmin) =
            score_pair($sdesc->{$s}, $ddesc->{$d});
        next unless $sc >= $parity;
        push @pairs, { s => $s, d => $d, n => $common, sp => $sp, dp => $dp,
                       score => $sc, smin => $scmin };
    }
    # shallowest first: a single mv covers more
    @pairs = sort { depth($a->{s}) <=> depth($b->{s})
                 || $b->{score} <=> $a->{score}
                 || $a->{s} cmp $b->{s} } @pairs;
    $npairs = scalar @pairs;

    my (@accepted, %psrc, %pdst);
    for my $p (@pairs) {
        next if covered($p->{s}, \%psrc) || covered($p->{d}, \%pdst);
        next if $psrc{ $p->{s} } || $pdst{ $p->{d} };
        push @accepted, $p;
        $psrc{ $p->{s} } = $pdst{ $p->{d} } = 1;
    }
    return @accepted;
}

#--- virtual application: the planner is re-run against the post-move state ---
# Directory hashes must be recomputed, otherwise round N+1 would match a folder
# on a Merkle hash that the moves of round N already invalidated.
sub rehash_dst {
    my (%leaf, %dir, %kids);
    for my $e (@$dst) {
        my $r = $e->{rel};
        next unless defined $r && length $r;
        if ($e->{type} eq 'd') { $dir{$r} = $e } else { $leaf{$r} = $e }
        my $i = rindex($r, '/');
        $kids{ substr($r, 0, $i) }{ substr($r, $i + 1) } = 1 if $i > 0;
    }
    my (%digest, %size);
    for my $r (sort { depth($b) <=> depth($a) || $b cmp $a } keys %dir) {
        my ($pay, $tot) = ('', 0);
        for my $n (sort keys %{ $kids{$r} || {} }) {   # byte sort, as dtsgen.pl
            my $c = "$r/$n";
            my ($t, $d, $s);
            if (my $l = $leaf{$c}) {
                ($t, $d) = ($l->{type}, pack('H*', $l->{hash}));
                $s = $l->{type} eq 'f' ? $l->{size} : 0;
            }
            else { ($t, $d, $s) = ('d', $digest{$c}, $size{$c} // 0) }
            next unless defined $d;
            $pay .= "$t $n\0$d";
            $tot += $s;
        }
        $digest{$r} = sha1('tree ' . length($pay) . "\0" . $pay);
        $size{$r}   = $tot;
        $dir{$r}{hash} = unpack('H*', $digest{$r});
        $dir{$r}{size} = $tot;
    }
}

sub apply_virtual {
    my ($done) = @_;
    my %map = map { $_->{from} => $_->{to} } @$done;
    return unless %map;
    for my $e (@$dst) {
        my $r = $e->{rel};
        next unless defined $r && length $r;
        for my $from (sort { length($b) <=> length($a) } keys %map) {
            if ($r eq $from) { $e->{rel} = $map{$from}; last }
            if (index($r, "$from/") == 0) {
                $e->{rel} = $map{$from} . substr($r, length $from);
                last;
            }
        }
    }
    rehash_dst();
}

if ($report) {
    plan_dirs_exact();                 # same starting point as the planner
    my @accepted = fuzzy_pairs();
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
           scalar(@accepted), $npairs;
    print "No mv emitted: --report-mvdir is a reporting mode.\n";
    print "Pass --fuzzy-dirs to act on them.\n" unless $fuzzy;
    exit 0;
}

#--- mv ordering: free targets first, cycles broken with a temporary name ----
# Runs once per round: a step of round N+1 starts from a path that only exists
# after round N, so rounds may never be interleaved.
my (@plan, @conflict);
my $tmpseq = 0;                                   # unique across rounds

sub schedule {
    my %occ = %dstall;
    my %isfrom = map { $_->{from} => $_ } @moves;
    my @pend = @moves;
    my @out;
    while (@pend) {
        my (@next, $progress);
        for my $m (@pend) {
            if (!$occ{ $m->{to} }) {
                push @out, $m;
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
        my $t = ".mutation_tmp_" . $tmpseq++;
        push @out, { from => $m->{from}, to => $t, kind => $m->{kind},
                     tmp => 1, orig => $m->{orig}, round => $m->{round} };
        delete $occ{ $m->{from} };
        delete $isfrom{ $m->{from} };
        push @pend, { from => $t, to => $m->{to}, kind => $m->{kind},
                      tmp => 1, orig => $m->{orig}, round => $m->{round},
                      score => $m->{score} };
        $isfrom{$t} = 1;
        $occ{$t} = 1;
    }
    push @plan, @out;
    # a logical move completed when one of its steps reached the final target
    for my $p (@out) {
        my $o = $p->{orig} or next;
        $o->{done} = 1 if $p->{to} eq $o->{to};
    }
}

#--- rounds ------------------------------------------------------------------
# Round 1 is the historical planner.  With --fuzzy-dirs the state is advanced
# virtually and the whole planner re-run, so files that an approximate folder
# carried along surface as ordinary file moves in the next round.
my $MAXROUNDS = 5;
my $round     = 0;
while (1) {
    $round++;
    index_dst() if $round > 1;
    @moves   = ();
    %usedsrc = (); %useddst = (); %taken = ();

    plan_dirs_exact();
    if ($fuzzy) {
        for my $p (fuzzy_pairs()) {
            push @moves, { from => $p->{d}, to => $p->{s}, kind => 'd',
                           score => $p->{score} };
            # consumed for THIS round's file pass only, so the dir move is not
            # duplicated file by file; the next round re-examines the contents
            $usedsrc{ $p->{s} } = 1;
            $useddst{ $p->{d} } = 1;
            $taken{ $p->{s} }   = 1;
        }
    }
    plan_files();

    @moves = grep { $_->{from} ne $_->{to} } @moves;    # net no-ops
    last unless @moves;
    $_->{orig} = $_, $_->{round} = $round for @moves;
    my $before = scalar @plan;
    schedule();
    last if scalar @plan == $before;                    # nothing schedulable
    apply_virtual([ grep { $_->{done} } @moves ]);

    last unless $fuzzy;
    if ($round >= $MAXROUNDS) {
        warn "round cap ($MAXROUNDS) reached: the plan may be incomplete\n";
        last;
    }
}
index_dst();                   # surplus pass works on final, post-move paths

# 3) surplus copies: global pass, on the final layout
my @extra;
for my $k (keys %sfk) {
    next unless @{ $sfk{$k} } == 1;               # source-side uniqueness only
    my $target = $sfk{$k}[0];
    my $cands  = $dfk{$k} or next;
    next unless @$cands > 1;
    my @f = sort @$cands;                         # already the post-move paths
    my ($keep) = grep { $_ eq $target } @f;
    $keep = $f[0] unless defined $keep;           # none lands right: keep the first
    push @extra, grep { $_ ne $keep } @f;
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

# Rounds in order, directories before files inside a round: a step of round N+1
# starts from a path that only exists once round N has run.
for my $rnd (1 .. $round) {
    for my $k ('d', 'f') {
        my @s = grep { ($_->{round} // 1) == $rnd && $_->{kind} eq $k } @plan;
        next unless @s;
        my $what = $k eq 'd' ? 'directories' : 'files';
        print $fh $k eq 'd' && $rnd == 1 ? '' : "\n";
        print $fh "# --- $what", ($rnd > 1 ? " (round $rnd)" : ''), " ---\n";
        for my $m (@s) {
            print $fh "mv -n ", q1($m->{from}), " ", q1($m->{to});
            printf $fh "   # fuzzy %.2f", $m->{score} if defined $m->{score};
            print $fh "\n";
        }
    }
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
    # {rel} already carries the final position: apply_virtual() rewrote it round
    # by round, so no mapping has to be composed here.
    my %gone = map { $_ => 1 } @rm;

    my (%leaf, %dirmt, %all);
    for my $e (@$dst) {
        my $r = $e->{rel};
        my $full = $e->{path};
        if (defined $r && length $r) {
            next if $gone{$r};
            $full = $dstroot eq '' ? $r : "$dstroot/$r";
        }
        if ($e->{type} eq 'd') { $dirmt{$full} = $e->{stamp} }
        else                   { $leaf{$full}  = $e }
        $all{$full} = 1;
    }

    # the script ends with `rmdir` over %rd, deepest first: a directory the plan
    # emptied is gone from the disk, so it must be gone from the projection too.
    # Without this the parent's Merkle payload keeps a phantom empty child.
    my %live;                                     # full path -> surviving children
    for my $p (keys %all) {
        my $i = rindex($p, '/');
        $live{ substr($p, 0, $i) }++ if $i > 0;
    }
    for my $r (sort { depth($b) <=> depth($a) || $b cmp $a } keys %rd) {
        my $full = $dstroot eq '' ? $r : "$dstroot/$r";
        next if !$all{$full} || $leaf{$full};     # absent, or not a directory
        next if $live{$full};                     # not empty: the rmdir fails
        delete $all{$full};
        delete $dirmt{$full};
        my $i = rindex($full, '/');
        $live{ substr($full, 0, $i) }-- if $i > 0;
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
