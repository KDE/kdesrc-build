# Loads every single ksb module to make sure they all compile.
use ksb;
use Test::More import => ['!note'];

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
use ksb::BuildSystem::Qt4;
use ksb::BuildSystem::Qt5;
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
use ksb::Updater;
use ksb::Updater::Bzr;
use ksb::Updater::Git;
use ksb::Updater::KDEProject;
use ksb::Updater::KDEProjectMetadata;
use ksb::Updater::Qt5;
use ksb::Updater::Svn;
use ksb::Util;
use ksb::Version;

ok(1 == 1, "Able to compile and load all kdesrc-build modules.");

done_testing();
