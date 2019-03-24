use 5.014;
use strict;
use warnings;

# Test use of --set-module-option-value

use Test::More;

use ksb::Application;

my $app = ksb::Application->new(qw(
    --pretend --rc-file t/data/sample-rc/kdesrc-buildrc
    --set-module-option-value), 'module2,tag,fake-tag10',
   '--set-module-option-value', 'setmod2,tag,tag-setmod10');
my @moduleList = @{$app->{modules}};

is(scalar @moduleList, 4, 'Right number of modules');

my $scm = $moduleList[3]->scm();
my ($branch, $type) = $scm->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/fake-tag10', 'Right tag name');
is($type, 'tag', 'Result came back as a tag');

($branch, $type) = $moduleList[1]->scm()->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/tag-setmod10', 'Right tag name (options block from cmdline)');
is($type, 'tag', 'cmdline options block came back as tag');

ok(!$moduleList[1]->isKDEProject(), 'setmod2 is *not* a "KDE" project');
is($moduleList[1]->fullProjectPath(), 'setmod2', 'fullProjectPath on non-KDE modules returns name');

done_testing();
