#!/usr/bin/perl
# dtsgen.pl v1 — inventaire signé + hash de Merkle, colonnes fixes
# Colonnes (1-based) : 1 type | 3-16 taille | 18-57 sha1 | 59-75 epoch.us
#                      77-91 UTC | 93+ chemin        (clé de doublon = 1-57)
# Types : f fichier | d répertoire | l lien | s spécial
# Usage : dtsgen.pl [--xdev] [--exclude REGEX]... [--max-size Mo]
#                   [--extern] [--batch N] [--verbose] RACINE...
#         dtsgen.pl --check FICHIER.dts     (présence + taille, sans hachage)
#   --xdev            ne pas franchir les points de montage
#   --exclude REGEX   écarter les chemins correspondants (répétable)
#   --max-size Mo     ignorer les fichiers plus gros
#   --extern          déléguer le hachage à sha1sum, par lots
#   --batch N         taille des lots et pas de progression (défaut 1000)
#   --verbose         pré-passe, progression, débit et temps restant
#   --check F.dts     vérifier présence/type/taille, sans hacher ; sortie 1 si écart
#   --help  --version
use strict;
use warnings;
no warnings 'recursion';
use Digest::SHA qw(sha1);
use Time::HiRes qw(stat lstat time);

my $VERSION = 'v1';
use Getopt::Long;

my @excl;
my $xdev    = 0;
my $maxmb   = 0;
my $extern  = 0;
my $batchsz = 1000;
my $verbose = 0;
my $check;

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
           'help'      => sub { usage() },
           'version'   => sub { print "dtsgen.pl $VERSION\n"; exit 0 })
    or die "options invalides (--help)\n";
my $skip = @excl ? do { my $r = join '|', @excl; qr/$r/ } : undef;
my $maxb = $maxmb * 1048576;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';
$| = 1;                     # sortie non tamponnée : une interruption ne perd rien

my $ZERO = pack('H*', '0' x 40);
my ($nfile, $ndir, $nskip, $nerr, $next, $nbatch) = (0, 0, 0, 0, 0, 0);
my $vol = 0;

my (@files, %pos, %ext);    # pré-passe : ordre des fichiers ; hashs externes
my $flushed  = 0;           # index du premier fichier non encore haché
my $totfile  = 0;           # nb total de fichiers (vides compris)
my $totbytes = 0;           # volume total à lire
my $t0;                     # début de la phase 2

sub hms {
    my $s = int($_[0] + 0.5);
    return sprintf "%d:%02d:%02d", int($s/3600), int($s/60)%60, $s%60 if $s >= 3600;
    return sprintf "%d:%02d", int($s/60), $s%60;
}

sub go {                    # octets -> Go ou Mo
    my $b = $_[0];
    return sprintf "%.1f Go", $b/1073741824 if $b >= 1073741824;
    return sprintf "%.1f Mo", $b/1048576;
}

sub utc {
    my @t = gmtime($_[0] || 0);
    sprintf "%04d%02d%02d-%02d%02d%02d",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];
}

sub emit {
    my ($type, $raw, $size, $mtime, $path) = @_;
    $size  //= 0;
    $mtime //= 0;
    my $sec = int $mtime;
    my $us  = int(($mtime - $sec) * 1e6 + 0.5);
    if ($us > 999999) { $sec++; $us = 0 }
    printf "%s %014d %s %010d.%06d %s %s\n",
           $type, $size, unpack('H*', $raw), $sec, $us, utc($sec), $path;
}

# liste triée d'un répertoire : [nom, chemin, type, \@stat]
# utilisée par la pré-passe ET par l'émission -> ordre identique garanti
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
        my @s = lstat $p;
        unless (@s) { warn "lstat: $p: $!\n"; $nerr++ if $count; next }
        my $t = -l _ ? 'l' : -d _ ? 'd' : -f _ ? 'f' : 's';
        if ($t eq 'f' && $maxb && $s[7] > $maxb) { $nskip++ if $count; next }
        push @ent, [$n, $p, $t, \@s];
    }
    return @ent;
}

# pré-passe : parcours sans lecture de contenu, dans l'ordre exact de l'émission
sub prescan {
    my ($path, $type, $st, $dev) = @_;
    if ($type eq 'f') {
        $totfile++;
        $totbytes += $st->[7];
        push @files, $path if $st->[7] > 0;
        if ($verbose && $totfile % 10000 == 0) {
            printf STDERR "  scan... %d fichiers, %s | %s\n", $totfile, go($totbytes), $path;
        }
        return;
    }
    return unless $type eq 'd';
    return if $xdev && defined $dev && $st->[0] != $dev;
    for my $e (entries($path, 0)) {
        prescan($e->[1], $e->[2], $e->[3], $st->[0]);
    }
}

