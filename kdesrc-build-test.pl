#!/usr/bin/env perl
# Test suite for kdesrc-build. If you encounter tests that fail on your
# correctly-configured system please let myself or the kde-buildsystem mailing
# list know so I can fix and/or workaround. -mpyne
#
# Copyright © 2008 - 2011 Michael Pyne. <mpyne@kde.org>
# Home page: http://kdesrc-build.kde.org/
#
# You may use, alter, and redistribute this software under the terms
# of the GNU General Public License, v2 (or any later version).

use strict;
use warnings;
use 5.010;
use Getopt::Long;
use Scalar::Util qw(blessed);
use Storable qw(freeze);
use FindBin qw($RealBin $Bin);

# Control whether we actually try to svn checkouts, possibly more later.
my $fullRun = 0;
GetOptions("full-run!" => \$fullRun);

package test; # Tells kdesrc-build not to run
require 'kdesrc-build';

# Reset to kdesrc-build's package so we don't have to import symbols back from
# kdesrc-build.
package main;

use FindBin qw($RealBin);
use lib "$RealBin/../share/apps/kdesrc-build/modules";
use lib "$RealBin/modules";

# Must come after require kdesrc-build. note will interfere with our debugging
# function, and we don't use it in the test harness anyways.
use Test::More import => ['!note'];
use File::Temp 'tempdir';
use Storable 'dclone';
use File::Copy;
use ksb::BuildSystem::QMake;
use ksb::BuildContext;
use ksb::Module;
use ksb::l10nSystem;

# From kdesrc-build
our %ENV_VARS;

# Base directory name to use for any needed filesystem tests.
my $testSourceDirName =
    tempdir('kdesrc-build-test-XXXXXX',
            TMPDIR => 1,   # Force creation under the temporary directory.
            CLEANUP => 1); # Delete temp directory when done.

my $ctx = ksb::BuildContext->new();
isa_ok($ctx, 'ksb::BuildContext', 'Ensure BuildContext classiness');
isa_ok($ctx->phases(), 'ksb::PhaseList', 'Ensure PhaseList classiness');

my %moreOptions = (
  'qt' => {
      'cxxflags' => '-pipe -march=i386',
      'configure-flags' => '-fast',
      'repository' => 'kde:qt',
  },

  'kdelibs' => {
      'cmake-options' => '-DTEST=TRUE',
      'unused' => 0,
  },

  'kdesdk' => { },

  'kdesupport' => { },

  'phonon' => { },

  'playground/libs' => { },

  'KDE/kdelibs' => {
      'cmake-options' => '-DTEST=TRUE',
  },

  'test' => {
      'source-dir' => '~/testsrc',
      'module-base-path' => 'KDE/KDE/test',
      'set-env' => { 'MOIN'=>'2' },
  },
);

for my $key (keys %moreOptions) {
    ${$ctx->{build_options}}{$key} = $moreOptions{$key};
}

