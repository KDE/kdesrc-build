# kdesrc-build

This script streamlines the process of setting up and maintaining a development
environment for KDE software.

It does this by automating the process of downloading source code from the
KDE source code repositories, building that source code, and installing it
to your local system.

**kdesrc-build** is a predecessor of a newly used tool called [**kde-builder**](https://invent.kde.org/sdk/kde-builder).  
The predecessor project was written in Perl, and this was a significant barrier for new contributions.
The successor project is written in Python - a much more acknowledged language. This means that newly wanted features can be implemented with ease.

## Quick howto

### Set up minimum dependencies

- You must have at least [Perl](https://www.perl.org/get.html) version 5.26
  installed. Most distributions include at least a minimal Perl set up, and
  Perl is also required for some portions of Qt and KDE software builds so it
  is good to have regardless.

- You must have [Git](https://git-scm.com/) installed to download KDE sources
  and kdesrc-build itself. Any supported version should be fine but We
  recommend at least version 2.26.

### Install kdesrc-build

If using Arch Linux, you can use [kdesrc-build-git](https://aur.archlinux.org/packages/kdesrc-build-git) AUR package.

For other distributions, you will need to make a local installation:

- Clone `kdesrc-build` to the folder you will use it from (assume it is `~/.local`):

```shell
$ cd ~/.local/share
$ git clone https://invent.kde.org/sdk/kdesrc-build.git
$ ln -sf ~/.local/share/kdesrc-build/kdesrc-build ~/.local/bin
```

- Make sure it works by running:

```shell
$ cd ~
$ kdesrc-build --version
```

You should see output similar to `kdesrc-build 22.07 (v22.07-577-g469df9b)`.

### Set up kdesrc-build:

Now that `kdesrc-build` is installed and works, you need to set up kdesrc-build
to work appropriately on your particular system.

```shell
$ kdesrc-build --initial-setup
```

This will install the distribution packages dependencies required by `kdesrc-build`,
generate a configuration file.

### Download the KDE project and dependency data:

```shell
$ kdesrc-build --metadata-only
```

This will download information describing the KDE source repositories and
their dependencies, which will help `kdesrc-build` figure out what to build.

`kdesrc-build` will maintain this automatically, but running this step separately
helps to verify that kdesrc-build can properly reach the KDE source repository
and allows the `--pretend` option in the next step to provide more accurate
output.

### Verify kdesrc-build has a good build plan:

```shell
$ kdesrc-build --pretend
```

This will have `kdesrc-build` go through the steps that it would perform, but
without actually doing them. `kdesrc-build` will do some basic pre-checks in this
stage to ensure that required command-line commands are available, including
`cmake`, `git`, `qmake`, and others.

This is the last good chance to make sure that `kdesrc-build` is set the way you
want it. If this command gives you a message that all modules were successfully
built, you can move onto the next step.

### Perform your first build:

```shell
$ kdesrc-build dolphin
```

This will build [Dolphin](https://apps.kde.org/dolphin/),
the Plasma file manager and its KDE-based dependencies. We choose Dolphin
since it is a good test case to exercise the whole build process.

For each module built, `kdesrc-build` will complete these steps:

- Update source code (initial download or later update)
- Set up the build system and configure source code with your options, if needed
- Perform the build, if needed
- Install the module

Hopefully everything will go well the first time, and kdesrc-build will be able
to download and build all the modules that you ask for.

## Further documentation

This is only a very cursory guide. For more information please see the KDE
Community [Get Involved/Development](https://community.kde.org/Get_Involved/development) page.

kdesrc-build includes a limited command-line description with the --help
option.

You can read the [kdesrc-build
handbook](https://docs.kde.org/?application=kdesrc-build) online.

Once you've set up a KDE development environment, kdesrc-build itself can
generate and build documentation (a handbook and a man page).

The handbook would be available in KHelpCenter (`help:/kdesrc-build`), while the
man page would be available in the KDE man pages or in the kdesrc-build build
directory:

```shell
$ cd ~/kde/build/kdesrc-build/doc
$ man ./kdesrc-build.1
```

### Behind the Curtain

For each build, kdesrc-build does several things:

- Finds the configuration file (based on the `--rc-file` option or by looking for
  `kdesrc-buildrc` in the current directory and falling back to
  `~/.config/kdesrc-buildrc`)
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
  inspection later (by default, `~/kde/src/log`).

kdesrc-build takes some pains to do perform source code updates and builds in
the way that a developer really would at the command line, using the same
`git`, `cmake`, `make` commands a user would. This means that users are free to
explore the source directory and build directory for a module without trampling
on additional data maintained by kdesrc-build: kdesrc-build does nothing
special in either the source or build directories.

### Important Command Line Options

These options are the most useful. Others are documented at [the kdesrc-build
online handbook](https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/cmdline.html).

| option |     Description    |
| ------ |  ----------------- |
| `--include-dependencies` | Adds any missing modules that are needed for the modules being built. Only works for KDE modules.                                                |
| `--pretend`              | Lists the actions kdesrc-build would take but doesn't actually do them. Useful for a double-check before a long build.                           |
| `--resume-from`          | Starts the build from the given module instead of building all modules. Can combine with `--stop-after` or `--stop-before`.                      |
| `--resume-after`         | Starts the build from *after* the given module, otherwise same as `--resume-from`.                                                               |
| `--stop-before`          | Stops the build just before the given module instead of building all modules. Can combine with `--resume-from` or `--resume-after`.              |
| `--stop-after`           | Stops the build just *after* the given module, otherwise the same as `--stop-before`.                                                            |
| `--no-src`               | Perform module builds as normal but don't try to update source directories. Use this when you've updated source codes yourself.                  |
| `--refresh-build`        | Completely cleans under the module build directories before building. Takes more time but can help recover from a broken build directory set up. |
