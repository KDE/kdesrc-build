package ksb::OptionsBase 0.20;

# Common code for dealing with kdesrc-build module options
# See POD docs below for more details.

use 5.014;
use warnings;

use ksb::Debug;
use ksb::Util;

use Storable qw(dclone);

# Public API

sub new
{
    my ($class) = @_;

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

sub hasStickyOption
{
    my ($self, $key) = @_;
    $key =~ s/^#//; # Remove sticky marker.

    return 1 if list_has([qw/pretend disable-agent-check/], $key);
    return exists $self->{options}{"#$key"};
}

sub hasOption
{
    my ($self, $key) = @_;

    return exists $self->{options}{$key};
}

# 1. The sticky option overriding the option name given.
# 2. The value of the option name given.
# 3. The empty string (this function never returns undef directly).
#
# The first matching option is returned. See ksb::Module::getOption, which
# is typically what you should be using.
sub getOption
{
    my ($self, $key) = @_;

    foreach ("#$key", $key) {
        return $self->{options}{$_} if exists $self->{options}{$_};
    }

    return '';
}

# Handles setting set-env options.
#
# value - Either a hashref (in which case it is simply merged into our
#     existing options) or a string value of the option as read from the
#     rc-file (which will have the env-var to set as the first item, the
#     value for the env-var to take as the rest of the value).
sub processSetEnvOption
{
    my ($self, $value) = @_;

    $self->{options}->{'set-env'} //= { };
    my $envVars = $self->{options}->{'set-env'};

    if (ref $value) {
        if (ref $value ne 'HASH') {
            croak_internal("Somehow passed a non-hashref to set-env handler");
        }

        @{$envVars}{keys %$value} = values %$value;
    }
    else {
        my ($var, $envValue) = split(' ', $value, 2);
        $envVars->{$var} = $envValue;
    }

    return;
}

# Sets the options in the provided hash to their respective values. If any
# special handling is needed then be sure to reimplement this method
# and to call this method with the resultant effective set of option-value
# pairs.
sub setOption
{
    my ($self, %options) = @_;

    # Special case handling.
    if (exists $options{'set-env'}) {
        $self->processSetEnvOption($options{'set-env'});
        delete $options{'set-env'};
    }

    # Everything else can be dumped straight into our hash.
    @{$self->{options}}{keys %options} = values %options;
}

# Simply removes the given option and its value, if present
sub deleteOption
{
    my ($self, $key) = @_;
    delete $self->{options}{$key} if exists $self->{options}{$key};
}

sub mergeOptionsFrom
{
    my $self = shift;
    my $other = assert_isa(shift, 'ksb::OptionsBase');

    my $newOpts = dclone($other->{options});
    $self->setOption(%$newOpts);
}

# Internal API

1;

__END__

=head1 OptionsBase

A class that encapsulates generic option-handling tasks for kdesrc-build, used
to implement common functions within C<BuildContext>, C<Module>, and C<ModuleSet>.

There is some internal trickery to ensure that program code can override
user-selected options in certain situations, which is why we don't simply
use a hash table directly. These are the so-called 'sticky' options, seen
internally as options with a name starting with #.

=head2 METHODS

=over

=item new

Creates a new C<OptionsBase>.

 my $self = OptionsBase->new();

=item hasOption

Returns true if the given option is present in the collection of options,
B<even if the value is C<undef>>.

=item hasStickyOption

Returns true if the given option has been overridden by a 'sticky' option.
Use C<getOption> to return the actual value in this case.

=item getOption

Returns the value of the given option. 'Sticky' options are returned in
preference to this object's own option (this allows you to temporarily
override an option with a sticky option without overwriting the option
value). If no such option is present, returns an empty string.

Note that C<Module> has its own, much more involved override of this
method. Note further that although C<undef> is not returned directly by
this method, that it's possible for sticky options to be set to undef (if
you're setting sticky option values, it's probably best not to do that).

=item setOption

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

=item deleteOption

Removes the given option (and its value), if present.

=item mergeOptionsFrom

Merges options from the given C<OptionsBase>, replacing any options already
present (but keeping other existing options). Nice to quickly setup an options
baseline to make small changes afterwards without having to worry about
aliasing the other module's option set.

=back

=head2 INTENT

This module is mostly used to encapsulate common code for handling module and
module-set options, for use by major subclasses.

The code in this class simply gets/sets options. To parse options and determine
what options to set, see L<ksb::Application> and its friends.

=cut
