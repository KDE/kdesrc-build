# Loads every single ksb module to make sure they all compile.
use ksb;
use Test::More import => ['!note'];
use POSIX;
use File::Basename;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

use ksb;
use ksb::Application;
use ksb::BuildContext;
use ksb::BuildException;
use ksb::BuildSystem;
use ksb::BuildSystem::Autotools;
use ksb::BuildSystem::CMakeBootstrap;
use ksb::BuildSystem::KDECMake;
use ksb::BuildSystem::Meson;
use ksb::BuildSystem::QMake;
use ksb::BuildSystem::QMake6;
use ksb::BuildSystem::Qt4;
use ksb::BuildSystem::Qt5;
use ksb::BuildSystem::Qt6;
use ksb::Cmdline;
use ksb::Debug;
use ksb::DebugOrderHints;
use ksb::DependencyResolver;
use ksb::FirstRun;
use ksb::IPC;
use ksb::IPC::Null;
use ksb::IPC::Pipe;
use ksb::KDEProjectsReader;
use ksb::Module;
use ksb::Module::BranchGroupResolver;
use ksb::ModuleResolver;
use ksb::ModuleSet;
use ksb::ModuleSet::KDEProjects;
use ksb::ModuleSet::Null;
use ksb::ModuleSet::Qt;
use ksb::OptionsBase;
use ksb::OSSupport;
use ksb::PhaseList;
use ksb::RecursiveFH;
use ksb::StatusView;
use ksb::TaskManager;
use ksb::Updater;
use ksb::Updater::Git;
use ksb::Updater::KDEProject;
use ksb::Updater::KDEProjectMetadata;
use ksb::Updater::Qt5;
use ksb::Util;
use ksb::Util::LoggedSubprocess;
use ksb::Version;

ok(1 == 1, "Able to compile and load all kdesrc-build modules.");

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
