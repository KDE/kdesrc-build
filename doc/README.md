# kdesrc-build Documentation

If you're reading this, it's probably from Gitlab. Welcome!

The documentation in this directory is split into two major categories:

1. Documentation for end users.
2. Documentation for kdesrc-build developers.

## End User Documentation

This documentation is not in *great* shape, but does exist. These docs are
contained completely within index.docbook using the KDE DocBook XML
documentation standards.

Most users access these docs at
[docs.kde.org](https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/), and
kdesrc-build itself will show URLs to specific portions of this documentation
if you run `kdesrc-build --help`, one pointing to the [table of configuration
options](https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/conf-options-table.html)
and the other to the [list of command-line
options](https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/cmdline.html).

To build these docs locally for testing, use the `build-docs` shell script here
in the doc/ directory (requires that you've already installed kdoctools
framework!), which will symlink the base KDE DocBook theme into the doc/
directory and generate multiple HTML files from the index.docbook.

### Man page

There is also a man page, also authored in Docbook, at
`man-kdesrc-build.1.docbook`. It will
be built and installed to the KDE-specific `MANPATH` if you build kdesrc-build
with CMake.  The content is mostly the same as in the normal DocBook docs but
can be more convenient at the command line, especially if Internet access is
not available.

## Documentation for kdesrc-build developers

Documentation for kdesrc-build itself is mostly within the source files, but I've put
scattered attempts together over time trying to improve that.

### POD format docs

I think I've settled on using [Perl's "POD"
format](https://perldoc.perl.org/perlpodspec) for documentation, even though
it's awful, simply because that's the best way to integrate the documentation
as close to the source code as possible.

See the source-reference/serve-docs.pl script (which requires
[Mojolicious](https://metacpan.org/pod/Mojolicious) and
[Mojolicious::Plugin::PODViewer](https://metacpan.org/pod/Mojolicious::Plugin::PODViewer)
to be installed from CPAN. I recommend
[cpanminus](https://metacpan.org/pod/App::cpanminus) to handle CPAN management
unless you are used to something else.

### Older docs

Older bits of documentation including `Internals.txt` (at the repository root)
and AsciiDoc-based documentation (in doc/source-reference) are likely still
helpful even though they're older, as the source has not drastically changed
over the years.

The AsciiDoc documentation in doc/source-reference has a CMakeLists.txt command
in that directory to build the documentation, assuming you have
[Asciidoctor](https://asciidoctor.org/) installed.

## kdesrc-build Tricks

These are some kdesrc-build tricks that probably should be documented with the
[KDE Community Wiki page](https://community.kde.org/Get_Involved/development#Set_up_kdesrc-build)
but for now they're at least worth nothing here:

- Use `--print-modules` to view which modules kdesrc-build would build, in the
  order they would be built in. This implies `--pretend` although it doesn't hurt
  to include that.

- Use `kdesrc-build --rebuild-failures` (potentially with `--no-src`) to
  rebuild modules that failed to build during the last kdesrc-build run. This
  is particularly useful when a silly local error breaks an important module
  and several dozen dependent modules.

- Use the `--no-stop-on-failure` command-line option (or
  the corresponding configuration file option) to make kdesrc-build not abort
  after the first module fails to build.

- Either way if you're running kdesrc-build frequently as part of a
  debug/build/debug cycle, don't forget to throw `--no-src` on the command line
  as appropriate.  If the build failed halfway through it is likely that all
  source updates completed, even for modules kdesrc-build didn't try to build.

- It is possible to build many module types that are not official KDE projects.
  This may be needed for upstream dependencies or simply because you only need
  a module to support your KDE-based workspace or application.

- There are many ways to have kdesrc-build find the right configuration. If you
  have only a single configuration you want then a ~/.kdesrc-buildrc might be
  the right call. If you want to support multiple configurations, then you can
  create multiple directories and have a file "kdesrc-buildrc" in each
  directory, which kdesrc-build will find if you run the script from that
  directory.

- Don't forget to have kdesrc-build update itself from git!

- You can use the 'branch' and 'tag' options to kdesrc-build to manually choose
  the proper git branch or tag to build. With KDE modules you should not
  normally need this. If even these options are not specific enough, then
  consider the 'revision' option, or manage the source code manually and use
  `--no-src` for that module.

- You can refer to option values that have been previously set in your
  kdesrc-build configuration file, by using the syntax ${option-name}. There's
  no need for the option to be recognized by kdesrc-build, so you can set
  user-specific variables this way.

- Low on disk space? Use the `remove-after-install` option to clean out
  unneeded directories after your build, just don't be surprised when compile
  times go up.

- Need help setting up environment variables to run your shiny new desktop?
  kdesrc-build offers a sample ~/.xsession setup (which is supported by many
  login managers), which can be used by enabling the `install-session-driver`
  option.

- For KDE-based modules, kdesrc-build can install a module and all of its
  dependencies, by using the `--include-dependencies` command line option.
  You can also use `--no-include-dependencies` if you just want to build
  a single module this time.

- Use `--resume-from` (or `--resume-after`) to have kdesrc-build start the
  build from a later module than normal, and `--stop-before` (or
  `--stop-after`) to have kdesrc-build stop the build at an earlier module than
  normal. This can also be used with `--print-modules`.

- Use the `ignore-modules` option with your module sets if you want to build
  every module in the set *except* for a few specific ones.

- Annoyed by the default directory layout? Consider changing the `directory-layout`
  configuration file option.

- kdesrc-build supports building from behind a proxy, for all you corporate
  types trying to get the latest-and-greatest desktop. Just make sure your
  compilation toolchain is up to the challenge....

- You can use the `custom-build-command` option to setup a custom build tool
  (assumed to be make-compatible). For instance, cmake supports the `ninja`
  tool, and kdesrc-build can use `ninja` as well via this option.

- You can also wrap kdesrc-build itself in a script if you want to do things
like unusual pre-build setup, post-install cleanup, etc. This also goes well
with the [`--query`][query] option.

### Troubleshooting

- Is `build-when-unchanged` disabled? Did you try building from a clean build
  directory? If your answer to either is "No" then try using `--refresh-build`
  with your next kdesrc-build run to force a clean build directory to be used.

- If you've been running a kdesrc-build-based install for a long time then it
  may be time to clean out the installation directory as well, especially if
  you don't use the [use-clean-install][] option to run `make uninstall` as
  part of the install process. There's no kdesrc-build option to blow up your
  installation prefix, but it's not hard to do yourself...

[use-clean-install]: https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/conf-options-table.html#conf-use-clean-install
[query]: https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/supported-cmdline-params.html#cmdline-query
