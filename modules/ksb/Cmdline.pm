package ksb::Cmdline 0.10;

use ksb;

use ksb::BuildContext;
use ksb::BuildException;
use ksb::Debug;
use ksb::PhaseList;
use ksb::OSSupport;
use ksb::Version qw(scriptVersion);

use Getopt::Long qw(GetOptionsFromArray :config gnu_getopt nobundling no_ignore_case);

=head1 SYNOPSIS

 # may exit! for things like --help, --version
 my $opts = ksb::Cmdline::readCommandLineOptionsAndSelectors();

 $ctx->setOption(%{$opts->{opts}->{global}});

 my @module_list = lookForModSelectors(@{$opts->{selectors}});

 if ($opts->{run_mode} eq 'query') {
   # handle query option
   exit 0;
 }

 # ... let's build
 for my $module (@module_list) {
   # override module options from rc-file
   $module->setOption(%{$opts->{opts}->{$module->name()}});
 }

=head1 DESCRIPTION

This package centralizes handling of command line options, to simplify handling
of user command input, for automated testing using mock command lines, and to
speed up simple operations by separating command line argument parsing from the
heavyweight module list generation process.

Since kdesrc-build is intended to be non-interactive once it starts, the
command-line is the primary interface to change program execution and has some
complications as a result.

At the command line, the user can specify things like:

=over

=item *

Modules or module-sets to build (by name)

=item *

Command line options (such as C<--pretend> or C<--no-src>, which normally apply
globally (i.e. overriding module-specific options in the config file)

=item *

Command line options that apply to specific modules (using C<--set-module-option-value>)

=item *

Build modes (install, build only, query)

=item *

Modules to I<ignore> building, using C<--ignore-modules>, which gobbles up
all remaining options.

=back

=head1 FUNCTIONS

=head2 readCommandLineOptionsAndSelectors

This function decodes the command line options passed into it and returns a
hashref describing what actions to take.

The resulting object will be shaped as follows:

  $return = {
    opts  => { # see ksb::BuildContext's "internalGlobalOptions"
      'global'      => {
        # Always present even if no options read in
        "opt-name"  => "opt-value",
        ...
      },
      "$modulename" => {
        "opt-name"  => "opt-value",
        ...
      },
      ...
    },
    phases => [ 'update', 'build', ... 'install' ],
    run_mode => 'build', # or 'install', 'uninstall', or 'query'
    selectors => [
      'juk',
      'frameworks-set',
      # etc.  MAY BE EMPTY in which case the command should build everything known
    ],
    'ignore-modules; => [
      'plasma-nm',
      'plasma-mobile',
      # etc.  MAY BE EMPTY in which case no modules should be stripped from a module-set
    ],
    'start-program' => [
      'cmd',
      '--opt1',
      'value',
      # etc.  USUALLY EMPTY
    ],
  }

Note this function may throw an exception in the event of an error, or exit the
program entirely.

=cut

