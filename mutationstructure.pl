#!/usr/bin/perl
# mutationstructure.pl v1.1
# Rejoue sur une arborescence DESTINATION la structure d'une arborescence SOURCE,
# à partir de deux fichiers .dts produits par dtsgen.pl.
# Ne copie rien, n'efface que des doublons : produit un script shell à relire.
#
# Usage : mutationstructure.pl [options] SOURCE.dts DESTINATION.dts
#   --grep REGEX      ne considérer que les chemins correspondants
#   --src-root PATH   racine à retirer des chemins source      (sinon déduite)
#   --dst-root PATH   racine à retirer des chemins destination (sinon déduite)
#   --remove          effacer les doublons destination devenus inutiles
#   --minsize N       taille plancher, défaut 100 octets
#   --out FILE        script shell (défaut : stdout)
#   --new-dts FILE    .dts projeté de la destination après exécution
#   --verbose         détail sur stderr
#   --parity-threshold F  score minimal d'appariement approximatif (défaut 0.80)
#   --report-mvdir    rapport des appariements de répertoires, sans rien émettre
#   --help  --version
#
# Appariement des répertoires, en deux étages :
#   1. hash de Merkle identique  -> certain (contenus ET noms), sous-arbre consommé
#   2. vote                      -> score = communs / max(|S'|,|D'|)
#      où S' et D' ne comptent que les fichiers ayant un correspondant
#      quelque part dans l'autre arbre (les fichiers propres à un côté,
#      grosse vidéo effacée du téléphone par exemple, ne pénalisent rien).
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
           'new-dts=s'  => \$newdts,  'verbose'    => \$verbose,
           'parity-threshold=f' => \$parity,
           'report-mvdir'       => \$report,
           'help'       => sub { usage() },
           'version'    => sub { print "mutationstructure.pl $VERSION\n"; exit 0 })
    or die "options invalides (--help)\n";
my ($SRC, $DST) = @ARGV;
die "usage: $0 [options] SOURCE.dts DESTINATION.dts\n" unless defined $DST;
my $RE = defined $grepstr ? qr/$grepstr/ : undef;

my $EMPTYTREE = sha1("tree 0\0");                 # tous les répertoires vides

#--- lecture -----------------------------------------------------------------
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
    die "$f: aucune ligne exploitable\n" unless @e;
    return \@e;
}

#--- détection de racine : explicite > ancre du --grep > préfixe commun -------
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
    if ($RE) {                                    # plus haut segment qui matche
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
            warn "racine $label déduite du --grep : '$r'\n" if $verbose;
            return $r;
        }
    }
    my $r = common_prefix(map { $_->{path} } @$ent);
    warn "racine $label déduite du préfixe commun : '$r'\n" if $verbose;
    return $r;
}

sub rel {
    my ($p, $r) = @_;
    return $p if $r eq '';
    return ''  if $p eq $r;
    return index($p, "$r/") == 0 ? substr($p, length($r) + 1) : undef;
}

sub depth { my $n = ($_[0] =~ tr{/}{}); return $_[0] eq '' ? -1 : $n }

