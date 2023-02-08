package ksb::Updater::KDEProjectMetadata 0.30;

# Updater used only to specifically update the "repo-metadata" module
# used for storing dependency information, among other things.
#
# Note: 2020-06-20 the previous "kde-build-metadata" module was combined into
# the "repo-metadata" module, under the '/dependencies' folder.

use ksb;

use parent qw(ksb::Updater::KDEProject);

use ksb::BuildException;
use ksb::Debug;
use ksb::IPC::Null;
use ksb::Util;

use JSON::PP;

sub name
{
    return 'metadata';
}

# Returns a list of the full kde-project paths for each module to ignore.
sub ignoredModules
{
    my $self = assert_isa(shift, 'ksb::Updater::KDEProjectMetadata');
    my $path = $self->module()->fullpath('source') . "/dependencies/build-script-ignore";

    # Now that we in theory have up-to-date source code, read in the
    # ignore file and propagate that information to our context object.

    my $fh = pretend_open($path) or
        croak_internal("Unable to read ignore data from $path: $!");

    my $ctx = $self->module()->buildContext();
    my @ignoreModules = map  { chomp $_; $_ } # 3 Remove newlines
                        grep { !/^\s*$/ }     # 2 Filter empty lines
                        map  { s/#.*$//; $_ } # 1 Remove comments
                        (<$fh>);

    return @ignoreModules;
}

# If JSON support is present, and the metadata has already been downloaded
# (e.g. with ->updateInternal), returns a hashref to the logical module group
# data contained within the kde-build-metadata, decoded from its JSON format.
# See https://community.kde.org/Infrastructure/Project_Metadata
sub logicalModuleGroups
{
    my $self = shift;
    my $path = $self->module()->fullpath('source') . "/dependencies/logical-module-structure";

    # The {} is an empty JSON obj to support pretend mode
    my $fh = pretend_open($path, '{}') or
        croak_internal("Unable to read logical module structure: $!");

    my ($json_hashref, $e) = do {
        local $/; # The 'local $/' disables line-by-line reading; slurps the whole file
        undef $@;
        my $json = eval { decode_json(<$fh>) };
        close $fh;

        ($json, $@); # Implicit return
    };

    croak_runtime ("Unable to load module group data from $path! :(\n\t$e") if $e;
    return $json_hashref;
}

sub updateInternal ($self, $ipc = ksb::IPC::Null->new())
{
    return $self->_mockTestMetadata()
        if isTesting();

    $self->SUPER::updateInternal($ipc);
}

sub _mockTestMetadata($self)
{
    # Nothing to do currently, mock data is handled directly by
    # ksb::Application (dependencies) or ksb::KDEProjectReader (project
    # metadata).
}

1;
