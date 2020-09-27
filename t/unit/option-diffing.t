use v5.22;
use warnings;

# Test the "option diffing" code used in Module.pm to help ensure that the only
# options sent across subprocess boundaries back to the main process are for
# options that have actually changed value, since we could conceptually have
# multiple subprocesses running at one time.

use Test::More;
use Storable qw(dclone);

use ksb::Module;

# Base easy case. Start from a known config and make some changes and ensure
# those changes are in the diff.
my $old_options = {
    'option-1' => 'a',
    'option-2' => 'b',
    'option-3' => 3,
};

my $new_options = dclone($old_options);
$new_options->{'option-2'} = 'c';
$new_options->{'option-4'} = 4;
$new_options->{'option-5'} = undef;
delete $new_options->{'option-3'};

my $diff = ksb::Module::_buildModulesOptionsPatch($old_options, $new_options);

my $expected = {
    del => [
        'option-3',
    ],
    set => {
        'option-2' => 'c',
        'option-4' => 4,
        'option-5' => undef,
    },
};

is_deeply($diff, $expected, 'Ensure options diffing works to support subprocesses.');

# Diff an existing object against itself. There should be no mention of any
# option names.
$diff = ksb::Module::_buildModulesOptionsPatch($old_options, $old_options);
$expected = { del => [ ], set => { } };

is_deeply($diff, $expected, 'Options diff is empty if no changes.');

# This exposes a problem I encountered with a trailing-if during refactoring.
my $kjs_build_pre = {
    'failure-count'          => 0,
    'git-cloned-repository'  => "kde:frameworks/kjs.git",
    'last-build-rev'         => "56731d848366a3f5efd48333dba9d0b325144c55",
    'last-cmake-options'     => "HhcYXwvfxj+llegRXKIeFA",
    'last-compile-warnings'  => 0,
    'last-install-rev'       => "56731d848366a3f5efd48333dba9d0b325144c55"
};

my $kjs_build_post = {
    'failure-count'          => 0,
    'git-cloned-repository'  => "kde:frameworks/kjs.git",
    'last-build-rev'         => "56731d848366a3f5efd48333dba9d0b325144c55",
    'last-cmake-options'     => "HhcYXwvfxj+llegRXKIeFA",
    'last-compile-warnings'  => 1110,
    'last-install-rev'       => "56731d848366a3f5efd48333dba9d0b325144c55"
};

$diff = ksb::Module::_buildModulesOptionsPatch($kjs_build_pre, $kjs_build_post);
$expected = { del => [ ], set => { 'last-compile-warnings' => 1110 } };
is_deeply($diff, $expected, 'Numeric compares against 0 show up');

# This ensures that only scalar values are considered for differencing, to
# allow us to pass objects holding references unchanged.
my $filled_with_refs = {
    'set-env' => {
        'FOO' => 'bar',
    },
    '#defined-at' => [
    ],
    'scalar1' => 3,
    'scalar2' => 3,
};

my $different_under_refs = {
    'set-env' => {
        'FOO' => 'baz',
    },
    '#defined-at' => [
        'scalar1' => 3,
    ],
    'scalar2' => 4,
};

$diff = ksb::Module::_buildModulesOptionsPatch($filled_with_refs, $different_under_refs);

# Both set-env/#defined-at values changed but our patch algo *IGNORES* those to
# prevent use from trying to break options.
$expected = {
    del => [ 'scalar1', ],
    set => { scalar2 => 4 },
};

is_deeply($diff, $expected, 'Changes under refs are ignored');

done_testing();
