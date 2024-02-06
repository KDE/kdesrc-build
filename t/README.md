# Tests

To run tests, make sure you have `TAP::Harness` and `Test::More` installed, and run

```
prove -I modules -r
```

from the `kdesrc-build` base directory.  The `-I` flag adds `kdesrc-build`'s own
internal modules to the search path by default.

This will run all tests under `t/`, including any (nested) subdirectories.

If you want to run specific tests then do

```
prove -I modules t/*.t
```

Replace the last parameter with the tests you want.
