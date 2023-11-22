# Ensure 'use ksb;' causes strict mode to activate

use ksb;
use Test::More;
use POSIX;
use File::Basename;

my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log

# Keep in mind with variable name here that $a and $b are special-cased by Perl
# to always be valid to make using 'sort' function less annoying.

my $d = 0;

# This should cause Perl to raise an exception in the eval block, to be
# captured in $@.
$d = eval '$f = 3; $f';

ok(defined $@, "'use ksb' activates 'use strict'");

# This should ensure no exception is raised.
$d = eval 'my $f = 3; $f';

ok(!$@, "eval on valid syntax with 'use ksb' works");
ok($d == 3, "eval with 'use ksb' returns properly");

eval {
    sub foo($arg1, $arg2) {
    }
};

ok(!$@, "eval on block with sub signatures works");

my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
done_testing();
