#!/usr/bin/perl -- # -*-Perl-*-
#------------------------------------------------------------------------------
#--  dts - a .dts database management
#--                                     Written by
#--                                     Arnaud BERTRAND
#--
#--   This code is freely distributable
#--
#--   File name : dts
#--   Title     : database of signed files
#--
#--   Purpose   : - Sort the database (.dts) generated with dtsgen.pl
#--
#--   Format    : col 1 type | 3-16 size | 18-57 sha1 | 59-75 epoch.us
#--               col 77-91 UTC | 93+ path       (key = cols 1-57)
#--
#--   Usage     : dts [-h[elp]] [[-eq | -neq | -gt | -lt] [n]] [-grep expr] filename(s)
#--               dts -update [-ndts <newfile>] [-ddts <deletefile>] filename(s)
#--               -eq   : list files that appear n times in database
#--               -neq  : list files that doesn't appear n times in database
#--               -gt   : list files that appear more than n times in database
#--               -lt   : list files that appear less than n times in database
#--               -grep expr : list group of identic files in which "expr" matches with one of the names
#--               -nogrep expr : idem, at least one name not matching
#--               -only expr : idem but if "expr" matches with all the names
#--               -notonly expr : list group of identic files in which
#--                                   "expr"  matches at least one time but
#--                                   does not match with all the names
#--               -bl          : Insert a blank line before each group
#--               -genrm       : generates the remove file
#--               -keep expr : keep element matching expr if exists
#--               -rmonly expr : generates the remove file but uncomment if expr matches
#--               -keeppriority expr[,expr...] : score 1000, 999, 998 ... (repeatable)
#--               -rmpriority   expr[,expr...] : score -1000, -999, -998 ... (repeatable)
#--                              In each group of duplicates the entry with the
#--                              highest score is kept, the others are removed.
#--                              Rules are tried in order and the first one that
#--                              matches fixes the score.  Default score 0.
#--                              An entry protected by -rmonly is never removed.
#--               -priorityfile F : rules read from a file (default ./dts.priority,
#--                              silently ignored if absent).  Scores go from
#--                              +800 down and -800 up, so the command line
#--                              always outranks the file.
#--               -nopriorityfile : ignore ./dts.priority
#--
#--                              Order in which the rules are tried :
#--                                -keeppriority (1000, 999 ...) then -keep
#--                                [keeppriority] of the file (800, 799 ...)
#--                                -rmpriority (-1000, -999 ...)
#--                                [rmpriority] of the file (-800, -799 ...)
#--               -showprio    : show the computed score.  Inspection only : the
#--                              output is meant to be read, not executed nor fed
#--                              back to dts (it breaks the column format).
#--               -szmin sizemin : do not consider entries smaller than size bytes
#--               -type X      : entry type to process, f(ile) d(ir) l(ink) s(pecial)
#--                              or a(ll).  Default f.   -type d finds duplicate trees.
#--               -h | -help | --help : this text
#--
#--               -update      : check if a file exists anymore
#--                   -ddts    : new dts for deleted file
#--                   -ndts    : new dts file (updated)
#--
#--   Match expressions (-grep, -nogrep, -only, -notonly, -keep, -rmonly,
#--                      -keeppriority, -rmpriority) :
#--
#--               f:/re/flags   regex on the basename
#--               p:/re/flags   regex on the whole path
#--               /re/flags     same as f:/re/flags
#--               operators     !   &&   ||   ( )       flags i m s x
#--               any non alphanumeric char may be used as delimiter, except
#--               ( and ) which group :  p:|/tmp/|   f:#\.jpg$#
#--               paired delimiters {} [] <> nest :  p:{/(a|b)/}
#--
#--               A string that does not start with / ! ( f: or p: is taken
#--               literally as a regex on the basename : "jpg" == "f:/jpg/"
#--
#--               ex : -grep '/\.jpg$/ && f:/^20/ && !p:/mk_/'
#--                    -keeppriority 'p:|/important/|i,f:/^IMG_/' -rmpriority '/^tmp|tmp$/'
#--
#--   Priority file (dts.priority) : one expression per line, most important
#--                      first.  Blank lines and lines starting with # ignored.
#--
#--               [keeppriority]
#--               /expr/ || /expr2/
#--               p:|/expr3/|
#--
#--               [rmpriority]
#--               f:/tmp/
#--               f:/\.bak$/
#--
#------------------------------------------------------------------------------
$DeletedFilename = "TmpDeleted.dts";
$UpdatedFilename = "TmpUpdated.dts";
$szmin = 0;
$Type  = "f";
$PrioFile = "dts.priority";        # lu s'il existe ; -nopriorityfile pour l'ignorer

