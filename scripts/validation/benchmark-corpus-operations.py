#!/usr/bin/env python3
"""Run opt-in Release operation tests on generated notebooks and an isolated app host.

The native resource lock covers preparation, compilation, tests and cleanup. Nothing discovers
or copies the installed Dev application or its data. Raw samples and test evidence survive;
DerivedData, downloaded package copies and synthetic databases are disposable.
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
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DD = ROOT / "build/DerivedData"
HOST_ID = "io.ichthyoplanktonzyh.lingrove.operations.validation"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument("--sizes", default="100,10000,20000")
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--skip-smoke", action="store_true")
    parser.add_argument("--tail-only", action="store_true", help="Rerun the corrected CLI retry and remaining destinations")
    parser.add_argument("--native-checks", action="store_true", help="Run affected native repository/lifecycle checks before timing")
    parser.add_argument("--checks-only", action="store_true", help="Run affected native checks without the operation inventory")
    parser.add_argument("--remaining-only", action="store_true", help="Measure the remaining load/save/organization paths")
    parser.add_argument("--paged-only", action="store_true", help="Measure page/detail readiness and fresh first-write fallbacks")
    parser.add_argument("--keep-build-on-failure", action="store_true")
    parser.add_argument("--packages-from", type=Path, help="Reuse this benchmark's package cache after a failed build")
    args = parser.parse_args()
    base = ROOT / "build/corpus-operation-benchmark" / args.label
    base.mkdir(parents=True, exist_ok=False)
    packages = args.packages_from.resolve() if args.packages_from else base / "source-packages"
    if args.packages_from:
        assert packages.name == "source-packages" and packages.parent.parent == base.parent
    host = base / "host/Lingrove Operations Validation.app"
    environment = dict(os.environ, CMAKE_OSX_ARCHITECTURES="arm64", TTS_BUILD_JOBS="4")

    def run(name, command, check=True):
        print("START " + name, flush=True)
        start = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with (base / (name + ".log")).open("w") as log:
            code = subprocess.run(command, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                                  stdout=log, stderr=subprocess.STDOUT).returncode
        with (base / "runs.jsonl").open("a") as log:
            log.write(json.dumps({"stage": name, "command": command, "start": start,
                "end": datetime.datetime.now(datetime.timezone.utc).isoformat(), "exitCode": code}) + "\n")
        print("END " + name + " exit=" + str(code), flush=True)
        if check and code:
            raise RuntimeError(name + " failed; see " + str(base / (name + ".log")))
        return code

    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        print("Waiting for the shared Apple validation lock", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Acquired shared Apple validation lock", flush=True)
        completed = False
        try:
            run("prepare", ["bash", "scripts/prepare_lingrove_workspace.sh"])
            run("generate", ["xcodegen", "generate"])
            common = ["-workspace", "build/lingrove-dependencies/Lingrove.xcworkspace", "-scheme", "Lingrove",
                "-derivedDataPath", "build/DerivedData", "-clonedSourcePackagesDirPath", str(packages)]
            run("resolve", ["xcodebuild", "-resolvePackageDependencies", *common,
                "-onlyUsePackageVersionsFromResolvedFile"])
            run("build", ["xcodebuild", "build-for-testing", *common, "-configuration", "Release",
                "-destination", "platform=macOS", "-onlyUsePackageVersionsFromResolvedFile",
                "-xcconfig", "Config/Signing.local.xcconfig", "CODE_SIGNING_ALLOWED=YES",
                "CODE_SIGN_IDENTITY=Apple Development", "ENABLE_TESTABILITY=YES", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"])
            original = DD / "Build/Products/Release/Lingrove.app"
            host.parent.mkdir(parents=True)
            subprocess.run(["ditto", "--norsrc", "--noextattr", str(original), str(host)], check=True)
            info_path = host / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            old_id = info["CFBundleIdentifier"]
            info.update(CFBundleIdentifier=HOST_ID, CFBundleName="Lingrove Operations Validation",
                        CFBundleDisplayName="Lingrove Operations Validation", LingroveIsolatedValidationHost=True)
            info_path.write_bytes(plistlib.dumps(info))
            signature = subprocess.run(["codesign", "-dvv", str(original)], capture_output=True, text=True, check=True)
            identity = next(line.split("=", 1)[1] for line in signature.stderr.splitlines() if line.startswith("Authority="))
            run("sign", ["python3", "scripts/sign_local_app.py", str(host), "--identity", identity, "--testing"])
            run("verify", ["codesign", "--verify", "--deep", "--strict", str(host)])
            source_plan = max((DD / "Build/Products").glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)
            plan = plistlib.loads(source_plan.read_bytes())
            files = subprocess.check_output(["git", "ls-files", "--", "Lingrove", "Packages", "LingroveTests", "project.yml"],
                cwd=ROOT, text=True).splitlines()
            files += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "Lingrove", "Packages", "LingroveTests"],
                cwd=ROOT, text=True).splitlines()
            # A git-archive checkout has no own index. Invoking git there may find the parent
            # checkout and silently return zero matching paths; hash the archived inputs itself.
            if not files:
                files = [str(path.relative_to(ROOT)) for name in ("Lingrove", "Packages", "LingroveTests")
                         for path in (ROOT / name).rglob("*") if path.is_file()]
                files.append("project.yml")
            (base / "source-hashes.json").write_text(json.dumps({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                for name in sorted(set(files)) if (ROOT / name).is_file()}, indent=2) + "\n")
            (base / "identity.json").write_text(json.dumps({
                "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "configuration": "Release", "architecture": "arm64", "hostBundleID": HOST_ID,
                "hostBinarySHA256": hashlib.sha256((host / "Contents/MacOS/Lingrove").read_bytes()).hexdigest(),
                "installedAppAccessed": False, "input": "generated synthetic notebooks only",
                "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                "sizes": args.sizes, "trials": args.trials, "scanTrials": 1,
                "focusedTrials": args.trials, "tailOnly": args.tail_only,
                "remainingOnly": args.remaining_only, "remainingTrials": args.trials if args.remaining_only else 0,
                "pagedOnly": args.paged_only, "pagedTrials": args.trials if args.paged_only else 0}, indent=2) + "\n")

            def execute(label, sizes, trials, mode="scan", selectors=None):
                output = base / label
                output.mkdir()

                def rewrite(value):
                    if isinstance(value, dict):
                        result = {key: rewrite(child) for key, child in value.items()}
                        if "TestBundlePath" in result or "TestHostPath" in result:
                            result.setdefault("EnvironmentVariables", {}).update(
                                LINGROVE_OPERATION_BENCHMARK_OUTPUT=str(output),
                                LINGROVE_OPERATION_BENCHMARK_SIZES=sizes,
                                LINGROVE_OPERATION_BENCHMARK_TRIALS=str(trials),
                                LINGROVE_OPERATION_BENCHMARK_MODE=mode)
                        return result
                    if isinstance(value, list):
                        return [rewrite(child) for child in value]
                    if isinstance(value, str):
                        if value == old_id:
                            return HOST_ID
                        return value.replace(str(original), str(host)).replace("__TESTROOT__/Release/Lingrove.app", str(host)).replace(
                            "__TESTROOT__", str(DD / "Build/Products"))
                    return value

                runfile = base / (label + ".xctestrun")
                runfile.write_bytes(plistlib.dumps(rewrite(plan)))
                result = base / (label + ".xcresult")
                code = run(label, ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
                    "-destination", "platform=macOS", "-derivedDataPath", "build/DerivedData",
                    "-parallel-testing-enabled", "NO",
                    *["-only-testing:" + name for name in (selectors or ["LingroveTests/VocabularyOperationBenchmarkTests"])],
                    *(["-skip-testing:LingroveTests/VocabularyUnifiedRepositoryTests/nativeCreateCancelSaveEditAndReopenJourney"]
                        if selectors else []),
                    "-resultBundlePath", str(result)], check=False)
                run(label + "-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)])
                summary = json.loads((base / (label + "-summary.log")).read_text())
                optional_ui_skip = selectors and summary.get("skippedTests") == 1 and \
                    "nativeCreateCancelSaveEditAndReopenJourney() skipped" in (base / (label + ".log")).read_text()
                if code or summary.get("failedTests") or (summary.get("skippedTests") and not optional_ui_skip) or not summary.get("passedTests"):
                    raise RuntimeError(label + " did not execute passing measurements")

            if args.native_checks or args.checks_only:
                execute("native-checks", "100", 1, selectors=[
                    "LingroveTests/VocabularyUnifiedRepositoryTests",
                    "LingroveTests/VocabularyLifecycleTests",
                    "LingroveTests/VocabularyBrowsingScaleTests",
                    "LingroveTests/VocabularyColdEntryCommandTests",
                    "LingroveTests/VocabularyExplanationTests",
                    "LingroveTests/VocabularyTagDeletionTests",
                    "LingroveTests/NoteAnkiSenderTests",
                    "LingroveTests/NotebookProgressModelIntegrationTests",
                    "LingroveTests/VocabularySearchPolicyTests",
                    "LingroveTests/VocabularySearchPreparationTests",
                    "LingroveTests/VocabularyGraphTests",
                    "LingroveTests/VocabularyEntryImportTests"])
            if args.checks_only:
                completed = True
            elif args.paged_only:
                execute("paged", args.sizes, args.trials, mode="paged")
            elif args.remaining_only:
                execute("remaining", args.sizes, args.trials, mode="remaining")
            elif args.tail_only:
                execute("tail", args.sizes, 1, mode="tail")
            else:
                if not args.skip_smoke:
                    execute("smoke", "100", 1)
                    execute("smoke-focused", "100", 1, mode="focused")
                execute("focused", args.sizes, args.trials, mode="focused")
                execute("measurements", args.sizes, 1)
            completed = True
        finally:
            # Only this run's synthetic fixtures and exact repository-scoped build caches retire.
            for output in (base / "smoke", base / "smoke-focused", base / "focused", base / "measurements", base / "tail", base / "remaining", base / "paged"):
                if output.exists():
                    for path in output.iterdir():
                        if path.is_dir() and (path.name.startswith("seed-") or path.name.startswith("trial-")):
                            shutil.rmtree(path)
            retire = [host.parent]
            if completed or not args.keep_build_on_failure:
                retire.extend([DD, packages])
            for path in retire:
                if path.exists():
                    shutil.rmtree(path)
            (base / "cleanup.json").write_text(json.dumps({"derivedDataAbsent": not DD.exists(),
                "syntheticFixturesRemoved": True, "packageCopiesRemoved": not packages.exists(),
                "hostRemoved": not host.exists(), "installedAppAccessed": False}, indent=2) + "\n")


if __name__ == "__main__":
    main()
