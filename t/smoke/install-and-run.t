# Test install and ability to run a simple status command w/out Perl failures

use ksb;
use Test::More;

use Cwd;
use IPC::Cmd;

# Assume we're running directly for git source root, as required for rest of
# test suite.

ok(-d "t", 'Test directory in right spot');
ok(-f "kdesrc-build", 'kdesrc-build script in right spot');

# This test can't pass from an installed kdesrc-build, unless user goes out of
# their way to move files around or establish a broken module layout. If this
# passes, we should be able to assume we're running from a git source dir
ok(-f "modules/ksb/Version.pm", 'kdesrc-build modules found in git-src');

# Make sure kdesrc-build can still at least start when run directly
my $result = system('./kdesrc-build', '--version', '--pretend');
is($result >> 8, 0, 'Direct-run kdesrc-build works');

use File::Temp ();

Test::More::note('Installing kdesrc-build to simulate running from install-dir');

my $tempInstallDir = File::Temp->newdir();
mkdir ("$tempInstallDir/bin") or die "Couldn't make fake bin dir! $!";

my $curdir = getcwd();
symlink("$curdir/kdesrc-build", "$tempInstallDir/bin/kdesrc-build");

# Ensure a direct symlink to the source directory of kdesrc-build still works
{
    local $ENV{PATH} = "$tempInstallDir/bin:" . $ENV{PATH};

    my $output = `kdesrc-build --version --pretend`;
    ok($output =~ /^kdesrc-build \d\d\.\d\d \(v\d\d/, '--version for git-based version is appropriate');

    die "kdesrc-build is supposed to be a symlink! $!"
        unless -l "$tempInstallDir/bin/kdesrc-build";
    die "Couldn't remove kdesrc-build symlink, will conflict with install! $!"
        unless unlink ("$tempInstallDir/bin/kdesrc-build");
}

# Ensure the installed version also works.
# TODO: Use manipulation on installed ksb::Version to ensure we're seeing right
# output?
{
    my $tempBuildDir = File::Temp->newdir();
    chdir ("$tempBuildDir") or die "Can't cd to build dir $!";

    # Use IPC::Cmd to capture (and ignore) output. All we need is the exit code
    my ($buildResult, $errMsg) = IPC::Cmd::run(
        command => [
            'cmake', "-DCMAKE_INSTALL_PREFIX=$tempInstallDir", "-DBUILD_doc=OFF", $curdir
        ],
        verbose => 0,
        timeout => 60);
    die "Couldn't run cmake! $errMsg"
        unless $buildResult;

    $buildResult = system ('make');
    die "Couldn't run make! $buildResult"
        if ($buildResult == -1 || ($buildResult >> 8) != 0);

    $buildResult = system ('make install');
    die "Couldn't install! $buildResult"
        if ($buildResult == -1 || ($buildResult >> 8) != 0);

    # Ensure newly-installed version is first in PATH
    local $ENV{PATH} = "$tempInstallDir/bin:" . $ENV{PATH};

    # Ensure we don't accidentally use the git repo modules/ path when we need to use
    # installed or system Perl modules
    local $ENV{PERL5LIB}; # prove turns -Ilib into an env setting

    my $output = `kdesrc-build --version --pretend`;
    ok($output =~ /^kdesrc-build \d\d\.\d\d\n?$/, '--version for installed version is appropriate');

    chdir($curdir);
}

done_testing();