# un exec sha1sum pour le prochain paquet de la liste
sub flush_batch {
    my $end = $flushed + $batchsz;
    $end = @files if $end > @files;
    my @p = @files[$flushed .. $end - 1];
    $flushed = $end;
    return unless @p;
    my $pid = open(my $fh, '-|');
    unless (defined $pid) { warn "fork: $!\n"; return }
    unless ($pid) {                                   # enfant
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

# retourne (type, digest brut, taille cumulée) ; liste vide si ignoré/erreur
sub visit {
    my ($path, $type, $st, $dev) = @_;
    my ($sdev, $size, $mtime) = @$st[0, 7, 9];

    if ($type eq 'l') {
        my $t = readlink $path;
        unless (defined $t && length $t) { warn "readlink: $path: $!\n"; $nerr++; return }
        my $raw = sha1('link ' . length($t) . "\0" . $t);
        emit('l', $raw, length($t), $mtime, $path);
        return ('l', $raw, 0);                        # un lien n'occupe rien
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
        my $raw = hash_file($path);
        unless (defined $raw) { warn "lecture: $path: $@"; $nerr++; return }
        emit('f', $raw, $size, $mtime, $path);
        $nfile++;
        $vol += $size;
        if ($verbose && $nfile % $batchsz == 0) {
            my $el  = time() - $t0;
            my $eta = '';
            if ($el > 1 && $vol > 0 && $totbytes > $vol) {
                my $rate = $vol / $el;
                $eta = sprintf ", %.0f Mo/s, reste ~%s",
                       $rate / 1048576, hms(($totbytes - $vol) / $rate);
            }
            printf STDERR "  ... %d/%d fichiers, %s/%s%s\n",
                   $nfile, $totfile, go($vol), go($totbytes), $eta;
        }
        return ('f', $raw, $size);
    }
    emit('s', $ZERO, 0, $mtime, $path);
    return ('s', $ZERO, 0);
}

#--- --check : le .dts decrit-il encore le disque ? (taille seulement) --------
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
        unless (@s) { print "MANQUANT  $p\n"; $miss++; next }
        my $r = -l _ ? 'l' : -d _ ? 'd' : -f _ ? 'f' : 's';
        if ($r ne $t) { print "TYPE $t->$r  $p\n"; $typ++; next }
        next unless $t eq 'f';
        if ($s[7] != $sz) { printf "TAILLE %d->%d  %s\n", $sz, $s[7], $p; $bad++ }
    }
    close $cf;
    warn "$n entrées : $miss manquantes, $typ de type changé, $bad de taille changée\n";
    exit($miss || $bad || $typ ? 1 : 0);
}

my @roots = @ARGV ? @ARGV : ('.');
my @start;
for my $r (@roots) {
    $r =~ s{/+$}{} unless $r eq '/';
    my @s = stat $r;                    # une racine nommée est suivie
    unless (@s) { warn "stat: $r: $!\n"; $nerr++; next }
    push @start, [$r, (-d _ ? 'd' : -f _ ? 'f' : 's'), \@s];
}

if ($extern || $verbose) {
    warn "dtsgen $VERSION — phase 1 : inventaire des fichiers...\n" if $verbose;
    my $ts = time();
    prescan(@$_[0, 1, 2], $_->[2][0]) for @start;
    $pos{ $files[$_] } = $_ for 0 .. $#files;
    warn sprintf("phase 1 terminée en %s : %d fichiers, %s à lire\n",
                 hms(time() - $ts), $totfile, go($totbytes)) if $verbose;
    ($nskip, $nerr) = (0, 0);           # comptés pour de bon à l'émission
}

warn "phase 2 : hachage...\n" if $verbose;
$t0 = time();
visit(@$_[0, 1, 2], $_->[2][0]) for @start;

warn sprintf("terminé en %s, %s\n", hms(time() - $t0), go($vol)) if $verbose;
warn "$nfile fichiers", ($extern ? " ($next via sha1sum, $nbatch lots)" : ""),
     ", $ndir répertoires, $nskip ignorés, $nerr erreurs\n";
