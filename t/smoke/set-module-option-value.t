use v5.22;
use warnings;

# Test use of --set-module-option-value

use Test::More;

use ksb::Application;

my @args = (qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc
    --set-module-option-value), 'module2,tag,fake-tag10',
   '--set-module-option-value', 'setmod2,tag,tag-setmod10');
my $app = ksb::Application::newFromCmdline(@args);
my @moduleList = $app->modules();

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

done_testing();
