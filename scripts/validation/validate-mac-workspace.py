#!/usr/bin/env python3
"""Mac Wave 4 A validation: isolated notebook workspace, real local storage, one visible journey.

The shared flock covers every Swift/Xcode/native operation through evidence publication.
Only approved fixed inputs are copied; no installed user app, account or permission is changed.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "build/mac-w4-a"
DD = ROOT / "build/DerivedData"
CACHE = Path("/Users/shadow/lingrove/build")
PACKAGES = ROOT / "build/mac-w4-a-source-packages"
HOST_NAME = "Lingrove Workspace Validation W4A"
HOST_ID = "io.ichthyoplanktonzyh.lingrove.mac.wave4.workspace.validation"
HOST = BASE / "host" / (HOST_NAME + ".app")
ENV = dict(os.environ, CMAKE_OSX_ARCHITECTURES="arm64", TTS_BUILD_JOBS="4",
           CLANG_MODULE_CACHE_PATH=str(ROOT / "build/mac-w4-a-module-cache"),
           SWIFTPM_MODULECACHE_OVERRIDE=str(ROOT / "build/mac-w4-a-swift-module-cache"))


def run(name, command, check=True):
    path = BASE / (name + ".log")
    print(f"{name}: running; evidence {path}", flush=True)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with path.open("w") as output:
        code = subprocess.run(command, cwd=ROOT, env=ENV, stdin=subprocess.DEVNULL,
                              stdout=output, stderr=subprocess.STDOUT).returncode
    with (BASE / "runs.jsonl").open("a") as output:
        output.write(json.dumps({"name": name, "command": command, "started": started,
            "exitCode": code, "ended": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")
    print(f"{name}: exit {code}", flush=True)
    if check and code:
        raise RuntimeError(f"{name} failed ({code}); see {path}")
    return code


def copy_input(source, target):
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-cR", str(source), str(target)], cwd=ROOT, check=True)


def prepare(suffix):
    copy_input(CACHE / "lingrove-dependencies/CotabbyInference", ROOT / "build/lingrove-dependencies/CotabbyInference")
    copy_input(CACHE / "tts-native/llama.cpp", ROOT / "build/tts-native/llama.cpp")
    copy_input(CACHE / "nibomo-validation/source-packages", PACKAGES)
    run("prepare-" + suffix, ["bash", "scripts/prepare_lingrove_workspace.sh"])
    run("xcodegen-" + suffix, ["xcodegen", "generate"])


def native_build(suffix):
    run("mac-build-" + suffix, ["xcodebuild", "build-for-testing", "-workspace",
        "build/lingrove-dependencies/Lingrove.xcworkspace", "-scheme", "Lingrove", "-configuration", "Debug",
        "-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
        "-clonedSourcePackagesDirPath", str(PACKAGES), "-disableAutomaticPackageResolution",
        "-xcconfig", "Config/Signing.local.xcconfig", "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=Apple Development", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        "-resultBundlePath", str(BASE / ("mac-build-" + suffix + ".xcresult"))])


def native_test(suffix, selectors, onscreen):
    for port in range(19880, 19883):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", port))
    (BASE / ("ports-" + suffix + ".json")).write_text(json.dumps({
        "checked": [19880, 19881, 19882], "allFreeBeforeExecution": True,
        "otherProcessesStopped": False}, indent=2) + "\n")
    products = DD / "Build/Products"
    original = products / "Debug/Lingrove.app"
    if HOST.exists():
        shutil.rmtree(HOST)
    copy_input(original, HOST)
    info = HOST / "Contents/Info.plist"
    value = plistlib.loads(info.read_bytes())
    old_id = value["CFBundleIdentifier"]
    value.update(CFBundleIdentifier=HOST_ID, CFBundleName=HOST_NAME, CFBundleDisplayName=HOST_NAME)
    info.write_bytes(plistlib.dumps(value))
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(original)], cwd=ROOT,
                               capture_output=True, text=True, check=True)
    identity = next(line.removeprefix("Authority=") for line in signature.stderr.splitlines() if line.startswith("Authority="))
    run("host-sign-" + suffix, ["codesign", "--force", "--deep", "--sign", identity,
                                "--preserve-metadata=entitlements", str(HOST)])
    run("host-verify-" + suffix, ["codesign", "--verify", "--deep", "--strict", str(HOST)])
    source = max(products.glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)
    plan = plistlib.loads(source.read_bytes())

    def rewrite(item):
        if isinstance(item, dict):
            result = {key: rewrite(child) for key, child in item.items()}
            # Both older target dictionaries and current TestConfigurations are supported. A
            # missing environment dictionary must be created on the actual target as well.
            if "TestBundlePath" in result or "TestHostPath" in result:
                environment = result.setdefault("EnvironmentVariables", {})
                environment.update(
                    LINGROVE_WORKSPACE_EVIDENCE_DIR=str(BASE / "native-ui"),
                    LINGROVE_REVIEW_EVIDENCE_DIR=str(BASE / "native-ui"),
                    LINGROVE_MAC_SYNC_TEST_PORT_MIN="19880")
                if onscreen:
                    environment["LINGROVE_WORKSPACE_ONSCREEN"] = str(BASE / "onscreen")
            return result
        if isinstance(item, list):
            return [rewrite(child) for child in item]
        if isinstance(item, str):
            if item == old_id:
                return HOST_ID
            return item.replace(str(original), str(HOST)).replace("__TESTROOT__/Debug/Lingrove.app", str(HOST))
        return item

    runfile = BASE / ("native-" + suffix + ".xctestrun")
    runfile.write_bytes(plistlib.dumps(rewrite(plan)))
    selected = selectors or (["LingroveTests/NotebookWorkspaceOnscreenAcceptanceTests"] if onscreen else [
        "LingroveTests/NotebookWorkspaceIntegrationTests",
        "LingroveTests/BuiltInReviewSessionIntegrationTests",
        "LingroveTests/BuiltInReviewKeyboardPolicyTests",
        "LingroveTests/MacNotebookAppServicesTests",
        "LingroveTests/VocabularyNotebookViewTests/ordinaryLibraryCommandInstallsAndRetainsTheHostedRoot()"])
    (BASE / ("host-" + suffix + ".json")).write_text(json.dumps({
        "bundleID": HOST_ID, "host": str(HOST), "sourcePlan": str(source),
        "binarySHA256": hashlib.sha256((HOST / "Contents/MacOS/Lingrove").read_bytes()).hexdigest(),
        "requiresXCTestHostMarker": True, "userAppTouched": False, "selectors": selected,
        "onscreen": onscreen}, indent=2) + "\n")
    result = BASE / ("native-result-" + suffix + ".xcresult")
    code = run("native-test-" + suffix, ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
        "-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
        "-parallel-testing-enabled", "NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        *["-only-testing:" + selector for selector in selected], "-resultBundlePath", str(result)], check=False)
    summary_code = run("native-summary-" + suffix,
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], check=False)
    if code or summary_code:
        raise RuntimeError("Native execution failed; inspect the stored summary/screenshots before a bounded correction")
    summary = json.loads((BASE / ("native-summary-" + suffix + ".log")).read_text())
    if summary.get("totalTestCount", 0) < 1 or summary.get("failedTests", 0) or summary.get("skippedTests", 0):
        raise RuntimeError("The native selection did not actually execute passing tests without skips")


def lint(suffix):
    paths = subprocess.run(["git", "diff", "--name-only", "--", "Lingrove"], cwd=ROOT,
                           capture_output=True, text=True, check=True).stdout.splitlines()
    paths += subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "Lingrove"], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout.splitlines()
    files = sorted({path for path in paths if path.endswith(".swift")})
    run("production-lint-" + suffix, ["swiftlint", "lint", "--strict", "--quiet", "--force-exclude", *files])


def cleanup():
    executable = str(HOST / "Contents/MacOS/Lingrove")
    candidates = subprocess.run(["pgrep", "-f", executable], cwd=ROOT, capture_output=True, text=True)
    stopped = []
    for value in candidates.stdout.split():
        pid = int(value)
        command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], cwd=ROOT,
                                 capture_output=True, text=True).stdout.strip()
        if command == executable:
            os.kill(pid, signal.SIGTERM)
            stopped.append(pid)
    remaining = []
    for pid in stopped:
        for _ in range(20):
            command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], cwd=ROOT,
                                     capture_output=True, text=True).stdout.strip()
            if command != executable:
                break
            time.sleep(0.1)
        else:
            remaining.append(pid)
    subprocess.run(["defaults", "delete", HOST_ID], cwd=ROOT, capture_output=True)
    interrupted = BASE / "initial-test-interruption.json"
    orphan_data = []
    orphan_domains = []
    if interrupted.exists():
        record = json.loads(interrupted.read_text())
        for value in record.get("orphanDataPaths", []):
            path = Path(value)
            if path.parent.resolve() != Path(tempfile.gettempdir()).resolve() or not path.name.startswith("lingrove-workspace-"):
                raise RuntimeError("The interrupted fixture cleanup record is outside its private temporary namespace")
            orphan_data.append(path)
        for domain in record.get("orphanPreferenceDomains", []):
            if not domain.startswith("lingrove.workspace.synthetic."):
                raise RuntimeError("The interrupted fixture preferences are outside their synthetic namespace")
            subprocess.run(["defaults", "delete", domain], cwd=ROOT, capture_output=True)
            orphan_domains.append(domain)
    user_library = Path.home() / "Library"
    paths = [DD, PACKAGES, ROOT / "build/mac-w4-a-module-cache", ROOT / "build/mac-w4-a-swift-module-cache",
        ROOT / "build/lingrove-dependencies", ROOT / "build/tts-native", ROOT / "build/dictionary-native",
        ROOT / "build/ocr-native", BASE / "host", user_library / "Application Support" / HOST_NAME,
        user_library / "Caches" / HOST_ID, user_library / "Saved Application State" / (HOST_ID + ".savedState"), *orphan_data]
    for path in paths:
        if path.exists():
            shutil.rmtree(path)
    preferences = user_library / "Preferences" / (HOST_ID + ".plist")
    if preferences.exists():
        preferences.unlink()
    orphan_preferences = [user_library / "Preferences" / (domain + ".plist") for domain in orphan_domains]
    for path in orphan_preferences:
        if path.exists():
            path.unlink()
    (BASE / "cleanup.json").write_text(json.dumps({
        "removed": [str(path) for path in paths], "allAbsent": all(not path.exists() for path in paths),
        "ownedPreferencesAbsent": not preferences.exists(), "sharedInputsUntouched": True,
        "interruptedFixtureDataAbsent": all(not path.exists() for path in orphan_data),
        "interruptedFixturePreferencesAbsent": all(not path.exists() for path in orphan_preferences),
        "simulatorsUsed": False, "ownedHostProcessesStopped": stopped, "ownedHostProcessesRemaining": remaining,
        "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    if remaining:
        raise RuntimeError("The private validation host did not exit during bounded cleanup")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["prepare", "generate", "build", "test", "onscreen", "lint", "cleanup"])
    parser.add_argument("--suffix", default="1")
    parser.add_argument("--only-test", action="append", default=[])
    args = parser.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    print("Waiting for shared Apple validation lock", flush=True)
    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Shared Apple validation lock acquired", flush=True)
        if args.stage == "prepare":
            prepare(args.suffix)
        elif args.stage == "generate":
            run("xcodegen-" + args.suffix, ["xcodegen", "generate"])
        elif args.stage == "build":
            native_build(args.suffix)
        elif args.stage in ("test", "onscreen"):
            native_test(args.suffix, args.only_test, args.stage == "onscreen")
        elif args.stage == "lint":
            lint(args.suffix)
        elif args.stage == "cleanup":
            cleanup()


if __name__ == "__main__":
    main()
