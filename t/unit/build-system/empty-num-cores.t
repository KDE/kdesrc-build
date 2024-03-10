# SPDX-FileCopyrightText: 2021, 2022 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Test that empty num-cores settings (which could lead to blank -j being passed
# to the build in some old configs) have their -j filtered out.

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Module;
use ksb::BuildSystem;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

package ksb::BuildSystem
{
    our @madeArguments;
    no warnings 'redefine';

    # Defang the build command and just record the args passed to it
    sub safe_make($self, $optsRef)
    {
        @madeArguments = @{$optsRef->{'make-options'}};
        return { was_successful => 1 };
    }
};

# Setup a shell build system
my $ctx = ksb::BuildContext->new;
my $module = ksb::Module->new($ctx, 'test');
my $buildSystem = ksb::BuildSystem->new($module);

# The -j logic will take off one CPU if you ask for too many so try to ensure
# test cases don't ask for too many.
my $max_cores = `nproc`;
chomp $max_cores;
$max_cores = int $max_cores // 2;
$max_cores = 2 if $max_cores < 2;

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

    $module->setOption('num-cores', $max_cores - 1);
    $buildSystem->buildInternal($testOption);
    is_deeply(\@ksb::BuildSystem::madeArguments, ['-j', $max_cores - 1, @{$resultRef}], "$testName with num-cores set");
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

    $module->setOption('num-cores', $max_cores - 1);
    $buildSystem->buildInternal($testOption);
    is_deeply(\@ksb::BuildSystem::madeArguments, ['-j', $max_cores - 1, @{$resultRef}], "$testName with num-cores set");
    $module->setOption('num-cores', '');
}

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
