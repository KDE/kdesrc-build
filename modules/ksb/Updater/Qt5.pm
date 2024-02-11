package ksb::Updater::Qt5 0.10;

use ksb;

=head1 DESCRIPTION

Handles updating Qt 5 source code. Requires git but uses Qt 5's dedicated
'init-repository' script to keep the source up to date and coherent.

=cut

use parent qw(ksb::Updater::Git);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util qw(:DEFAULT :await run_logged_p);

sub name
{
    return 'qt5';
}

# Handles calling init-repository to clone or update the appropriate Qt 5
# submodules.
#
# Returns number of commits updated (or rather, will...)
sub _updateRepository ($self)
{
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');

    if (!pretending() && (! -e "$srcdir/init-repository" || ! -x _)) {
        croak_runtime ("The Qt 5 repository update script could not be found, or is not executable!");
    }

    # See https://wiki.qt.io/Building_Qt_5_from_Git#Getting_the_source_code for
    # why we skip web engine by default. As of 2019-01-12 it is only used for
    # PIM or optionally within Plasma
    my @modules = split(' ', $module->getOption('use-qt5-modules'));
    push @modules, qw(default -qtwebengine)
        unless @modules;

    my $subset_arg = join(',', @modules);

    # -f forces a re-update if necessary
    my @command = ("$srcdir/init-repository", '-f', "--module-subset=$subset_arg");
    note ("\tUsing Qt 5 modules: ", join(', ', @modules));

    my $result = await_exitcode(
        run_logged_p($module, 'init-repository', $srcdir, \@command)
    );

    croak_runtime ("Couldn't update Qt 5 repository submodules!")
        unless $result;

    return 1; # TODO: Count commits
}

# Updates an existing Qt5 super module checkout.
# Throws exceptions on failure, otherwise returns number of commits updated
# OVERRIDE from super class
sub updateExistingClone ($self)
{
    assert_isa($self, __PACKAGE__);

    # Update init-repository and the shell of the super module itself.
    my $promise = $self->SUPER::updateExistingClone();

    # updateRepository has init-repository work to update the source
    $self->_updateRepository();

    return $promise;
}

# Either performs the initial checkout or updates the current git checkout
# for git-using modules, as appropriate.
#
# If errors are encountered, an exception is raised.
#
# Returns the number of *commits* affected.
# OVERRIDE from super class
sub updateCheckout ($self)
{
    assert_isa($self, __PACKAGE__);
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');

    if (-d "$srcdir/.git") {
        # Note that this function will throw an exception on failure.
        return $self->updateExistingClone();
    } else {
        $self->_verifySafeToCloneIntoSourceDir($module, $srcdir);

        $self->_clone($module->getOption('repository'));

        note ("\tQt update script is installed, downloading remainder of Qt");
        note ("\tb[y[THIS WILL TAKE SOME TIME]");

        # With the supermodule cloned, we then need to call into
        # init-repository to have it complete the checkout.
        return $self->_updateRepository(); # num commits
    }
}

1;
