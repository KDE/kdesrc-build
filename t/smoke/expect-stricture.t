# Ensure 'use ksb;' causes strict mode to activate

use ksb;
use Test::More;

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

done_testing();
