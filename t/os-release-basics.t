use 5.014;
use strict;
use warnings;

# Test ksb::OSSupport

use Test::More;

use ksb::OSSupport;

# Unit test of _readOSRelease
my @kvPairs = ksb::OSSupport->_readOSRelease('t/data/os-release');

is(scalar @kvPairs, 4, 'Right number of key/value pairs');

my %opts = map { @{$_}[0,1] } @kvPairs;

is($opts{NAME}, 'Totally Valid Name', 'Right NAME');
is($opts{ID}, 'kdesrc-build', 'Right ID');
is($opts{ID_LIKE}, 'sabayon gentoo-hardened gentoo', 'Right ID_LIKE');
is($opts{SPECIAL}, '$VAR \\ ` " is set', 'Right SPECIAL');

# Use tests
my $os = new_ok('ksb::OSSupport', ['t/data/os-release']);
is($os->bestDistroMatch(qw/arch kdesrc-build sabayon/), 'kdesrc-build', 'ID preferred');
is($os->bestDistroMatch(qw/ubuntu fedora gentoo/), 'gentoo', 'ID_LIKE respected');
is($os->bestDistroMatch(qw/fedora gentoo gentoo-hardened sabayon/), 'gentoo', 'ID_LIKE preference order proper');
is($os->vendorID, 'kdesrc-build', 'Right ID');

done_testing();
