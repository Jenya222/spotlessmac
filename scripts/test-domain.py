#!/usr/bin/env python3
"""Run domain XCTest without testmanagerd; never clean the user's files.

Usage: python3 scripts/test-domain.py [SpotlessMacTests/SomeTests.swift ...]
Requires full Xcode. UI compilation is verified separately with xcodebuild.
Temporary build products and fixture files are deliberately retained in /private/tmp.
"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="spotlessmac-domain-", dir="/private/tmp"))
developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
platform = developer / "Platforms/MacOSX.platform/Developer"
frameworks = str(platform / "Library/Frameworks")
libraries = str(platform / "usr/lib")
sources = sorted(str(path) for path in (repo / "SpotlessMac").rglob("*.swift")
                 if "App" not in path.relative_to(repo / "SpotlessMac").parts
                 or path.name == "Theme.swift")
common = ["-swift-version", "6", "-DDEBUG", "-Xfrontend", "-disable-sandbox",
          "-module-cache-path", str(root / "cache")]
subprocess.run(["xcrun", "swiftc", *common, "-enable-testing", "-emit-library",
                "-emit-module", "-module-name", "SpotlessMac", *sources,
                "-o", str(root / "libSpotlessMac.dylib"),
                "-emit-module-path", str(root / "SpotlessMac.swiftmodule")], check=True)
bundle = root / "DomainTests.xctest"
(bundle / "Contents/MacOS").mkdir(parents=True)
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "DomainTests",
    "CFBundleIdentifier": "local.spotless.domain-tests",
    "CFBundlePackageType": "BNDL",
}))
tests = sys.argv[1:] or sorted(str(path) for path in (repo / "SpotlessMacTests").glob("*.swift"))
subprocess.run(["xcrun", "swiftc", *common, "-emit-library", "-module-name", "DomainTests",
                "-I", str(root), "-L", str(root), "-lSpotlessMac", "-F", frameworks,
                "-I", libraries, "-L", libraries, "-framework", "XCTest",
                "-Xlinker", "-rpath", "-Xlinker", str(root),
                "-Xlinker", "-rpath", "-Xlinker", frameworks, *tests,
                "-o", str(bundle / "Contents/MacOS/DomainTests")], check=True)
# Production loads knowledge from Bundle.main. Host XCTest in a temporary app
# with the same resource layout, rather than Xcode's resource-free runner bundle.
host = root / "DomainRunner.app"
runner = host / "Contents/MacOS/xctest"
runner.parent.mkdir(parents=True)
shutil.copy2(developer / "usr/bin/xctest", runner)
(host / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "xctest",
    "CFBundleIdentifier": "local.spotless.domain-runner",
    "CFBundlePackageType": "APPL",
}))
shutil.copytree(repo / "SpotlessMac/Resources/Knowledge", host / "Contents/Resources/Knowledge")
# The copied Xcode runner's relative rpaths no longer point into Xcode. Supply
# its frameworks and Swift XCTest support only to this child process.
runner_env = os.environ.copy()
runner_env["DYLD_FRAMEWORK_PATH"] = os.pathsep.join([
    str(developer / "Frameworks"), str(developer / "PrivateFrameworks"), frameworks,
])
runner_env["DYLD_LIBRARY_PATH"] = libraries
print(f"Test products retained at {root}", flush=True)
subprocess.run([str(runner), str(bundle)], env=runner_env, check=True)
