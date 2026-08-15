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
#--   Usage     : dts [-h[elp]] [[-eq | -neq | -gt | -lt] [n]] [-grep string] filename(s)
#--               dts -update [-ndts <newfile>] [-ddts <deletefile>] filename(s)
#--               -eq   : list files that appear n times in database
#--               -neq  : list files that doesn't appear n times in database
#--               -gt   : list files that appear more than n times in database
#--               -lt   : list files that appear less than n times in database
#--               -grep string : list group of identic files in which "string" matches with one of the names
#--               -nogrep string : idem, at least one name not matching
#--               -only string : idem but if "string" matches with all the names
#--               -notonly string : list group of identic files in which
#--                                   "string"  matches at least one time but
#--                                   does not match with all the names
#--               -bl          : Insert a blank line before each group
#--               -genrm       : generates the remove file
#--               -keep string : keep element matching string if exists
#--               -rmonly string : generates the remove file but uncomment if string matches
#--               -szmin sizemin : do not consider entries smaller than size bytes
#--               -type X      : entry type to process, f(ile) d(ir) l(ink) s(pecial)
#--                              or a(ll).  Default f.   -type d finds duplicate trees.
#--               -h | -help | --help : this text
#--
#--               -update      : check if a file exists anymore
#--                   -ddts    : new dts for deleted file
#--                   -ndts    : new dts file (updated)
#--
#------------------------------------------------------------------------------
$DeletedFilename = "TmpDeleted.dts";
$UpdatedFilename = "TmpUpdated.dts";
$szmin = 0;
$Type  = "f";

#--- offsets du format a colonnes fixes ---------------------------------------
$O_TYPE = 0;    $L_TYPE = 1;
$O_SIZE = 2;    $L_SIZE = 14;
$O_KEY  = 0;    $L_KEY  = 57;     # type + taille + sha1
$O_PATH = 92;

$nblev = 1;
while (defined($_ = $ARGV[0]) && /^-|^\d+$/) {
  shift;
  last if /^--$/;
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
          print if s/^#-- //;
      };
      exit;
  };
};

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
      $keycounter{$clef}++;
      $grepflag{$clef}   = 1 if  /$GrepString/o;
      $nogrepflag{$clef} = 1 if !/$GrepString/o;
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
        if (($IndBlankLine == 1) && ($oldclef ne $clef)) { print STDOUT "\n"; }
        if ($IndGenRm == 1) {
          next unless $allrest;
          $comment = "";
          do { $comment = "#"; $nbk = 1; } if ($oldclef ne $clef);
          if ($IndGenRmOnly == 1) {
            if (/$GrepString/o) {
              print STDOUT "rm $allrest\n"; }
            else {
              print STDOUT "#rm $allrest\n"; }
          }
          elsif ($IndKeep == 1) {
            if (/$GrepString/o && $nbk) {
              print STDOUT "#rm $allrest\n";
              $nbk = 0; }
            else {
              print STDOUT "rm $allrest\n"; }
          }
          else {
             print STDOUT $comment . "rm $allrest\n"; }
          }
        else {
          print STDOUT $_ . "\n"; }
        $oldclef = $clef;
      };
    };
close(FILE);
unlink $Tmp;
# -----------------------------------------------------------------------------
