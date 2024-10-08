<!--
SPDX-FileCopyrightText: 2012 Michael Pyne <mpyne@kde.org>
SPDX-License-Identifier: CC-BY-4.0
-->

# Module list construction

An overview of the steps performed in constructing the module list:

There are two parallel flows performed for module list construction

1. Configuration file module list processing. The configuration file supports
modules of various types along with module-sets. Modules of the kde-project
type (available *only* from a module-set) can be converted later into 0, 1, or
more git modules. Modules are formed into the list in the order given in the
configuration file, but any modules implictly pulled in from the kde-project
modules will be sorted appropriately by repo-metadata/dependencies.

2. Modules can be directly specified on the command line. kde-projects modules
can be forced by preceding the module name with a '+'.

After processing command line module names, any modules that match a module
(or module-set) given from the configuration file will have the configuration
file version of that module spliced into the list to replace the command line
one.

So a graphical overview of configuration file modules

>    git, setA/git, setA/git, setA/git, setB/proj

which is proj-expanded to form (for instance)

>    git, setA/git, setA/git, setA/git, setB/git, setB/git

and is then filtered (respecting --resume-{from,after})

>    setA/git, setA/git, setA/git, setB/git, setB/git

(and even this leaves out some details, e.g. l10n).

Command-line modules:

kdesrc-build also constructs a list of command-line-passed modules. Since the
module names are read before the configuration file is even named (let alone
read) kdesrc-build has to hold onto the list until much later in
initialization before it can really figure out what's going on with the
command line. So the sequence looks more like:

> nameA/??, nameB/??, +nameC/??, nameD/??

Then + names are forced to be proj-type

> nameA/??, nameB/??, nameC/proj, nameD/??

From here we "splice" in configuration file modules that have matching names
to modules from the command line.

> nameA/??, nameB/git, nameC/proj, nameD/??

Following this we run a filter pass to remove whole module-sets that we don't
care about (as the applyModuleFilters function cares only about
$module->name(). In this example nameA happened to match a module-set name
only.

> nameB/git, nameC/proj, nameD/??

Finally we match and expand potential module-sets

> nameB/git, nameC/proj, nameE/proj, nameF/proj

Not only does this expansion try to splice in modules under a named
module-set, but it forces each module that doesn't already have a type into
having a 'proj' type but with a special "guessed name" annotation, which is
used later for proj-expansion.

At this point we should be at the same point as if there were no command-line
modules, just before we expand kde-projects modules (yes, this means that the
--resume-* flags are checked twice for this case). At this point there is a
separate pass to ensure that all modules respect the --no-{src,build,etc.}
options if they had been read from the command line, but that could probably
be done at any time and still work just fine.

One other nuance is that if _nameD/??_ above had *not* actually been part of a
module-set and was also not the name of an existing kde-project module, then
trying to proj-expand it would have resulted in an exception being thrown
(this is where the check for unknown modules occurs).
