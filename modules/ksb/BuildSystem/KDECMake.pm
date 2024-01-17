package ksb::BuildSystem::KDECMake 0.20;

# Class responsible for building CMake-based modules, with special support for KDE modules.

use ksb;

use parent qw(ksb::BuildSystem);

use ksb::BuildContext 0.30;
use ksb::Debug;
use ksb::Util qw(:DEFAULT :await run_logged_p);
use ksb::Util::LoggedSubprocess;

use List::Util qw(first);

my $BASE_GENERATOR_MAP = {
    'Ninja' => {
        optionsName => 'ninja-options',
        installTarget => 'install',
        requiredPrograms => [
            qw{ninja cmake qmake}
        ],
        buildCommands => [
            qw{ninja}
        ]
    },
    'Unix Makefiles' => {
        optionsName => 'make-options',
        installTarget => 'install/fast',
        requiredPrograms => [
            qw{cmake qmake}
        ],
        # Non Linux systems can sometimes fail to build when GNU Make would work,
        # so prefer GNU Make if present, otherwise try regular make.
        buildCommands => [
            qw{gmake make}
        ]
    }
};

# Extra generators that are compatible to the base generators above.
# See: https://cmake.org/cmake/help/latest/manual/cmake-generators.7.html#extra-generators
my $GENERATOR_MAP = {
    'Ninja' => $BASE_GENERATOR_MAP->{'Ninja'},
    'CodeBlocks - Ninja' => $BASE_GENERATOR_MAP->{'Ninja'},
    'CodeLite - Ninja' => $BASE_GENERATOR_MAP->{'Ninja'},
    'Sublime Text 2 - Ninja' => $BASE_GENERATOR_MAP->{'Ninja'},
    'Kate - Ninja' => $BASE_GENERATOR_MAP->{'Ninja'},
    'Eclipse CDT4 - Ninja' => $BASE_GENERATOR_MAP->{'Ninja'},

    'Unix Makefiles' => $BASE_GENERATOR_MAP->{'Unix Makefiles'},
    'CodeBlocks - Unix Makefiles' => $BASE_GENERATOR_MAP->{'Unix Makefiles'},
    'CodeLite - Unix Makefiles' => $BASE_GENERATOR_MAP->{'Unix Makefiles'},
    'Sublime Text 2 - Unix Makefiles' => $BASE_GENERATOR_MAP->{'Unix Makefiles'},
    'Kate - Unix Makefiles' => $BASE_GENERATOR_MAP->{'Unix Makefiles'},
    'Eclipse CDT4 - Unix Makefiles' => $BASE_GENERATOR_MAP->{'Unix Makefiles'}
};

sub _checkGeneratorIsWhitelisted
{
    my $generator = shift;

    return exists ($GENERATOR_MAP->{$generator});
}

sub _stripGeneratorFromCMakeOptions
{
    my $nextShouldBeGenerator = 0;
    my @filtered = grep {
        my $accept = 1;
        if ($nextShouldBeGenerator) {
            $nextShouldBeGenerator = 0;
            $accept = 0;
        } else {
            my $maybeGenerator = $_;
            if ($maybeGenerator =~ /^-G(\S*(\s*\S)*)\s*/) {
                my $generator = $1 // '';
                $nextShouldBeGenerator = 1 if ($generator eq '');
                $accept = 0;
            }
        }

        $accept == 1;
    } (@_);
    return @filtered;
}

sub _findGeneratorInCMakeOptions
{
    my $nextShouldBeGenerator = 0;
    my @filtered = grep {
        my $accept = 0;
        if ($nextShouldBeGenerator) {
            $nextShouldBeGenerator = 0;
            $accept = 1;
        } else {
            my $maybeGenerator = $_;
            if ($maybeGenerator =~ /^-G(\S*(\s*\S)*)\s*/) {
                my $generator = $1 // '';
                if ($generator ne '') {
                    $accept = 1;
                } else {
                    $nextShouldBeGenerator = 1;
                }
            }
        }

        $accept == 1;
    } (@_);

    for my $found (@filtered) {
        if ($found =~ /^-G(\S*(\s*\S)*)\s*/) {
            $found = $1 // '';
        }
        return $found unless ($found eq '');
    }

    return '';
}

