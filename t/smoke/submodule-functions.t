# Test submodule-related features

use ksb;
use Test::More;

use File::Temp qw(tempdir);
use autodie qw(:io);
use IPC::Cmd qw(run);

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
    say $file, "Initial content";
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
    say $file, "Initial content";
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

$result = run(
    command => [qw(git submodule add ../submodule)],
    verbose => 0,
    timeout => 10,
);
ok($result, 'git submodule add worked');

ok(ksb::Updater::Git::_hasSubmodules(), "Submodules detected when they are present");

chdir ('/'); # Allow auto-cleanup
done_testing();
