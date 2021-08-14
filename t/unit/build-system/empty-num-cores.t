use 5.014;
use strict;
use warnings;

# Test that empty num-cores settings (which could lead to blank -j being passed
# to the build in some old configs) have their -j filtered out.

use Test::More;

use ksb::Module;
use ksb::BuildSystem;

package ksb::BuildSystem
{
    our @madeArguments;
    no warnings 'redefine';

    # Defang the build command and just record the args passed to it
    sub safe_make(@)
    {
        my ($self, $optsRef) = @_;
        @madeArguments = @{$optsRef->{'make-options'}};
        return { was_successful => 1 };
    }
};

my $ctx = ksb::BuildContext->new;
my $module = ksb::Module->new($ctx, 'test');
my $buildSystem = ksb::BuildSystem->new($module);

# Ensure binpath and libpath options work

my $testOption = 'make-options';

my @testMatrix = (
    [ 'a b -j', [qw(a b)], 'Empty -j removed at end' ],
    [ '-j a b', [qw(a b)], 'Empty -j removed at beginning' ],
    [ 'a b', [qw(a b)], 'Opts without -j left alone' ],
    [ '-j', [qw()], 'Empty -j with no other opts removed' ],
    [ 'a -j 17 b', [qw(a -j 17 b)], 'Numeric -j left alone' ],
    [ 'a -j17 b', [qw(a -j17 b)], 'Numeric -j left alone' ],
);

for (@testMatrix) {
    my ($testString, $resultRef, $testName) = @{$_};
    $module->setOption($testOption, $testString);
    $buildSystem->buildInternal($testOption);
    is_deeply(\@ksb::BuildSystem::madeArguments, $resultRef, $testName);

    $module->setOption('num-cores', 4);
    $buildSystem->buildInternal($testOption);
    is_deeply(\@ksb::BuildSystem::madeArguments, ['-j', 4, @{$resultRef}], "$testName with num-cores set");
    $module->setOption('num-cores', '');
}

$testOption = 'ninja-options';
$module->setOption('make-options', 'not used');
$module->setOption('cmake-generator', 'Kate - Ninja');

for (@testMatrix) {
    my ($testString, $resultRef, $testName) = @{$_};
    $module->setOption($testOption, $testString);
    $buildSystem->buildInternal($testOption);
    is_deeply(\@ksb::BuildSystem::madeArguments, $resultRef, $testName);

    $module->setOption('num-cores', 4);
    $buildSystem->buildInternal($testOption);
    is_deeply(\@ksb::BuildSystem::madeArguments, ['-j', 4, @{$resultRef}], "$testName with num-cores set");
    $module->setOption('num-cores', '');
}

done_testing();
