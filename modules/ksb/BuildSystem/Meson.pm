package ksb::BuildSystem::Meson 0.10;

use ksb;

=head1 DESCRIPTION

This is a build system used to support configuring with L<Meson|https://mesonbuild.com/>.

Note that Meson requires Ninja as its underlying build system so anything dealing with Meson
can assume Ninja support is present.

Control the flags passed to Meson's setup step using the C<configure-flags> option.

=cut

use parent qw(ksb::BuildSystem);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util qw(:DEFAULT :await run_logged_p);

sub name
{
    return 'meson';
}

# Override
# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::Meson');
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $buildDir = $module->fullpath('build');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @setupOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    return await_exitcode(
        run_logged_p($module, 'meson-setup', $sourcedir, [
            'meson', 'setup', $buildDir,
            '--prefix', $installdir,
            @setupOptions,
        ])
    );
}

# Override
sub supportsAutoParallelism ($self)
{
    return 1; # meson requires ninja so supports this by default
}

# Override
sub buildInternal
{
    my $self = shift;

    return $self->SUPER::buildInternal('ninja-options');
}

# Override
sub buildCommands
{
    return 'ninja';
}

# Override
sub requiredPrograms
{
    return ('meson', 'ninja');
}

# Override
sub configuredModuleFileName
{
    return 'build.ninja';
}

1;