#--- offsets du format a colonnes fixes ---------------------------------------
$O_TYPE = 0;    $L_TYPE = 1;
$O_SIZE = 2;    $L_SIZE = 14;
$O_KEY  = 0;    $L_KEY  = 57;     # type + taille + sha1
$O_PATH = 92;

#==============================================================================
#  Expressions de correspondance
#
#  matching($fullpath, $expr) -> 1 / 0
#
#  Grammaire :   expr   := and ( '||' and )*
#                and    := not ( '&&' not )*
#                not    := '!' not | '(' expr ')' | terme
#                terme  := [f:|p:] <delim> regex <delim> [imsx]*
#
#  Une chaine qui ne commence pas par / ! ( f: p: est prise telle quelle
#  comme regex sur le basename (compatibilite : -grep jpg).
#==============================================================================

%MXCACHE = ();
@MXT     = ();
$MXP     = 0;
$MXSRC   = '';

sub mx_is_expr {                   # la chaine est-elle une expression ?
  my ($s) = @_;
  return 0 unless defined $s;
  $s =~ s/^\s+//;
  return ($s =~ m{^[/!(]} || $s =~ /^[fp]:/) ? 1 : 0;
}

sub mx_tokenize {                  # chaine -> liste de jetons
  my ($s) = @_;
  my @t;
  my $n = length $s;
  my $i = 0;
  while ($i < $n) {
    my $c = substr($s, $i, 1);
    if ($c =~ /\s/) { $i++; next; }
    my $off = $i;
    if (substr($s, $i, 2) eq '&&') { $i += 2; push @t, {k=>'AND',   off=>$off, end=>$i}; next; }
    if (substr($s, $i, 2) eq '||') { $i += 2; push @t, {k=>'OR',    off=>$off, end=>$i}; next; }
    if ($c eq '!')                 { $i++;    push @t, {k=>'NOT',   off=>$off, end=>$i}; next; }
    if ($c eq '(')                 { $i++;    push @t, {k=>'LP',    off=>$off, end=>$i}; next; }
    if ($c eq ')')                 { $i++;    push @t, {k=>'RP',    off=>$off, end=>$i}; next; }
    if ($c eq ',')                 { $i++;    push @t, {k=>'COMMA', off=>$off, end=>$i}; next; }

    my $scope = 'f';
    if (substr($s, $i, 2) =~ /^([fp]):$/) { $scope = $1; $i += 2; }

    die "dts: delimiteur de regex manquant dans '$s'\n" if $i >= $n;
    my $delim = substr($s, $i, 1);
    die "dts: delimiteur de regex invalide ('$delim') dans '$s'\n"
        if $delim =~ /[\w\s]/ || $delim eq '(' || $delim eq ')';
    #  delimiteurs apparies : { } [ ] < >  (imbrication comptee, comme en Perl)
    my %PAIR  = ('{' => '}', '[' => ']', '<' => '>');
    my $close = $PAIR{$delim};
    my $open  = defined $close ? $delim : '';
    $close = $delim unless defined $close;
    $i++;
    my $pat    = '';
    my $closed = 0;
    my $depth  = 0;
    while ($i < $n) {
      my $ch = substr($s, $i, 1);
      if ($ch eq "\\" && $i + 1 < $n) { $pat .= "\\" . substr($s, $i+1, 1); $i += 2; next; }
      if ($open ne '' && $ch eq $open) { $depth++; }
      elsif ($ch eq $close) {
        if ($depth == 0) { $i++; $closed = 1; last; }
        $depth--;
      }
      $pat .= $ch; $i++;
    }
    die "dts: regex non terminee (delimiteur '$delim') dans '$s'\n" unless $closed;
    my $flags = '';
    while ($i < $n && substr($s, $i, 1) =~ /[imsx]/) { $flags .= substr($s, $i, 1); $i++; }
    push @t, {k=>'RE', scope=>$scope, pat=>$pat, flags=>$flags, off=>$off, end=>$i};
  }
  return @t;
}

sub mx_peek { return $MXP < @MXT ? $MXT[$MXP]{k} : ''; }

sub mx_or {
  my $l = mx_and();
  while (mx_peek() eq 'OR') {
    $MXP++;
    my $r = mx_and();
    my $a = $l;
    $l = sub { ($a->(@_) || $r->(@_)) ? 1 : 0 };
  }
  return $l;
}

sub mx_and {
  my $l = mx_not();
  while (mx_peek() eq 'AND') {
    $MXP++;
    my $r = mx_not();
    my $a = $l;
    $l = sub { ($a->(@_) && $r->(@_)) ? 1 : 0 };
  }
  return $l;
}

sub mx_not {
  if (mx_peek() eq 'NOT') { $MXP++; my $e = mx_not(); return sub { $e->(@_) ? 0 : 1 }; }
  if (mx_peek() eq 'LP') {
    $MXP++;
    my $e = mx_or();
    die "dts: parenthese fermante manquante dans '$MXSRC'\n" unless mx_peek() eq 'RP';
    $MXP++;
    return $e;
  }
  if (mx_peek() eq 'RE') {
    my $t = $MXT[$MXP++];
    my ($pat, $flags) = ($t->{pat}, $t->{flags});
    my $qr = $flags ne '' ? eval { qr/(?$flags:$pat)/ } : eval { qr/$pat/ };
    unless (defined $qr) {
      my $err = $@; $err =~ s/ at .* line \d+\.?\n?$//; chomp $err;
      die "dts: regex invalide /$pat/$flags dans '$MXSRC' : $err\n";
    }
    return $t->{scope} eq 'p' ? sub { $_[1] =~ $qr ? 1 : 0 }
                              : sub { $_[0] =~ $qr ? 1 : 0 };
  }
  die "dts: expression incomplete ou invalide : '$MXSRC'\n";
}

sub mx_build {                     # liste de jetons -> code ref
  my ($tokens, $src) = @_;
  local @MXT   = @$tokens;
  local $MXP   = 0;
  local $MXSRC = $src;
  die "dts: expression vide dans '$src'\n" unless @MXT;
  my $c = mx_or();
  die "dts: texte inattendu apres l'expression dans '$src'\n" if $MXP < @MXT;
  return $c;
}

sub mx_compile {                   # chaine -> code ref
  my ($s) = @_;
  unless (mx_is_expr($s)) {
    my $qr = eval { qr/$s/ };
    unless (defined $qr) {
      my $err = $@; $err =~ s/ at .* line \d+\.?\n?$//; chomp $err;
      die "dts: regex invalide '$s' : $err\n";
    }
    return sub { $_[0] =~ $qr ? 1 : 0 };
  }
  my @t = mx_tokenize($s);
  die "dts: virgule interdite ici : '$s'\n" if grep { $_->{k} eq 'COMMA' } @t;
  return mx_build(\@t, $s);
}

sub mx_rules {                     # chaine -> liste de [libelle, code ref]
  my ($s) = @_;
  die "dts: expression manquante\n" unless defined $s;
  return ([$s, mx_compile($s)]) unless mx_is_expr($s);
  my @t = mx_tokenize($s);
  my @groups;
  my @cur;
  for my $tk (@t) {
    if ($tk->{k} eq 'COMMA') { push @groups, [@cur]; @cur = (); next; }
    push @cur, $tk;
  }
  push @groups, [@cur];
  my @out;
  for my $g (@groups) {
    die "dts: regle vide dans '$s'\n" unless @$g;
    my $lab = substr($s, $g->[0]{off}, $g->[-1]{end} - $g->[0]{off});
    push @out, [$lab, mx_build($g, $lab)];
  }
  return @out;
}

sub matching {                     # 1 si $expr correspond a $fullpath
  my ($fullpath, $expr) = @_;
  return 1 unless defined $expr && length $expr;
  my $c = $MXCACHE{$expr};
  $c = $MXCACHE{$expr} = mx_compile($expr) unless $c;
  my $base = $fullpath;
  $base =~ s{^.*/}{}s;
  return $c->($base, $fullpath);
}

sub priority {                     # score de $fullpath : 1000..  0  ..-1000
  my ($fullpath) = @_;                 # positionne aussi $PrioLabel
  my $base = $fullpath;
  $base =~ s{^.*/}{}s;
  for my $r (@Rules) {
    if ($r->[2]->($base, $fullpath)) { $PrioLabel = $r->[1]; return $r->[0]; }
  }
  $PrioLabel = '';
  return 0;
}

#--- fichier de priorites -----------------------------------------------------
#  [keeppriority]        une expression par ligne, dans l'ordre decroissant
#  expr                  # lignes vides et lignes commencant par # ignorees
#  [rmpriority]
#  expr
#------------------------------------------------------------------------------
sub load_priority_file {
  my ($file, $explicit) = @_;
  unless (open(PF, "< $file")) {
    die "dts: -priorityfile $file : $!\n" if $explicit;
    return 0;                        # fichier par defaut absent : silence
  }
  my $sec = '';
  my $n   = 0;
  while (<PF>) {
    s/\r?\n$//;
    next if /^\s*$/ || /^\s*#/;
    if (/^\s*\[\s*([A-Za-z]+)\s*\]\s*$/) {
      my $s = lc $1;
      $s =~ s/priority$//;
      die "dts: $file ligne $.: section inconnue [$1]\n" unless $s eq 'keep' || $s eq 'rm';
      $sec = $s;
      next;
    }
    s/^\s+//; s/\s+$//;
    die "dts: $file ligne $.: regle en dehors de toute section\n" unless $sec;
    my @r = eval { mx_rules($_) };
    if ($@) { my $e = $@; $e =~ s/^dts: //; die "dts: $file ligne $.: $e"; }
    if ($sec eq 'keep') { push @KeepFile, @r; } else { push @RmFile, @r; }
    $n += scalar @r;
  }
  close(PF);
  return $n;
}

#==============================================================================
#  Analyse des options
#==============================================================================
$nblev = 1;
while (defined($_ = $ARGV[0]) && /^-|^\d+$/) {
  shift;
  last if /^--$/;

  # options a nom long : testees en premier, avec next, pour ne pas etre
  # capturees par les prefixes plus courts (-keep, -rmonly...)
  if (/^-keeppri/)        { push @KeepPrio, mx_rules(shift @ARGV); next; }
  if (/^-rmpri/)          { push @RmPrio,   mx_rules(shift @ARGV); next; }
  if (/^-showprio/)       { $IndShowPrio = 1; next; }
  if (/^-nopriorityfile/) { $PrioFile = ''; $PrioFileGiven = 0; next; }
  if (/^-priorityfile/)   { $PrioFile = shift @ARGV; $PrioFileGiven = 1;
                            die "dts: -priorityfile : nom de fichier manquant\n"
                                unless defined $PrioFile && length $PrioFile;
                            next; }

  /^\d+$/ && do { $nblev = int $_; next; };
  /^-gt/       && do { $IndGreater = 1; };
  /^-lt/       && do { $IndLess    = 1; };
  /^-neq/      && do { $IndNeq     = 1; };
  /^-eq/       && do { $IndEq      = 1; };
  /^-grep/     && do { $IndGrep      = 1; $GrepString = $ARGV[0]; shift; };
  /^-nogrep/   && do { $IndNoGrep    = 1; $GrepString = $ARGV[0]; shift; };
  /^-only/     && do { $IndAllGrep   = 1; $GrepString = $ARGV[0]; shift; };
  /^-notonly/  && do { $IndNoAllGrep = 1; $GrepString = $ARGV[0]; shift; };
  /^-bl/       && do { $IndBlankLine = 1; };
  /^-genrm/    && do { $IndBlankLine = 1; $IndGenRm = 1; };
  /^-keep/     && do { $IndKeep = 1; $GrepString = shift; };
  /^-rmonly/   && do { $IndBlankLine = 1; $IndGenRm = 1; $IndGenRmOnly = 1;
                       $IndNoAllGrep = 1; $GrepString = $ARGV[0]; shift; };
  /^-szmin/    && do { $szmin = shift; };
  /^-type/     && do { $Type  = shift; };
  /^-update/   && do { $IndUpdate = 1; };
  /^-ddts/     && do { $DeletedFilename = $ARGV[0]; shift; };
  /^-ndts/     && do { $UpdatedFilename = $ARGV[0]; shift; };

  # print out header for help
  /^--?h/ && do {
      $MyName = $0;
      open MyName;
      while (<MyName>) {
          print if s/^#-- ?//;
      };
      exit;
  };
};

# -keep combine aux priorites devient la derniere regle "keep" de la ligne de commande
if ((@KeepPrio || @RmPrio) && $IndKeep) {
  push @KeepPrio, [$GrepString, mx_compile($GrepString)];
}

if (length($PrioFile) && !$IndUpdate) {
  $nprio = load_priority_file($PrioFile, $PrioFileGiven);
  print STDERR "dts: $PrioFile : $nprio regle(s) de priorite\n" if $nprio;
}

die "dts: trop de regles de priorite en ligne de commande (max 200 par sens)\n"
    if @KeepPrio > 200 || @RmPrio > 200;
die "dts: trop de regles de priorite dans $PrioFile (max 800 par section)\n"
    if @KeepFile > 800 || @RmFile > 800;

#  Table unique, dans l'ordre de parcours : la premiere regle qui correspond
#  fixe le score.  Ligne de commande avant fichier, "keep" avant "rm".
sub add_rules {
  my ($list, $base, $step) = @_;
  for (my $i = 0; $i <= $#$list; $i++) {
    push @Rules, [$base + $step * $i, $list->[$i][0], $list->[$i][1]];
  }
}
add_rules(\@KeepPrio,  1000, -1);
add_rules(\@KeepFile,   800, -1);
add_rules(\@RmPrio,   -1000,  1);
add_rules(\@RmFile,    -800,  1);
$IndPrio = @Rules ? 1 : 0;

$TypeRe = ($Type eq "a") ? qr/./ : qr/[\Q$Type\E]/;

sub wanted {                       # ligne retenue ?
  my ($l) = @_;
  return 0 unless length($l) > $O_PATH;
  return 0 unless substr($l, $O_TYPE, $L_TYPE) =~ /^$TypeRe$/;
  return 0 if substr($l, $O_SIZE, $L_SIZE) + 0 < $szmin;
  return 1;
}

if ($IndUpdate == 1) {
  open(FU, "> $UpdatedFilename") || die("can not open $UpdatedFilename for writing\n");
  open(FD, "> $DeletedFilename") || die("can not open $DeletedFilename for writing\n");
  while (<>) {
    s/\r?\n$//;
    $FPath = substr($_, $O_PATH);
    $FPath =~ s/["\n\r]//g;
    $FPath =~ s/(.):/\/$1/;
    if (-e $FPath) {
      print FU "$_\n";
    }
    else {
      print FD "$_\n";
      print STDERR "--- removed --- + $FPath +\n";
    }
  }
  die("end of update ... results in file $UpdatedFilename and $DeletedFilename\n");
}

$Tmp = "tmpuniq.$$";
open(FILE, "| LC_ALL=C sort -r > $Tmp") || die "Can't open sort pipe\n";
select(STDOUT); $| = 1;     # make unbuffered
select(FILE);   $| = 1;     # make unbuffered

while (<>) {
      s/\r?\n$//;
      next unless wanted($_);
      print FILE $_ . "\n";
      $clef = substr($_, $O_KEY, $L_KEY);
      $path = substr($_, $O_PATH);
      $keycounter{$clef}++;
      if ($IndPrio) {
        $p = priority($path);
        $bestprio{$clef} = $p if !exists $bestprio{$clef} || $p > $bestprio{$clef};
      }
      if (defined $GrepString) {
        if (matching($path, $GrepString)) { $grepflag{$clef}   = 1; }
        else                              { $nogrepflag{$clef} = 1; }
      }
    };

close(FILE);
select(STDOUT);
if (($IndNeq != 1) && ($IndLess != 1) && ($IndGreater != 1)) { $IndEq = 1 };
open(FILE, "< $Tmp") || die "Can't reopen $Tmp\n";
while (<FILE>) {
      s/\r?\n$//;
      $clef    = substr($_, $O_KEY, $L_KEY);
      $allrest = substr($_, $O_PATH);
      $condok  = 0;
      $val     = $keycounter{$clef};
      $gflag   = $grepflag{$clef};
      $ngflag  = $nogrepflag{$clef};
      if (   (($IndEq      == 1) && ($val == $nblev))
          || (($IndNeq     == 1) && ($val != $nblev))
          || (($IndLess    == 1) && ($val <  $nblev))
          || (($IndGreater == 1) && ($val >  $nblev))) { $condok = 1; };
      if ( ($IndGrep      == 1) && ($gflag != 1) ) { $condok = 0; };
      if ( ($IndNoGrep    == 1) && ($ngflag != 1) ) { $condok = 0; };
      if ( ($IndAllGrep   == 1) && (($gflag != 1) || ($ngflag == 1)) ) { $condok = 0; };
      if ( ($IndNoAllGrep == 1) && (($gflag != 1) || ($ngflag != 1)) ) { $condok = 0; };
      if ($condok == 1) {
        $prio   = $IndPrio ? priority($allrest) : 0;
        $prinfo = "p=$prio" . ($PrioLabel ne '' ? " $PrioLabel" : "");
        $suffix = $IndShowPrio ? "\t# $prinfo" : "";
        if (($IndBlankLine == 1) && ($oldclef ne $clef)) { print STDOUT "\n"; }
        if ($IndGenRm == 1) {
          next unless $allrest;
          $nbk = 1 if ($oldclef ne $clef);
          if ($IndPrio == 1) {
            $keepit = 0;
            if ($nbk && $prio == $bestprio{$clef}) { $keepit = 1; $nbk = 0; }
            # une entree protegee par -rmonly n'est jamais effacee
            $keepit = 1 if !$keepit && $IndGenRmOnly == 1
                           && !matching($allrest, $GrepString);
            print STDOUT ($keepit ? "#rm " : "rm ") . $allrest . $suffix . "\n";
          }
          elsif ($IndGenRmOnly == 1) {
            if (matching($allrest, $GrepString)) {
              print STDOUT "rm $allrest$suffix\n"; }
            else {
              print STDOUT "#rm $allrest$suffix\n"; }
          }
          elsif ($IndKeep == 1) {
            if (matching($allrest, $GrepString) && $nbk) {
              print STDOUT "#rm $allrest$suffix\n";
              $nbk = 0; }
            else {
              print STDOUT "rm $allrest$suffix\n"; }
          }
          else {
            if ($nbk) { print STDOUT "#rm $allrest$suffix\n"; $nbk = 0; }
            else      { print STDOUT "rm $allrest$suffix\n"; }
          }
        }
        else {
          print STDOUT ($IndShowPrio ? "$prinfo\t" : "") . $_ . "\n"; }
        $oldclef = $clef;
      };
    };
close(FILE);
unlink $Tmp;
# -----------------------------------------------------------------------------
