use v5.22;
use warnings;

# Ensure that the custom-build-command can at least make it to the
# $module->runPhase_p() portion when no build system can be auto-detected.

use ksb::Application;
use ksb::Module;
use ksb::BuildSystem;
use ksb::Debug qw();

use Test::More;

use Mojo::Promise;

package ksb::Module {
    no warnings 'redefine';

    our $testSucceeded = 0;

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

# Mock override
    sub runPhase_p {
        my ($self, $phase) = @_;
        $testSucceeded = 1;
        return Mojo::Promise->new->resolve({was_successful => 1});
    }
};

package ksb::BuildSystem {
    no warnings 'redefine';

    use Test::More import => [qw(is)];

# Mock override
    sub buildInternal {
        my $self = shift;

        is($self->name(), 'generic', 'custom-build-system is generic unless overridden');

        return { was_successful => 1, warnings => 0, };
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

    my $optsAndSelectors = ksb::Application::readCommandLineOptionsAndSelectors(@args);
    my @selectors = $app->establishContext($optsAndSelectors);
    my $workload  = $app->modulesFromSelectors(@selectors);
    my @moduleList = @{$workload->{selectedModules}};

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
    $module->build()->wait;

    is ($ksb::Module::testSucceeded, 1, "Made it to buildInternal()");
}

done_testing();
