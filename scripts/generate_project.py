#!/usr/bin/env python3
"""Generate a deterministic, dependency-free Xcode project. No XcodeGen needed."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sources = sorted([*root.glob("AdaptivePDF/**/*.swift"), *root.glob("AdaptivePDF/**/*.mm"), *root.glob("Tests/*.swift")])
ui_sources = sorted(root.glob("Tests/UITests/*.swift"))
def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def q(value):
    return '"' + str(value).replace('"', '\\"') + '"'

project, group, products, target, app, phase, resources_phase = map(uid, ["project", "group", "products", "target", "app", "phase", "resources"])
ui_target, ui_product, ui_phase, ui_dependency, ui_proxy = map(uid, ["ui-target", "ui-product", "ui-phase", "ui-dependency", "ui-proxy"])
objects = []
refs, builds = [], []
for source in sources:
    relative = str(source.relative_to(root))
    ref, build = uid(relative), uid(relative + "build")
    refs.append(ref)
    builds.append(build)
    kind = "sourcecode.cpp.objcpp" if source.suffix == ".mm" else "sourcecode.swift"
    objects.append(f'{ref} = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(relative)}; sourceTree = "<group>"; }};')
    objects.append(f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};')
resource_builds = []
ui_builds = []
for source in ui_sources:
    relative = str(source.relative_to(root))
    ref, build = uid(relative), uid(relative + "build")
    refs.append(ref)
    ui_builds.append(build)
    objects.append(f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(relative)}; sourceTree = "<group>"; }};')
    objects.append(f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};')
for resource in sorted(root.glob("AdaptivePDF/Resources/*")):
    if not resource.is_file():
        continue
    relative = str(resource.relative_to(root))
    ref, build = uid(relative), uid(relative + "build")
    refs.append(ref)
    resource_builds.append(build)
    kind = "image.icns" if resource.suffix == ".icns" else "text"
    objects.append(f'{ref} = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(relative)}; sourceTree = "<group>"; }};')
    objects.append(f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};')
library_ref, library_link, library_copy, framework_phase, embed_phase = map(uid, ["qpdf-ref", "qpdf-link", "qpdf-copy", "frameworks", "embed-frameworks"])
refs.append(library_ref)
objects += [
    f'{library_ref} = {{isa = PBXFileReference; lastKnownFileType = compiled.mach-o.dylib; path = "Vendor/qpdf/lib/libqpdf.30.dylib"; sourceTree = "<group>"; }};',
    f'{library_link} = {{isa = PBXBuildFile; fileRef = {library_ref}; }};',
    f'{library_copy} = {{isa = PBXBuildFile; fileRef = {library_ref}; settings = {{ATTRIBUTES = (CodeSignOnCopy,); }}; }};',
    f'{framework_phase} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({library_link},); runOnlyForDeploymentPostprocessing = 0; }};',
    f'{embed_phase} = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = ({library_copy},); name = "Embed qpdf"; runOnlyForDeploymentPostprocessing = 0; }};',
    f'{app} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = AdaptivePDF.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
    f'{ui_product} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = AdaptivePDFUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};',
    f'{products} = {{isa = PBXGroup; children = ({app},{ui_product},); name = Products; sourceTree = "<group>"; }};',
    f'{group} = {{isa = PBXGroup; children = ({",".join(refs)}, {products},); sourceTree = "<group>"; }};',
    f'{phase} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0; }};',
    f'{resources_phase} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0; }};',
    f'{ui_phase} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ui_builds)},); runOnlyForDeploymentPostprocessing = 0; }};',
    f'{ui_proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = AdaptivePDF; }};',
    f'{ui_dependency} = {{isa = PBXTargetDependency; target = {target}; targetProxy = {ui_proxy}; }};'
]
for owner in ["project", "target", "ui-target"]:
    configs = []
    for config in ["Debug", "Release"]:
        config_id = uid(owner + config)
        configs.append(config_id)
        settings = {
            "MACOSX_DEPLOYMENT_TARGET": "15.0", "SDKROOT": "macosx", "SWIFT_VERSION": "5.0",
            "CLANG_ENABLE_MODULES": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if config == "Debug" else "",
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        }
        if owner == "target":
            settings.update({
                "PRODUCT_NAME": "AdaptivePDF", "PRODUCT_BUNDLE_IDENTIFIER": "local.adaptivepdf.reader",
                "INFOPLIST_FILE": "AdaptivePDF/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
                "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-",
                "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "NO",
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
                "SUPPORTED_PLATFORMS": "macosx", "ARCHS": "$(ARCHS_STANDARD)",
                "MARKETING_VERSION": "1.0.0", "CURRENT_PROJECT_VERSION": "12",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES" if config == "Debug" else "NO",
                "SWIFT_OBJC_BRIDGING_HEADER": "AdaptivePDF/AdaptivePDF-Bridging-Header.h",
                "CLANG_CXX_LANGUAGE_STANDARD": "c++20", "CLANG_ENABLE_OBJC_ARC": "YES",
                "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/Vendor/qpdf/include",
                "LIBRARY_SEARCH_PATHS": "$(inherited) $(SRCROOT)/Vendor/qpdf/lib",
            })
        if owner == "ui-target":
            settings.update({
                "PRODUCT_NAME": "AdaptivePDFUITests", "PRODUCT_BUNDLE_IDENTIFIER": "local.adaptivepdf.reader.UITests",
                "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-",
                "TEST_TARGET_NAME": "AdaptivePDF", "ENABLE_TESTING_SEARCH_PATHS": "YES",
                "ENABLE_APP_SANDBOX": "NO",
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
            })
        body = " ".join(f'{key} = {q(value)};' for key, value in settings.items())
        objects.append(f'{config_id} = {{isa = XCBuildConfiguration; buildSettings = {{{body}}}; name = {config}; }};')
    objects.append(f'{uid(owner + "configs")} = {{isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
objects += [
    f'{target} = {{isa = PBXNativeTarget; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({phase},{framework_phase},{resources_phase},{embed_phase},); buildRules = (); dependencies = (); name = AdaptivePDF; productName = AdaptivePDF; productReference = {app}; productType = "com.apple.product-type.application"; }};',
    f'{ui_target} = {{isa = PBXNativeTarget; buildConfigurationList = {uid("ui-targetconfigs")}; buildPhases = ({ui_phase},); buildRules = (); dependencies = ({ui_dependency},); name = AdaptivePDFUITests; productName = AdaptivePDFUITests; productReference = {ui_product}; productType = "com.apple.product-type.bundle.ui-testing"; }};',
    f'{project} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 1620; TargetAttributes = {{{ui_target} = {{TestTargetID = {target}; }}; }}; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (zh_CN, en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},{ui_target},); }};',
]
destination = root / "AdaptivePDF.xcodeproj"
destination.mkdir(exist_ok=True)
(destination / "project.pbxproj").write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + "\n".join(objects) + f'\n}}; rootObject = {project}; }}\n')
schemes = destination / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "AdaptivePDF.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AdaptivePDF.app" BlueprintName="AdaptivePDF" ReferencedContainer="container:AdaptivePDF.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AdaptivePDF.app" BlueprintName="AdaptivePDF" ReferencedContainer="container:AdaptivePDF.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {destination} with {len(sources)} application/test source files")
(schemes / "AdaptivePDFUITests.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="AdaptivePDFUITests.xctest" BlueprintName="AdaptivePDFUITests" ReferencedContainer="container:AdaptivePDF.xcodeproj"/></BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="AdaptivePDFUITests.xctest" BlueprintName="AdaptivePDFUITests" ReferencedContainer="container:AdaptivePDF.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AdaptivePDF.app" BlueprintName="AdaptivePDF" ReferencedContainer="container:AdaptivePDF.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<AnalyzeAction buildConfiguration="Debug"/>
</Scheme>
''')
