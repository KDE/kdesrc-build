package ksb::IPC;

# Common IPC-related constants.

# IPC message types
use constant {
    MODULE_SUCCESS  => 1, # Used for a successful src checkout
    MODULE_FAILURE  => 2, # Used for a failed src checkout
    MODULE_SKIPPED  => 3, # Used for a skipped src checkout (i.e. build anyways)
    MODULE_UPTODATE => 4, # Used to skip building a module when had no code updates

    # One of these messages should be the first message placed on the queue.
    ALL_SKIPPED     => 5, # Used to indicate a skipped update process (i.e. build anyways)
    ALL_FAILURE     => 6, # Used to indicate a major update failure (don't build)
    ALL_UPDATING    => 7, # Informational message, feel free to start the build.

    # Used to indicate specifically that a source conflict has occurred.
    MODULE_CONFLICT => 8,
};

1;
