# Tests

## Test format

Each file/folder in ./cases. If it is a folder
the file ./case/$t/run is exected. If it is a 
file, it is executed directly.

Only an exit code of 0 will be considered
a passed test.

Each test has a 1 minute timeout, but tests are expected to run as
fast as possible.

Up to one megabyte of test output will be logged.

When each test is run, it will have cwd in a new temporary directory
that is deleted on the end of the test.

When each test is run it will have the following variables set.

Tests may run in parallel, tests should not depend on global state
outside of the working directory.

## Test environment variables

### TEST_CASE

The absolute path to the test case being run, .i.e. realpath ./case/$t

## Test dependencies

Tests can rely on the following dependencies in $PATH

janet, posix sh, timeout, posix cli tools, expect.
