use 5.014;
use strict;
use warnings;

# Test tag names based on time

use Test::More;

use ksb::Application;

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

done_testing();
