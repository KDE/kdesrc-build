package ksb::BuildSystem::Autotools 0.10;

# This is a module used to support configuring with autotools.

use ksb;

use parent qw(ksb::BuildSystem);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util qw(:DEFAULT run_logged_p);
use Mojo::Promise;

use List::Util qw(first);

sub name
{
    return 'autotools';
}

# Returns a promise that resolves to the specific configure command to use.
#
# This may execute commands to re-run autoconf to generate the script.
#
# If these commands fail the promise will reject.
sub _findConfigureCommands ($self)
{
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');

    my $configureCommand = first { -e "$sourcedir/$_" } qw(configure autogen.sh);
    my $configureInFile  = first { -e "$sourcedir/$_" } qw(configure.in configure.ac);

    if ($configureCommand ne 'autogen.sh' && $configureInFile) {
        return Mojo::Promise->resolve($configureCommand);
    }

    # If we have a configure.in or configure.ac but configureCommand is autogen.sh
    # we assume that configure is created by autogen.sh as usual in some GNU Projects.
    # So we run autogen.sh first to create the configure command and
    # recheck for that.
    if ($configureInFile && $configureCommand eq 'autogen.sh') {
        my $promise = run_logged_p($module, 'autogen', $sourcedir, ["$sourcedir/$configureCommand"])
            ->then(sub ($exitcode) {
                die "Autogen failed with exit code $exitcode"
                    if $exitcode != 0;
            })->then(sub {
                # Cleanup any stray Makefiles that may be present, if generated
                return run_logged_p($module, 'distclean', $sourcedir, [qw(make distclean)])
                    if -e "$sourcedir/Makefile";
                # nothing to do, return successful exit code
                return 0;
            })->then(sub ($exitcode) {
                die "Failed to run make distclean, exit code $exitcode"
                    if $exitcode != 0;
            })->then(sub {
                # Now recheck
                $configureCommand = first { -e "$sourcedir/$_" } qw(configure autogen.sh);
                return $configureCommand;
            });

        return $promise;
    }

    return Mojo::Promise->reject('No configure command available')
        unless $configureCommand;

    return Mojo::Promise->resolve($configureCommand);
}

# Return value style: boolean
sub configureInternal ($self)
{
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $builddir  = $module->fullpath('build');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @bootstrapOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    my $result;
    my $promise = $self->_findConfigureCommands()->then(sub ($configureCommand) {
        p_chdir($module->fullpath('build'));

        return run_logged_p($module, 'configure', $builddir, [
            "$sourcedir/$configureCommand", "--prefix=$installdir",
            @bootstrapOptions
        ]);
    })->then(sub ($exitcode) {
        $result = $exitcode;
    })->catch(sub ($err) {
        error ("\tError configuring $module: r[b[$err]");
        return 0;
    })->wait;

    return $result == 0;
}

1;
