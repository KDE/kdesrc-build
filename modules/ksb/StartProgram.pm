package StartProgram;

use ksb;
use ksb::Debug;

=pod

=encoding UTF-8

=head1 SYNOPSIS

kdesrc-build --run [options] <module-name> [arguments]

=head1 OPTIONS

  -e, --exec <program>    Specify program of the module. Default to module name.
  -f, --fork              Launch the program in a new session.

=head1 EXAMPLES

B<kdesrc-build --run -f kate -l 5 file1.txt>

  Launch kate in a new session with '-l 5 file1.txt' arguments.

B<kdesrc-build --run -e kate-syntax-highlighter kate --list-themes>

  Launch kate-syntax-highlighter of module kate with '--list-themes' argument.

=cut

sub executeCommandLineProgram
{
    my ($ctx, @args) = @_;

    my $optExec = undef;
    my $optFork = 0;

    # We cannot use GetOptionsFromArray here, because -e or -f could be meant to be arguments of module executable. But that would steal them.
    # We manually care of them, they can only appear in front of module/executable name.
    my $arg;
    while ($arg = shift @args) {
        if ($arg eq "-f" || $arg eq "--fork") {
            $optFork = 1;
            next;
        } elsif ($arg eq "-e" || $arg eq "--exec") {
            $optExec = shift @args;
            if (not defined $optExec){
                error("-e option requires a name of executable");
                exit(1)
            }
            next;
        }
        last;
    }

    my $module = $arg;
    if (not defined $module) { # the case when user specified -e executable_name and/or -f, but then did not specified the module name
        error("The module name is missing");
        exit 1;
    }
    my $executable = $optExec // $module;
    my $buildData = $ctx->{persistent_options};

    if (not defined $buildData->{$module}) {
        say qq(Module "$module" has not been built yet.);
        exit 1;
    }

    my $buildDir   = $buildData->{$module}{'build-dir'};
    my $installDir = $buildData->{$module}{'install-dir'};
    my $revision   = $buildData->{$module}{'last-build-rev'};
    my $execPath   = "$installDir/bin/$executable";

    if (not -e $execPath) {
        say qq(Executable "$executable" does not exist.);
        say qq(Try to set executable name with -e option.);
        exit 127;    # Command not found
    }

    # Most of the logic is done by Perl, so the shell script here should be POSIX
    # compliant. Consider using ShellCheck to make sure of that.
    my $script = <<~EOF;
        #!/bin/sh

        # Set up environment variables (dot command).
        . "$buildDir/prefix.sh"

        # Launch the program with optional arguments.
        if [ "$optFork" = 1 ]; then
            setsid -f "$execPath" \$@
        else
            "$execPath" \$@
        fi
        EOF

    # Print run information
    note (
        "#" x 80, "\n",
        "Module:             $module\n",
        "Executable:         $executable\n",
        "Revision:           $revision\n",
        "Arguments:          @args\n",
        "#" x 80, "\n",
        "\n"
    );

    exit 0 if pretending();

    # Instead of embedding @args in shell script with string interpolation, pass
    # them as arguments of the script. Let the shell handle the list through "$@",
    # so it will do the quoting on each one of them.
    #
    # Run the script with sh options specification:
    #        sh      -c command_string  command_name        $1 $2 $3...
    exec('/bin/sh', '-c', $script, "kdesrc-build run script", @args) or do {
        # If we get to here, that sucks, but don't continue.
        error ("Error executing $executable: $!");
        exit 1;
    };
}

1;
