#!/usr/bin/env perl

use 5.014;
use ksb::PromiseChain;

use Mojo::IOLoop;
use Mojo::Promise;
use Test::More;

my $deps = ksb::PromiseChain->new;

my $high_water_mark = 0;

# Generate a subroutine that checks to make sure the number it is generated
# with ends up being the highest number ever set when the sub finally runs. We
# use this to verify dependencies work right by giving lower numbers an earlier
# required step..

my $generate_check = sub {
    my ($i) = shift;

    return sub {
        die "Last set test was $high_water_mark compared to $i"
            unless $high_water_mark <= $i;
        $high_water_mark = $i;
        return 1;
    }
};

# First step introduces a short delay. If things work right, all subsequent
# jobs should block for just a bit and then complete.
$deps->addItem('kdelibs/update' , 'update', sub {
    my $p = Mojo::Promise->new;
    Mojo::IOLoop->timer(0.5, sub { $high_water_mark = 1; $p->resolve; });
    return $p;
});
$deps->addItem('kdebase/update' , 'update', $generate_check->(2));
$deps->addItem('juk/update'     , 'update', $generate_check->(3));
$deps->addItem('kdelibs/build'  , 'build' , $generate_check->(2));
$deps->addItem('kdebase/build'  , 'build' , $generate_check->(3));
$deps->addItem('kdebase/install', 'build' , $generate_check->(4));
$deps->addItem('juk/build'      , 'build' , $generate_check->(5));
$deps->addItem('juk/install'    , 'build' , $generate_check->(6));

# These correspond to intermodule dependencies as in kde-build-metadata
$deps->addDep('kdelibs/build'  , 'kdelibs/update');
$deps->addDep('kdebase/build'  , 'kdebase/update');
$deps->addDep('kdebase/install', 'kdebase/build');
$deps->addDep('juk/build'      , 'juk/update');
$deps->addDep('juk/install'    , 'juk/build');

# Get our all-in-one promise and go
my $promise = $deps->makePromiseChain();
my $result;

$promise->then( sub {
    $result = 1;
}, sub {
    my ($err) = @_;
    say "Something failed! $err";
})->wait;

is($result, 1, 'Testing promise chain');

done_testing();
