package ksb::Util 0.30;

# Useful utilities, which are exported into the calling module's namespace by default.

use ksb;

use Scalar::Util qw(blessed);
use File::Path qw(make_path remove_tree);
use File::Find;
use Cwd qw(getcwd);
use Errno qw(:POSIX);
use Digest::MD5;

use ksb::Debug;
use ksb::Version qw(scriptVersion);
use ksb::BuildException;

use Mojo::IOLoop::Subprocess;
use Mojo::Util qw(trim);

use Exporter qw(import); # Use Exporter's import method
our @EXPORT = qw(assert_isa assert_in

                 list_has any unique_items get_list_digest

                 split_quoted_on_whitespace prettify_seconds

                 log_command filter_program_output
                 disable_locale_message_translation locate_exe

                 file_digest_md5 safe_unlink safe_system p_chdir
                 pretend_open safe_rmtree is_dir_empty
                 super_mkdir
                 );
our @EXPORT_OK = qw(run_logged_p);

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
# either the given paths or the current PATH.
# E.g.:
# locate_exe('make') -> '/usr/bin/make'
# locate_exe('make', 'foo', 'bar') -> /foo/make
# If the executable is not found undef is returned.
#
# This assumes that the module environment has already been updated since
# binpath doesn't exactly correspond to $ENV{'PATH'}.
sub locate_exe
{
    my ($prog, @preferred) = @_;

    # If it starts with a / the path is already absolute.
    return $prog if $prog =~ /^\//;

    my @paths = @preferred ? @preferred : split(/:/, $ENV{'PATH'});
    for my $path (@paths)
    {
        return "$path/$prog" if (-x "$path/$prog");
    }

    return undef;
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
sub safe_system :prototype(@)
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
sub p_chdir :prototype($)
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
sub file_digest_md5 ($fileName)
{
    my $md5 = Digest::MD5->new;

    open (my $file, '<', $fileName)
        or croak_runtime("Unable to open $fileName: $!");
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
    if (!locate_exe($program)) {
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

    if ($module->hasStickyOption('error-log-file')) {
        error("$module already has error log set, tried to set to r[b[$logfile]");
        return;
    }

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

    if (pretending()) {
        pretend ("\tWould have run g['" . join ("' '", @command) . "'");
        return 0;
    }

    # Do this before we fork so we can see errors
    my $logpath = $module->getLogPath("$filename.log");

    # Fork a child, with its stdout connected to CHILD.
    my $pid = open(CHILD, '-|');
    if ($pid)
    {
        # Parent
        if (!$callbackRef && debugging()) {
            # If no other callback given, pass to debug() if debug-mode is on.
            while (<CHILD>) {
                print ($_) if $_;
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
        if ($callbackRef || debugging()) {
            open (STDOUT, "|tee $logpath") or do {
                error ("Error opening pipe to tee command.");
                # Don't abort, hopefully STDOUT still works.
            };
        }
        else {
            open (STDOUT, '>', $logpath) or do {
                error ("Error $! opening log to $logpath!");
            };
        }

        # Make sure we log everything.
        open (STDERR, ">&STDOUT");

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

=head2 run_logged_p

This is similar to C<log_command> in that this runs the given command and
arguments in a separate process. The difference is that this command
I<does not wait> for the process to finish, and instead returns a
L<Mojo::Promise> that resolves to the exit status of the sub-process.

This is useful in permitting concurrent code without needing to resolve
significant changes from a separate thread of execution over time.

 my $promise = run_logged_p($module, 'build', [qw(make -j8)]);
 $promise->then(sub ($result) {
   say "Process result: $result";
 })->wait;

Another important difference is that fewer options are currently supported.
In particular there is no built-in way to filter the program output or to
force off locale translations.

=cut

sub run_logged_p ($module, $filename, $argRef)
{
    {
        local $" = "', '"; # list separator
        debug ("run_logged_p(): Module $module, Command: ['$argRef->@*']");
        if (pretending()) {
            pretend ("\tWould have run g['$argRef->@*']");
            return Mojo::Promise->resolve(0);
        }
    }

    my $subprocess = Mojo::IOLoop::Subprocess->new;

    my $promise = $subprocess->run_p(sub {
        # This happens in a CHILD PROCESS, not in the main process!
        # This means that changes made by log_command or function calls made
        # via log_command will not be saved or noted unless they are made part
        # of the return value, or sent earlier via a 'progress' event.

        return log_command($module, $filename, $argRef);
    })->then(sub ($exitcode) {
        # This happens back in the main process, so we can reintegrate the
        # changes into our data structures if needed.

        debug ("run_logged_p(): $module $filename complete: $exitcode");

        _setErrorLogfile($module, "$filename.log")
            unless $exitcode == 0;

        return $exitcode;
    });

    return $promise;
}

# This subroutine acts like split(' ', $_) except that double-quoted strings
# are not split in the process.
#
# First parameter: String to split on whitespace.
# Return value: A list of the individual words and quoted values in the string.
# The quotes themselves are not returned.
sub split_quoted_on_whitespace ($line)
{
    use Text::ParseWords qw(parse_line);

    # 0 means not to keep delimiters or quotes
    return parse_line('\s+', 0, trim($line));
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
#  default  - String to use if the file doesn't exist in pretend mode
#
# Returns:
#  filehandle on success (supports readline() and eof()), can return boolean
#  false if there is an error opening an existing file (or if the file doesn't
#  exist when not in pretend mode)
sub pretend_open
{
    my $path = shift;
    my $defaultText = shift // '';
    my $fh;

    if (pretending() && ! -e $path) {
        open $fh, '<', \$defaultText or return;
    }
    else {
        open $fh, '<', $path or return;
    }

    return $fh;
}

# Returns true if the given sub returns true for any item in the given listref.
sub any :prototype(&@)
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
# Does nothing in pretend mode.  An analog to "rm -rf" from Linux.
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

# Utility function to see if a directory path is empty or not
sub is_dir_empty
{
    my $dir = shift;

    opendir my $dirh, $dir or return;

    # while-readdir needs Perl 5.12
    while (readdir $dirh) {
        next if ($_ eq '.' || $_ eq '..');

        closedir ($dirh);
        return; # not empty
    }

    closedir ($dirh);
    return 1;
}

# Takes in a string and returns 1 if that string exists somewhere in the
# path variable.
# Subroutine to recursively symlink a directory into another location, in a
# similar fashion to how the XFree/X.org lndir() program does it.  This is
# reimplemented here since some systems lndir doesn't seem to work right.
#
# As a special exception to the GNU GPL, you may use and redistribute this
# function however you would like (i.e. consider it public domain).
#
# The first parameter is the directory to symlink from.
# The second parameter is the destination directory name.
#
# e.g. if you have $from/foo and $from/bar, lndir would create $to/foo and
# $to/bar.
#
# All intervening directories will be created as needed.  In addition, you
# may safely run this function again if you only want to catch additional files
# in the source directory.
#
# Note that this function will unconditionally output the files/directories
# created, as it is meant to be a close match to lndir.
#
# RETURN VALUE: Boolean true (non-zero) if successful, Boolean false (0, "")
#               if unsuccessful.
sub safe_lndir
{
    my ($from, $to) = @_;

    # Create destination directory.
    if (not -e $to)
    {
        print "$to\n";
        if (not pretending() and not super_mkdir($to))
        {
            error ("Couldn't create directory r[$to]: b[r[$!]");
            return 0;
        }
    }

    # Create closure callback subroutine.
    my $wanted = sub {
        my $dir = $File::Find::dir;
        my $file = $File::Find::fullname;
        $dir =~ s/$from/$to/;

        # Ignore the .svn directory and files.
        return if $dir =~ m,/\.svn,;

        # Create the directory.
        if (not -e $dir)
        {
            print "$dir\n";

            if (not pretending())
            {
                super_mkdir ($dir) or croak_runtime("Couldn't create directory $dir: $!");
            }
        }

        # Symlink the file.  Check if it's a regular file because File::Find
        # has no qualms about telling you you have a file called "foo/bar"
        # before pointing out that it was really a directory.
        if (-f $file and not -e "$dir/$_")
        {
            print "$dir/$_\n";

            if (not pretending())
            {
                symlink $File::Find::fullname, "$dir/$_" or
                    croak_runtime("Couldn't create file $dir/$_: $!");
            }
        }
    };

    # Recursively descend from source dir using File::Find
    eval {
        find ({ 'wanted' => $wanted,
                'follow_fast' => 1,
                'follow_skip' => 2},
              $from);
    };

    if ($@)
    {
        error ("Unable to symlink $from to $to: $@");
        return 0;
    }

    return 1;
}

# Subroutine to delete recursively, everything under the given directory,
# unless we're in pretend mode.
#
# Used from ksb::BuildSystem to handle cleaning a build directory.
#
# i.e. the effect is similar to "rm -r $arg/* $arg/.*".
#
# This assumes we're called from a separate child process.  Therefore the
# normal logging routines are /not used/, since our output will be logged
# by the parent kdesrc-build.
#
# The first parameter should be the absolute path to the directory to delete.
#
# Returns boolean true on success, boolean false on failure.
sub prune_under_directory
{
    my $dir = shift;
    my $errorRef;

    print "starting delete of $dir\n";
    eval {
        remove_tree($dir, { keep_root => 1, error => \$errorRef });
    };

    if ($@ || @$errorRef)
    {
        error ("\tUnable to clean r[$dir]:\n\ty[b[$@]");
        return 0;
    }

    return 1;
}

1;
