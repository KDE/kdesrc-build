#!/usr/bin/perl
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

package test; # Tells kdesrc-build not to run
require 'kdesrc-build';

# Must come after require kdesrc-build. note will interfere with our debugging
# function, and we don't use it in the test harness anyways.
use Test::More 'no_plan', import => ['!note'];
use File::Temp 'tempdir';

# From kdesrc-build
our %package_opts;
our %ENV_VARS;

# Base directory name to use for any needed filesystem tests.
my $testSourceDirName =
    tempdir('kdesrc-build-test-XXXXXX',
            TMPDIR => 1,   # Force creation under the temporary directory.
            CLEANUP => 1); # Delete temp directory when done.

my %more_package_opts = (
  'qt-copy' => {
      'cxxflags' => '-pipe -march=i386',
      'configure-flags' => '-fast',
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

for my $key (keys %more_package_opts) {
    $package_opts{$key} = $more_package_opts{$key};
}

# If using set-env, it is handled by the handle_set_env routine, so the
# value should be the space separated VAR and VALUE.
set_option('global', 'set-env', 'TESTY_MCTEST yes');
set_option('global', 'cxxflags', '-g -O0');
set_option('global', 'cmake-options', '-DCMAKE_BUILD_TYPE=RelWithDebInfo');
set_option('global', 'svn-server', 'svn+ssh://svn.kde.org/home/kde');
set_option('global', 'configure-flags', '-fast -dbus');
set_option('global', '#configure-flags', '-fast -dbus');
set_option('global', 'source-dir', '~/' . "kdesrc-build-unused");
set_option('global', '#unused', '1');
set_option('global', 'branch', '4.3');

# Commence testing proper
is(get_source_dir(), $ENV{HOME} . "/kdesrc-build-unused", 'Correct tilde-expansion for source-dir');

# We know tilde-expansion works for source-dir, reset to our temp dir.
set_option('global', 'source-dir', $testSourceDirName);
is(get_option('qt-copy', 'cxxflags'), '-pipe -march=i386', 'qt-copy cxxflags handling');
is(get_option('qt-copy', 'configure-flags'), '-fast', 'qt-copy configure-flags handling');
is(get_option('kdelibs', 'unused'), 1, 'Test normal sticky option');
like(get_option('kdelibs', 'cmake-options'), qr/^-DCMAKE_BUILD_TYPE=RelWithDebInfo/, 'kdelibs cmake-options appending');
like(get_option('kdelibs', 'cmake-options'), qr/-DTEST=TRUE$/, 'kdelibs options appending');
is(get_option('test', 'branch', 'module'), undef, 'get_option limit to module level');

set_option('kdelibs', 'branch', 'trunk');
is(svn_module_url('kdelibs'), 'svn+ssh://svn.kde.org/home/kde/trunk/KDE/kdelibs', 'KDE module trunk');

set_option('kdelibs', 'tag', '4.1.3');
set_option('kdelibs', 'branch', '4.2');
like(handle_branch_tag_option('kdelibs', 'tags'), qr(/tags/KDE/4.1.3/kdelibs$), 'KDE module tag preferred to branch');

set_option('kdelibs', 'tag', '');
like(handle_branch_tag_option('kdelibs', 'branches'), qr(/branches/KDE/4.2/kdelibs$), 'KDE module branch');

set_option('kdesupport', 'branch', 'trunk');
set_option('kdesupport', 'svn-server', 'svn://anonsvn.kde.org/home/kde');
# Ensure svn info exists in our source dir. This requires actually accessing
# anonsvn, so use --depth empty and --ignore-externals to minimize load on
# server.
my @svnArgs = (
    qw{svn co
    --depth empty
    --ignore-externals
    svn://anonsvn.kde.org/home/kde/trunk/kdesupport},
    "$testSourceDirName/kdesupport");
is(system(@svnArgs), 0, "Make empty subversion checkout.") or BAIL_OUT('Missing svn checkout capability?');

is(svn_module_url('kdesupport'), 'svn://anonsvn.kde.org/home/kde/trunk/kdesupport', 'non-KDE module trunk');

# Issue reported by dfaure 2011-02-06, where the kdesupport-branch was not being
# obeyed when global-branch was set to 4.6, so somehow kdesrc-build wanted a
# mystical kdesupport-from-4.6 branch
set_option('kdesupport', 'branch', 'master');
set_option('kdesupport', 'prefix', '/d/kde/inst/kdesupport-for-4.6');
set_option('global', 'branch', '4.6');
is(svn_module_url('kdesupport'), 'svn://anonsvn.kde.org/home/kde/branches/kdesupport/master', 'kdesupport-for-$foo with local branch override');

set_option('kdesupport', 'tag', 'kdesupport-for-4.2');
like(handle_branch_tag_option('kdesupport', 'tags'), qr(/tags/kdesupport-for-4.2$), 'non-KDE module tag (no name appended)');
is(svn_module_url('kdesupport'), 'svn://anonsvn.kde.org/home/kde/tags/kdesupport-for-4.2', 'non-KDE module tag (no name; entire URL)');

set_option('phonon', 'branch', '4.2');
is(svn_module_url('phonon'), 'svn+ssh://svn.kde.org/home/kde/branches/phonon/4.2', 'non-KDE module branch (no name appended)');

set_option('phonon', 'branch', '');
set_option('phonon', 'module-base-path', 'tags/phonon/4.2');
is(svn_module_url('phonon'), 'svn+ssh://svn.kde.org/home/kde/tags/phonon/4.2', 'module-base-path');

my @result1 = qw/a=b g f/;
my @quoted_result = ('a=b g f', 'e', 'c=d', 'bless');
is_deeply([ split_quoted_on_whitespace('"a=b g f" "e" c=d bless') ], \@quoted_result, "split_quoted_on_whitespace quotes and spaces");
is_deeply([ split_quoted_on_whitespace('a=b g f') ], \@result1, 'split_quoted_on_whitespace space, no quotes');
is_deeply([ split_quoted_on_whitespace(' a=b g f') ], \@result1, 'split_quoted_on_whitespace space no quotes, leading whitespace');
is_deeply([ split_quoted_on_whitespace('a=b g f ') ], \@result1, 'split_quoted_on_whitespace space no quotes, trailing whitespace');
is_deeply([ split_quoted_on_whitespace(' a=b g f ') ], \@result1, 'split_quoted_on_whitespace space no quotes, leading and trailing whitespace');

like(get_svn_info('kdesupport', 'URL'), qr/anonsvn\.kde\.org/, 'svn-info output (url)');
like(get_svn_info('kdesupport', 'Revision'), qr/^\d+$/, 'svn-info output (revision)');

# Test get_subdir_path
is(get_subdir_path('kdelibs', 'build-dir'),
    "$testSourceDirName/build",
    'build-dir subdir path rel');
is(get_subdir_path('kdelibs', 'log-dir'),
    "$testSourceDirName/log",
    'log-dir subdir path rel');
set_option('kdelibs', 'build-dir', '/tmp');
is(get_subdir_path('kdelibs', 'build-dir'), "/tmp", 'build-dir subdir path abs');
set_option('kdelibs', 'build-dir', '~/tmp/build');
is(get_subdir_path('kdelibs', 'build-dir'), "$ENV{HOME}/tmp/build", 'build-dir subdir path abs');

# correct log dir
print "Creating log directory:\n";
setup_logging_subsystem();
my $logdir = get_log_dir('playground/libs');
ok(log_command('playground/libs', 'touch', ['touch', '/tmp/tmp.tmp']) == 0, 'creating temp file');
ok(-e "$ENV{HOME}/kde4/log/latest/playground/libs/touch.log", 'correct playground/libs log path');
unlink('/tmp/tmp.tmp');

# Trunk and non-trunk l10n
is(svn_module_url('l10n-kde4'), 'svn+ssh://svn.kde.org/home/kde/branches/stable/l10n-kde4', 'stable l10n path');
set_option('global', 'branch', 'trunk');
is(svn_module_url('l10n-kde4'), 'svn+ssh://svn.kde.org/home/kde/trunk/l10n-kde4', 'trunk l10n path');

is(get_source_dir('test'), "$ENV{HOME}/testsrc", 'separate source-dir for modules');
update_module_environment('test');
is($ENV_VARS{'TESTY_MCTEST'}, 'yes', 'setting global set-env for modules');
is($ENV_VARS{'MOIN'}, '2', 'setting module set-env for modules');

# Ensure svn URL hierarchy is correct
like(svn_module_url('test'), qr{/home/kde/KDE/KDE/test$}, 'svn_module_url prefer module specific to global');
set_option('test', 'override-url', 'svn://annono');
is(svn_module_url('test'), 'svn://annono', 'testing override-url');

my @modules = process_arguments('--test,override-url=svn://ann');
is(svn_module_url('test'), 'svn://ann', 'testing process_arguments module options');
is(scalar @modules, 0, 'testing process_arguments return value for no passed module names');

@modules = qw/qt-copy kdelibs kdebase/;
my @defaultPhases = Module->phases();
my @Modules = map { Module->new($_) } (@modules);

# Ensure functions like updateModulePhases doesn't change the objects we pass in.
my @backupModuleCopy = @{Storable::dclone(\@Modules)};

# Should be no change if there are no manual-update, no-src, etc. in the rc file
# so force one of those on.
set_option('kdelibs', 'no-build', 1);
my @phaseFilteredModules = updateModulePhases(@Modules);
is_deeply(\@Modules, \@backupModuleCopy, 'Ensure objects not modified through references to them');
delete $package_opts{'kdelibs'}->{'manual-update'};

# Now test --no-src/--no-build/etc.
is_deeply([process_arguments(@modules)], \@Modules, 'testing process_arguments return value for passed module names');

$_->filterOutPhase('update') foreach @Modules;
is_deeply([process_arguments(@modules, '--no-src')], \@Modules, 'testing --no-src phase updating');

# Reset Module package's default phases
Module->setPhases(@defaultPhases);
Module->filterOutPhase('test'); # This would change based on run-tests

# Reported by Kurt Hindenburg (IIRC). Passing --no-src would also disable the
# build (in updateModulesPhases) because of the global '#no-src' being set in
# process_arguments.
my @temp_modules = process_arguments(@modules, '--no-src');
# There should be no module-specific no-src/no-build/manual-update/etc. set.
is_deeply([updateModulePhases(@temp_modules)], \@temp_modules, 'updateModulePhases only for modules');

Module->setPhases(@defaultPhases);
@Modules = map { Module->new($_) } (@modules);
$_->filterOutPhase('build') foreach @Modules;

# Test only --no-build
is_deeply([process_arguments(@modules, '--no-build')], \@Modules, 'testing --no-build phase updating');

# Reset Module package's default phases
Module->setPhases(@defaultPhases);

$_->filterOutPhase('update') foreach @Modules;
is_deeply([process_arguments(@modules, '--no-build', '--no-src')], \@Modules, 'testing --no-src and --no-build phase updating');

# Reset
delete @package_opts{grep { $_ ne 'global' } keys %package_opts};
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

module qt-copy
    configure-flags -fast
end module
EOF
open my $fh, '<', \$conf;

# Read in new options
my @conf_modules = read_options($fh);
is(get_option('qt-copy', 'configure-flags'), '-fast', 'read_options/parse_module');
is(get_option('kdelibs', 'repository'), 'kde:kdelibs', 'git-repository-base');

my @ConfModules = map { Module->new($_) }(qw/kdelibs kdesrc-build kde-runtime qt-copy/);
$ConfModules[1] = Module->new('kdesrc-build', 'proj'); # This should be a kde_projects.xml
$ConfModules[2] = Module->new('kde-runtime', 'proj');  # This should be a kde_projects.xml
$ConfModules[1]->setModuleSet('set1');
$ConfModules[2]->setModuleSet('set1');
is_deeply(\@conf_modules, \@ConfModules, 'read_options module reading');

# Test resume-from options
set_option('global', 'resume-from', 'kdesrc-build');
my @filtered_modules = applyModuleFilters(@conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[1..$#ConfModules]], 'resume-from under module-set');

set_option('global', 'resume-from', 'kde-runtime');
@filtered_modules = applyModuleFilters(@conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[2..$#ConfModules]], 'resume-from under module-set, not first module in set');

set_option('global', 'resume-from', 'set1');
@filtered_modules = applyModuleFilters(@conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[1..$#ConfModules]], 'resume-from a module-set');

set_option('global', 'resume-after', 'set1');
# Setting both resume-from and resume-after should raise an exception.
$@ = '';
eval {
    @filtered_modules = applyModuleFilters(@conf_modules);
};
isa_ok($@, 'BuildException', 'resume-{from,after} combine for exception');

delete $package_opts{'global'}->{'resume-from'};
@filtered_modules = applyModuleFilters(@conf_modules);
is_deeply(\@filtered_modules, [@ConfModules[3..$#ConfModules]], 'resume-after a module-set');

# Test sub directory creation.
ok(! -d "$testSourceDirName/build", 'Ensure build dir does not exist');
isnt(super_mkdir("$testSourceDirName/build"), 0, 'Make temp build directory');
ok(-d "$testSourceDirName/build", 'Double-check temp build dir created');

# svn cd'ed on us, switch to a known directory to avoid errors unlinking the
# temporary directory.
chdir('/');