sub _checkToolchainOk
{
    my $toolchain = shift;
    return $toolchain ne '' && -f $toolchain && -r $toolchain;
}

sub _stripToolchainFromCMakeOptions
{
    my @filtered = grep {
        my $accept = 1;
        my $maybeToolchain = $_;
        if ($maybeToolchain =~ /^-DCMAKE_TOOLCHAIN_FILE=(\S*(\s*\S)*)\s*/) {
            $accept = 0;
        }

        $accept == 1;
    } (@_);
    return @filtered;
}

sub _findToolchainInCMakeOptions
{
    my $found = first {
        my $accept = 0;
        my $maybeToolchain = $_;
        if ($maybeToolchain =~ /^-DCMAKE_TOOLCHAIN_FILE=(\S*(\s*\S)*)\s*/) {
            my $file = $1 // '';
            $accept = 1 if (_checkToolchainOk($file));
        }

        $accept == 1;
    } (@_);

    if ($found && $found =~ /^-DCMAKE_TOOLCHAIN_FILE=(\S*(\s*\S)*)\s*/) {
        $found = $1 // '';
        return $found if (_checkToolchainOk($found));
    }

    return '';
}

sub _determineCmakeToolchain
{
    my $self = shift;

    my $module = $self->module();
    my @cmakeOptions = split_quoted_on_whitespace ($module->getOption('cmake-options'));

    my $toolchain = first { _checkToolchainOk($_); } (
        _findToolchainInCMakeOptions(@cmakeOptions),
        $module->getOption('cmake-toolchain')
    );

    return $toolchain // '';
}

sub cmakeToolchain
{
    my $self = shift;
    if (not (exists $self->{cmake_toolchain})) {
        $self->{cmake_toolchain} = $self->_determineCmakeToolchain();
    }
    return $self->{cmake_toolchain};
}

sub hasToolchain
{
    my $self = shift;
    return $self->cmakeToolchain() ne '';
}

# Returns true if CMake is run with ninja, which supports setting -j
# automatically.
sub supportsAutoParallelism ($self)
{
    my $generator     = $self->cmakeGenerator();
    my $generatorOpts = $GENERATOR_MAP->{$generator}->{optionsName};

    return 0
        unless $generatorOpts;

    return 1
        if $generatorOpts eq 'ninja-options';

    return 0;
}

sub _determineCmakeGenerator
{
    my $self = shift;

    my $module = $self->module();
    my @cmakeOptions = split_quoted_on_whitespace ($module->getOption('cmake-options'));

    my $generator = first { _checkGeneratorIsWhitelisted($_); } (
        _findGeneratorInCMakeOptions(@cmakeOptions),
        $module->getOption('cmake-generator'),
        'Unix Makefiles'
    );

    croak_internal("Unable to determine CMake generator for: $module") unless $generator;
    return $generator;
}

sub cmakeGenerator
{
    my $self = shift;
    if (not (exists $self->{cmake_generator})) {
        $self->{cmake_generator} = $self->_determineCmakeGenerator();
    }
    return $self->{cmake_generator};
}

sub needsInstalled
{
    my $self = shift;

    return 0 if $self->name() eq 'kde-common'; # Vestigial
    return 1;
}

sub name
{
    return 'KDE CMake';
}

