# Ensure that the custom-build-command can at least make it to the
# $module->buildInternal() portion when no build system can be auto-detected.

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;
use ksb::Module;
use ksb::BuildSystem;
use ksb::Debug qw();

my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log

package ksb::Module {
    no warnings 'redefine';

# Mock override
    sub update {
        my $self = shift;

        is("$self", $self->name(), "We're a real ksb::Module");
        ok(!$self->pretending(), "Test makes no sense if we're pretending");
        return 0; # shell semantics
    }

# Mock override
    sub install {
        my $self = shift;
    }
};

package ksb::BuildSystem {
    no warnings 'redefine';

    our $testSucceeded = 0;

    use Test::More import => [qw(is)];

# Mock override
    sub buildInternal {
        my $self = shift;

        is($self->name(), 'generic', 'custom-build-system is generic unless overridden');
        $testSucceeded = 1;

        return { was_successful => 1 };
    }

# Mock override
    sub needsRefreshed {
        return "";
    }

# Mock override
    sub createBuildSystem {
        return 1;
    }

# Mock override
    sub configureInternal {
        return 1;
    }
};

my @args = qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc --no-metadata
              --custom-build-command echo --override-build-system generic);
{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 4, 'Right number of modules');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');

    my $module = $moduleList[0];
    is ($module->getOption('custom-build-command'), 'echo', 'Custom build command setup');
    is ($module->getOption('override-build-system'), 'generic', 'Custom build system required');

    ok (defined $module->buildSystem(), 'module has a buildsystem');

    # Don't use ->isa because we want this exact class
    is (ref $module->buildSystem(), 'ksb::BuildSystem');

    # Disable --pretend mode, the build/install methods should be mocked and
    # harmless and we won't proceed to buildInternal if in pretend mode
    # otherwise.
    ksb::Debug::setPretending(0);
    $module->build();

    is ($ksb::BuildSystem::testSucceeded, 1, "Made it to buildInternal()");
}

my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section

done_testing();
