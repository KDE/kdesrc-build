package ksb::BuildException 0.20;

# A class to wrap 'exception' messages for the script, allowing them to be
# dispatch based on type and automatically stringified.

use v5.22;
use strict;
use warnings;
use Carp;
use overload
    '""' => \&to_string;

use Exporter qw(import);
our @EXPORT = qw(croak_runtime croak_internal had_an_exception make_exception);

sub new
{
    my ($class, $type, $msg) = @_;

    return bless({
        'exception_type' => $type,
        'message'        => $msg,
    }, $class);
}

sub to_string
{
    my $exception = shift;
    return $exception->{exception_type} . " Error: " . $exception->{message};
}

sub message
{
    my $self = shift;
    return $self->{message};
}

sub setMessage
{
    my ($self, $newMessage) = @_;
    $self->{message} = $newMessage;
}

#
# Exported utility functions
#

# Returns a Perl exception object to pass to 'die' function
# The returned reference will be an instance of ksb::BuildException.
#
# First parameter: Exception type, 'Exception' if undef
# Second parameter: Message to show to user
sub make_exception
{
    my $exception_type = shift // 'Exception';
    my $message = shift;
    my $levels = shift // 0; # Allow for more levels to be removed from bt

    # Remove this subroutine from the backtrace
    local $Carp::CarpLevel = 1 + $levels;

    $message = Carp::longmess($message)
        if $exception_type eq 'Internal';
    return ksb::BuildException->new($exception_type, $message);
}

# Helper function to return $@ if $@ is a ksb::BuildException.
#
# This function assumes that an eval block had just been used in order to set
# or clear $@ as appropriate.
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
    if (exists $ENV{HARNESS_ACTIVE}) {
        goto &croak_internal; # calls croak_internal with same params.
    }

    die (make_exception('Runtime', $_[0], 1));
}

# Should be used for "logic errors" (i.e. impossibilities in program state, things
# that shouldn't be possible no matter what input is fed at runtime)
sub croak_internal
{
    die (make_exception('Internal', $_[0], 1));
}

#
# A small subclass to hold the option name that caused a config exception to
# be thrown.
#
# Typically this will be caught by config-reading code in ksb::Application,
# which will add filename and line number information to the message.
#
package ksb::BuildException::Config 0.10 {
    use parent qw(ksb::BuildException);
    use Scalar::Util qw(blessed);

    sub new
    {
        my ($class, $bad_option_name, $msg) = @_;
        my $self = ksb::BuildException->new('Config', $msg);
        $self->{'config_invalid_option_name'} = $bad_option_name;
        return $self;
    }

    sub problematicOptionName
    {
        my $self = shift;
        return $self->{'config_invalid_option_name'};
    }

    # Should return a lengthy explanation of how to use a given option for use in
    # error messages, or undef if no explanation is unavailable.
    sub optionUsageExplanation
    {
        my $optionName = shift;
        my $result;

        if (blessed($optionName)) {
            # Should only happen if called as method: ie. $optionName == $self
            $optionName = $optionName->problematicOptionName();
        }

        if ($optionName eq 'git-repository-base') {
            $result = <<"EOF";
The y[git-repository-base] option requires a repository name and URL.

e.g. git-repository base y[b[kde-sdk] g[b[https://invent.kde.org/sdk/]

Use this in a "module-set" group:

e.g.
module-set kdesdk-set
    repository y[b[kde-sdk]
    use-modules kdesrc-build kde-dev-scripts clazy
end module-set
EOF
        }

        return $result;
    }

    1;
};

1;

