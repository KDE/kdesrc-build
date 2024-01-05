# Verify that a user-set CMAKE_PREFIX_PATH is not removed, even if we supply
# "magic" of our own
# See bug 395627 -- https://bugs.kde.org/show_bug.cgi?id=395627

use ksb;

use Test::More;
use POSIX;
use File::Basename;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

my @savedCommand;
my $log_called = 0;

# Redefine log_command to capture whether it was properly called. This is all
# very order-dependent, we need to load ksb::Util before kdesrc-build itself
# does to install the new subroutine before it's copied over into the other
# package symbol tables.
BEGIN {
    use ksb::Util;
    use Mojo::Promise;

    no strict 'refs';
    no warnings 'redefine';

    *ksb::Util::run_logged_p = sub ($module, $filename, $dir, $argRef) {
        $log_called = 1;
        @savedCommand = @{$argRef};
        return Mojo::Promise->resolve(0); # success
    };
}

use ksb::Application;
use ksb::Module;

my @args = qw(--pretend --rc-file t/data/bug-395627/kdesrc-buildrc);

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 6, 'Right number of modules');
    isa_ok ($moduleList[0]->buildSystem(), 'ksb::BuildSystem::KDECMake');

    my $result;
    my @prefixes;
    my $prefix;

    # This requires log_command to be overridden above
    $result = $moduleList[0]->setupBuildSystem();
    is ($log_called, 1, 'Overridden log_command was called');
    ok ($result, 'Setup build system for auto-set prefix path');

    # We should expect an auto-set -DCMAKE_PREFIX_PATH passed to cmake somewhere
    ($prefix) = grep { /-DCMAKE_PREFIX_PATH/ } @savedCommand;
    is ($prefix, '-DCMAKE_PREFIX_PATH=/tmp/qt5', 'Prefix path set to custom Qt prefix');

    $result = $moduleList[2]->setupBuildSystem();
    ok ($result, 'Setup build system for manual-set prefix path');

    (@prefixes) = grep { /-DCMAKE_PREFIX_PATH/ } @savedCommand;
    is (scalar @prefixes, 1, 'Only one set prefix path in manual mode');
    if (@prefixes) {
        is ($prefixes[0], '-DCMAKE_PREFIX_PATH=FOO', 'Manual-set prefix path is as set by user');
    }

    $result = $moduleList[4]->setupBuildSystem();
    ok ($result, 'Setup build system for manual-set prefix path');

    (@prefixes) = grep { /-DCMAKE_PREFIX_PATH/ } @savedCommand;
    is (scalar @prefixes, 1, 'Only one set prefix path in manual mode');
    if (@prefixes) {
        is ($prefixes[0], '-DCMAKE_PREFIX_PATH:PATH=BAR', 'Manual-set prefix path is as set by user');
    }
}

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
