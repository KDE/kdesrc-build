# Test tag names based on time

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;

my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log

my $app = ksb::Application->new(qw(--pretend --rc-file t/data/branch-time-based/kdesrc-buildrc));
my @moduleList = $app->modules();

is(scalar @moduleList, 3, 'Right number of modules');

for my $mod (@moduleList) {
    my $scm = $mod->scm();
    isa_ok($scm, 'ksb::Updater::Git');

    my ($branch, $type) = $scm->_determinePreferredCheckoutSource();
    is($branch, 'master@{3 weeks ago}', 'Right tag name');
    is($type, 'tag', 'Result came back as a tag with detached HEAD');
}

my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section

done_testing();
