package ksb::OptionsBase 0.20;

use ksb;

=head1 DESCRIPTION

A class that encapsulates generic option-handling tasks for kdesrc-build, used
to implement common functions within L<ksb::BuildContext>, L<ksb::Module>, and
C<ModuleSet>.

There is some internal trickery to ensure that program code can override
user-selected options in certain situations, which is why we don't simply
use a hash table directly. These are the so-called 'sticky' options, seen
internally as options with a name starting with #.

=head2 INTENT

This module is mostly used to encapsulate common code for handling module and
module-set options, for use by major subclasses.

The code in this class simply gets/sets options. To parse options and determine
what options to set, see L<ksb::Application> and its friends.

=cut

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

use Storable qw(dclone);

# Public API

=head1 METHODS

=cut

=head2 new

Creates a new C<OptionsBase>.

 my $self = OptionsBase->new();

=cut

sub new ($class)
{
    # We don't directly bless the options hash so that subclasses can
    # use this base hash table directly (as long as they don't overwrite
    # 'options', of course.
    my $self = {
        options => {
            'set-env' => { }, # Long story...
        },
    };

    return bless $self, $class;
}

=head2 hasStickyOption

Returns true if the given option has been overridden by a 'sticky' option.
Use L</"getOption"> to return the actual value in this case.

=cut

sub hasStickyOption ($self, $key)
{
    $key =~ s/^#//; # Remove sticky marker.

    return 1 if list_has([qw/pretend disable-agent-check/], $key);
    return exists $self->{options}{"#$key"};
}

=head2 hasOption

Returns true if the given option has been set for this module.
Use L</"getOption"> to return the actual value in this case.

=cut

sub hasOption ($self, $key)
{
    return exists $self->{options}{$key};
}

=head2 getOption

Returns the value of the given option. 'Sticky' options are returned in
preference to this object's own option (this allows you to temporarily
override an option with a sticky option without overwriting the option
value). If no such option is present, returns an empty string.

Note that L<ksb::Module> has its own, much more involved override of this
method. Note further that although C<undef> is not returned directly by
this method, that it's possible for sticky options to be set to undef (if
you're setting sticky option values, it's probably best not to do that).

=cut

sub getOption ($self, $key)
{
    foreach ("#$key", $key) {
        return $self->{options}{$_}
            if $self->hasOption($_);
    }

    return '';
}

=head2 setOption

Sets the given option(s) to the given values.

 $self->setOption(%options);

Normally seen as simply:

 $self->setOption($option, $value);

For the vast majority of possible options, setting the same option again
overwrites any previous value. However for C<set-env> options, additional
option sets instead will B<append> to previously-set values.

If you need to perform special handling based on option values, subclass
this function, but be sure to call B<this> setOption() with the resulting
set of options (if any are left to set).

=cut

sub setOption ($self, %options)
{
    # Special case handling.
    if (exists $options{'set-env'}) {
        $self->_processSetEnvOption($options{'set-env'});
        delete $options{'set-env'};
    }

    # Special-case handling
    my $repoOption = 'git-repository-base';
    if (exists $options{$repoOption}) {
        my $value = $options{$repoOption};

        if (ref($value) eq 'HASH') {
            # The case when we merge the constructed OptionBase module (from the config) into the BuildContext. The type of $value is a hash (dict).
            foreach my $key (keys %{$value}) {
                $self->{options}{$repoOption}{$key} = $value->{$key};
            }
            delete $options{$repoOption};
        } else {
            # The case when we first read the option from the config. The type of $value is a scalar (string).
            my ($repo, $url) = ($value =~ /^([a-zA-Z0-9_-]+)\s+(.+)$/);

            if (!$repo || !$url) {
                die ksb::BuildException::Config->new($repoOption,
                    "Invalid git-repository-base setting: $value");
            }

            # This will be a hash reference instead of a scalar
            my $hashref = $self->getOption($repoOption) || {};
            $hashref->{$repo} = $url;
            $self->{options}{$repoOption} = $hashref;
            return
        }
    }

    # Everything else can be dumped straight into our hash.
    @{$self->{options}}{keys %options} = values %options;
}

=head2 deleteOption

Removes the given option (and its value), if present.

=cut

sub deleteOption ($self, $key)
{
    delete $self->{options}{$key}
        if exists $self->{options}{$key};
}

=head2 mergeOptionsFrom

Merges options from the given C<OptionsBase>, replacing any options already
present (but keeping other existing options). Nice to quickly setup an options
baseline to make small changes afterwards without having to worry about
aliasing the other module's option set.

=cut

sub mergeOptionsFrom ($self, $other)
{
    assert_isa($other, 'ksb::OptionsBase');

    my $newOpts = dclone($other->{options});
    $self->setOption(%$newOpts);
}

# Internal API

# Handles setting set-env options.
#
# value - Either a hashref (in which case it is simply merged into our
#     existing options) or a string value of the option as read from the
#     rc-file (which will have the env-var to set as the first item, the
#     value for the env-var to take as the rest of the value).
sub _processSetEnvOption ($self, $value)
{
    $self->{options}->{'set-env'} //= { };
    my $envVars = $self->{options}->{'set-env'};

    if (ref $value) {
        if (ref $value ne 'HASH') {
            croak_internal("Somehow passed a non-hashref to set-env handler");
        }

        @{$envVars}{keys %$value} = values %$value;
    } else {
        my ($var, $envValue) = split(' ', $value, 2);
        $envVars->{$var} = $envValue;
    }

    return;
}

1;
