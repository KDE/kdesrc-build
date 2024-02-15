#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2024 Andrew Shark <ashark@linuxcomp.ru>
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""
This script generates the zsh completions file.
"""

import os.path
import subprocess

p = subprocess.run("./kdesrc-build --show-options-specifiers", cwd=os.path.expanduser(os.getcwd() + "/.."), shell=True, capture_output=True, text=True).stdout
specifiers = p.split("\n")
specifiers = list(filter(None, specifiers))  # remove empty string from last line
specifiers.sort()
if not specifiers:
    print("Cannot get options specifiers")
    exit(1)


individual_options = []
conflicting_sets = []
set_tails = {}

# Manually handled conflicts. No need to fully specify the set, just add one option from each, and final conflict set will contain all elements from conflicting sets.
# A single option such as "--quiet" is considered as a set of one element.
conflicting_sets.extend([
    {"--dependency-tree", "--dependency-tree-fullpath"},
    {"--src-only", "--no-src"},
    {"--resume-from", "--resume-after"},
    {"--stop-before", "--stop-after"},
    {"--quiet", "--really-quiet", "--verbose", "--debug"},
    {"--show-info", "--show-options-specifiers", "--version"},
    {"--metadata-only", "--no-metadata"},
    {"--build-only", "--no-build"},
    {"--install-only", "--no-install"},
    {"-d", "-D", "--include-dependencies"}
])


# Returns the id of set to which the conflicting_options were added
def add_conflicting_options(conflicting_options: list) -> int:
    for conflicting_set in conflicting_sets:
        for conflicting_option in conflicting_options:
            if conflicting_option in conflicting_set:
                conflicting_set.update(conflicting_options)
                return id(conflicting_set)
    new_set = set(conflicting_options)
    conflicting_sets.append(new_set)
    return id(new_set)


# Start parsing specifiers
for line in specifiers:
    nargs = None
    negatable = False
    
    if line.endswith("=s"):
        nargs = 1
        line = line.removesuffix("=s")
    elif line.endswith("!"):
        nargs = 0
        line = line.removesuffix("!")
        negatable = True
    elif line.endswith("=s{,}"):
        nargs = -1  # unlimited
        line = line.removesuffix("=s{,}")
    elif line.endswith(":10"):  # for --nice
        nargs = 1  # will assume it is mandatory
        line = line.removesuffix(":10")
    else:
        nargs = 0
    
    parts = line.split("|")
    dashed_parts = []
    for part in parts:
        if len(part) == 1:
            dashed_parts.append("-" + part)
        else:
            dashed_parts.append("--" + part)
            if negatable:
                dashed_parts.append("--no-" + part)
                add_conflicting_options(dashed_parts)
    set_id = add_conflicting_options(dashed_parts)
    individual_options.extend(dashed_parts)
    
    if nargs == 0:
        set_tails[set_id] = ""
    elif nargs == 1:
        if line == "rc-file":
            set_tails[set_id] = "\":::_files\""
            continue
        elif any(option for option in ["--resume-from", "--stop-before"] if option in dashed_parts):
            set_tails[set_id] = "\":::_kdesrc-build_modules\""
            continue
        set_tails[set_id] = "\":argument:\""
    else:  # infinite
        if any(option for option in ["--ignore-modules"] if option in dashed_parts):
            set_tails[set_id] = "\":::_kdesrc-build_modules\""
            continue
        set_tails[set_id] = "\":arguments:\""

all_conflicting = []
for conflicting_set in conflicting_sets:
    all_conflicting.extend(list(conflicting_set))

not_conflicting = []
for individual_option in individual_options:
    if individual_option not in all_conflicting:
        not_conflicting.append(individual_option)

# Adding descriptions:
# Note: Use "Edit | Sort Lines" to sort them alphabetically
short_descriptions = {  # contains one of the options (any of them) from set, and description for a set
    "--async": "Perform source update and build process in parallel",
    "--binpath": "Set the environment variable PATH while building",
    "--branch": "Checkout the specified branch",
    "--branch-group": "General group from which you want modules to be chosen",
    "--build-dir": "The directory that contains the built sources",
    "--build-only": "Only perform/Skip the build process.",
    "--build-system-only": "Abort building a module just before the make command",
    "--cmake-generator": "Which generator to use with CMake",
    "--cmake-options": "Flags to pass to CMake when creating the build system for the module",
    "--cmake-toolchain": "Specify a toolchain file to use with CMake",
    "--color": "Toggle colorful output",
    "--compile-commands-export": "Generation of a compile_commands.json",
    "--compile-commands-linking": "Creation of symbolic links from compile_commands.json to source directory",
    "--configure-flags": "Flags to pass to ./configure ",
    "--custom-build-command": "Run a different command in order to perform the build process",
    "--cxxflags": "Flags to use for building the module",
    "--delete-my-patches": "Let kdesrc-build delete source directories that may contain user data",
    "--delete-my-settings": "Overwrite existing files which may contain user data",
    "--dependency-tree": "Print out dependency information on the modules that would be built",
    "--dest-dir": "The name a module is given on disk",
    "--directory-layout": "Layout which kdesrc-build should use when creating source and build directories",
    "--disable-agent-check": "Prevent ssh from asking for your pass phrase for every module",
    "--do-not-compile": "Select a specific set of directories not to be built in a module",
    "--force-build": "Disable skipping the build process.",
    "--generate-config": "Installs a base kdesrc-buildrc",
    "--generate-vscode-project-config": "Generate a vscode project config",
    "--help": "Displays help on commandline options",
    "--http-proxy": "Use specified URL as a proxy server for any HTTP network communications",
    "--ignore-modules": "Do not include specified modules in the update/build process",
    "--include-dependencies": "Builds/Skip KDE-based dependencies",
    "--initial-setup": "Installs Plasma env vars (~/.bashrc), required system pkgs, and a base kdesrc-buildrc",
    "--install-after-build": "Install the package after it successfully builds",
    "--install-dir": "Where to install the module after it is built",
    "--install-distro-packages": "Installs required system pkgs",
    "--install-environment-driver": "Install script to easily establish needed environment variables to run the built Plasma",
    "--install-only": "Only perform/Skip the install process",
    "--install-session-driver": "Install a driver for the graphical login manager",
    "--libname": "Default name of the installed library directory",
    "--libpath": "Set the environment variable LD_LIBRARY_PATH while building",
    "--log-dir": "Directory used to hold the log files generated by the script",
    "--make-install-prefix": "A command and its options to precede the make install command used to install modules",
    "--make-options": "Pass command line options to the make command",
    "--metadata-only": "Only perform/Skip the metadata download process",
    "--nice": "Priority kdesrc-build will set for itself",
    "--ninja-options": "Pass command line options to the ninja build command",
    "--no-tests": "Tests",
    "--num-cores": "Set the number of available CPUs",
    "--num-cores-low-mem": "Set the number of CPUs that is deemed safe for heavyweight or other highly-intensive modules",
    "--override-build-system": "Manually specify the correct build type",
    "--persistent-data-file": "Change where kdesrc-build stores its persistent data",
    "--pretend": "Dont actually take major actions, instead describe what would be done",
    "--purge-old-logs": "Automatically delete old log directories",
    "--qmake-options": "Options passed to the qmake command",
    "--qt-install-dir": "Where to install qt modules after build",
    "--query": "Query a parameter of the modules in the build list",
    "--rc-file": "Read configuration from filename instead of default",
    "--rebuild-failures": "Only those modules which failed to build on a previous run.",
    "--reconfigure": "Run cmake or configure again, without cleaning the build directory",
    "--refresh-build": "Start the build from scratch",
    "--remove-after-install": "Delete the source and/or build directory after the module is successfully installed",
    "--resume": "Resume after a build failure",
    "--resume-from": "Skips modules until just before or after the given package, then operates as normal",
    "--revision": "Checkout a specific numbered revision",
    "--run": "A program to run with kdesrc-build",
    "--run-tests": "Built the modules with support for running their test suite",
    "--set-module-option-value": "Override an option in your configuration file for a specific module",
    "--source-dir": "Directory that stores the KDE sources",
    "--src-only": "Only perform/Skip update source code",
    "--stop-before": "Stops just before or after the given package is reached",
    "--stop-on-failure": "Stops/Does not stop the build as soon as a package fails to build",
    "--tag": "Download a specific release of a module",
    "--uninstall": "Uninstalls the module",
    "--use-clean-install": "Run make uninstall directly before running make install",
    "--use-idle-io-priority ": "Use lower priority for disk and other I/O",
    "--use-inactive-modules": "Allow kdesrc-build to also clone and pull from repositories marked as inactive",
    "--verbose": "Change the level of verbosity",
    "--version": "Script information",
}

for conflicting_set in conflicting_sets:
    for opt in list(conflicting_set):
        if opt in short_descriptions:
            set_tails[id(conflicting_set)] = f"\"[{short_descriptions[opt]}]\"" + set_tails[id(conflicting_set)]
            break


# sort first by positive options; positive and negative goes in pair.
def set_sort(input_set) -> list:
    listed = list(input_set)
    
    negative = []
    positive = []
    
    for el in listed:
        if el.startswith("--no-"):
            negative.append(el)
        else:
            positive.append(el)
    
    result = []
    positive.sort()
    
    while len(positive) > 0:
        el = positive.pop(0)
        result.append(el)
        if "--no-" + el.removeprefix("--") in negative:
            result.append("--no-" + el.removeprefix("--"))
            negative.remove("--no-" + el.removeprefix("--"))
    
    negative.sort()
    while len(negative) > 0:
        result.append(negative.pop(0))
    
    return result


# Start printing
print("""\
#compdef kdesrc-build kde-builder

# Autogenerated by gen_zsh_completions.py. Do not edit it manually.
# See https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/supported-cmdline-params.html for description of options

_arguments \\\
""")

for conflicting_set in conflicting_sets:
    if len(conflicting_set) > 1:
        sting_spaced = " ".join(set_sort(conflicting_set))
        sting_commaed = ",".join(set_sort(conflicting_set))
        
        appending = set_tails[id(conflicting_set)]
        print(f"  \"({sting_spaced})\"{{{sting_commaed}}}{appending} \\")
    else:
        appending = set_tails[id(conflicting_set)]
        print(f"  \"{list(conflicting_set)[0]}\"{appending} \\")

print("""\
  \\
  "*:: :_kdesrc-build_modules"\
""")
