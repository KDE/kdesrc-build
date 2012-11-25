package ksb::Util;

# Useful utilities, which are exported into the calling module's namespace by default.

use v5.10; # Needed for state keyword
use strict;
use warnings;

use Carp qw(cluck);
use Scalar::Util qw(blessed);
use File::Path qw(make_path);
use Cwd qw(getcwd);
use Errno qw(:POSIX);
use Digest::MD5;

use ksb::Debug;
use ksb::Version qw(scriptVersion);

use Exporter qw(import); # Use Exporter's import method
our @EXPORT = qw(list_has make_exception assert_isa assert_in
                 croak_runtime croak_internal download_file absPathToExecutable
                 fileDigestMD5 log_command disable_locale_message_translation
                 split_quoted_on_whitespace safe_unlink safe_system p_chdir
                 super_mkdir filter_program_output prettify_seconds);

# Function to work around a Perl language limitation.
# First parameter is a reference to the list to search. ALWAYS.
# Second parameter is the value to search for.
# Returns true if the value is in the list
sub list_has
{
    my ($listRef, $value) = @_;
    my @list = @{$listRef};

    return scalar grep { "$_" eq "$value" } (@list);
}

# Subroutine to return the path to the given executable based on the
# current PATH.  e.g. if you pass make you could get '/usr/bin/make'.  If
# the executable is not found undef is returned.
#
# This assumes that the module environment has already been updated since
# binpath doesn't exactly correspond to $ENV{'PATH'}.
sub absPathToExecutable
{
    my $prog = shift;
    my @paths = split(/:/, $ENV{'PATH'});

    # If it starts with a / the path is already absolute.
    return $prog if $prog =~ /^\//;

    for my $path (@paths)
    {
        return "$path/$prog" if (-x "$path/$prog");
    }

    return undef;
}

# Returns a Perl object worth "die"ing for. (i.e. can be given to the die
# function and handled appropriately later with an eval). The returned
# reference will be an instance of BuildException. The actual exception
# type is passed in as the first parameter (as a string), and can be
# retrieved from the object later using the 'exception_type' key, and the
# message is returned as 'message'
#
# First parameter: Exception type. Recommended are one of: Config, Internal
# (for logic errors), Runtime (other runtime errors which are not logic
# bugs in kdesrc-build), or just leave blank for 'Exception'.
# Second parameter: Message to show to user
# Return: Reference to the exception object suitable for giving to "die"
sub make_exception
{
    my $exception_type = shift // 'Exception';
    my $message = shift;
    my $levels = shift // 0; # Allow for more levels to be removed from bt

    # Remove this subroutine from the backtrace
    local $Carp::CarpLevel = 1 + $levels;

    $message = Carp::cluck($message) if $exception_type eq 'Internal';
    return bless({
        'exception_type' => $exception_type,
        'message'        => $message,
    }, 'BuildException');
}

# Should be used for "runtime errors" (i.e. unrecoverable runtime problems that
# don't indicate a bug in the program itself).
sub croak_runtime
{
    die (make_exception('Runtime', $_[0], 1));
}

# Should be used for "logic errors" (i.e. impossibilities in program state, things
# that shouldn't be possible no matter what input is fed at runtime)
sub croak_internal
{
    die (make_exception('Internal', $_[0], 1));
}

# Throws an exception if the first parameter is not an object at all, or if
# it is not an object of the type given by the second parameter (which
# should be a string of the class name. There is no return value;
sub assert_isa
{
    my ($obj, $class) = @_;

    if (!blessed($obj) || !$obj->isa($class)) {
        croak_runtime("$obj is not of type $class, but of type " . ref($obj));
    }

    return $obj;
}

# Throws an exception if the first parameter is not included in the
# provided list of possible alternatives. The list of alternatives must
# be passed as a reference, as the second parameter.
sub assert_in
{
    my ($val, $listRef) = @_;

    if (!list_has($listRef, $val)) {
        croak_runtime("$val is not a permissible value for its argument");
    }

    return $val;
}

# Subroutine to unlink the given symlink if global-pretend isn't set.
sub safe_unlink
{
    if (pretending())
    {
        pretend ("\tWould have unlinked ", shift, ".");
        return 1; # Return true
    }

    return unlink (shift);
}

# Subroutine to execute the system call on the given list if the pretend
# global option is not set.
#
# Returns the shell error code, so 0 means success, non-zero means failure.
sub safe_system(@)
{
    if (!pretending())
    {
        whisper ("\tExecuting g['", join("' '", @_), "'");
        return system (@_) >> 8;
    }

    pretend ("\tWould have run g['", join("' '", @_), "'");
    return 0; # Return true
}

