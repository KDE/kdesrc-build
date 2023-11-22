# Checks that we don't inadvertently eat non-option arguments in cmdline
# processing, which happened with some cmdline options that were inadvertently
# handled both directly in _readCommandLineOptionsAndSelectors and indirectly
# via being in ksb::BuildContext::defaultGlobalFlags)
#
# See bug 402509 -- https://bugs.kde.org/show_bug.cgi?id=402509

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;
use ksb::Module;

my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log

# This bug had affected --stop-on-failure and --disable-snapshots
my @args = qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc --stop-on-failure setmod3);

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 1, 'Right number of modules (just one)');
    is ($moduleList[0]->name(), 'setmod3', 'mod list[2] == setmod3');
}

$args[-2] = '--disable-snapshots';

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 1, 'Right number of modules (just one)');
    is ($moduleList[0]->name(), 'setmod3', 'mod list[2] == setmod3');
}

my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section

done_testing();
