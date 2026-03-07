#!/usr/bin/env python3
"""Add Swift files to the Fantastty Xcode project.

Usage:
  python3 scripts/add_to_xcode.py --source Fantastty/Models/TmuxControlMode/TmuxEvent.swift
  python3 scripts/add_to_xcode.py --test FantasttyTests/TmuxProtocolParserTests.swift
  python3 scripts/add_to_xcode.py --create-test-target
"""

import argparse
import hashlib
import os
import re
import sys

PBXPROJ = "Fantastty.xcodeproj/project.pbxproj"

# Known UUIDs from the project
MAIN_TARGET_UUID = "CB5692159373E500BD905E3F"
MAIN_SOURCES_PHASE_UUID = "ED910C49EDEE49A83A2DFB84"
MODELS_GROUP_UUID = "45158AA4C8059D62D1F22F87"
PROJECT_UUID = "905EFD1D59D9230BA485D851"
MAIN_GROUP_UUID = "2E46A21E389E5A68179E9553"
MAIN_BUILD_CONFIG_LIST = "1F3AD90E8C542E9F08B021C3"

# UUIDs we'll generate deterministically for the test target
TEST_TARGET_UUID = "F1E2D3C4B5A69788A1B2C3D4"
TEST_SOURCES_PHASE_UUID = "F2E3D4C5B6A7988BA2B3C4D5"
TEST_GROUP_UUID = "F3E4D5C6B7A8A99CA3B4C5D6"
TEST_PRODUCT_UUID = "F4E5D6C7B8A9BAADA4B5C6D7"
TEST_BUILD_CONFIG_LIST = "F5E6D7C8B9AACBBEA5B6C7D8"
TEST_DEBUG_CONFIG_UUID = "F6E7D8C9BAABDCCFA6B7C8D9"
TEST_RELEASE_CONFIG_UUID = "F7E8D9CABBBCEDDAB7C8D9EA"
TEST_FRAMEWORKS_PHASE = "F8E9DACBCCCDFEEBC8D9EAFB"
TMUX_CONTROL_MODE_GROUP_UUID = "A0B1C2D3E4F5A6B7C8D9E0F1"


def gen_uuid(seed: str) -> str:
    """Generate a deterministic 24-char hex UUID from a seed string."""
    h = hashlib.sha256(seed.encode()).hexdigest()[:24].upper()
    return h


def read_pbxproj() -> str:
    with open(PBXPROJ, "r") as f:
        return f.read()


def write_pbxproj(content: str):
    with open(PBXPROJ, "w") as f:
        f.write(content)


def add_source_file(filepath: str):
    """Add a Swift source file to the main target."""
    content = read_pbxproj()
    filename = os.path.basename(filepath)

    # Generate UUIDs
    file_ref_uuid = gen_uuid(f"fileref-{filepath}")
    build_file_uuid = gen_uuid(f"buildfile-{filepath}")

    # Check if already added
    if file_ref_uuid in content or filename in content:
        # Check more carefully - the filename might exist for a different path
        if file_ref_uuid in content:
            print(f"  Already in project: {filepath}")
            return
        # filename exists but might be a different file, use the UUID check
        pass

    # 1. Add PBXBuildFile entry
    build_file_line = f"\t\t{build_file_uuid} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_uuid} /* {filename} */; }};\n"
    content = content.replace(
        "/* End PBXBuildFile section */",
        f"{build_file_line}/* End PBXBuildFile section */",
    )

    # 2. Add PBXFileReference entry
    file_ref_line = f'\t\t{file_ref_uuid} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = "<group>"; }};\n'
    content = content.replace(
        "/* End PBXFileReference section */",
        f"{file_ref_line}/* End PBXFileReference section */",
    )

    # 3. Add to appropriate group
    if "TmuxControlMode/" in filepath:
        # Add to TmuxControlMode group (create if needed)
        if TMUX_CONTROL_MODE_GROUP_UUID not in content:
            _create_tmux_control_mode_group(content)
            content = read_pbxproj()  # re-read after modification
        group_uuid = TMUX_CONTROL_MODE_GROUP_UUID
    elif "Views/" in filepath:
        # Find Views group
        group_uuid = _find_group_uuid(content, "Views")
    elif "Models/" in filepath:
        group_uuid = MODELS_GROUP_UUID
    else:
        group_uuid = MAIN_GROUP_UUID

    # Insert into group's children
    content = _add_to_group(content, group_uuid, file_ref_uuid, filename)

    # 4. Add to Sources build phase
    source_line = f"\t\t\t\t{build_file_uuid} /* {filename} in Sources */,\n"
    # Find the Sources phase and add before closing paren
    pattern = rf"({MAIN_SOURCES_PHASE_UUID}.*?files = \(.*?)(^\t\t\t\);)"
    content = re.sub(
        pattern,
        rf"\1{source_line}\2",
        content,
        flags=re.DOTALL | re.MULTILINE,
    )

    write_pbxproj(content)
    print(f"  Added to main target: {filepath}")