# Is exactly like "chdir", but it will also print out a message saying that
# we're switching to the directory when debugging.
sub p_chdir($)
{
    my $dir = shift;
    debug ("\tcd g[$dir]\n");

    chdir ($dir) or do {
        return 1 if pretending();
        croak_runtime("Could not change to directory $dir: $!");
    };
}

# Helper subroutine to create a directory, including any parent
# directories that may also need created.
# Throws an exception on failure. See File::Path.
sub super_mkdir
{
    my $pathname = shift;
    state %createdPaths;

    if (pretending()) {
        if (!exists $createdPaths{$pathname} && ! -e $pathname) {
            pretend ("\tWould have created g[$pathname]");
        }

        $createdPaths{$pathname} = 1;
        return 1;
    }
    else {
        make_path($pathname);
        return (-e $pathname) ? 1 : 0;
    }
}

# Calculates the MD5 digest of a file already on-disk. The digest is
# returned as a hex string digest as from Digest::MD5::md5_hex
#
# First parameter: File name to read
# Return value: hex string MD5 digest of file.
# An exception is thrown if an error occurs reading the file.
sub fileDigestMD5
{
    my $fileName = shift;
    my $md5 = Digest::MD5->new;

    open my $file, '<', $fileName or croak_runtime(
        "Unable to open $fileName: $!");
    binmode($file);

    $md5->addfile($file);
    return $md5->hexdigest();
}

# This function is intended to disable the message translation catalog
# settings in the program environment, so that any child processes executed
# will have their output untranslated (and therefore scrapeable).
#
# As such this should only be called for a forked child about to exec as
# there is no easy way to undo this within the process.
sub disable_locale_message_translation
{
    # Ensure that program output is untranslated by setting 'C' locale.
    # We're really trying to affect the LC_MESSAGES locale category, but
    # LC_ALL is a catch-all for that (so needs to be unset if set).
    #
    # Note that the ONLY SUPPORTED way to pass file names, command-line
    # args, etc. to commands is under the UTF-8 encoding at this point, as
    # that is the only sane way for this en_US-based developer to handle
    # the task.  Patches (likely using Encode::Locale) are accepted. :P

    $ENV{'LC_MESSAGES'} = 'C';
    if ($ENV{'LC_ALL'}) {
        $ENV{'LANG'} = $ENV{'LC_ALL'}; # This is lower-priority "catch all"
        delete $ENV{'LC_ALL'};
    }
}

# Returns an array of lines output from a program.  Use this only if you
# expect that the output will be short.
#
# Since there is no way to disambiguate no output from an error, this
# function will call die on error, wrap in eval if this bugs you.
#
# First parameter is subroutine reference to use as a filter (this sub will
# be passed a line at a time and should return true if the line should be
# returned).  If no filtering is desired pass 'undef'.
#
# Second parameter is the program to run (either full path or something
# accessible in $PATH).
#
# All remaining arguments are passed to the program.
#
# Return value is an array of lines that were accepted by the filter.
sub filter_program_output
{
    my ($filterRef, $program, @args) = @_;
    $filterRef //= sub { return 1 }; # Default to all lines

    debug ("Slurping '$program' '", join("' '", @args), "'");

    my $pid = open(my $childOutput, '-|');
    croak_internal("Can't fork: $!") if ! defined($pid);

    if ($pid) {
        # parent
        my @lines = grep { &$filterRef; } (<$childOutput>);
        close $childOutput;
        waitpid $pid, 0;

        return @lines;
    }
    else {
        disable_locale_message_translation();

        # We don't want stderr output on tty.
        open (STDERR, '>', '/dev/null') or close (STDERR);

        exec { $program } ($program, @args) or
            croak_internal("Unable to exec $program: $!");
    }
}

