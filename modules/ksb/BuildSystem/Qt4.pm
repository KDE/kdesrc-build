package ksb::BuildSystem::Qt4 0.10;

use ksb;

=head1 DESCRIPTION

Build system for the Qt4 toolkit.  It actually works for Qt6 qtbase as well
because of how simple it is but don't tell anyone that.

=cut

use parent qw(ksb::BuildSystem);

use ksb::Debug;
use ksb::Util;

sub needsInstalled
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::Qt4');
    my $module = $self->module();
    return $module->getOption('qtdir') ne $module->fullpath('build');
}

sub name
{
    return 'Qt';
}

sub needsBuilddirHack
{
    return 1;
}

# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::Qt4');
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');
    my $script = "$srcdir/configure";

    if (! -e $script && !pretending())
    {
        error ("\tMissing configure script for r[b[$module]");
        return 0;
    }

    my @commands = split (/\s+/, $module->getOption('configure-flags'));
    push @commands, '-confirm-license', '-opensource';

    # Get the user's CXXFLAGS
    my $cxxflags = $module->getOption('cxxflags');
    $module->buildContext()->queueEnvironmentVariable('CXXFLAGS', $cxxflags);

    my $prefix = $module->getOption('qtdir');

    if (!$prefix)
    {
        error ("\tThe b[qtdir] option must be set to determine where to install r[b[$module]");
        return 0;
    }

    # Some users have added -prefix manually to their flags, they
    # probably shouldn't anymore. :)

    if (scalar grep /^-prefix(=.*)?$/, @commands)
    {
        warning (<<EOF);
b[y[*]
b[y[*] You have the y[-prefix] option selected in your $module configure flags.
b[y[*] kdesrc-build will correctly add the -prefix option to match your Qt
b[y[*] directory setting, so you do not need to use -prefix yourself.
b[y[*]
EOF
    }

    push @commands, "-prefix", $prefix;
    unshift @commands, $script;

    my $builddir = $module->fullpath('build');
    my $old_flags = $module->getPersistentOption('last-configure-flags') || '';
    my $cur_flags = get_list_digest(@commands);

    if(($cur_flags ne $old_flags) ||
       ($module->getOption('reconfigure')) ||
       (! -e "$builddir/Makefile")
      )
    {
        note ("\tb[r[LGPL license selected for Qt].  See $srcdir/LICENSE.LGPL");

        info ("\tRunning g[configure]...");

        $module->setPersistentOption('last-configure-flags', $cur_flags);

        my $result;
        my $promise = run_logged_p($module, "configure", $builddir, \@commands);
        $promise = $promise->then(sub ($exitcode) {
            $result = ($exitcode == 0);
        });

        $promise->wait;

        return $result;
    }

    # Skip execution of configure.
    return 1;
}

1;
