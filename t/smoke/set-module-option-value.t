# Test use of --set-module-option-value

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;

my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log

my $app = ksb::Application->new(qw(
    --pretend --rc-file t/data/sample-rc/kdesrc-buildrc
    --set-module-option-value), 'module2,tag,fake-tag10',
   '--set-module-option-value', 'setmod2,tag,tag-setmod10');
my @moduleList = @{$app->{modules}};

is(scalar @moduleList, 4, 'Right number of modules');

my ($module) = grep { "$_" eq 'module2' } @moduleList;
my $scm = $module->scm();
my ($branch, $type) = $scm->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/fake-tag10', 'Right tag name');
is($type, 'tag', 'Result came back as a tag');

($module) = grep { "$_" eq 'setmod2' } @moduleList;
($branch, $type) = $module->scm()->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/tag-setmod10', 'Right tag name (options block from cmdline)');
is($type, 'tag', 'cmdline options block came back as tag');

ok(!$module->isKDEProject(), 'setmod2 is *not* a "KDE" project');
is($module->fullProjectPath(), 'setmod2', 'fullProjectPath on non-KDE modules returns name');

my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section

done_testing();