# Subroutine to return a string suitable for displaying an elapsed time,
# (like a stopwatch) would.  The first parameter is the number of seconds
# elapsed.
sub prettify_seconds
{
    my $elapsed = $_[0];
    my $str = "";
    my ($days,$hours,$minutes,$seconds,$fraction);

    $fraction = int (100 * ($elapsed - int $elapsed));
    $elapsed = int $elapsed;

    $seconds = $elapsed % 60;
    $elapsed = int $elapsed / 60;

    $minutes = $elapsed % 60;
    $elapsed = int $elapsed / 60;

    $hours = $elapsed % 24;
    $elapsed = int $elapsed / 24;

    $days = $elapsed;

    $seconds = "$seconds.$fraction" if $fraction;

    my @str_list;

    for (qw(days hours minutes seconds))
    {
        # Use a symbolic reference without needing to disable strict refs.
        # I couldn't disable it even if I wanted to because these variables
        # aren't global or localized global variables.
        my $value = eval "return \$$_;";
        my $text = $_;
        $text =~ s/s$// if $value == 1; # Make singular

        push @str_list, "$value $text" if $value or $_ eq 'seconds';
    }

    # Add 'and ' in front of last element if there was more than one.
    push @str_list, ("and " . pop @str_list) if (scalar @str_list > 1);

    $str = join (", ", @str_list);

    return $str;
}

# Subroutine to mark a file as being the error log for a module.  This also
# creates a symlink in the module log directory for easy viewing.
# First parameter is the module in question.
# Second parameter is the filename in the log directory of the error log.
sub _setErrorLogfile
{
    my $module = assert_isa(shift, 'Module');
    my $logfile = shift;

    return unless $logfile;

    my $logdir = $module->getLogDir();

    $module->setOption('#error-log-file', "$logdir/$logfile");
    debug ("Logfile for $module is $logfile");

    # Setup symlink in the module log directory pointing to the appropriate
    # file.  Make sure to remove it first if it already exists.
    unlink("$logdir/error.log") if -l "$logdir/error.log";

    if(-e "$logdir/error.log")
    {
        # Maybe it was a regular file?
        error ("r[b[ * Unable to create symlink to error log file]");
        return;
    }

    symlink "$logfile", "$logdir/error.log";
}