eval {

ksb::Util->import();

# If using set-env, it is handled by the handle_set_env routine, so the
# value should be the space separated VAR and VALUE.
$ctx->setOption('set-env', 'TESTY_MCTEST yes');
$ctx->setOption('cxxflags', '-g -O0');
$ctx->setOption('cmake-options', '-DCMAKE_BUILD_TYPE=RelWithDebInfo');
$ctx->setOption('svn-server', 'svn+ssh://svn.kde.org/home/kde');
$ctx->setOption('configure-flags', '-fast -dbus');
$ctx->setOption('#configure-flags', '-fast -dbus');
$ctx->setOption('source-dir', '~/' . "kdesrc-build-unused");
$ctx->setOption('#unused', '1');
$ctx->setOption('branch', '4.3');

# Commence testing proper
p_chdir ($testSourceDirName);

SKIP: {
    skip 'git not installed', 1 unless defined absPathToExecutable('git');

    if (!is(system('git', 'init', 'test-git-dir'), 0, 'Create new git directory')) {
        skip 'git does not work', 1;
    }

    p_chdir('test-git-dir');

    my @gitStatusOutput = filter_program_output(sub { /On branch/ }, qw/git status/);
    is(@gitStatusOutput, 1, 'Correct number of items from filter_program_output');
    is(`git status`, join('', filter_program_output(undef, qw/git status/)), 'Ensure filter_program_output works w/ no filter');
    is($ctx->getSourceDir(), $ENV{HOME} . "/kdesrc-build-unused", 'Correct tilde-expansion for source-dir');

    p_chdir($testSourceDirName);
}

# We know tilde-expansion works for source-dir, reset to our temp dir.
$ctx->setOption('source-dir', $testSourceDirName);

SKIP: {
    skip 'No XML testing', 1 unless $fullRun;

    my $fh = ensure_projects_xml_present($ctx);
    ok($fh, 'Valid filehandle from ensure_projects_xml_present');

    my $metadataModuleSet = ksb::Module->new($ctx, 'kde-build-metadata');
    isa_ok($metadataModuleSet, 'ksb::Module');
    $metadataModuleSet->setScmType('proj');

    my @buildMetadataModule = expandXMLModules($ctx, $metadataModuleSet);
    my $metadataModule = shift @buildMetadataModule;
    is($metadataModule->scmType(), 'metadata', 'expandXMLModules adds kde-build-metadata');

    $metadataModule->scm()->updateInternal();
}

# Ensure the utility methods work.
my @listWithDuplicates = qw(2 3 5 2 8);

# For some reason sort cannot be used with unique_list()'s output directly,
# probably it needs to be coerced to a list somehow instead of trying to guess
# that I mean for it to do some other magic.
my @uniqList = unique_list(@listWithDuplicates);
@uniqList = sort @uniqList;

is_deeply(\@uniqList, [qw(2 3 5 8)], 'unique_list');

my ($qtModule, $kdelibsModule, $testModule, $kdesupportModule, $phononModule)
    = map {
        ksb::Module->new($ctx, $_);
    } (qw/qt kdelibs test kdesupport phonon/);

like($kdelibsModule->getLogDir(), qr{^$testSourceDirName/log}, 'correct log dir for test run');
is($qtModule->getOption('cxxflags'), '-pipe -march=i386', 'qt cxxflags handling');
is($qtModule->getOption('configure-flags'), '-fast', 'qt configure-flags handling');
is($kdelibsModule->getOption('unused'), 1, 'Test normal sticky option');
like($kdelibsModule->getOption('cmake-options'), qr/^-DCMAKE_BUILD_TYPE=RelWithDebInfo/, 'kdelibs cmake-options appending');
like($kdelibsModule->getOption('cmake-options'), qr/-DTEST=TRUE$/, 'kdelibs options appending');
is($testModule->getOption('branch', 'module'), undef, 'get_option limit to module level');

$kdelibsModule->setOption('branch', 'trunk');
is($kdelibsModule->scm()->svn_module_url(), 'svn+ssh://svn.kde.org/home/kde/trunk/KDE/kdelibs', 'KDE module trunk');

$kdelibsModule->setOption('tag', '4.1.3');
$kdelibsModule->setOption('branch', '4.2');
like(ksb::Updater::Svn::_handle_branch_tag_option($kdelibsModule, 'tags'), qr(/tags/KDE/4\.1\.3/kdelibs$), 'KDE module tag preferred to branch');

$kdelibsModule->setOption('tag', '');
like(ksb::Updater::Svn::_handle_branch_tag_option($kdelibsModule, 'branches'), qr(/branches/KDE/4.2/kdelibs$), 'KDE module branch');

$kdesupportModule->setOption('branch', 'trunk');
$kdesupportModule->setOption('svn-server', 'svn://anonsvn.kde.org/home/kde');

# Ensure svn info exists in our source dir. This requires actually accessing
# anonsvn, so use --depth empty and --ignore-externals to minimize load on
# server.
my @svnArgs = (
    qw{svn co
    --depth empty
    --ignore-externals
    svn://anonsvn.kde.org/home/kde/trunk/kdesupport},
    "$testSourceDirName/kdesupport");

my $svnAvail = defined absPathToExecutable('svn') && $fullRun;

SKIP: {
    skip 'svn not installed', 1 unless $svnAvail;
    $svnAvail = is(system(@svnArgs), 0, "Make empty subversion checkout.");
}

$ENV{HOME} = $testSourceDirName;
ksb::Updater::Svn::_install_missing_ssl_signature();

my $signatureFile = "$testSourceDirName/.subversion/auth/svn.ssl.server/ec08b331e2e6cabccb6c3e17a85e28ce";
ok(-e $signatureFile, "Verify KDE SVN server SSL signature can be installed");

use Digest::MD5;
my $md5 = Digest::MD5->new();
open my $md5Data, '<', $signatureFile;
binmode($md5Data);
is ($md5->addfile($md5Data)->hexdigest, '15d0534068cdbe340fc29db520b8beaa', "Verify installed KDE SVN SSL certificate is correct");
close $md5Data;

is($kdesupportModule->scm()->svn_module_url(), 'svn://anonsvn.kde.org/home/kde/trunk/kdesupport', 'non-KDE module trunk');

# Issue reported by dfaure 2011-02-06, where the kdesupport-branch was not being
# obeyed when global-branch was set to 4.6, so somehow kdesrc-build wanted a
# mystical kdesupport-from-4.6 branch
$kdesupportModule->setOption('branch', 'master');
$kdesupportModule->setOption('prefix', '/d/kde/inst/kdesupport-for-4.6');
$ctx->setOption('branch', '4.6');
is($kdesupportModule->scm()->svn_module_url(), 'svn://anonsvn.kde.org/home/kde/branches/kdesupport/master', 'kdesupport-for-$foo with local branch override');

$kdesupportModule->setOption('tag', 'kdesupport-for-4.2');
like(ksb::Updater::Svn::_handle_branch_tag_option($kdesupportModule, 'tags'), qr(/tags/kdesupport-for-4.2$), 'non-KDE module tag (no name appended)');
is($kdesupportModule->scm()->svn_module_url(), 'svn://anonsvn.kde.org/home/kde/tags/kdesupport-for-4.2', 'non-KDE module tag (no name; entire URL)');

$phononModule->setOption('branch', '4.2');
is($phononModule->scm()->svn_module_url(), 'svn+ssh://svn.kde.org/home/kde/branches/phonon/4.2', 'non-KDE module branch (no name appended)');

$phononModule->setOption('branch', '');
$phononModule->setOption('module-base-path', 'tags/phonon/4.2');
is($phononModule->scm()->svn_module_url(), 'svn+ssh://svn.kde.org/home/kde/tags/phonon/4.2', 'module-base-path');

my @result1 = qw/a=b g f/;
my @quoted_result = ('a=b g f', 'e', 'c=d', 'bless');
is_deeply([ split_quoted_on_whitespace('"a=b g f" "e" c=d bless') ], \@quoted_result, "split_quoted_on_whitespace quotes and spaces");
is_deeply([ split_quoted_on_whitespace('a=b g f') ], \@result1, 'split_quoted_on_whitespace space, no quotes');
is_deeply([ split_quoted_on_whitespace(' a=b g f') ], \@result1, 'split_quoted_on_whitespace space no quotes, leading whitespace');
is_deeply([ split_quoted_on_whitespace('a=b g f ') ], \@result1, 'split_quoted_on_whitespace space no quotes, trailing whitespace');
is_deeply([ split_quoted_on_whitespace(' a=b g f ') ], \@result1, 'split_quoted_on_whitespace space no quotes, leading and trailing whitespace');
is_deeply([ split_quoted_on_whitespace('-DFOO="${MODULE}" BAR') ],
          ['-DFOO=${MODULE}', 'BAR'], 'split_quoted_on_whitespace with braces/quotes');

SKIP: {
    skip "svn not available or network was down", 2 unless $svnAvail;

    is($kdesupportModule->scmType(), 'svn', 'svn requirement detection');
    like($kdesupportModule->scm()->svnInfo('URL'), qr/anonsvn\.kde\.org/, 'svn-info output (url)');
    like($kdesupportModule->scm()->svnInfo('Revision'), qr/^\d+$/, 'svn-info output (revision)');
}

# Test get_subdir_path
is($kdelibsModule->getSubdirPath('build-dir'),
    "$testSourceDirName/build",
    'build-dir subdir path rel');
is($kdelibsModule->getSubdirPath('log-dir'),
    "$testSourceDirName/log",
    'log-dir subdir path rel');
$kdelibsModule->setOption('build-dir', '/tmp');
is($kdelibsModule->getSubdirPath('build-dir'), "/tmp", 'build-dir subdir path abs');
$kdelibsModule->setOption('build-dir', '~/tmp/build');
is($kdelibsModule->getSubdirPath('build-dir'), "$ENV{HOME}/tmp/build", 'build-dir subdir path abs and tilde expansion');

# correct log dir for modules with a / in the name
my $playLibsModule = ksb::Module->new($ctx, 'playground/libs');
my $logdir = $playLibsModule->getLogDir();

ok(log_command($playLibsModule, 'touch', ['touch', "$testSourceDirName/touched"]) == 0, 'creating temp file');
ok(-e "$testSourceDirName/log/latest/playground/libs/touch.log", 'correct playground/libs log path');

#$kdelibsModule->setOption('log-dir', '~/kdesrc-build-log');
#my $isoDate = strftime("%F", localtime); # ISO 8601 date per setup_logging_subsystem
#is($kdelibsModule->getLogDir(), "$ENV{HOME}/kdesrc-build-log/$isoDate-01/kdelibs", 'getLogDir tilde expansion');

is($testModule->getSourceDir(), "$ENV{HOME}/testsrc", 'separate source-dir for modules');
$testModule->setupEnvironment();
is($ctx->{env}->{'TESTY_MCTEST'}, 'yes', 'setting global set-env for modules');
is($ctx->{env}->{'MOIN'}, '2', 'setting module set-env for modules');

my $unlikelyEnvVar = 'KDESRC_BUILD_TEST_PATH';
$ENV{$unlikelyEnvVar} = 'FAILED';
$ctx->prependEnvironmentValue($unlikelyEnvVar, 'TEST_PATH');

# Ensure that an empty {env} variable is not used.
ok(defined $ctx->{env}->{$unlikelyEnvVar}, 'prependEnvironmentValue queues value');
is($ctx->{env}->{$unlikelyEnvVar}, 'TEST_PATH:FAILED', 'prependEnvironmentValue queues in right order');

$unlikelyEnvVar .= '1';
$ctx->{env}->{$unlikelyEnvVar} = '/path/1:/path/2';
$ctx->prependEnvironmentValue($unlikelyEnvVar, '/path/0');

is($ctx->{env}->{$unlikelyEnvVar}, '/path/0:/path/1:/path/2', 'prependEnvironmentValue queues multiple times');

# Finally, see what happens when no env var or pre-existing queued var is set

$unlikelyEnvVar .= '1';
$ctx->prependEnvironmentValue($unlikelyEnvVar, '/path/10');

is($ctx->{env}->{$unlikelyEnvVar}, '/path/10', 'prependEnvironmentValue initial value');

# Ensure svn URL hierarchy is correct
like($testModule->scm()->svn_module_url(), qr{/home/kde/KDE/KDE/test$}, 'svn_module_url prefer module specific to global');
$testModule->setOption('override-url', 'svn://annono');
is($testModule->scm()->svn_module_url(), 'svn://annono', 'testing override-url');

my $pendingOptions = { };
my @modules = process_arguments($ctx, $pendingOptions, '--test,override-url=svn://ann');
is($pendingOptions->{test}{'override-url'}, 'svn://ann', 'testing process_arguments module options');
is(scalar @modules, 0, 'testing process_arguments return value for no passed module names');

@modules = qw/qt kdelibs kdebase/;
my $kdebaseModule;
$ctx = ksb::BuildContext->new();
my @Modules = map { ksb::Module->new($ctx, $_) } (@modules);
my $backupCtx = dclone($ctx);

# Ensure functions like updateModulePhases doesn't change the objects we pass
# in.
my $resetContext = sub {
    $ctx = dclone($backupCtx);
    # We must re-create modules to have the same context as ctx.
    @Modules = map { ksb::Module->new($ctx, $_) } (@modules);
    ($qtModule, $kdelibsModule, $kdebaseModule) = @Modules;
};

# Should be no change if there are no manual-update, no-src, etc. in the rc
# file so force one of those on that way we know updateModulePhases did
# something.
$kdelibsModule->setOption('no-build', 1);
my $backupModuleCopy = dclone(\@Modules);
updateModulePhases(@Modules);
is_deeply(\@Modules, $backupModuleCopy, 'Ensure objects not modified through references to them');
$kdelibsModule->deleteOption('no-build');

# Now test --no-src/--no-build/etc.
is_deeply([process_arguments($ctx, {}, @modules)], \@Modules, 'testing process_arguments return value for passed module names');

$_->phases()->filterOutPhase('update') foreach @Modules;
is_deeply([process_arguments($ctx, {}, @modules, '--no-src')], \@Modules, 'testing --no-src phase updating');
ok(!list_has([$ctx->phases()->phases()], 'update'), 'Build context also not updating');

&$resetContext();

# Reported by Kurt Hindenburg (IIRC). Passing --no-src would also disable the
# build (in updateModulesPhases) because of the global '#no-src' being set in
# process_arguments.
my @temp_modules = process_arguments($ctx, {}, @modules, '--no-src');
# There should be no module-specific no-src/no-build/manual-update/etc. set.
is_deeply([updateModulePhases(@temp_modules)], \@temp_modules, 'updateModulePhases only for modules');

&$resetContext();

$kdelibsModule->setOption('run-tests', 1);
my $newModules = dclone(\@Modules);

# is_deeply does not work under blessed references i.e. it will not verify
# the contents of blessed array references are actually equal, which causes
# some tests to spuriously pass in my experience :(
# Instead we compare the canonical in-memory representations of data structures
# which should have identical contents. This means we should use ok() instead
# of is() since we don't want the expected value dumped to tty.
$Storable::canonical = 1;
is(freeze($newModules), freeze(\@Modules), 'identical objects are identical');

$newModules->[1]->phases()->addPhase('test'); # kdelibs
ok(freeze([updateModulePhases(@Modules)]) eq freeze($newModules), 'Make sure run-tests is recognized for a module');

ok(!$kdebaseModule->getOption('run-tests'), 'run-tests not set for kdebase');
$newModules->[2]->phases()->addPhase('test'); # kdebase
ok(freeze([updateModulePhases(@Modules)]) ne freeze($newModules), 'Make sure run-tests is recognized only for its module');

&$resetContext();

# Test only --no-build
$_->phases()->filterOutPhase('build') foreach @Modules;
ok(freeze([process_arguments($ctx, {}, @modules, '--no-build')])
    eq freeze(\@Modules), 'testing --no-build phase updating');
ok(!list_has([$ctx->phases()->phases()], 'build'), 'Build context also not building');

# Add on --no-src
$_->phases()->filterOutPhase('update') foreach @Modules;
ok(freeze([process_arguments($ctx, {}, @modules, '--no-build', '--no-src')])
    eq freeze(\@Modules), 'testing --no-src and --no-build phase updating');

ok(!list_has([$ctx->phases()->phases()], 'build') &&
   !list_has([$ctx->phases()->phases()], 'update'),
       'Build context also not building or updating');

my $conf = <<EOF;
global
    git-repository-base test kde:
end global

module-set
    use-modules kdelibs
    repository test
end module-set

module-set set1
    use-modules kdesrc-build kde-runtime
    repository kde-projects
end module-set

module qt
    configure-flags -fast
    repository kde:qt
end module

module kde-runtime
    manual-build true
end module
EOF
open my $fh, '<', \$conf;

&$resetContext();

# Read in new options
my @conf_modules = read_options($ctx, $fh);
# qt
is($conf_modules[3]->getOption('configure-flags'), '-fast', 'read_options/parse_module');

# kdelibs
is($conf_modules[0]->getOption('repository'), 'kde:kdelibs', 'git-repository-base');
is($conf_modules[0]->scmType(), 'git', 'Ensure repository gives git scm (part 1)');

is($conf_modules[2]->getOption('manual-build'), 'true', 'manual-build for kde-projects submodule (Bug 288611)');

my @ConfModules = map { ksb::Module->new($ctx, $_) }(qw/kdelibs kdesrc-build kde-runtime qt/);

is($ConfModules[0]->scmType(), 'git', 'Ensure repository gives git scm (part 2)');
$ConfModules[0]->setModuleSet(''); # Unnamed module set, instead of undef
$ConfModules[1]->setModuleSet('set1');
$ConfModules[1]->setScmType('proj');
$ConfModules[2]->setModuleSet('set1');
$ConfModules[2]->setScmType('proj');
$ConfModules[2]->setOption('manual-build', 'true');
$ConfModules[3]->setOption('repository', 'kde:qt');

# This test must be performed to get the test after to pass, due to differences in each
# code path leading to one having build_obj still undef.
is($ConfModules[3]->buildSystemType(), $conf_modules[3]->buildSystemType(), 'Qt build systems load right.');
ok(freeze(\@conf_modules) eq freeze(\@ConfModules), 'read_options module reading');

# Test resume-from options
$ctx->setOption('resume-from', 'kdesrc-build');
my @filtered_modules = applyModuleFilters($ctx, @conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[1..$#ConfModules]], 'resume-from under module-set');

$ctx->setOption('resume-from', 'kde-runtime');
@filtered_modules = applyModuleFilters($ctx, @conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[2..$#ConfModules]], 'resume-from under module-set, not first module in set');

$ctx->setOption('resume-from', 'set1');
@filtered_modules = applyModuleFilters($ctx, @conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[1..$#ConfModules]], 'resume-from a module-set');

$ctx->setOption('resume-after', 'set1');
# Setting both resume-from and resume-after should raise an exception.
$@ = '';
eval {
    @filtered_modules = applyModuleFilters($ctx, @conf_modules);
};
isa_ok($@, 'BuildException', 'resume-{from,after} combine for exception');

$ctx->deleteOption('resume-from');
@filtered_modules = applyModuleFilters($ctx, @conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[3..$#ConfModules]], 'resume-after a module-set');

# Test sub directory creation.
ok(! -d "$testSourceDirName/build", 'Ensure build dir does not exist');
isnt(super_mkdir("$testSourceDirName/build"), 0, 'Make temp build directory');
ok(-d "$testSourceDirName/build", 'Double-check temp build dir created');

# Test log_command callback.
my $flagged = 0;
my $callback = sub {
    $flagged = 1;
    $flagged = 2 if !defined($_[0]);
};

is (log_command($ctx, 'test-callback', ['ls', '-1'], { callback => $callback }), 0, 'Successful return of log_command');
cmp_ok ($flagged, '>', 0, 'log_command actually calls callback');
is ($flagged, 2, 'Test undef was passed at end of execution');

$flagged = 0;
my $lc_all_found = 0;

$callback = sub {
    return if !defined $_[0];
    $flagged      ||= !!/^LC_MESSAGES=C/;
    $lc_all_found ||= !!/^LC_ALL=/;
};

$ENV{'LC_ALL'} = 'en_US.UTF-8';

log_command($ctx, 'test-no_translate-messages', ['/usr/bin/env'], { callback => $callback, no_translate => 1 });
ok ($flagged, 'Verify LC_MESSAGES set if no_translate used');
ok (!$lc_all_found, 'Verify LC_ALL stripped if no_translate used');

# Test isSubdirBuildable
my $tokenModule = ksb::Module->new($ctx, 'test-module');
my $buildSystem = ksb::BuildSystem->new($tokenModule);
ok ($buildSystem->isSubdirBuildable('meh'), 'generic-build isSubdirBuildable');
ok ($buildSystem->createBuildSystem(), 'Ensure createBuildSystem can be called');
ok ($buildSystem->cleanBuildSystem(),  'Ensure cleanBuildSystem can be called');

$buildSystem = ksb::l10nSystem->new($ctx);
ok (!$buildSystem->isSubdirBuildable('scripts'), 'l10n-build isSubdirBuildable-scripts');
ok ($buildSystem->isSubdirBuildable(''), 'l10n-build isSubdirBuildable-other');

# Note to packagers: This assumes qmake or qmake-qt4 are already installed on
# the system.
my @qmakePossibilities = ksb::BuildSystem::QMake::absPathToQMake();
SKIP: {
    is (scalar @qmakePossibilities, 1, 'Ensure exactly one qmake is returned from possibilities.')
        or skip "Need a qmake candidate for next test", 1; # Skip next tests if no qmake
    like ($qmakePossibilities[0], qr/^qmake/, 'qmake candidate looks like a qmake executable.');

    # Duplicate test in scalar context the whole time.
    my $newQMakePossibility = ksb::BuildSystem::QMake::absPathToQMake();
    like ($newQMakePossibility, qr/^qmake/, 'qmake looks like an executable even in scalar context.');
}

do {
    local $ENV{HOME} = "$testSourceDirName"; # Search right spot for kde-env-master.sh
    local $ENV{XDG_CONFIG_HOME} = $testSourceDirName;

    # This test set must be run first as xsession depends on this env-master.
    is(system('/bin/sh', '-n', "$RealBin/sample-kde-env-master.sh"), 0,
        'env-master pre-install syntax check');

    local $ENV{KDESRC_BUILD_TESTING} = 1; # Tell sample-xsession.sh not to run.

    is(system('/bin/sh', '-u', "$RealBin/sample-kde-env-master.sh"), 0,
        'env-master unset variable check');

    # Deliberately after env-master, env-master should have no unset variables if user doesn't set
    # this up.
    ok(File::Copy::copy("$RealBin/sample-kde-env-user.sh", "$testSourceDirName/kde-env-user.sh"),
        'env-user   sample installation');

    # Ensure this function can run without throwing exception.
    ok(installTemplatedFile("$RealBin/sample-kde-env-master.sh", "$testSourceDirName/kde-env-master.sh", $ctx) || 1,
        'env-master template installation');

    is(system('/bin/sh', '-n', "$RealBin/sample-xsession.sh"), 0,
        'xsession   pre-install syntax check');

    ok(File::Copy::copy("$RealBin/sample-xsession.sh", "$testSourceDirName/xsession.sh"),
        'xsession   installation');

    is(system('/bin/sh', '-u', "$RealBin/sample-xsession.sh"), 0,
        'xsession   unset variable check');

    is(system('/bin/sh', '-n', "$testSourceDirName/xsession.sh"), 0,
        'xsession post-install syntax check');
};

open my $testFile, '>', "$testSourceDirName/md5-sample";
print $testFile "sample-vector";
close $testFile;

is(fileDigestMD5("$testSourceDirName/md5-sample"),
    'fe840f4320cfd6e7ce9070756400e42e', 'MD5 file digests');

done_testing();
### TESTS GO ABOVE THIS LINE
}; # eval

if (my $err = $@) {
    if (blessed ($err) && $err->isa('BuildException')) {
        say "Test suite failed after kdesrc-build threw the following exception:";
        say "$@->{message}";
        fail();
    }
    else {
        die; # Re-throw
    }
}

# svn cd'ed on us, switch to a known directory to avoid errors unlinking the
# temporary directory. In an "END" block so this should occur even if we
# exit testing due to failure/exception.
END {
    chdir('/');
    if (!$fullRun) {
        print "The full test suite was not run. To do so, " .
              "pass --full-run when running the tests\n";
    }
}