def add_test_file(filepath: str):
    """Add a Swift test file to the test target."""
    content = read_pbxproj()
    filename = os.path.basename(filepath)

    if TEST_TARGET_UUID not in content:
        print("  ERROR: Test target not found. Run --create-test-target first.")
        sys.exit(1)

    file_ref_uuid = gen_uuid(f"fileref-{filepath}")
    build_file_uuid = gen_uuid(f"buildfile-test-{filepath}")

    if file_ref_uuid in content:
        print(f"  Already in project: {filepath}")
        return

    # 1. Add PBXBuildFile
    build_file_line = f"\t\t{build_file_uuid} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_uuid} /* {filename} */; }};\n"
    content = content.replace(
        "/* End PBXBuildFile section */",
        f"{build_file_line}/* End PBXBuildFile section */",
    )

    # 2. Add PBXFileReference
    file_ref_line = f'\t\t{file_ref_uuid} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = "<group>"; }};\n'
    content = content.replace(
        "/* End PBXFileReference section */",
        f"{file_ref_line}/* End PBXFileReference section */",
    )

    # 3. Add to test group
    content = _add_to_group(content, TEST_GROUP_UUID, file_ref_uuid, filename)

    # 4. Add to test Sources build phase
    source_line = f"\t\t\t\t{build_file_uuid} /* {filename} in Sources */,\n"
    pattern = rf"({TEST_SOURCES_PHASE_UUID}.*?files = \(.*?)(^\t\t\t\);)"
    content = re.sub(
        pattern,
        rf"\1{source_line}\2",
        content,
        flags=re.DOTALL | re.MULTILINE,
    )

    write_pbxproj(content)
    print(f"  Added to test target: {filepath}")