# Subroutine to run a command, optionally filtering on the output of the child
# command.
#
# First parameter is the module object being built (for logging purposes
#   and such).
# Second parameter is the name of the log file to use (relative to the log
#   directory).
# Third parameter is a reference to an array with the command and its
#   arguments.  i.e. ['command', 'arg1', 'arg2']
#
# After the required three parameters you can pass a hash reference of
# optional features:
#   'callback' => a reference to a subroutine to have each line
#   of child output passed to.  This output is not supposed to be printed
#   to the screen by the subroutine, normally the output is only logged.
#   However this is useful for e.g. munging out the progress of the build.
#   USEFUL: When there is no more output from the child, the callback will be
#     called with an undef string.  (Not just empty, it is also undefined).
#
#   'no_translate' => any true value will cause a flag to be set to request
#   the executed child process to not translate (for locale purposes) its
#   output, so that it can be screen-scraped.
#
# The return value is the shell return code, so 0 is success, and non-zero is
#   failure.
#
# NOTE: This function has a special feature.  If the command passed into the
#   argument reference is 'kdesrc-build', then log_command will, when it
#   forks, execute the subroutine named by the second parameter rather than
#   executing a child process.  The subroutine should include the full package
#   name as well (otherwise the package containing log_command's implementation
#   is used).  The remaining arguments in the list are passed to the
#   subroutine that is called.
sub log_command
{
    my ($module, $filename, $argRef, $optionsRef) = @_;
    assert_isa($module, 'Module');
    my @command = @{$argRef};

    $optionsRef //= { };
    my $callbackRef = $optionsRef->{'callback'};

    debug ("log_command(): Module $module, Command: ", join(' ', @command));

    # Fork a child, with its stdout connected to CHILD.
    my $pid = open(CHILD, '-|');
    if ($pid)
    {
        # Parent
        if (!$callbackRef && debugging()) {
            # If no other callback given, pass to debug() if debug-mode is on.
            $callbackRef = sub {
                return unless $_; chomp; debug($_);
            };
        }

        # Final fallback: Do nothing
        $callbackRef //= sub { };

        # Filter each line
        &{$callbackRef}($_) while (<CHILD>);

        # Let callback know there is no more output.
        &{$callbackRef}(undef) if defined $callbackRef;

        close CHILD;

        # If the module fails building, set an internal flag in the module
        # options with the name of the log file containing the error message.
        # TODO: ($? is set when closing CHILD pipe?)
        my $result = $?;
        _setErrorLogfile($module, "$filename.log") if $result;

        return $result;
    }
    else
    {
        # Child. Note here that we need to avoid running our exit cleanup
        # handlers in here. For that we need POSIX::_exit.

        # Apply altered environment variables.
        $module->buildContext()->commitEnvironmentChanges();

        if (pretending())
        {
            pretend ("\tWould have run g['", join ("' '", @command), "'");
            POSIX::_exit(0);
        }

        my $logdir = $module->getLogDir();
        if (!$logdir || ! -e $logdir)
        {
            # Error creating directory for some reason.
            error ("\tLogging to std out due to failure creating log dir.");
        }

        # Redirect STDIN to /dev/null so that the handle is open but fails when
        # being read from (to avoid waiting forever for e.g. a password prompt
        # that the user can't see.

        open (STDIN, '<', "/dev/null") unless exists $ENV{'KDESRC_BUILD_USE_TTY'};
        open (STDOUT, "|tee $logdir/$filename.log") or do {
            error ("Error opening pipe to tee command.");
            # Don't abort, hopefully STDOUT still works.
        };

        # Make sure we log everything.
        # In the case of Qt, we may have forced on progress output so let's
        # leave that interactive to keep the logs sane.
        if (!($module->buildSystemType() eq 'Qt' &&
           $module->buildSystem()->forceProgressOutput()))
        {
            open (STDERR, ">&STDOUT");
        }

        # Call internal function, name given by $command[1]
        if ($command[0] eq 'kdesrc-build')
        {
            # No colors!
            ksb::Debug::setColorfulOutput(0);
            debug ("Calling $command[1]");

            my $cmd = $command[1];
            splice (@command, 0, 2); # Remove first two elements.

            no strict 'refs'; # Disable restriction on symbolic subroutines.
            if (! &{$cmd}(@command)) # Call sub
            {
                POSIX::_exit (EINVAL);
            }

            POSIX::_exit (0); # Exit child process successfully.
        }

        # Don't leave empty output files, give an indication of the particular
        # command run. Use print to go to stdout.
        say "# kdesrc-build running: '", join("' '", @command), "'";
        say "# from directory: ", getcwd();

        # If a callback is set assume no translation can be permitted.
        disable_locale_message_translation() if $optionsRef->{'no_translate'};

        # External command.
        exec (@command) or do {
            my $cmd_string = join(' ', @command);
            error (<<EOF);
r[b[Unable to execute "$cmd_string"]!
$!

Please check your binpath setting (it controls the PATH used by kdesrc-build).
Currently it is set to g[$ENV{PATH}].
EOF
            # Don't use return, this is the child still!
            POSIX::_exit (1);
        };
    }
}

# This subroutine acts like split(' ', $_) except that double-quoted strings
# are not split in the process.
#
# First parameter: String to split on whitespace.
# Return value: A list of the individual words and quoted values in the string.
# The quotes themselves are not returned.
sub split_quoted_on_whitespace
{
    use Text::ParseWords qw(parse_line);
    my $line = shift;

    # Remove leading/trailing whitespace
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    # 0 means not to keep delimiters or quotes
    return parse_line('\s+', 0, $line);
}

# This subroutine downloads the file pointed to by the URL given in the
# first parameter, saving to the given filename.  (FILENAME, not
# directory). HTTP and FTP are supported, but this functionality requires
# libwww-perl
#
# First parameter: URL of link to download (i.e. http://kdesrc-build.kde.org/foo.tbz2)
# Second parameter: Filename to save as (i.e. $ENV{HOME}/blah.tbz2)
# Third parameter: URL of a proxy to use (undef or empty means proxy as set in environment)
# Return value is 0 for failure, non-zero for success.
sub download_file
{
    my ($url, $filename, $proxy) = @_;

    my $ua = LWP::UserAgent->new(timeout => 30);
    my $scriptVersion = scriptVersion();

    # Trailing space adds the appropriate LWP info since the resolver is not
    # my custom coding anymore.
    $ua->agent("kdesrc-build/$scriptVersion ");

    if ($proxy) {
        whisper ("Using proxy $proxy for FTP, HTTP downloads");
        $ua->proxy(['http', 'ftp'], $proxy);
    }
    else {
        whisper ("Using proxy as determined by environment");
        $ua->env_proxy();
    }

    whisper ("Downloading g[$filename] from g[$url]");
    my $response = $ua->mirror($url, $filename);

    # LWP's mirror won't auto-convert "Unchanged" code to success, so check for
    # both.
    return 1 if $response->code == 304 || $response->is_success;

    error ("Failed to download y[b[$url] to b[$filename]");
    error ("Result was: y[b[" . $response->status_line . "]");
    return 0;
}

1;

