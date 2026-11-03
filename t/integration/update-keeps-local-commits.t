# SPDX-FileCopyrightText: 2026 David Faure <faure@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Test that updating a git module fast-forwards its branch, and doesn't lose
# local commits made on it.

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

use ksb::Application;
use ksb::IPC::Null;

sub git (@args)
{
    my ($ok, $err, $full) = run(command => ['git', @args], verbose => 0, timeout => 10);
    BAIL_OUT("git @args failed: " . join('', @$full))
        unless $ok;
}

sub gitOutput (@args)
{
    my ($ok, $err, $full, $stdout) = run(command => ['git', @args], verbose => 0, timeout => 10);
    BAIL_OUT("git @args failed: " . join('', @$full))
        unless $ok;
    my $out = join('', @$stdout);
    chomp $out;
    return $out;
}

sub commitFile ($name)
{
    open my $file, '>', $name;
    say $file "content of $name";
    close $file;
    git('add', $name);
    git('commit', '-q', '-m', "Add $name");
}

my $dir = tempdir(CLEANUP => 1);
my $upstream = "$dir/upstream";
my $srcdir = "$dir/src";
my $origDir = POSIX::getcwd();

mkdir $upstream;
chdir $upstream;
git(qw(init -q -b master));
git(qw(config --local user.name kdesrc-build));
git(qw(config --local user.email kdesrc-build@kde.org));
commitFile('first');

mkdir $srcdir;
git('clone', '-q', $upstream, "$srcdir/testmodule");
chdir "$srcdir/testmodule";
git(qw(config --local user.name kdesrc-build));
git(qw(config --local user.email kdesrc-build@kde.org));

my $rcFile = "$dir/kdesrc-buildrc";
{
    open my $rc, '>', $rcFile;
    print $rc <<EOF;
global
    source-dir $srcdir
    build-dir $dir/build
    log-dir $dir/log
end global

module testmodule
    repository $upstream
end module
EOF
    close $rc;
}

chdir $origDir;
my $app = ksb::Application->new('--rc-file', $rcFile);
my ($module) = $app->modules();
is("$module", 'testmodule', 'Module was read from the rc-file');
my $ipc = ksb::IPC::Null->new();
$module->scm()->{ipc} = $ipc;

my $updateError;
sub updateModule ()
{
    chdir $module->fullpath('source');
    git(qw(fetch -q origin));
    my $ok;
    $updateError = '';
    $module->scm()->_updateToRemoteHead('origin', 'master')
        ->then(sub ($result) { $ok = $result; }, sub ($error) { $ok = 0; $updateError = "$error"; })
        ->wait;
    return $ok;
}

# A real git failure must fail the update.
chdir $upstream;
commitFile('second');
chdir $module->fullpath('source');
my $before = gitOutput(qw(rev-parse HEAD));
{
    # An untracked file where upstream adds one makes only the merge fail.
    # Artificial: the real update stashes untracked files first.
    open my $file, '>', 'second';
    close $file;
}
ok(!updateModule(), 'Update fails when git cannot fast-forward');
like($updateError, qr/Unable to fast-forward/, 'Update failed in the fast-forward');
unlink 'second';
is(gitOutput(qw(rev-parse HEAD)), $before, 'Branch was not changed by the failed update');
ok(!defined $ipc->receiveMessage(), 'No local-commits message for a git failure');

# Behind upstream only: fast-forward.
ok(updateModule(), 'Update of a branch behind upstream succeeds');
is(gitOutput(qw(rev-parse HEAD)), gitOutput(qw(rev-parse origin/master)), 'Branch was fast-forwarded');
ok(!defined $ipc->receiveMessage(), 'No post-build message after a fast-forward');

# Local commit, nothing new upstream: nothing to do.
commitFile('local');
my $localCommit = gitOutput(qw(rev-parse HEAD));
ok(updateModule(), 'Update of a branch ahead of upstream succeeds');
is(gitOutput(qw(rev-parse HEAD)), $localCommit, 'Branch ahead of upstream was kept');
ok(!defined $ipc->receiveMessage(), 'No post-build message when only ahead of upstream');

# Local commit, and upstream moved on: the local commit must survive.
chdir $upstream;
commitFile('third');
ok(updateModule(), 'Update of a branch with local commits does not fail the build');
is(gitOutput(qw(rev-parse HEAD)), $localCommit, 'Local commit was kept');
like($ipc->receiveMessage() // '', qr/was not updated/, 'User is told the module was not updated');

chdir $origDir;

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