sub readCommandLineOptionsAndSelectors (@options)
{
    my $phases = ksb::PhaseList->new();
    my @savedOptions = @options; # Copied for use in debugging.
    my $opts = {
        opts             => {
            global       => { },
        },
        phases           => [ ],
        run_mode         => 'build',
        selectors        => [ ],
        'ignore-modules' => [ ],
        'start-program'  => [ ],
    };

    # Getopt::Long will store options in %foundOptions, since that is what we
    # pass in. To allow for custom subroutines to handle an option it is
    # required that the sub *also* be in %foundOptions... whereupon it will
    # promptly be overwritten if we're not careful. Instead we let the custom
    # subs save to %auxOptions, and read those in back over it later.
    my (%foundOptions, %auxOptions);

    %foundOptions = (
        'show-info' => sub { _showInfoAndExit();    },
        version     => sub { _showVersionAndExit(); },
        'show-options-specifiers' => sub { _showOptionsSpecifiersAndExit(); },
        help        => sub { _showHelpAndExit();    },

        # Intended as a short option, -d would imply --include-dependencies and
        # -D implies --no-include-dependencies.
        d => sub {
            $auxOptions{'include-dependencies'} = 1;
        },

        D => sub {
            $auxOptions{'include-dependencies'} = 0;
        },

        uninstall => sub {
            $opts->{run_mode} = 'uninstall';
            $phases->phases('uninstall');
        },
        'no-src' => sub {
            $phases->filterOutPhase('update');
        },
        'no-install' => sub {
            $phases->filterOutPhase('install');
        },
        'no-tests' => sub {
            # The "right thing" to do
            $phases->filterOutPhase('test');

            # What actually works at this point.
            $foundOptions{'run-tests'} = 0;
        },
        'no-build' => sub {
            $phases->filterOutPhase('build');
        },
        # Mostly equivalent to the above
        'src-only' => sub {
            $phases->phases('update');
        },
        'build-only' => sub {
            $phases->phases('build');
        },
        'install-only' => sub {
            $opts->{run_mode} = 'install';
            $phases->phases('install');
        },
        'install-dir' => sub {
            my ($optName, $arg) = @_;
            $auxOptions{'install-dir'} = $arg;
            $foundOptions{reconfigure} = 1;
        },
        query => sub {
            my (undef, $arg) = @_;

            my $validMode = qr/^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/;
            die("Invalid query mode $arg")
                unless $arg =~ $validMode;

            $opts->{run_mode} = 'query';
            $auxOptions{query} = $arg;
            $auxOptions{pretend} = 1; # Implied pretend mode
        },
        pretend => sub {
            # Set pretend mode but also force the build process to run.
            $auxOptions{pretend} = 1;
            $foundOptions{'build-when-unchanged'} = 1;
        },
        resume => sub {
            $auxOptions{resume} = 1;
            $phases->filterOutPhase('update'); # Implied --no-src
            $foundOptions{'no-metadata'} = 1;  # Implied --no-metadata
        },
        verbose        => sub { $foundOptions{'debug-level'} = ksb::Debug::WHISPER },
        quiet          => sub { $foundOptions{'debug-level'} = ksb::Debug::NOTE    },
        'really-quiet' => sub { $foundOptions{'debug-level'} = ksb::Debug::WARNING },
        debug          => sub {
            $foundOptions{'debug-level'} = ksb::Debug::DEBUG;
            say ("Commandline was: ", join(', ', @savedOptions));  # cannot use Debug::debug() yet, as debugLevel is not yet initialized
        },

        # Hack to set module options
        'set-module-option-value' => sub {
            my ($optName, $arg) = @_;
            my ($module, $option, $value) = split (',', $arg, 3);
            if ($module && $option) {
                $opts->{opts}->{$module} //= { };
                $opts->{opts}->{$module}->{$option} = $value;
            }
        },

        # Getopt::Long doesn't set these up for us even though we specify an
        # array. Set them up ourselves.
        'ignore-modules' => [ ],

        # Module selectors, the <> is Getopt::Long shortcut for an
        # unrecognized non-option value (i.e. an actual argument)
        '<>' => sub ($arg) { push @{$opts->{selectors}}, $arg; },
    );

    # Handle any "cmdline-eligible" options not already covered.
    my $flagHandler = sub ($optName, $optValue) {
        # Assume to set if nothing provided.
        $optValue = 1 if ($optValue // '') eq '';
        $optValue = 0 if lc($optValue) eq 'false';
        $optValue = 0 if !$optValue;

        $auxOptions{$optName} = $optValue;
    };

    $foundOptions{$_} //= $flagHandler
        foreach (keys %ksb::BuildContext::GlobalOptions_with_negatable_form);

    # build options for Getopt::Long
    my @supportedOptions = _supportedOptions();

    # If we have --run option, grab all the rest arguments to pass to the corresponding parser.
    # This way the arguments after --run could start with "-" or "--".
    my $run_index = -1;
    foreach my $i (0 .. $#options) {
        if ($options[$i] eq "--run" or $options[$i] eq "--start-program") {
            $run_index = $i;
            last;
        }
    }

    if ($run_index != -1) {
        @{ $opts->{"start-program"} } = @options[$run_index+1 .. $#options];
        @options = @options[0 .. $run_index-1]; # remove all after --run, and the --run itself

        if (! @{ $opts->{"start-program"} }){ # check this here, because later the empty list will be treated as not wanting to start program
            error ("You need to specify a module with the --run option");
            exit 1; # Do not continue
        }
    }

    # Actually read the options.
    my $optsSuccess = GetOptionsFromArray(\@options, \%foundOptions,
        # Options here should not duplicate the flags and options defined below
        # from ksb::BuildContext! supportedOptions() should make this check.
        @supportedOptions,

        '<>', # Required to read non-option args
        );

    if (!$optsSuccess) {
        croak_runtime("Error reading command-line options.");
    }

    # Don't get ignore-modules confused with global options
    my @protectedKeys = ('ignore-modules');
    @{$opts}{@protectedKeys} = @foundOptions{@protectedKeys};
    delete @foundOptions{@protectedKeys};

    # To store the values we found, need to strip out the values that are
    # subroutines, as those are the ones we created. Alternately, place the
    # subs inline as an argument to the appropriate option in the
    # GetOptionsFromArray call above, but that's ugly too.
    my @readOptionNames = grep {
        ref($foundOptions{$_}) ne 'CODE'
    } (keys %foundOptions);

    # Slice assignment: $left{$key} = $right{$key} foreach $key (@keys), but
    # with hashref syntax everywhere.
    @{ $opts->{opts}->{global} }{@readOptionNames}
        = @foundOptions{@readOptionNames};

    @{ $opts->{opts}->{global} }{keys %auxOptions}
        = values %auxOptions;

    @{$opts->{phases}} = $phases->phases();

    return $opts;
}

sub _showVersionAndExit
{
    my $version = "kdesrc-build " . scriptVersion();
    say $version;
    exit;
}

sub _showHelpAndExit
{
    say <<~DONE;
        This script automates the download, build, and install process for KDE software using the latest available source code.

        Documentation at https://docs.kde.org/?application=kdesrc-build
            Commonly used command line options:             https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/cmdline.html#cmdline-commonly-used-options
            Supported command-line parameters:              https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/supported-cmdline-params.html
            Table of available configuration options:       https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/conf-options-table.html
        DONE
    exit;
}

sub _showInfoAndExit
{
    my $os_vendor = ksb::OSSupport->new->vendorID();
    my $version = "kdesrc-build " . scriptVersion();
    say <<~DONE;
        $version
        OS: $os_vendor
        DONE

    exit;
}

sub _showOptionsSpecifiersAndExit
{
    my @supportedOptions = _supportedOptions();

    # The initial setup options are handled outside of Cmdline (in the starting script).
    my @initial_options = ("initial-setup", "install-distro-packages", "generate-config");

    foreach my $option (@supportedOptions, @initial_options) {
        print "$option\n";
    }

    exit;
}

our @phase_changing_options = (
    'build-only',
    'install-only',
    'no-build',
    'no-install',
    'no-src|S',
    'no-tests',
    'src-only|s',
    'uninstall',
);


# Return option specifiers ready to be fed into GetOptionsFromArray
sub _supportedOptions
{
    # See https://perldoc.perl.org/5.005/Getopt::Long for options specification format

    my @non_context_options = (
        'dependency-tree',
        'dependency-tree-fullpath',
        'help|h',
        "list-installed",
        'metadata-only',
        'no-metadata|M',
        'query=s',
        'rc-file=s',
        'rebuild-failures',
        'resume',
        'resume-after|after|a=s',
        'resume-from|from|f=s',
        'set-module-option-value=s',
        'show-info',
        'show-options-specifiers',
        'stop-after|to=s',
        'stop-before|until=s',
        'version|v',
    );

    my @context_options_with_extra_specifier = (
        'build-when-unchanged|force-build!',
        'colorful-output|color!',
        'ignore-modules|!=s{,}',
        'niceness|nice:10',
        'pretend|dry-run|p',
        'refresh-build|r',
    );

    my @options_converted_to_canonical = (
        'd', # --include-dependencies, which is already pulled in via ksb::BuildContext::defaultGlobalFlags
        'debug',
        'D', # --no-include-dependencies, which is already pulled in via ksb::BuildContext::defaultGlobalFlags
        'quiet|quite|q',
        'really-quiet',
        'verbose',
    );

    # For now, place the options we specified above
    my @options = (@non_context_options, @phase_changing_options, @context_options_with_extra_specifier, @options_converted_to_canonical);

    # Remove stuff like ! and =s from list above;
    my @optNames = map { m/([a-zA-Z-]+)/; $1 } @options;

    # Make sure this doesn't overlap with BuildContext default flags and options
    my %optsSeen;

    @optsSeen{@optNames} = (1) x @optNames;

    $optsSeen{$_}++ foreach keys %ksb::BuildContext::GlobalOptions_with_negatable_form;
    $optsSeen{$_}++ foreach keys %ksb::BuildContext::GlobalOptions_with_parameter;
    $optsSeen{$_}++ foreach keys %ksb::BuildContext::GlobalOptions_without_parameter;

    my @violators = grep { $optsSeen{$_} > 1 } keys %optsSeen;
    if (@violators) {
        die "The following options overlap in ksb::Cmdline: [" . join(', ', @violators) . "]!";
    }

    # Now, place the rest of the options, that have specifier dependent on group
    push @options,
        (map { "$_!" } (keys %ksb::BuildContext::GlobalOptions_with_negatable_form)),
        (map { "$_=s" } (keys %ksb::BuildContext::GlobalOptions_with_parameter)),
        (map { "$_" } (keys %ksb::BuildContext::GlobalOptions_without_parameter)),
    ;

    return @options;
}

1;