sub covered {                                     # rel sous un sous-arbre traité
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

#--- indexation --------------------------------------------------------------
my $src = read_dts($SRC);
my $dst = read_dts($DST);
$srcroot = detect_root($src, $srcroot, 'source');
$dstroot = detect_root($dst, $dstroot, 'destination');

my (%srcdir, %dstdir, %srcfile, %dstfile);        # rel -> entrée
my (%sdh, %ddh, %sfk, %dfk);                      # hash/clé -> [rel...]
my %dstall;                                       # rel -> 1, occupation réelle

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

#--- planification -----------------------------------------------------------
my @moves;                                        # {from, to, kind}
my (%usedsrc, %useddst);                          # sous-arbres consommés
my %taken;                                        # rel destination déjà promise

# 1) répertoires, du moins profond au plus profond
for my $r (sort { depth($a) <=> depth($b) || $a cmp $b } keys %srcdir) {
    next if covered($r, \%usedsrc);
    my $h = $srcdir{$r}{hash};
    next unless @{ $sdh{$h} } == 1;               # ambigu côté source : on passe
    my $cands = $ddh{$h} or next;
    if (grep { $_ eq $r } @$cands) {              # déjà au bon endroit
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

# 2) fichiers restants
for my $r (sort keys %srcfile) {
    next if covered($r, \%usedsrc);
    my $k = $srcfile{$r}{size} . ':' . $srcfile{$r}{hash};
    next unless @{ $sfk{$k} } == 1;               # unique côté source seulement
    my $cands = $dfk{$k} or next;
    my @free = grep { !covered($_, \%useddst) } sort @$cands;
    next unless @free;
    my ($keep) = grep { $_ eq $r } @free;         # déjà en place ?
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

#--- appariement approximatif de répertoires (vote) --------------------------
# construit la liste des fichiers descendants de chaque répertoire
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
    my ($sk, $dk) = @_;                # deux listes de clés
    my (%cnt, $common);
    $cnt{$_}++ for @$sk;
    for my $k (@$dk) { if (($cnt{$k} // 0) > 0) { $cnt{$k}--; $common++ } }
    my $sp = grep { $dfk{$_} } @$sk;   # présents quelque part en destination
    my $dp = grep { $sfk{$_} } @$dk;   # présents quelque part en source
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
    next if @{ $sfk{$k} } > 20 || @$dr > 20;      # clé trop répandue : on passe
    for my $s (@{ $sfk{$k} }) {
        for my $d (@$dr) {
            my ($a, $b) = ($s, $d);
            while (1) {                           # le couple et tous ses ancêtres
                my $i = rindex($a, '/'); my $j = rindex($b, '/');
                last if $i <= 0 || $j <= 0;
                $a = substr($a, 0, $i); $b = substr($b, 0, $j);
                last if $a eq $b;                 # déjà au même endroit
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
# le plus haut d'abord : un seul mv couvre davantage
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
    printf "=== appariements approximatifs (seuil %.2f) ===\n", $parity;
    printf "racine source      : '%s'\nracine destination : '%s'\n\n",
           $srcroot, $dstroot;
    unless (@accepted) { print "aucun couple au-dessus du seuil.\n"; exit 0 }
    for my $p (@accepted) {
        printf "[%.2f] %s  ->  %s\n", $p->{score}, $p->{d}, $p->{s};
        printf "       %d communs / max(%d,%d)   (min : %.2f)\n",
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
        printf "       + %d fichiers votent : %s%s\n", scalar(@vote),
               join(', ', @vote[0 .. ($#vote > 2 ? 2 : $#vote)]),
               (@vote > 3 ? ", ..." : '') if @vote;
        print  "       ~ $_ : suit le dossier, absent de la source\n" for @stay;
        printf "       ! %s : suit le dossier alors qu'il releve de %s\n",
               $_->[0], $_->[1] for @elsewhere;
        print "\n";
    }
    printf "%d couple(s) retenu(s) sur %d candidat(s) au-dessus du seuil.\n",
           scalar(@accepted), scalar(@pairs);
    print "Aucun mv emis : --report-mvdir est un mode rapport.\n";
    exit 0;
}

#--- ordonnancement des mv : cibles libres d'abord, cycles par nom temporaire --
my (@plan, @conflict);
{
    my %occ = %dstall;
    delete $occ{ $_->{to} } for grep { 0 } @moves;   # rien à pré-libérer
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
            elsif ($isfrom{ $m->{to} }) { push @next, $m }   # en attente
            else { push @conflict, $m }                      # occupé par un tiers
        }
        @pend = @next;
        next if $progress;
        last unless @pend;
        my $m = shift @pend;                      # cycle : on casse par un temp
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

#--- mv effectivement aboutis (une etape atteint la cible finale) ------------
my %done;
for my $p (@plan) {
    next unless defined $p->{id};
    $done{ $p->{id} } = 1 if $p->{to} eq $moves[ $p->{id} ]{to};
}
my @real = map { $moves[$_] } grep { $done{$_} } 0 .. $#moves;

# 3) exemplaires surnuméraires : passe globale, y compris sous un répertoire déplacé
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
    next unless @{ $sfk{$k} } == 1;               # unique côté source seulement
    my $target = $sfk{$k}[0];
    my $cands  = $dfk{$k} or next;
    next unless @$cands > 1;
    my @f = map { [ $_, finalrel($_) ] } sort @$cands;
    my ($keep) = grep { $_->[1] eq $target } @f;
    $keep = $f[0] unless $keep;                   # aucun ne tombe juste : on garde le 1er
    push @extra, map { $_->[0] } grep { $_->[0] ne $keep->[0] } @f;
}

#--- garde-fou d'effacement --------------------------------------------------
my @rm;
if ($remove) {
    my %doomed = map { $_ => 1 } @extra;
    for my $x (@extra) {
        my $e = $dstfile{$x} or next;
        next if $e->{size} < $minsize;
        my $k = $e->{size} . ':' . $e->{hash};
        my @surv = grep { !$doomed{$_} } @{ $dfk{$k} };
        unless (@surv) {                          # ne doit jamais arriver
            warn "REFUS d'effacer $x : aucun exemplaire ne survivrait\n";
            next;
        }
        push @rm, $x;
    }
}

#--- écriture du script ------------------------------------------------------
sub q1 { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }
sub parent { my $i = rindex($_[0], '/'); return $i < 0 ? '' : substr($_[0], 0, $i) }

my $fh;
if ($out eq '-') { $fh = \*STDOUT } else { open $fh, '>', $out or die "$out: $!\n" }
binmode $fh, ':raw';

printf $fh "#!/bin/sh\n# genere par mutationstructure.pl\n"
         . "#   source      : %s   (racine '%s')\n"
         . "#   destination : %s   (racine '%s')\n"
         . "#   filtre      : %s   taille mini : %d\n"
         . "# A RELIRE AVANT EXECUTION.\n\nset -e\ncd %s || exit 1\n\n",
    $SRC, $srcroot, $DST, $dstroot,
    (defined $grepstr ? $grepstr : '(aucun)'), $minsize, q1($dstroot);

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
    print $fh $k eq 'd' ? "# --- repertoires ---\n" : "\n# --- fichiers ---\n";
    print $fh "mv -n ", q1($_->{from}), " ", q1($_->{to}), "\n" for @s;
}

if (@rm) {
    print $fh "\n# --- doublons (", scalar(@rm), ") ---\n";
    print $fh "rm -f ", q1($_), "\n" for sort @rm;
}

my %rd;
$rd{ parent($_->{from}) } = 1 for @plan;
$rd{ parent($_) } = 1 for @rm;
delete $rd{''};
if (%rd) {
    print $fh "\n# --- menage (echoue sans dommage si non vide) ---\n";
    print $fh "rmdir ", q1($_), " 2>/dev/null || true\n"
        for sort { depth($b) <=> depth($a) || $b cmp $a } keys %rd;
}

if (@conflict) {
    print $fh "\n# --- NON TRAITES : cible deja occupee par autre chose ---\n";
    print $fh "# mv ", q1($_->{from}), " ", q1($_->{to}), "\n" for @conflict;
}
close $fh unless $out eq '-';

#--- .dts projeté ------------------------------------------------------------
if (defined $newdts) {
    my %map = map { $_->{from} => $_->{to} } @real;   # ancien rel -> nouveau rel
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

    my %orig = map { $_->{path} => 1 } @$dst;     # racines d'origine du .dts
    my %istop;
    for my $p (keys %orig) {
        my $i = rindex($p, '/');
        $istop{$p} = 1 if $i <= 0 || !$orig{ substr($p, 0, $i) };
    }
    my %kids;                                     # reconstruction de l'arbre
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
    warn "$newdts écrit\n" if $verbose;
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

warn sprintf("%d mv (%d rep., %d fic.), %d rm, %d conflits\n",
     scalar(@plan), scalar(grep { $_->{kind} eq 'd' } @plan),
     scalar(grep { $_->{kind} eq 'f' } @plan), scalar(@rm), scalar(@conflict));
