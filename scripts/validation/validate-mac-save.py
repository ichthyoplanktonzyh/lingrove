#!/usr/bin/env python3
"""Focused Wave 3 save correctness/build checks; deliberately records no latency evidence.

The shared flock covers every Swift/Xcode/native command through evidence publication.
All data, test-host identity and copied dependencies belong to this disposable worktree.
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
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "build/mac-w3-a"
DD = ROOT / "build/DerivedData"
CACHE = Path("/Users/shadow/lingrove/build")
PACKAGES = ROOT / "build/mac-w3-a-source-packages"
HOST_ID = "io.ichthyoplanktonzyh.lingrove.mac.wave3.save.validation"
ENV = dict(os.environ, CMAKE_OSX_ARCHITECTURES="arm64", TTS_BUILD_JOBS="4",
           CLANG_MODULE_CACHE_PATH=str(ROOT / "build/mac-w3-a-module-cache"))


def run(name, command, check=True):
    path = BASE / (name + ".log")
    print(f"{name}: evidence {path}", flush=True)
    with path.open("w") as output:
        code = subprocess.run(command, cwd=ROOT, env=ENV, stdin=subprocess.DEVNULL,
                              stdout=output, stderr=subprocess.STDOUT).returncode
    with (BASE / "runs.jsonl").open("a") as output:
        output.write(json.dumps({"name": name, "exitCode": code,
            "command": command, "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")
    print(f"{name}: exit {code}", flush=True)
    if code and check:
        raise RuntimeError(f"{name} failed; inspect {path}")
    return code


def copy_input(source, destination):
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["/bin/cp", "-cR", str(source), str(destination)], cwd=ROOT, check=True)


def prepare(suffix):
    copy_input(CACHE / "lingrove-dependencies/CotabbyInference", ROOT / "build/lingrove-dependencies/CotabbyInference")
    copy_input(CACHE / "tts-native/llama.cpp", ROOT / "build/tts-native/llama.cpp")
    copy_input(CACHE / "nibomo-validation/source-packages", PACKAGES)
    run("prepare-" + suffix, ["bash", "scripts/prepare_lingrove_workspace.sh"])
    run("xcodegen-" + suffix, ["xcodegen", "generate"])


def package(suffix, regression, selected):
    selectors = ("LingroveNotebookEntrySaveIntegrationTests|EngineScopedCommandIntegrationTests|"
                 "LingroveNotebookStoreIntegrationTests") if regression else "LingroveNotebookEntrySaveIntegrationTests"
    if selected:
        selectors = "|".join(selected)
    run("engine-" + suffix, ["swift", "test", "--package-path", "Packages/LingroveNotebookEngine",
        "--scratch-path", "build/mac-w3-a-engine", "--cache-path", "build/mac-w3-a-swift-cache",
        "--disable-dependency-cache", "--manifest-cache", "local", "--filter", selectors])


def native_build(suffix):
    run("mac-build-" + suffix, ["xcodebuild", "build-for-testing", "-workspace",
        "build/lingrove-dependencies/Lingrove.xcworkspace", "-scheme", "Lingrove", "-configuration", "Debug",
        "-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
        "-clonedSourcePackagesDirPath", str(PACKAGES), "-disableAutomaticPackageResolution",
        "-xcconfig", "Config/Signing.local.xcconfig", "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=Apple Development", "-resultBundlePath", str(BASE / ("mac-build-" + suffix + ".xcresult"))])


def native_test(suffix, selectors):
    products = DD / "Build/Products"
    original = products / "Debug/Lingrove.app"
    host = BASE / "host/Lingrove Save Validation.app"
    if host.exists():
        shutil.rmtree(host)
    copy_input(original, host)
    info = host / "Contents/Info.plist"
    value = plistlib.loads(info.read_bytes())
    original_id = value["CFBundleIdentifier"]
    value.update(CFBundleIdentifier=HOST_ID, CFBundleName="Lingrove Save Validation", CFBundleDisplayName="Lingrove Save Validation")
    info.write_bytes(plistlib.dumps(value))
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(original)], cwd=ROOT, capture_output=True, text=True, check=True)
    identity = next(line.removeprefix("Authority=") for line in signature.stderr.splitlines() if line.startswith("Authority="))
    run("host-sign-" + suffix, ["codesign", "--force", "--deep", "--sign", identity, "--preserve-metadata=entitlements", str(host)])
    run("host-verify-" + suffix, ["codesign", "--verify", "--deep", "--strict", str(host)])
    plan_source = max(products.glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)
    plan = plistlib.loads(plan_source.read_bytes())

    def rewrite(item):
        if isinstance(item, dict):
            return {key: rewrite(child) for key, child in item.items()}
        if isinstance(item, list):
            return [rewrite(child) for child in item]
        if isinstance(item, str):
            if item == original_id:
                return HOST_ID
            return item.replace(str(original), str(host)).replace("__TESTROOT__/Debug/Lingrove.app", str(host))
        return item

    plan = rewrite(plan)
    runfile = BASE / ("native-" + suffix + ".xctestrun")
    runfile.write_bytes(plistlib.dumps(plan))
    selected = selectors or [
        "LingroveTests/VocabularyUnifiedRepositoryTests/narrowCaptureAndLiteralEditorRetainOtherEntriesAndNewMemberships",
        "LingroveTests/VocabularyUnifiedRepositoryTests/cachedArchiveSeesExternalCommitsAndRejectsRetiredGenerationWithoutNotification",
        "LingroveTests/VocabularyUnifiedRepositoryTests/explicitCaptureDraftMergeMediaBackupAndRestartUseTheSameEngine",
        "LingroveTests/VocabularyUnifiedRepositoryTests/oldDraftImportAnkiAndExplanationCallbacksCannotAcquireANewGeneration",
        "LingroveTests/VocabularyCLITests/invalidLaterOperationAndReceiptFailureRollBackContentAndMedia",
        "LingroveTests/VocabularyCLITests/dryRunCommitReplayAndPortableReadUseOneTransactionAndRefreshStore"]
    # Swift Testing identifiers include (). Without it Xcode can return success with zero
    # selected methods, which our result-count assertion rejects explicitly.
    selected = [selector if selector.endswith("()") else selector + "()" for selector in selected]
    (BASE / ("host-" + suffix + ".json")).write_text(json.dumps({
        "bundleID": HOST_ID, "host": str(host), "sourcePlan": str(plan_source),
        "binarySHA256": hashlib.sha256((host / "Contents/MacOS/Lingrove").read_bytes()).hexdigest(),
        "expectsProductionServicesSkipped": True, "userAppTouched": False, "selectors": selected}, indent=2) + "\n")
    result = BASE / ("native-result-" + suffix + ".xcresult")
    code = run("native-test-" + suffix, ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
        "-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
        *["-only-testing:" + selector for selector in selected], "-resultBundlePath", str(result)], check=False)
    run("native-summary-" + suffix, ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
    summary = json.loads((BASE / ("native-summary-" + suffix + ".log")).read_text())
    if code or summary.get("totalTestCount", 0) != len(selected) or summary.get("failedTests", 0):
        raise RuntimeError("Native tests did not execute the selected passing checks; inspect the stored evidence")


def cleanup():
    host = BASE / "host/Lingrove Save Validation.app/Contents/MacOS/Lingrove"
    candidates = subprocess.run(["pgrep", "-f", str(host)], cwd=ROOT, capture_output=True, text=True)
    owned = []
    for value in candidates.stdout.split():
        pid = int(value)
        command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        if command == str(host):
            os.kill(pid, signal.SIGTERM); owned.append(pid)
    remaining = []
    for pid in owned:
        for _ in range(20):
            command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], cwd=ROOT, capture_output=True, text=True).stdout.strip()
            if command != str(host):
                break
            time.sleep(0.1)
        else:
            remaining.append(pid)
    subprocess.run(["defaults", "delete", HOST_ID], cwd=ROOT, capture_output=True)
    paths = [DD, ROOT / "build/mac-w3-a-engine", ROOT / "build/mac-w3-a-swift-cache", ROOT / "build/mac-w3-a-module-cache",
        PACKAGES, ROOT / "build/lingrove-dependencies", ROOT / "build/tts-native", ROOT / "build/ocr-native",
        ROOT / "build/dictionary-native", BASE / "host"]
    for path in paths:
        if path.exists():
            shutil.rmtree(path)
    (BASE / "cleanup.json").write_text(json.dumps({"removed": [str(path) for path in paths],
        "allAbsent": all(not path.exists() for path in paths), "ownedHostPIDsStopped": owned,
        "ownedHostPIDsRemaining": remaining,
        "sharedInputsUntouched": True, "userAppTouched": False, "simulatorsUsed": False,
        "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    if remaining:
        raise RuntimeError("The owned validation host did not exit during bounded cleanup")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["package", "regression", "prepare", "build", "test", "lint", "cleanup"])
    parser.add_argument("--suffix", default="1")
    parser.add_argument("--only-test", action="append", default=[])
    args = parser.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    print("Waiting for shared Apple validation lock", flush=True)
    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Shared Apple validation lock acquired", flush=True)
        if args.stage in ("package", "regression"):
            package(args.suffix, args.stage == "regression", args.only_test)
        elif args.stage == "prepare":
            prepare(args.suffix)
        elif args.stage == "build":
            native_build(args.suffix)
        elif args.stage == "test":
            native_test(args.suffix, args.only_test)
        elif args.stage == "lint":
            files = ["Lingrove/Services/Vocabulary/VocabularyArchive.swift", "Lingrove/Services/Vocabulary/VocabularyStore.swift",
                "Lingrove/Support/Vocabulary/VocabularyPolicy.swift", "Lingrove/Support/Vocabulary/VocabularySaveLiteralEquality.swift"]
            run("lint-" + args.suffix, ["swiftlint", "lint", "--strict", "--quiet", "--force-exclude", *files])
        else:
            cleanup()


if __name__ == "__main__":
    main()
