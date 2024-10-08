# SPDX-FileCopyrightText: 2019, 2022, 2023 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Test submodule-related features

use ksb;
use Test::More;

use File::Temp qw(tempdir);
use autodie qw(:io);
use IPC::Cmd qw(run);
use POSIX;
use File::Basename;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

use ksb::Updater::Git;

# Create an empty directory for a git module, ensure submodule-related things
# work without a submodule, then add a submodule and ensure that things remain
# as expected.

my $dir = tempdir(CLEANUP => 1);
chdir ($dir);

# Setup the later submodule
mkdir ('submodule');
chdir ('submodule');

my $result = run(
    command => [qw(git init)],
    verbose => 0,
    timeout => 10,
);
ok($result, "git init worked");

{
    open my $file, '>', 'README.md';
    say $file "Initial content";
    close $file;
}

$result = run(
    command => [qw(git config --local user.name kdesrc-build)],
    verbose => 0,
    timeout => 10,
);
if (!$result) {
    BAIL_OUT("Can't setup git username, subsequent tests will fail");
}

$result = run(
    command => [qw(git config --local user.email kdesrc-build@kde.org)],
    verbose => 0,
    timeout => 10,
);
if (!$result) {
    BAIL_OUT("Can't setup git username, subsequent tests will fail");
}

$result = run(
    command => [qw(git add README.md)],
    verbose => 0,
    timeout => 10,
);
ok($result, "git add file worked");

$result = run(
    command => [qw(git commit -m FirstCommit)],
    verbose => 0,
    timeout => 10,
);
ok($result, "git commit worked");

# Setup a supermodule
chdir ($dir);

mkdir ('supermodule');
chdir ('supermodule');

$result = run(
    command => [qw(git init)],
    verbose => 0,
    timeout => 10,
);
ok($result, "git supermodule init worked");

{
    open my $file, '>', 'README.md';
    say $file "Initial content";
    close $file;
}

$result = run(
    command => [qw(git config --local user.name kdesrc-build)],
    verbose => 0,
    timeout => 10,
);
if (!$result) {
    BAIL_OUT("Can't setup git username, subsequent tests will fail");
}

$result = run(
    command => [qw(git config --local user.email kdesrc-build@kde.org)],
    verbose => 0,
    timeout => 10,
);
if (!$result) {
    BAIL_OUT("Can't setup git username, subsequent tests will fail");
}

$result = run(
    command => [qw(git add README.md)],
    verbose => 0,
    timeout => 10,
);
ok($result, "git supermodule add file worked");

$result = run(
    command => [qw(git commit -m FirstCommit)],
    verbose => 0,
    timeout => 10,
);
ok($result, "git supermodule commit worked");

### Submodule checks

ok(!ksb::Updater::Git::_hasSubmodules(), "No submodules detected when none present");

# git now prevents use of local clones of other git repos on the file system
# unless specifically enabled, due to security risks from symlinks. See
# https://github.blog/2022-10-18-git-security-vulnerabilities-announced/#cve-2022-39253
$result = run(
    command => [qw(git -c protocol.file.allow=always submodule add ../submodule)],
    verbose => 0,
    timeout => 10,
);
ok($result, 'git submodule add worked');

ok(ksb::Updater::Git::_hasSubmodules(), "Submodules detected when they are present");

chdir ('/'); # Allow auto-cleanup

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
