package ksb::BuildSystem::Qt5 0.10;

# Build system for the Qt5 toolkit

use ksb;

use ksb::BuildException;
use ksb::BuildSystem;
use ksb::Debug;
use ksb::Util qw(:DEFAULT :await run_logged_p);

use parent qw(ksb::BuildSystem);

# OVERRIDE
sub configuredModuleFileName
{
    return 'Makefile';
}

# OVERRIDE
sub name
{
    return 'Qt5';
}

# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, __PACKAGE__);
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');
    my $script = "$srcdir/configure";

    if (! -e $script && !pretending())
    {
        error ("\tMissing configure script for r[b[$module]");
        return 0;
    }

    my @commands = split (/\s+/, $module->getOption('configure-flags'));
    push @commands, qw(-confirm-license -opensource -nomake examples -nomake tests);

    # Get the user's CXXFLAGS
    my $cxxflags = $module->getOption('cxxflags');
    $module->buildContext()->queueEnvironmentVariable('CXXFLAGS', $cxxflags);

    my $prefix = $module->getOption('prefix');
    my $qtdir  = $module->getOption('qtdir');

    if ($prefix && $qtdir && $prefix ne $qtdir) {
        warning (<<EOF);
b[y[*]
b[y[*] Building the Qt module, but the install directory for Qt is not set to the
b[y[*] Qt directory to use.
b[y[*]   install directory ('prefix' option): b[$prefix]
b[y[*]   Qt install to use ('qtdir'  option): b[$qtdir]
b[y[*]
b[y[*] Try setting b[qtdir] to the same setting as the Qt module's b[prefix].
b[y[*]
EOF
    }

    $prefix ||= $qtdir; # Use qtdir for install if prefix not set

    # Some users have added -prefix manually to their flags, they
    # probably shouldn't anymore. :)

    if (grep /^-prefix(=.*)?$/, @commands) {
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

    if(($cur_flags eq $old_flags)          &&
        !$module->getOption('reconfigure') &&
        -e "$builddir/Makefile"
    ) {
        return 1;
    }

    note ("\tb[r[LGPL license selected for Qt].  See $srcdir/LICENSE.LGPL");
    info ("\tRunning g[configure]...");

    $module->setPersistentOption('last-configure-flags', $cur_flags);

    return await_exitcode(run_logged_p($module, "configure", $builddir, \@commands));
}

1;
