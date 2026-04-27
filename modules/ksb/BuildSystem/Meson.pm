# SPDX-FileCopyrightText: 2019, 2022 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

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

    my @commands = ('meson', 'setup', $buildDir, '--prefix', $installdir, @setupOptions);

    my $old_options = $module->getPersistentOption('last-meson-options') || '';
    my $new_digest = get_list_digest(@commands);
    my $alreadyConfigured = -e "$buildDir/meson-private/build.dat";

    if ($alreadyConfigured
        && $old_options eq $new_digest
        && !$module->getOption('reconfigure'))
    {
        # Nothing changed; skip running meson setup. Ninja will re-invoke meson
        # to regenerate as needed (including after a meson upgrade), which
        # avoids tripping over a build.dat written by an older meson version.
        whisper ("\tSkipping meson setup, build dir is already configured");
        return 1;
    }

    if ($alreadyConfigured) {
        # Force regeneration so changed configure-flags take effect (and to
        # refresh a build.dat left behind by an older meson).
        splice @commands, 3, 0, '--reconfigure';
    }

    $module->setPersistentOption('last-meson-options', $new_digest);

    return await_exitcode(
        run_logged_p($module, 'meson-setup', $sourcedir, \@commands)
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
