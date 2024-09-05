<!--
SPDX-FileCopyrightText: 2018 Michael Pyne <mpyne@kde.org>
SPDX-License-Identifier: CC-BY-4.0
-->

# ksb::Module

## DESCRIPTION

This is ksb::Module, one of the core classes within kdesrc-build. It represents
any single "buildable" module that kdesrc-build can manage. It acts as a common
interface to the multiple types of build systems and source control management
systems that kdesrc-build supports.

The many options available to the user are managed using setOption/getOption
(but see also the ksb::OptionsBase class that this derives from).

kdesrc-build manages persistent metadata for each module as well, see
{set,get}PersistentOption

## METHODS

The basic description of each method is listed here for ease of reference. See
the source code itself for more detail.

### Perl integration

These functions are used to integrate into the Perl runtime or for use from
other Perl modules.

* ``new``, creates a new ksb::Module, and sets any provided options.

* ``toString``, for "stringifying" a module into a quoted string.

* ``compare``, for sorting ksb::Modules amongst each other based on name.

### CONFIGURATION

These functions are used to configure what the ksb::Module object should do,
change settings, etc.

* ``setModuleSet``, optional, specifies the ksb::ModuleSet this module was
  spawned from.

* ``setScmType``, sets the source control plugin (git, kde-projects) based
  on the given scmType name. Normally auto-detection is used instead, this
  permits manual setup.

* ``buildSystemFromName``, as with ``setScmType``, used to manually set the
  build system plugin. This is exposed to the user as *override-build-system*.

* ``setBuildSystem``, like ``buildSystemFromName``, but passes the proper
  ksb::BuildSystem directly.

* ``setOption``, sets a configuration option that can be checked later using
  getOption.  Normally set from user input (cmdline or rc-file) but supports
  ways for kdesrc-build to internally override user settings or set hidden
  flags for action in later phases. Does not survive beyond the current
  execution.

* ``setPersistentOption``, sets an option to a string value that will be
  read-in again on the next kdesrc-build run and can then be queried again.

* ``unsetPersistentOption``, removes an existing persistent option.

### INTROSPECTION

These functions are generally just read-only accessors of information about the
object.

#### BASIC INFORMATION

* ``name``, returns the module name. Only one module with a given name can be
  present during a build.

* ``buildContext``, returns the ksb::BuildContext (as set when the object
  was constructed)

* ``phases``, returns the list of execution phases (update, buildsystem, test,
  etc.) that apply to this module in this execution.

* ``moduleSet``, returns the ksb::ModuleSet that was assigned earlier as the
  source set. If no module set was assigned, returns a valid (but null) set.

#### PLUGIN HANDLERS

* ``scm``, **autodetects** the appropriate scm plugin if not already done (or
  manually set), and then returns the ksb::Updater plugin.

* ``buildSystem``, **autodetects** the appropriate build system plugin if not
  already done (or manually set) and then returns the
  ksb::BuildSystem|ksb/BuildSystem.pm plugin.

