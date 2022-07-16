package ksb::BuildSystem::CMakeBootstrap 0.10;

use ksb;

=head1 DESCRIPTION

This is a module used to do only one thing: Bootstrap CMake onto a system
that doesn't have it, or has only an older version of it.

=cut

use parent qw(ksb::BuildSystem);

use ksb::Debug;
use ksb::Util qw(run_logged_p);

sub name
{
    return 'cmake-bootstrap';
}

sub requiredPrograms
{
    return qw{c++ make};
}

# Return value style: boolean
sub configureInternal ($self)
{
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @bootstrapOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    my $builddir = $module->fullpath('build');
    my $result;
    my $promise = run_logged_p(
        $module, 'cmake-bootstrap', [
            "$sourcedir/bootstrap", "--prefix=$installdir",
            @bootstrapOptions
        ]
    )->then(sub ($exitcode) {
        $result = ($exitcode == 0);
    });

    $promise->wait;
    return $result;
}

1;