# Called by the module being built before it runs its build/install process. Should
# setup any needed environment variables, build context settings, etc., in preparation
# for the build and install phases.
sub prepareModuleBuildEnvironment
{
    my ($self, $ctx, $module, $prefix) = @_;

    # Suppress injecting qt-install-dir/install-dir related environment variables if a toolchain is also set
    # Let the toolchain files/definitions take care of themselves.
    return if $self->hasToolchain();

    # Avoid moving /usr up in env vars
    if ($prefix ne '/usr') {
        # Find the normal CMake "config" mode files for find_package()
        $ctx->prependEnvironmentValue('CMAKE_PREFIX_PATH', $prefix);
        # Try to ensure that older "module" mode find_package() calls also point to right directory
        $ctx->prependEnvironmentValue('CMAKE_MODULE_PATH', "$prefix/lib64/cmake:$prefix/lib/cmake");
        # Set the plugin path correctly for configuration-time access e.g. by Extra CMake Modules
        $ctx->prependEnvironmentValue('QT_PLUGIN_PATH', "$prefix/lib64/plugins:$prefix/lib/plugins");
        $ctx->prependEnvironmentValue('XDG_DATA_DIRS', "$prefix/share");
    }

    my $qt_installdir = $module->getOption('qt-install-dir');
    if ($qt_installdir && $qt_installdir ne $prefix) {
        # Ensure we can find Qt5's own CMake modules
        $ctx->prependEnvironmentValue('CMAKE_PREFIX_PATH', $qt_installdir);
        $ctx->prependEnvironmentValue('CMAKE_MODULE_PATH', "$qt_installdir/lib/cmake");
    }
}

# This should return a list of executable names that must be present to
# even bother attempting to use this build system. An empty list should be
# returned if there's no required programs.
sub requiredPrograms
{
    my $self = shift;
    my $generator = $self->cmakeGenerator();
    my @required = @{$GENERATOR_MAP->{$generator}->{requiredPrograms}};
    return @required;
}

# Returns a list of possible build commands to run, any one of which should
# be supported by the build system.
sub buildCommands
{
    my $self = shift;
    my $generator = $self->cmakeGenerator();
    my @progs = @{$GENERATOR_MAP->{$generator}->{buildCommands}};
    return @progs;
}

sub configuredModuleFileName
{
    my $self = shift;
    return 'cmake_install.cmake';
}

sub runTestsuite
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::KDECMake');
    my $module = $self->module();

    # Note that we do not run safe_make, which should really be called
    # safe_compile at this point.

    # Step 1: Ensure the tests are built, oh wait we already did that when we ran
    # CMake :)

    my $make_target = 'test';
    if ($module->getOption('run-tests') eq 'upload') {
        $make_target = 'Experimental';
    }

    info ("\tRunning test suite...");

    # Step 2: Run the tests.
    my $buildCommand = $self->defaultBuildCommand();
    my $numTests = 'Some'; # overwritten by a specific number, hopefully

    my $cmd = ksb::Util::LoggedSubprocess->new
        ->module($module)
        ->log_to('test-results')
        ->set_command([ $buildCommand, $make_target ]);

    $cmd->on(child_output => sub ($cmd, $line) {
        $numTests = $1
            if ($line =~ /([0-9]+) tests failed out of/);
    });

    my $result = await_exitcode($cmd->start);

    if (!$result) {
        my $logDir = $module->getLogDir();
        warning ("\t$numTests tests failed for y[$module], consult $logDir/test-results.log for info");
    } else {
        info ("\tAll tests ran successfully.");
    }

    return $result;
}

# Re-implementing the one in BuildSystem since in CMake we want to call
# make install/fast, so it only installs rather than building + installing
sub installInternal
{
    my $self = shift;
    my $module = $self->module();
    my @cmdPrefix = @_;
    my $generator = $self->cmakeGenerator();
    my $target = $GENERATOR_MAP->{$generator}->{installTarget};

    $target = 'install' if $module->getOption('custom-build-command');

    return $self->safe_make ({
            target => $target,
            message => "Installing g[$module]",
            'prefix-options' => [@cmdPrefix],
            logfile => 'install',
           })->{was_successful};
}

sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::KDECMake');
    my $module = $self->module();

    if ($module->getOption('generate-vscode-project-config')) {
        generateVSCodeConfig($module);
    } else {
        debug ("\tGenerating .vscode directory - disabled for this module");
    }

    # Use cmake to create the build directory (sh script return value
    # semantics).
    if ($self->_safe_run_cmake())
    {
        return 0;
    }

    # handle the linking of compile_commands.json back to source directory if wanted
    # allows stuff like clangd to function out of the box
    if ($module->getOption('compile-commands-linking')) {
        # symlink itself will keep existing files untouched!
        my $builddir = $module->fullpath('build');
        my $srcdir = $module->fullpath('source');
        if (-e "$builddir/compile_commands.json") {
            remake_symlink("$builddir/compile_commands.json", "$srcdir/compile_commands.json");
        }
    }

    return 1;
}

# Generate default config files for VSCode.
#
# This populates the settings VSCode needs to work with most KDE projects,
# such as C++ support, correct build directory, and LSP / IntelliSense.
sub generateVSCodeConfig
{
    if (pretending()) {
        pretend ("\tWould have generated .vscode directory");
        return;
    }
    
    my $module = shift;
    my $projectName = $module->name();
    my $buildDir = $module->fullpath('build');
    my $srcDir = $module->fullpath('source');
    my $installDir = $module->installationPath();
    my $libDir = $module->getOption('libname');
    my $configDir = "$srcDir/.vscode";

    if (-e $configDir) {
        if (-d $configDir) {
            debug ("\tGenerating .vscode directory - skipping as it already exists");
        } elsif (-f $configDir) {
            error ("\tGenerating .vscode directory - cannot proceed, file .vscode exists");
        }  
        return;
    } else {
        debug ("\tGenerating .vscode directory for $projectName: $configDir");
    }

    mkdir($configDir);

    use FindBin;
    my $baseDir = $FindBin::RealBin;
    my $dataDir = "$baseDir/data/vscode";

    # c_cpp_properties.json configures C++, CMake & IntelliSense.
    my $cCppPropertiesJson = _readFile("$dataDir/c_cpp_properties.json.in");

    # settings.json configures the paths for CMake, QML, Qt, etc.
    my $settingsJson = _readFile("$dataDir/settings.json.in");
    $settingsJson =~ s/\$buildDir/$buildDir/g;
    $settingsJson =~ s/\$installDir/$installDir/g;
    $settingsJson =~ s/\$libDir/$libDir/g;

    # extensions.json recommends extensions to install/enable.
    my $extensionsJson = _readFile("$dataDir/extensions.json.in");

    # launch.json configures the run with debugger functionality.
    my $launchJson = _readFile("$dataDir/launch.json.in");

    _writeToFile("$configDir/c_cpp_properties.json", $cCppPropertiesJson);
    _writeToFile("$configDir/settings.json", $settingsJson);
    _writeToFile("$configDir/extensions.json", $extensionsJson);
    _writeToFile("$configDir/launch.json", $launchJson);

    return 1;
}

# Reads the contents of a file.
# 
# Arguments:
#  $file_path: The path to the file to read.
# 
# Returns: The contents of the file as a string.
sub _readFile
{
    my ($file_path) = @_;

    open my $file, '<', $file_path or warning("\tCouldn't open $file_path: $!");
    my $content = do { local $/; <$file> };
    close $file;

    return $content;
}

# Writes content to a file.
# 
# Arguments:
#  $file_path: The path to the file to write to.
#  $content: The content to write to the file.
#
# Returns: Nothing.
sub _writeToFile
{
    my ($file_path, $content) = @_;

    open my $file, '>', $file_path or warning("\tCouldn't open $file_path: $!");
    print $file $content or warning("\tCouldn't write to $file_path: $!");
    close $file or warning("\tError closing $file_path: $!");
}

# Return value style: hashref to build results object (see ksb::BuildSystem::safe_make)
sub buildInternal
{
    my $self = shift;
    my $generator = $self->cmakeGenerator();
    my $defaultOptionsName = $GENERATOR_MAP->{$generator}->{optionsName};
    my $optionsName = shift // "$defaultOptionsName";

    return $self->SUPER::buildInternal($optionsName);
}