* ``scmType``, returns the **name** of the scm plugin (as determined by
  scm(), which can itself cause an autodetection pass.

* ``buildSystemType``, returns the **name** of the build system plugin (as
  determined by buildSystem(), which can itself cause an autodetection pass.

* ``currentScmRevision``, returns a string with an scm-specific revision ID.
  Can be a Git-style SHA or something else entirely.
  Can case an autodetection of the scm plugin.

#### PATHS

Various path-handling functions. These aren't always easy to tell what they do
just from the method name, sadly.

* ``getSubdirPath``, maps a path from the rc-file (based on the option-name to
  pass to getOption) to a potential absolute path (handling tilde expansion
  and relative paths). Does not handle colon-separated paths.

* ``getInstallPathComponents``, returns information about the directory the
  module should be installed to. See the detailed docs for this method at its
  decl, but generally you can just call fullpath today.

* ``getSourceDir``, returns absolute base path to the source directory (not
  including dest-dir, module name, or anything else specific to this module).

* ``getLogDir``, returns the base path to use for logs for this module during
  this execution. **NOTE** Different modules can have different base paths.

* ``getLogPath``, returns the absolute filename to open() for a log file for
  this module based on the given basename. Updates the 'latest' symlink, which
  can trigger clean up of old log dirs after all modules are built. Only use
  when you're really going to open a log file!

* ``fullpath``, returns the absolute full path to the source or build
  directory, including any module name or dest-dir accoutrement. This is the
  directory you can git-clone to, cd to for build, etc.

* ``destDir``, returns the 'dest-dir' for the module. dest-dir is effectively
  just a way to modify the on-disk module name. It used to be used more heavily
  to allow for having multiple build/source directories for a given
  module (varying by branch or tag), but even with git this value may change
  for KDE-based repositories to set subdirectories that match KDE project
  paths. Supports expanding '$MODULE' or '${MODULE}' sequences to what
  otherwise would have been the dest-dir.

* ``installationPath``, as labeled on the tin. Prefers the 'prefix' option but
  falls back to 'install-dir' if not set.

#### USER AND PERSISTENT OPTIONS

* ``getOption``, returns the value of the given named option. If no such option
  exists, inherits the same value from the module's build context. If no such
  option exists there either, returns an empty string. Option values are used
  by this function only exist during this script's execution. There is magic to
  permit build jobs that run in a subprocess to feed option changes back to the
  parent process.

  * accepts an option name, normally as set in the rc-file. Can also accept a
    second parameter 'module', to prevent falling back to a global option.
    However doing this also permits ``undef`` to be returned so you must check
    whether the result is defined.

  * Options starting with '#' can only be set internally (i.e. not from rc-file
    or cmdline) so this can be used as a way to tag modules with data meant not
    to be user-accessible...  but this should probably be factored into a
    dedicated parallel option stack.

  * The combination of module-specific and global options also contains a wee
    bit of magic to control things like whether option values combine
    ("$global-value $module-value" style) or whether a module setting
    completely masks a global setting.

* ``getPersistentOption``, similar to ``getOption``, only without the
  module/global magic and the append/mask magic, and the subprocess-support
  magic. But this function can return options that have been set in a previous
  kdesrc-build run. kdesrc-build uses the location of the rc-file to determine
  where to look for data from prior runs.

#### KDE-SPECIFIC HANDLERS

* ``fullProjectPath``, returns the logical module path in the git.kde.org
  infrastructure for the module, if it's defined from a kde-projects module
  set.  E.g. for the 'juk' module, would return 'kde/kdemultimedia/juk'.

* ``isKDEProject``, returns true if the module was sourced from the special
  ``kde-projects`` module set in the user's rc-file. In this case the module's
  ``moduleSet()`` function should return a ksb::ModuleSet that is-a
  ksb::ModuleSet::KDEProjects.

### OPERATIONS

* ``update``, which executes the update (or pretends to do so) using the
  appropriate source control system and returns a true/false value reflecting
  success.  Note this can also throw exceptions and future code is moving more
  to this mode of error-handling.

* ``build``, which executes the build **and** install (or pretends to in pretend
  mode) using the appropriate build system and returns a true/false value
  reflecting success. Can also run the testsuite as part of the build. Note
  this can also throw exceptions and future code is moving more to this as the
  error-handling mechanism.

* ``setupBuildSystem``, which sets up the build system for the module to permit
  ``build`` to work, including creating build dir, running cmake/configure/etc.
  as appropriate. It is called automatically but will not take any action if
  the build system is already established.

* ``install``, which installs (or pretends to install) the module. Called
  automatically by ``build``.

* ``uninstall``, which uninstalls (or pretends to uninstall) the module. Not
  normally called but can be configured to be called.

* ``applyUserEnvironment``, this adds ``set-env`` module-specific environment
  variable settings into the module's build context, called by
  ``setupEnvironment``. This is needed since $ENV is not actually updated by
  ksb::BuildContext until after a new child process is ``fork``'ed.

* ``setupEnvironment``, called by the kdesrc-build build driver, running in a
  subprocess, before calling the appropriate update/build/install etc. method.

* ``getPostBuildMessages``, which returns a list of messages intended to be shown
  to the user at the end of the build because they are so important that they should
  not be missed. These should be used lightly, if at all.

* ``addPostBuildMessage``, which pairs with ``getPostBuildMessages`` to add a message
  to show to the user at the end of the build.