def create_test_target():
    """Add the FantasttyTests target to the project."""
    content = read_pbxproj()

    if TEST_TARGET_UUID in content:
        print("  Test target already exists.")
        return

    # Create FantasttyTests directory
    os.makedirs("FantasttyTests", exist_ok=True)

    # 1. Add PBXFileReference for the test product
    product_ref = f'\t\t{TEST_PRODUCT_UUID} /* FantasttyTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = FantasttyTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
    content = content.replace(
        "/* End PBXFileReference section */",
        f"{product_ref}/* End PBXFileReference section */",
    )

    # 2. Add PBXGroup for FantasttyTests
    test_group = f"""\t\t{TEST_GROUP_UUID} /* FantasttyTests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t);
\t\t\tpath = FantasttyTests;
\t\t\tsourceTree = "<group>";
\t\t}};
"""
    content = content.replace(
        "/* End PBXGroup section */",
        f"{test_group}/* End PBXGroup section */",
    )

    # 3. Add test group to main group's children
    content = _add_to_group(content, MAIN_GROUP_UUID, TEST_GROUP_UUID, "FantasttyTests")

    # 4. Add test product to Products group
    products_group = _find_group_uuid(content, "Products")
    if products_group:
        content = _add_to_group(content, products_group, TEST_PRODUCT_UUID, "FantasttyTests.xctest")

    # 5. Add PBXSourcesBuildPhase for tests
    test_sources = f"""\t\t{TEST_SOURCES_PHASE_UUID} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
    content = content.replace(
        "/* End PBXSourcesBuildPhase section */",
        f"{test_sources}/* End PBXSourcesBuildPhase section */",
    )

    # 6. Add PBXFrameworksBuildPhase for tests (empty)
    test_frameworks = f"""\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
    content = content.replace(
        "/* End PBXFrameworksBuildPhase section */",
        f"{test_frameworks}/* End PBXFrameworksBuildPhase section */",
    )

    # 7. Add PBXNativeTarget for tests
    test_target = f"""\t\t{TEST_TARGET_UUID} /* FantasttyTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TEST_BUILD_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "FantasttyTests" */;
\t\t\tbuildPhases = (
\t\t\t\t{TEST_SOURCES_PHASE_UUID} /* Sources */,
\t\t\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = FantasttyTests;
\t\t\tproductName = FantasttyTests;
\t\t\tproductReference = {TEST_PRODUCT_UUID} /* FantasttyTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
"""
    content = content.replace(
        "/* End PBXNativeTarget section */",
        f"{test_target}/* End PBXNativeTarget section */",
    )

    # 8. Add test target to project's targets list
    content = content.replace(
        f"targets = (\n\t\t\t\t{MAIN_TARGET_UUID} /* Fantastty */,\n\t\t\t);",
        f"targets = (\n\t\t\t\t{MAIN_TARGET_UUID} /* Fantastty */,\n\t\t\t\t{TEST_TARGET_UUID} /* FantasttyTests */,\n\t\t\t);",
    )

    # 9. Add XCBuildConfiguration for test target (Debug and Release)
    test_debug_config = f"""\t\t{TEST_DEBUG_CONFIG_UUID} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = 39A946CQ75;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.blainecook.fantastty.tests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Fantastty.app/Contents/MacOS/Fantastty";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
"""
    test_release_config = f"""\t\t{TEST_RELEASE_CONFIG_UUID} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = 39A946CQ75;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.blainecook.fantastty.tests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Fantastty.app/Contents/MacOS/Fantastty";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""
    content = content.replace(
        "/* End XCBuildConfiguration section */",
        f"{test_debug_config}{test_release_config}/* End XCBuildConfiguration section */",
    )

    # 10. Add XCConfigurationList for test target
    test_config_list = f"""\t\t{TEST_BUILD_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "FantasttyTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{TEST_DEBUG_CONFIG_UUID} /* Debug */,
\t\t\t\t{TEST_RELEASE_CONFIG_UUID} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
"""
    content = content.replace(
        "/* End XCConfigurationList section */",
        f"{test_config_list}/* End XCConfigurationList section */",
    )

    write_pbxproj(content)
    print("  Created FantasttyTests target.")


def create_tmux_control_mode_group():
    """Create the TmuxControlMode group under Models."""
    content = read_pbxproj()
    if TMUX_CONTROL_MODE_GROUP_UUID in content:
        print("  TmuxControlMode group already exists.")
        return
    _create_tmux_control_mode_group(content)


def _create_tmux_control_mode_group(content: str):
    group_entry = f"""\t\t{TMUX_CONTROL_MODE_GROUP_UUID} /* TmuxControlMode */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t);
\t\t\tpath = TmuxControlMode;
\t\t\tsourceTree = "<group>";
\t\t}};
"""
    content = content.replace(
        "/* End PBXGroup section */",
        f"{group_entry}/* End PBXGroup section */",
    )
    # Add to Models group
    content = _add_to_group(content, MODELS_GROUP_UUID, TMUX_CONTROL_MODE_GROUP_UUID, "TmuxControlMode")
    write_pbxproj(content)
    print("  Created TmuxControlMode group under Models.")


def _find_group_uuid(content: str, name: str) -> str | None:
    """Find a PBXGroup UUID by its name/path."""
    pattern = rf"(\w{{24}}) /\* {re.escape(name)} \*/ = {{\s*isa = PBXGroup;"
    match = re.search(pattern, content)
    return match.group(1) if match else None


def _add_to_group(content: str, group_uuid: str, child_uuid: str, child_name: str) -> str:
    """Add a child reference to a PBXGroup's children list."""
    child_line = f"\t\t\t\t{child_uuid} /* {child_name} */,\n"
    # Find the group and its children closing paren
    pattern = rf"({group_uuid}.*?children = \(.*?)(^\t\t\t\);)"
    content = re.sub(
        pattern,
        rf"\1{child_line}\2",
        content,
        count=1,
        flags=re.DOTALL | re.MULTILINE,
    )
    return content


def main():
    parser = argparse.ArgumentParser(description="Add files to Fantastty Xcode project")
    parser.add_argument("--source", action="append", help="Source file to add to main target")
    parser.add_argument("--test", action="append", help="Test file to add to test target")
    parser.add_argument("--create-test-target", action="store_true", help="Create FantasttyTests target")
    parser.add_argument("--create-tmux-group", action="store_true", help="Create TmuxControlMode group")

    args = parser.parse_args()

    if args.create_test_target:
        create_test_target()
    if args.create_tmux_group:
        create_tmux_control_mode_group()
    if args.source:
        for f in args.source:
            add_source_file(f)
    if args.test:
        for f in args.test:
            add_test_file(f)


if __name__ == "__main__":
    main()
