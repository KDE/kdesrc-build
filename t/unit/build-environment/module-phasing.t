use v5.22;
use feature 'signatures';
no warnings 'experimental::signatures';

use Test::More;

use ksb::BuildContext;
use ksb::Application;

my $file_data = '';  # Rewritten for each test and hacked into the rc-file loading machinery.

# Monkey patch the loadRcFile to always return a filehandle to our
# embedded kdesrc-buildrc
*ksb::BuildContext::loadRcFile = sub ($ctx) {
    $ctx->{rcFile} = '/dev/null';
    open my $fh, '<', \$file_data or die "Can't open file!";
    return $fh;
};

sub regenRcFile ($rcFileGlobal, $rcFileModule) {
    my $data = <<"EOF";
global
    branch 5.14
    run-tests true   # Default is not to run tests
    $rcFileGlobal
end global

module kdesrc-build
    repository https://invent.kde.org/sdk/kdesrc-build.git
    $rcFileModule
end module
EOF

    $file_data = $data;
}

### Start tests

my $test_data = [
    # name
    # global rc-file changes
    # module rc-file changes
    # cmdline args to add
    # resulting phases for global context
    # resulting phases for the module
    ["base case", '', '',
        [qw()],
        'update buildsystem build test install',
        'update buildsystem build test install',
        ],
    ["base --no-src", '', '',
        [qw(--no-src)],
        'buildsystem build test install',
        'buildsystem build test install',
        ],
    ["base --src-only", '', '',
        [qw(--src-only)],
        'update',
        'update',
        ],
    ["rc-file testing off", 'run-tests false', '',
        [qw()],
        'update buildsystem build install',
        'update buildsystem build install',
        ],
    ["rc-file testing and --no-src", 'run-tests false', '',
        [qw(--no-src)],
        'buildsystem build install',
        'buildsystem build install',
        ],
    ["base with manual-update (non-selected)", '', 'manual-update true',
        [qw()],
        'update buildsystem build test install',
        'buildsystem build test install',
        ],
];

for my $testcase (@{$test_data}) {
    my $testName = $testcase->[0];
    regenRcFile($testcase->[1], $testcase->[2]);

    my $app = ksb::Application->new;
    my $ctx = $app->context();

    my $optsAndSelectors =
        ksb::Application::readCommandLineOptionsAndSelectors(
            qw(--pretend --rc-file /dev/null),
            @{$testcase->[3]}
        );
    my @selectors = $app->establishContext($optsAndSelectors);

    note("--- New test $testName");
    is(scalar @selectors, 0, "$testName: Ensure selectors are empty.");
    my $module_resolver = $app->{module_resolver};
    is(scalar @{$module_resolver->{inputModulesAndOptions}}, 1, "$testName: Right number of modules read in.");

    my $module = $module_resolver->{definedModules}->{'kdesrc-build'};
    isa_ok($module, 'ksb::Module', 'pre-resolved module');
    is($module->getOption('repository', 'module'),
        'https://invent.kde.org/sdk/kdesrc-build.git',
        "$testName: Read-in module option value is correct");

    my $ctxPhases    = [split(' ', $testcase->[4])];
    my $modulePhases = [split(' ', $testcase->[5])];
    if(!is_deeply([$ctx->phases()->phases()], $ctxPhases, "$testName: context phases ok")) {
        diag(explain($ctx->phases(), explain($ctxPhases)));
    }

    # Run the module metadata resolution step and resolve selectors (or in this
    # case the lack of specific selectors) to the relevant modules read from
    # rc-file
    my $workload = $app->modulesFromSelectors(@selectors);

    is (!!$workload->{build}, 1, 'Workload tells us we can safely build');

    my @modules = @{$workload->{selectedModules}};

    is (scalar @modules, 1, 'Resolved to right number of modules');
    is ($modules[0]->name(), $module->name(), 'Resolved module is same as pre-resolved.');

    # Test that the test options were actually passed in properly.
    my @globalRcOpts = split(' ', $testcase->[1]);
    my @moduleRcOpts = split(' ', $testcase->[2]);

    # Normalize getOption output like getOption does
    $globalRcOpts[1] = '0' if $globalRcOpts[1] eq 'false';
    $moduleRcOpts[1] = '0' if $moduleRcOpts[1] eq 'false';

    is($ctx->getOption($globalRcOpts[0]), $globalRcOpts[1], 'ctx global opt was properly set')
        if @globalRcOpts;
    is($module->getOption($moduleRcOpts[0]), $moduleRcOpts[1], "$moduleRcOpts[0] was properly set")
        if @moduleRcOpts;

    # Test that the phases come out right if the inputs are fed in right
    if(!is_deeply([$module->phases()->phases()], $modulePhases, "$testName: module phases ok")) {
        diag(explain($module->phases(), explain($modulePhases)));
    }
}

done_testing();