package ksb::ModuleSet::Qt 0.10;

# Class: ModuleSet::Qt
#
# This represents a collection of Qt5 source code modules that are collectively
# kept up to date by Qt's init-repository script. This module set is
# essentially used to make sure that generated ksb::Modules use proper scm()
# and buildSystems()
#
# Use of this module-set is controlled by the 'repository' option being set to
# the magic value 'qt-projects', just as 'kde-projects' is used for KDE.

use ksb;

use parent qw(ksb::ModuleSet);

use ksb::BuildContext;
use ksb::BuildException;
use ksb::BuildSystem::Qt5;
use ksb::Debug;
use ksb::Module;
use ksb::Util;

sub _makeQt5Module
{
    my $self = assert_isa(shift, __PACKAGE__);
    my $ctx  = assert_isa(shift, 'ksb::BuildContext');

    my $newModule = ksb::Module->new($ctx, 'Qt5');

    $self->_initializeNewModule($newModule);

    # Repo URL to the Qt5 "supermodule" that contains the documented
    # init-repository script.
    # See https://wiki.qt.io/Building_Qt_5_from_Git
    $newModule->setOption('repository', 'https://invent.kde.org/qt/qt/qt5.git');
    $newModule->setScmType('qt5');
    $newModule->setBuildSystem(ksb::BuildSystem::Qt5->new($newModule));

    # Convert the use-modules/ignore-modules entries into a form appropriate
    # for init-repository's module-subset option.
    my @modEntries = ($self->modulesToFind(), map { "-$_" } $self->modulesToIgnore());
    $newModule->setOption('use-qt5-modules', join(' ', @modEntries));

    return $newModule;
}

# This function should be called after options are read and build metadata is
# available in order to convert this module set to a list of ksb::Module.
#
# In our case, we will return ONLY ONE MODULE. That module will handle "sub
# modules" via the init-repository script so from kdesrc-build's perspective it
# is handled as a single unit.
#
# OVERRIDE from super class
sub convertToModules
{
    my ($self, $ctx) = @_;
    return $self->_makeQt5Module($ctx);
}

1;