### Internal package functions.

# Subroutine to run CMake to create the build directory for a module.
# CMake is not actually run if pretend mode is enabled.
#
# First parameter is the module to run cmake on.
# Return value is the shell return value as returned by log_command().  i.e.
# 0 for success, non-zero for failure.
sub _safe_run_cmake
{
    my $self = shift;
    my $module = $self->module();
    my $generator = $self->cmakeGenerator();
    my $toolchain = $self->cmakeToolchain();
    my $srcdir = $module->fullpath('source');
    my @commands = split_quoted_on_whitespace ($module->getOption('cmake-options'));

    # grep out empty fields
    @commands = grep {!/^\s*$/} @commands;
    @commands = _stripGeneratorFromCMakeOptions(@commands);
    @commands = _stripToolchainFromCMakeOptions(@commands);

    unshift @commands, "-DCMAKE_TOOLCHAIN_FILE=$toolchain" if $toolchain ne '';

    # generate a compile_commands.json if requested for e.g. clangd tooling
    unshift @commands, "-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON" if $module->getOption('compile-commands-export');

    # Add -DBUILD_foo=OFF options for the directories in do-not-compile.
    # This will only work if the CMakeLists.txt file uses macro_optional_add_subdirectory()
    my @masked_directories = split(' ', $module->getOption('do-not-compile'));
    push @commands, "-DBUILD_$_=OFF" foreach @masked_directories;

    # Get the user's CXXFLAGS, use them if specified and not already given
    # on the command line.
    my $cxxflags = $module->getOption('cxxflags');
    if ($cxxflags and not grep { /^-DCMAKE_CXX_FLAGS(:\w+)?=/ } @commands)
    {
        push @commands, "-DCMAKE_CXX_FLAGS:STRING=$cxxflags";
    }

    my $installdir = $module->installationPath();

    push @commands, "-DCMAKE_INSTALL_PREFIX=$installdir";

    # Add custom Qt to the prefix (but don't overwrite a user-set install-dir)
    my $qt_installdir = $module->getOption('qt-install-dir');
    if ($qt_installdir && $qt_installdir ne $installdir &&
        !grep { /^\s*-DCMAKE_PREFIX_PATH/ } (@commands)
       )
    {
        push @commands, "-DCMAKE_PREFIX_PATH=$qt_installdir";
    }

    if ($module->getOption('run-tests') &&
        !grep { /^\s*-DBUILD_TESTING(:BOOL)?=(ON|TRUE|1)\s*$/ } (@commands)
       )
    {
        whisper ("Enabling tests");
        push @commands, "-DBUILD_TESTING:BOOL=ON";
    }

    if ($module->getOption('run-tests') eq 'upload')
    {
        whisper ("Enabling upload of test results");
        push @commands, "-DBUILD_experimental:BOOL=ON";
    }

    unshift @commands, 'cmake', '-B', '.', '-S', $srcdir, '-G', $generator; # Add to beginning of list.

    my $old_options =
        $module->getPersistentOption('last-cmake-options') || '';
    my $builddir = $module->fullpath('build');

    if (($old_options ne get_list_digest(@commands)) ||
        $module->getOption('reconfigure') ||
        ! -e "$builddir/CMakeCache.txt" # File should exist only on successful cmake run
       )
    {
        info ("\tRunning g[cmake] targeting b[$generator]...");

        # Remove any stray CMakeCache.txt
        safe_unlink ("$srcdir/CMakeCache.txt")   if -e "$srcdir/CMakeCache.txt";
        safe_unlink ("$builddir/CMakeCache.txt") if -e "$builddir/CMakeCache.txt";

        $module->setPersistentOption('last-cmake-options', get_list_digest(@commands));

        # await_result, not await_exitcode, to match return semantic
        return await_result(run_logged_p($module, "cmake", $builddir, \@commands));
    }

    # Skip cmake run
    return 0;
}

1;
