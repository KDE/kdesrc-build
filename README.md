# kdesrc-build

This script is intended to help streamline the process of setting up and
maintaining a KDE development environment for contributors to KDE community
software.

It does this by automating the process of downloading source code from the
KDE source code repositories, building that source code, and installing it
to your local system.

## Note the Alternatives

NOTICE!

If you are a power user just trying to test the latest KDE releases like [KDE
Plasma 5](https://www.kde.org/plasma-desktop) or the [KDE
Applications](https://www.kde.org/applications/) then there are potentially
easier options you may wish to consider first. KDE provides a quick-starter
distribution, [KDE neon Developer Edition](https://neon.kde.org/download), and
your favorite distribution may also have <q>bleeding edge</q> packages that may
be easier to try out.

However if you're testing out the latest KDE Frameworks or are involved in
development yourself, you'll probably find it easiest to use kdesrc-build.
Continue on to set how to set it up.

## QUICK HOWTO

1. Setup minimum dependencies

- You must have at least [Perl](https://www.perl.org/get.html) version 5.14
  installed. Most distributions include at least a minimal Perl setup, and
  Perl is also required for some portions of Qt and KDE software builds so it
  is good to have regardless.

- You must have [Git](https://git-scm.com/) installed to download KDE sources
  and kdesrc-build itself. We recommend at least version 2.10.

2. Install kdesrc-build:

- Clone kdesrc-build from git, by running from a terminal:

```shell
$ mkdir -p ~/kdesrc
$ cd ~/kdesrc
$ git clone https://anongit.kde.org/kdesrc-build
$ cd kdesrc-build # kdesrc-build is in this directory
```

- Make sure it works by running:

```shell
$ cd ~/kde/kdesrc-build
$ ./kdesrc-build --version
```

you should see output similar to `kdesrc-build 18.10 (v18.10-20-g1c39943)`.
later we will setup kdesrc-build to keep itself updated automatically.

2. setup kdesrc-build:

- now that kdesrc-build is installed and works, you need to setup kdesrc-build
  to work appropriately on your particular system. do this by running the
  provided setup script to generate the **configuration file**
  (~/.kdesrc-buildrc):

```shell
$ ~/kde/kdesrc-build-setup
```

- Answer the questions given, but do not fret if you don't know what exactly
  you want to build, it is easy to edit the configuration later or just to
  re-run `kdesrc-build-setup` again.

- This script will reference a standard configuration provided as part of the
  kdesrc-build repository that you downloaded earlier. As kdesrc-build
  self-updates these changes will reflect for your configuration as well.

3. Download the KDE project and dependency data:

```shell
$ cd ~/kde/kdesrc-build
$ ./kdesrc-build --metadata-only
```

This will download information describing the KDE source repositories and
their dependencies, which will help kdesrc-build figure out what to build.

kdesrc-build will maintain this automatically, but running this step separately
helps to verify kdesrc-build can properly reach the KDE source repository and
allows the `--pretend` option in the next step to provide more accurate output.

4. Verify kdesrc-build has a good build plan:

```shell
$ cd ~/kde/kdesrc-build
$ ./kdesrc-build --pretend
```

This will have kdesrc-build go through the steps that it would perform, but
without actually doing them. kdesrc-build will do some basic pre-checks in this
stage to ensure that required command-line commands are available, including
`cmake`, `git`, `qmake`, and others.

This is the last good chance to make sure that kdesrc-build is set the way you
want it. If this command gives you a message that all modules were successfully
built, you can move onto the next step.

5. Perform your first build:

```shell
$ cd ~/kde/kdesrc-build
$ ./kdesrc-build --stop-on-failure
```

This will perform the build, completing these steps for every module:

    - Update source code (initial download or later update)
    - Setup build system and configure source code with your options, if needed
    - Perform the build, if needed
    - Install the module

The `--stop-on-failure` flag causes kdesrc-build to stop the first time a
module fails to build, in case there are missing dependencies. If not set,
kdesrc-build would otherwise try to build all the modules even if some fail.

Hopefully everything will go well the first time, and kdesrc-build will be able
to download and build all of the modules that you ask for. :)

## UPGRADING KDESRC-BUILD

Upgrading is simple.

You can delete your old kdesrc-build directory (make sure you don't have any
local changes in there first, or your kdesrc-buildrc file!) and then install
the new version where the old kdesrc-build directory used to be.

In fact, it is recommended to use git to update kdesrc-build itself, so that
kdesrc-build is kept upgraded automatically. This is setup already in the
sample configuration for KF5, where kdesrc-build is configured to update
itself.

One thing to keep in mind when using kdesrc-build to manage keeping itself
up to date is that updates won't take effect until the *next* time you run
kdesrc-build.

You may want to edit your ~/.kdesrc-buildrc to make sure any new
options are included. You should always read the changes for the new version
however, as sometimes there are slight changes in behavior necessary to adapt
to updates in the source repository. If you are running kdesrc-build from its
git repository, you can use the "git log" command from inside the kdesrc-build
source directory to see the latest changes.

You can use the `./kdesrc-build --version` command to ensure that you have
successfully upgraded kdesrc-build.

## SAMPLE CONFIGURATION

A sample configuration file is included for demonstration purposes. You could
copy it to your `~/.kdesrc-buildrc` and edit, but you should use the provided
`kdesrc-build-setup` script instead.

## UPDATES

You can find updated versions of kdesrc-build online as part of the
extragear/utils module: (You can also see the change log this way)

https://cgit.kde.org/kdesrc-build.git/

In fact, it is unlikely that future releases will be made. Though new versions
will be tagged, they will not be released as source tarballs. You should run
from git (it is likely a 'stable' branch will be setup to make this more
feasible)

## HELP!!!

This is only a very cursory guide. For more information please see the KDE
Community [Get Involved for
Development](https://community.kde.org/Get_Involved/development) page.

## REFERENCE

kdesrc-build includes a limited command-line description with the --help
option.

You can read the [kdesrc-build
handbook](https://docs.kde.org/index.php?application=kdesrc-build) online.

Once you've setup a KDE development environment, kdesrc-build itself can
generate and build documentation (a handbook and a man page).

The handbook would be available in KHelpCenter (help:/kdesrc-build), while the
man page would be available in the KDE man pages or in the kdesrc-build build
directory:

```shell
$ cd $(~/kde/kdesrc-build --query build-dir kdesrc-build)/doc
$ man ./kdesrc-build.1
```

You can also ask for help online on the #kde-devel channel of IRC (irc.kde.org).

Additionally you can ask for help on the KDE support mailing lists, such as
kde-devel@kde.org

Finally you can drop me an email at mpyne@kde.org (although I have a job/family
and therefore don't always have time to respond)

### Behind the Curtain

For each build, kdesrc-build does several things:

- Finds the configuration file (based on the --rc-file option or by looking for
  `kdesrc-buildrc` in the current directory and falling back to
  `~/.kdesrc-buildrc`)
- Reads the configuration file to generate:
    - Default options to apply for each module
    - A list of modules to build. Modules can be grouped in "module-sets", but
      kdesrc-build converts each set to a list of modules.
- Reduces the module list to modules chosen on the command line (either by name
  or through options like `--resume-from`).
- For modules known to be KDE repositories (derived from a module-set using the
  special `kde-projects` repository):
    - If `--include-dependencies` is enabled, adds needed KDE modules into the
      build, then
    - Reorders KDE modules with respect to each other to ensure they are built
      in dependency order.
- Builds each module in the resulting list of modules. This is broken into
  "phases", and each phase's output is logged to a specific directory for
  inspection later (by default, ~/kde/src/log).

kdesrc-build takes some pains to do perform source code updates and builds in
the way that a developer really would at the command line, using the same
`git`, `cmake`, `make` commands a user would. This means that users are free to
explore the source directory and build directory for a module without trampling
on additional data maintained by kdesrc-build: kdesrc-build does nothing
special in either the source or build directories.

### Important Command Line Options

These options are the most useful. Others are documented at [the kdesrc-build
online handbook](https://go.kde.org/u/ksbcmdline).

| option |     Description    |
| ------ |  ----------------- |
| `--include-dependencies` | Adds any missing modules that are needed for the modules being built. Only works for KDE modules.                                               |
| `--pretend`              | Lists the actions kdesrc-build would take but doesn't actually do them. Useful for a double-check before a long build.                          |
| `--resume-from`          | Starts the build from the given module instead of building all modules. Can combine with `--stop-after` or `--stop-before`.                     |
| `--resume-after`         | Starts the build from *after* the given module, otherwise same as `--resume-from`.                                                              |
| `--stop-before`          | Stops the build just before the given module instead of building all modules. Can combine with `--resume-from` or `--resume-after`.             |
| `--stop-after`           | Stops the build just *after* the given module, otherwise the same as `--stop-before`.                                                           |
| `--no-src`               | Perform module builds as normal but don't try to update source directories. Use this when you've updated source codes yourself.                 |
| `--refresh-build`        | Completely cleans under the module build directories before building. Takes more time but can help recover from a broken build directory setup. |

### Cleaning the build and install directories

kdesrc-build will if possible avoid regenerating the build system and avoid
complete rebuilds of existing modules. This avoids wasting significant amounts
of time rebuilding source codes that have not changed, as all supported build
systems are smart enough to rebuild when necessary.

However it can sometimes happen that a rebuild is needed but wasn't detected,
if this happens you can force a build directory to be fully rebuilt using the
`--refresh-build` option to kdesrc-build.

If all else fails and your development environment which was working fine now
can't seem to upgrade modules anymore, another option is to consider deleting
the install directory (~/kde/usr by default) completely and rebuilding
everything (using `--refresh-build`), but this can take a significant amount of
time!

## CONTACT INFO

If you find a bug, please report it at the [KDE
Bugzilla](https://bugs.kde.org/)

If you have any questions, please let me know: Michael Pyne <mpyne@kde.org>
