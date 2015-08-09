package ksb::Util;

# Useful utilities, which are exported into the calling module's namespace by default.

use 5.014; # Needed for state keyword
use strict;
use warnings;

our $VERSION = '0.10';

use Carp qw(cluck);
use Scalar::Util qw(blessed);
use File::Path qw(make_path);
use File::Find;
use Cwd qw(getcwd);
use Errno qw(:POSIX);
use Digest::MD5;
use HTTP::Tiny;

use ksb::Debug;
use ksb::Version qw(scriptVersion);
use ksb::BuildException;

use Exporter qw(import); # Use Exporter's import method
our @EXPORT = qw(list_has assert_isa assert_in any unique_items
                 croak_runtime croak_internal had_an_exception make_exception
                 download_file absPathToExecutable
                 fileDigestMD5 log_command disable_locale_message_translation
                 split_quoted_on_whitespace safe_unlink safe_system p_chdir
                 pretend_open safe_rmtree get_list_digest
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
# reference will be an instance of ksb::BuildException. The actual exception
# type is passed in as the first parameter (as a string), and can be retrieved
# from the object later using the 'exception_type' key, and the message is
# returned as 'message'
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
    return ksb::BuildException->new($exception_type, $message);
}

# Helper function to return $@ if $@ is a ksb::BuildException.
#
# This function assumes that an eval block had just been used in order to set or
# clear $@ as appropriate.
sub had_an_exception
{
    if ($@ && ref $@ && $@->isa('ksb::BuildException')) {
        return $@;
    }

    return;
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
        croak_internal("$obj is not of type $class, but of type " . ref($obj));
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

    pretend ("\tWould have run g['" . join("' '", @_) . "'");
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

    # Check early for whether an executable exists since otherwise
    # it is possible for our fork-open below to "succeed" (i.e. fork()
    # happens OK) and then fail when it gets to the exec(2) syscall.
    if (!absPathToExecutable($program)) {
        croak_runtime("Can't find $program in PATH!");
    }

    my $execFailedError = "\t - kdesrc-build - exec failed!\n";
    my $pid = open(my $childOutput, '-|');
    croak_internal("Can't fork: $!") if ! defined($pid);

    if ($pid) {
        # parent
        my @lines = grep { &$filterRef; } (<$childOutput>);
        close $childOutput or do {
            # $! indicates a rather grievous error
            croak_internal("Unable to open pipe to read $program output: $!") if $!;

            # we can pass serious errors back to ourselves too.
            my $exitCode = $? >> 8;
            if ($exitCode == 99 && @lines >= 1 && $lines[0] eq $execFailedError) {
                croak_runtime("Failed to exec $program, is it installed?");
            }

            # other errors might still be serious but don't need a backtrace
            if (pretending()) {
                whisper ("$program gave error exit code $exitCode");
            } else {
                warning ("$program gave error exit code $exitCode");
            }
        };

        return @lines;
    }
    else {
        disable_locale_message_translation();

        # We don't want stderr output on tty.
        open (STDERR, '>', '/dev/null') or close (STDERR);

        exec { $program } ($program, @args) or do {
            # Send a message back to parent
            print $execFailedError;
            exit 99; # Helper proc, so don't use finish(), just die
        };
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
    my $module = assert_isa(shift, 'ksb::Module');
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
    assert_isa($module, 'ksb::Module');
    my @command = @{$argRef};

    $optionsRef //= { };
    my $callbackRef = $optionsRef->{'callback'};

    debug ("log_command(): Module $module, Command: ", join(' ', @command));

    if (pretending())
    {
        pretend ("\tWould have run g['" . join ("' '", @command) . "'");
        return 0;
    }

    # Fork a child, with its stdout connected to CHILD.
    my $pid = open(CHILD, '-|');
    if ($pid)
    {
        # Parent
        if (!$callbackRef && debugging()) {
            # If no other callback given, pass to debug() if debug-mode is on.
            while (<CHILD>) {
                debug(chomp($_)) if $_;
            }
        }

        if ($callbackRef) {
            &{$callbackRef}($_) while (<CHILD>);

            # Let callback know there is no more output.
            &{$callbackRef}(undef);
        }

        # This implicitly does a waitpid() as well
        close CHILD or do {
            if ($! == 0) {
                _setErrorLogfile($module, "$filename.log");
                return $?;
            }

            return 1;
        };

        return 0;
    }
    else
    {
        # Child. Note here that we need to avoid running our exit cleanup
        # handlers in here. For that we need POSIX::_exit.

        # Apply altered environment variables.
        $module->buildContext()->commitEnvironmentChanges();

        my $logdir = $module->getLogDir();
        if (!$logdir || ! -e $logdir)
        {
            # Error creating directory for some reason.
            error ("\tLogging to std out due to failure creating log dir.");
        }

        $SIG{PIPE} = "IGNORE";
        $SIG{INT} = sub {
            close (STDOUT); # This should be a pipe
            close (STDERR);
            POSIX::_exit(EINTR);
        };

        # Redirect STDIN to /dev/null so that the handle is open but fails when
        # being read from (to avoid waiting forever for e.g. a password prompt
        # that the user can't see.

        open (STDIN, '<', "/dev/null") unless exists $ENV{'KDESRC_BUILD_USE_TTY'};
        if ($callbackRef) {
            open (STDOUT, "|tee $logdir/$filename.log") or do {
                error ("Error opening pipe to tee command.");
                # Don't abort, hopefully STDOUT still works.
            };
        }
        else {
            open (STDOUT, '>', "$logdir/$filename.log");
        }

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

    my $scriptVersion = scriptVersion();
    my %opts = (
        # Trailing space adds lib version info
        agent => "kdesrc-build/$scriptVersion ",
        timeout => 30,
    );

    if ($proxy) {
        whisper ("Using proxy $proxy for HTTP downloads");
        $opts{proxy} = $proxy;
    }

    my $http_client = HTTP::Tiny->new(%opts);

    whisper ("Downloading g[$filename] from g[$url]");
    my $response = $http_client->mirror($url, $filename);

    return 1 if $response->{success};

    $response->{reason} .= " $response->{content}" if $response->{status} == 599;
    error ("Failed to download y[b[$url] to b[$filename]");
    error ("Result was: y[b[$response->{status} $response->{reason}]");

    return 0;
}

# Function: pretend_open
#
# Opens the given file and returns a filehandle to it if the file actually
# exists or the script is not in pretend mode. If the script is in pretend mode
# and the file is not already present then an open filehandle to an empty
# string is returned.
#
# Parameters:
#  filename - Path to the file to open.
#
# Returns:
#  filehandle on success (supports readline() and eof()), can return boolean
#  false if there is an error opening an existing file (or if the file doesn't
#  exist when not in pretend mode)
sub pretend_open
{
    my $path = shift;
    my $fh;

    if (pretending() && ! -e $path) {
        my $simulatedFile = '';
        open $fh, '<', \$simulatedFile or return;
    }
    else {
        open $fh, '<', $path or return;
    }

    return $fh;
}

# Returns true if the given sub returns true for any item in the given listref.
sub any(&@)
{
    my ($subRef, $listRef) = @_;
    ($subRef->($_) && return 1) foreach @{$listRef};
    return 0;
}

# Returns unique items of the list. Order not guaranteed.
sub unique_items
{
    # See perlfaq4
    my %seen;
    my @results = grep { ! $seen{$_}++; } @_;
    return @results;
}

# Subroutine to delete a directory and all files and subdirectories within.
# Does nothing in pretend mode.  An analogue to "rm -rf" from Linux.
# Requires File::Find module.
#
# First parameter: Path to delete
# Returns boolean true on success, boolean false for failure.
sub safe_rmtree
{
    my $path = shift;

    # Pretty user-visible path
    my $user_path = $path;
    $user_path =~ s/^$ENV{HOME}/~/;

    my $delete_file_or_dir = sub {
        # $_ is the filename/dirname.
        return if $_ eq '.' or $_ eq '..';
        if (-f $_ || -l $_)
        {
            unlink ($_) or croak_runtime("Unable to delete $File::Find::name: $!");
        }
        elsif (-d $_)
        {
            rmdir ($File::Find::name) or
                croak_runtime("Unable to remove directory $File::Find::name: $!");
        }
    };

    if (pretending())
    {
        pretend ("Would have removed all files/folders in $user_path");
        return 1;
    }

    # Error out because we probably have a logic error even though it would
    # delete just fine.
    if (not -d $path)
    {
        error ("Cannot recursively remove $user_path, as it is not a directory.");
        return 0;
    }

    eval {
        $@ = '';
        finddepth( # finddepth does a postorder traversal.
        {
            wanted => $delete_file_or_dir,
            no_chdir => 1, # We'll end up deleting directories, so prevent this.
        }, $path);
    };

    if ($@)
    {
        error ("Unable to remove directory $user_path: $@");
        return 0;
    }

    return 1;
}

# Returns a hash digest of the given options in the list.  The return value is
# base64-encoded at this time.
#
# Note: Don't be dumb and pass data that depends on execution state as the
# returned hash is almost certainly not useful for whatever you're doing with
# it.  (i.e. passing a reference to a list is not helpful, pass the list itself)
#
# Parameters: List of scalar values to hash.
# Return value: base64-encoded hash value.
sub get_list_digest
{
    use Digest::MD5 "md5_base64"; # Included standard with Perl 5.8

    return md5_base64(@_);
}

1;

