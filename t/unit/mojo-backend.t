use v5.22;
use Test::More;
use Test::Mojo;
use Cwd qw(getcwd);

use web::BackendServer;

my $opts = {
    options => {
        global => {
            'rc-file' => 't/data/sample-rc/kdesrc-buildrc',
            pretend   => 1,
        },
    },
};

my $t = Test::Mojo->new('web::BackendServer', $opts);

$t->get_ok('/config')
  ->status_is(200)
  ->content_is(getcwd() . '/t/data/sample-rc/kdesrc-buildrc');

$t->get_ok('/known_modules')
  ->status_is(200)
  ->json_is('', [[qw(set1 setmod1 setmod2 setmod3)], 'module2'], 'right module output');

done_testing();
