package ksb::BuildException 0.20;

# A class to wrap 'exception' messages for the script, allowing them to be
# dispatch based on type and automatically stringified.

use 5.014; # Needed for state keyword
use strict;
use warnings;
use overload
    '""' => \&to_string;

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

e.g. git-repository base y[b[kde] g[b[https://anongit.kde.org/]

Use this in a "module-set" group:

e.g.
module-set kdesupport-set
    repository y[b[kde]
    use-modules automoc akonadi soprano attica
end module-set
EOF
        }

        return $result;
    }

    1;
};

1;

