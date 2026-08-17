#!/usr/bin/perl
# unit tests for matching() : eval the "expressions" part of dts.pl
# The two cuts are anchored on code, not on comment wording, so rewording a
# banner cannot silently leak the option loop into the eval.
open(S, "< dts.pl") or die;
my $src = do { local $/; <S> };
close S;
$src =~ s/.*?^\%MXCACHE = \(\);/\%MXCACHE = ();/ms;
$src =~ s/^\$nblev = 1;.*//ms or die "t_matching: cannot find the option loop in dts.pl\n";
eval $src;
die "eval: $@" if $@;

my $ok = 0; my $ko = 0;
sub is {
    my ($got, $want, $name) = @_;
    if ($got eq $want) { $ok++ }
    else { $ko++; print "KO  $name : expected '$want', got '$got'\n" }
}
sub m_ok  { my ($p,$e,$n) = @_; is(matching($p,$e), 1, $n) }
sub m_no  { my ($p,$e,$n) = @_; is(matching($p,$e), 0, $n) }
sub dies  { my ($e,$n) = @_; eval { matching('/a/b', $e) }; is(($@ ? 1 : 0), 1, $n) }

# --- bare form = regex on the basename ---------------------------------------
m_ok('/tmp/photos/IMG_2020.jpg', 'jpg',      'bare: basename contains jpg');
m_no('/jpg/photos/a.png',        'jpg',      'bare: the jpg directory does not count');
m_ok('/a/b/x.jpg',               '\.jpg$',   'bare: end anchor');

# --- f: p: and delimiters ----------------------------------------------------
m_ok('/tmp/important/a.jpg', 'p:|/important/|', 'p: with delimiter |');
m_no('/tmp/important/a.jpg', 'f:|/important/|', 'f: does not see the path');
m_ok('/x/IMPORTANT.txt',     'f:/important/i',  'flag i');
m_no('/x/IMPORTANT.txt',     'f:/important/',   'without flag i');
m_ok('/x/a.jpg',             '/\.jpg$/',        '/re/ == f:/re/');
m_ok('/x/a,b.jpg',           'f:/a{1,3},b/',    'comma inside the regex');
m_ok('/x/a.jpg',             'f:#\.jpg#',       'delimiter #');
m_ok('/x/a|b',               'f:|a\|b|',        'escaped delimiter');
m_ok('/Corbeille/a.txt', 'p:{/(Corbeille|Downloads)/}', 'paired delimiter {}');
m_ok('/x/aaa.txt',       'f:{^a{2,3}\\.}',            'nested braces');
m_ok('/x/b.txt',         'f:[^[ab]\\.]',              'delimiter [] with a class');
m_no('/x/c.txt',         'f:[^[ab]\\.]',              'delimiter [] : no match');
m_ok('/x/a<b',           'f:<a\\<b>',                   'escaped delimiter <>');
dies('f:<a<b>',          'unbalanced delimiter <>');
dies('f:(a)',            'parenthesis forbidden as a delimiter');

# --- operators ---------------------------------------------------------------
my $E = '/\.jpg$/ && f:/^20/ && !p:/mk_/';
m_ok('/photos/2021/20210310.jpg', $E, 'triple AND: true');
m_no('/photos/2021/20210310.png', $E, 'triple AND: extension');
m_no('/photos/2021/img.jpg',      $E, 'triple AND: prefix');
m_no('/photos/mk_/20210310.jpg',  $E, 'triple AND: negation');

m_ok('/a/b.png', '/\.jpg$/ || /\.png$/',        'OR');
m_no('/a/b.gif', '/\.jpg$/ || /\.png$/',        'OR false');
m_ok('/a/b.gif', '!/\.jpg$/',                   'NOT');
m_ok('/a/b.gif', '!!/\.gif$/',                  'double NOT');
m_ok('/a/b.jpg', '(/\.jpg$/ || /\.png$/) && !/^tmp/', 'parentheses');
m_no('/a/tmp.jpg', '(/\.jpg$/ || /\.png$/) && !/^tmp/', 'parentheses + negation');
# && binds tighter than ||
m_ok('/a/b.jpg', '/^zz/ && /^zz/ || /\.jpg$/',  'precedence && > ||');

# --- errors ------------------------------------------------------------------
dies('/unterminated',       'unterminated regex');
dies('/a/ &&',              'missing operand');
dies('(/a/',                'unclosed parenthesis');
dies('/a/ /b/',             'trailing tokens');
dies('f:/a(/',            'invalid regex');

# --- splitting into rules ----------------------------------------------------
my @r = mx_rules('f:/^IMG/,p:|/important/|i,/\.raw$/');
is(scalar @r, 3, 'mx_rules: 3 rules');
is($r[0][0], 'f:/^IMG/',        'mx_rules: label 1');
is($r[1][0], 'p:|/important/|i','mx_rules: label 2');
is($r[2][0], '/\.raw$/',        'mx_rules: label 3');
@r = mx_rules('f:/a{1,3}/');
is(scalar @r, 1, 'mx_rules: a comma inside the regex does not split');
@r = mx_rules('tmp');
is(scalar @r, 1, 'mx_rules: bare form not split');
is($r[0][0], 'tmp', 'mx_rules: bare label');

# --- priority file -----------------------------------------------------------
sub wf { open(O, "> tf.priority") or die; print O $_[0]; close O }
sub load { @KeepFile = (); @RmFile = (); wf($_[0]); return load_priority_file("tf.priority", 1) }

is(load("[keeppriority]\n/a/\n/b/\n\n[rmpriority]\nf:/tmp/\n"), 3, 'file: 3 rules');
is(scalar @KeepFile, 2, 'file: 2 keep');
is(scalar @RmFile,   1, 'file: 1 rm');
is($KeepFile[0][0], '/a/', 'file: label kept');
is(load("# all comments\n\n"), 0, 'file: empty');
is(load("[KeepPriority]\n/a/\n[RM]\n/b/\n"), 2, 'file: section names are case insensitive');
is(load("[keeppriority]\n  f:/x/  \n"), 1, 'file: surrounding blanks');
is($KeepFile[0][0], 'f:/x/', 'file: label stripped');
is(load("[keeppriority]\n/a/,/b/\n"), 2, 'file: list on one line');
is(load("[keeppriority]\n/x/\n[rmpriority]\n/y/\n[keeppriority]\n/z/\n"), 3, 'file: repeated sections');
is($KeepFile[1][0], '/z/', 'file: order preserved across repeated sections');
eval { load("/a/\n") };            is(($@ ? 1 : 0), 1, 'file: rule outside of any section');
eval { load("[nawak]\n/a/\n") };  is(($@ ? 1 : 0), 1, 'file: unknown section');
eval { load("[keeppriority]\n/abc\n") }; is(($@ ? 1 : 0), 1, 'file: unterminated regex');
@KeepFile = (); @RmFile = ();
is(load_priority_file("not_there.priority", 0), 0, 'file: absent and implicit -> 0');
eval { load_priority_file("not_there.priority", 1) }; is(($@ ? 1 : 0), 1, 'file: absent and explicit -> error');
unlink "tf.priority";

print "\n$ok tests OK, $ko failures\n";
exit($ko ? 1 : 0);
