#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2024 Andrew Shark <ashark@linuxcomp.ru>
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""
This script generates the zsh completions file.
"""

import os.path
import subprocess

p = subprocess.run("./kdesrc-build --show-options-specifiers", cwd=os.path.expanduser("~/kde6"), shell=True, capture_output=True, text=True).stdout
specifiers = p.split("\n")
specifiers = list(filter(None, specifiers))  # remove empty string from last line
specifiers.sort()

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
short_descriptions = {  # contains one of the options (any of them) from set, and description for a set
  "--help": "Displays help on commandline options",
  "--version": "Displays version information",
  "--pretend": "Dont actually take major actions, instead describe what would be done",
  "--list-build": "List what modules would be built in the order in which they would be built",
  "--dependency-tree": "Print out dependency information on the modules that would be built",
  "--src-only": "Only perform/Skip update source code",
  "--refresh-build": "Start the build from scratch",
  "--rc-file": "Read configuration from filename instead of default",
  "--initial-setup": "Installs Plasma env vars (~/.bashrc), required system pkgs, and a base kdesrc-buildrc",
  "--install-distro-packages": "Installs required system pkgs",
  "--generate-config": "Installs a base kdesrc-buildrc",
  "--update-shellrc": "Installs Plasma env vars (~/.bashrc)",
  "--resume-from": "Skips modules until just before or after the given package, then operates as normal",
  "--stop-before": "Stops just before or after the given package is reached",
  "--include-dependencies": "Builds/Skip KDE-based dependencies",
  "--stop-on-failure": "Stops/Does not stop the build as soon as a package fails to build",
  "--quiet": "Do not be as noisy with the output.",
  "--really-quiet": "Only output warnings and errors.",
  "--verbose": "Be very descriptive about what is going on, and what kdesrc-build is doing.",
  "--show-info": "Displays information about kdesrc-build and the operating system",
  "--color": "Toggle colorful output",
  "--metadata-only": "Only perform/Skip the metadata download process",
  "--build-only": "Only perform/Skip the build process.",
  "--install-only": "Only perform/Skip the install process",
  "--rebuild-failures": "Only those modules which failed to build on a previous run.",
  "--force-build": "Disable skipping the build process.",
  "--resume": "Resume after a build failure",
  "--generate-vscode-project-config": "Generate a vscode project config",
}

for conflicting_set in conflicting_sets:
    if len(conflicting_set) > 1:
        for opt in list(conflicting_set):
            if opt in short_descriptions:
                set_tails[id(conflicting_set)] = f"\"[{short_descriptions[opt]}]\"" + set_tails[id(conflicting_set)]
                break

# Start printing
print("""\
#compdef kdesrc-build"

# Autogenerated by gen_zsh_completions.py. Do not edit it manually.
# See https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/supported-cmdline-params.html for description of options

_arguments \\\
""")

for conflicting_set in conflicting_sets:
    if len(conflicting_set) > 1:
        sting_spaced = " ".join(list(conflicting_set))
        sting_commaed = ",".join(list(conflicting_set))
        
        appending = set_tails[id(conflicting_set)]
        print(f"  \"({sting_spaced})\"{{{sting_commaed}}}{appending} \\")
    else:
        appending = set_tails[id(conflicting_set)]
        print(f"  \"{list(conflicting_set)[0]}\"{appending} \\")

print("""\
  \\
  "*:: :_kdesrc-build_modules"\
""")
