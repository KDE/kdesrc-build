# Test ksb::OSSupport

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::OSSupport;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

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
is($os->bestDistroMatch(qw/fedora gentoo gentoo-hardened sabayon/), 'sabayon', 'ID_LIKE preference order proper');
is($os->vendorID, 'kdesrc-build', 'Right ID');

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
