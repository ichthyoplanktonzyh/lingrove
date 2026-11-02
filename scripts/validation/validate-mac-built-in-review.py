#!/usr/bin/env python3
"""Bounded Mac E checks, using disposable storage and an isolated native test host.

Every Apple/Swift command and its evidence are covered by the shared flock. No
running user application, account, permission or simulator is inspected or stopped.
Fixed dependency inputs are copied from the approved read-only cache into this tree.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "build/mac-w2-e"
CACHE = Path("/Users/shadow/lingrove/build")
DD = ROOT / "build/DerivedData"
PACKAGES = ROOT / "build/mac-w2-e-source-packages"
ENV = dict(os.environ)
ENV.update(CMAKE_OSX_ARCHITECTURES="arm64", TTS_BUILD_JOBS="4",
           CLANG_MODULE_CACHE_PATH=str(ROOT / "build/mac-w2-e-module-cache"))


def run(name, command, check=True):
    path = BASE / (name + ".log")
    print(f"{name}: running; evidence {path}", flush=True)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with path.open("w") as output:
        code = subprocess.run(command, cwd=ROOT, env=ENV, stdin=subprocess.DEVNULL,
                              stdout=output, stderr=subprocess.STDOUT).returncode
    with (BASE / "runs.jsonl").open("a") as output:
        output.write(json.dumps({"name": name, "started": started, "exitCode": code,
                                 "ended": datetime.datetime.now(datetime.timezone.utc).isoformat()}) + "\n")
    print(f"{name}: exit {code}", flush=True)
    if check and code:
        raise RuntimeError(f"{name} failed ({code}); see {path}")
    return code


def package_checks(suffix, regression):
    selector = ("BuiltInNotebookReviewIntegrationTests|EngineScopedCommandIntegrationTests|"
                "LingroveNotebookReviewCompletionTests|LingroveNotebookReviewEnrollmentIntegrationTests|"
                "LingroveNotebookCardLinkIntegrationTests") if regression else "BuiltInNotebookReviewIntegrationTests"
    run("engine-" + suffix, ["swift", "test", "--package-path", "Packages/LingroveNotebookEngine",
        "--scratch-path", "build/mac-w2-e-engine", "--cache-path", "build/mac-w2-e-swift-cache",
        "--disable-dependency-cache", "--manifest-cache", "local", "--filter", selector])


def copy_input(source, target):
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-cR", str(source), str(target)], check=True)


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
        "CODE_SIGN_IDENTITY=Apple Development", "-resultBundlePath", str(BASE / ("mac-build-" + suffix + ".xcresult"))])


def native_test(suffix, selectors):
    products = DD / "Build/Products"
    original = products / "Debug/Lingrove.app"
    host = BASE / "host/Lingrove Review Validation.app"
    if host.exists():
        shutil.rmtree(host)
    copy_input(original, host)
    info = host / "Contents/Info.plist"
    value = plistlib.loads(info.read_bytes())
    old_id = value["CFBundleIdentifier"]
    new_id = "io.ichthyoplanktonzyh.lingrove.review.validation"
    value.update(CFBundleIdentifier=new_id, CFBundleName="Lingrove Review Validation",
                 CFBundleDisplayName="Lingrove Review Validation")
    info.write_bytes(plistlib.dumps(value))
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(original)], capture_output=True, text=True, check=True)
    identity = next(line.removeprefix("Authority=") for line in signature.stderr.splitlines() if line.startswith("Authority="))
    run("host-sign-" + suffix, ["codesign", "--force", "--deep", "--sign", identity,
                                "--preserve-metadata=entitlements", str(host)])
    run("host-verify-" + suffix, ["codesign", "--verify", "--deep", "--strict", str(host)])
    source = max(products.glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)
    plan = plistlib.loads(source.read_bytes())

    def rewrite(item):
        if isinstance(item, dict):
            for key, child in item.items():
                item[key] = rewrite(child)
            if "EnvironmentVariables" in item:
                item["EnvironmentVariables"]["LINGROVE_REVIEW_EVIDENCE_DIR"] = str(BASE / "native-ui")
            return item
        if isinstance(item, list):
            return [rewrite(child) for child in item]
        if isinstance(item, str):
            return item.replace(str(original), str(host)).replace("__TESTROOT__/Debug/Lingrove.app", str(host)) if item != old_id else new_id
        return item

    plan = rewrite(plan)
    runfile = BASE / ("native-" + suffix + ".xctestrun")
    runfile.write_bytes(plistlib.dumps(plan))
    (BASE / ("host-" + suffix + ".json")).write_text(json.dumps({
        "bundleID": new_id, "host": str(host), "sourcePlan": str(source),
        "sha256": hashlib.sha256((host / "Contents/MacOS/Lingrove").read_bytes()).hexdigest(),
        "isolatedHost": True, "offscreenNativeComponents": True, "visibleUserAppLaunched": False}, indent=2))
    result = BASE / ("native-result-" + suffix + ".xcresult")
    selected = selectors or ["LingroveTests/BuiltInReviewSessionIntegrationTests", "LingroveTests/BuiltInReviewKeyboardPolicyTests"]
    code = run("native-test-" + suffix, ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
        "-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
        *["-only-testing:" + selector for selector in selected], "-resultBundlePath", str(result)], check=False)
    summary_code = run("native-summary-" + suffix,
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], check=False)
    if code:
        raise RuntimeError("Native execution failed; inspect stored summary and screenshots before retrying")
    if summary_code:
        raise RuntimeError("Native execution needs an inspectable xcresult summary")
    summary = json.loads((BASE / ("native-summary-" + suffix + ".log")).read_text())
    if summary.get("totalTestCount", 0) < 1 or summary.get("failedTests", 0) != 0:
        raise RuntimeError("Native result did not execute passing tests")


def cleanup():
    executable = str(BASE / "host/Lingrove Review Validation.app/Contents/MacOS/Lingrove")
    candidates = subprocess.run(["pgrep", "-f", executable], capture_output=True, text=True)
    stopped = []
    for value in candidates.stdout.split():
        pid = int(value)
        command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
        if command == executable:
            os.kill(pid, signal.SIGTERM)
            stopped.append(pid)
    remaining = []
    for pid in stopped:
        for _ in range(20):
            command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
            if command != executable:
                break
            time.sleep(0.1)
        else:
            remaining.append(pid)
    preferences = subprocess.run(["defaults", "delete", "io.ichthyoplanktonzyh.lingrove.review.validation"],
                                 capture_output=True)
    paths = [DD, ROOT / "build/mac-w2-e-engine", ROOT / "build/mac-w2-e-swift-cache",
             ROOT / "build/mac-w2-e-module-cache", PACKAGES, ROOT / "build/lingrove-dependencies",
             ROOT / "build/tts-native", ROOT / "build/dictionary-native", ROOT / "build/ocr-native", BASE / "host"]
    for path in paths:
        if path.exists():
            shutil.rmtree(path)
    (BASE / "cleanup.json").write_text(json.dumps({
        "removed": [str(path) for path in paths], "allAbsent": all(not path.exists() for path in paths),
        "sharedInputsUntouched": True, "serversStarted": False, "simulatorsUsed": False,
        "ownedHostProcessesStopped": stopped, "ownedHostProcessesRemaining": remaining,
        "ownedPreferencesRemoved": preferences.returncode == 0,
        "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2))
    if remaining:
        raise RuntimeError("The owned validation host did not exit during bounded cleanup")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["package", "regression", "prepare", "generate", "build", "test", "lint", "cleanup"])
    parser.add_argument("--suffix", default="1")
    parser.add_argument("--only-test", action="append", default=[])
    args = parser.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    print("Waiting for shared Apple validation lock", flush=True)
    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Shared Apple validation lock acquired", flush=True)
        if args.stage in ("package", "regression"):
            package_checks(args.suffix, args.stage == "regression")
        elif args.stage == "prepare":
            prepare(args.suffix)
        elif args.stage == "generate":
            run("xcodegen-" + args.suffix, ["xcodegen", "generate"])
        elif args.stage == "build":
            native_build(args.suffix)
        elif args.stage == "test":
            native_test(args.suffix, args.only_test)
        elif args.stage == "lint":
            files = [str(path.relative_to(ROOT)) for directory in ("Models", "Services", "Support", "UI")
                     for path in (ROOT / "Lingrove" / directory / "BuiltInReview").glob("*.swift")]
            files.append("Lingrove/Services/Presentation/BuiltInReviewWindowController.swift")
            run("lint-" + args.suffix, ["swiftlint", "lint", "--strict", "--quiet", "--force-exclude", *files])
        elif args.stage == "cleanup":
            cleanup()


if __name__ == "__main__":
    main()
