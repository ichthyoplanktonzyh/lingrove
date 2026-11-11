#!/usr/bin/env python3
"""Compare old/new Release engines against byte-identical synthetic SQLite copies.

The fixture calls only APIs shared by both revisions. Native validation is serialized with
the repository lock; baseline source, generated databases and owned DerivedData are retired.
Logs, source hashes and measurements remain in the labelled build directory.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = '''// swift-tools-version:6.1
import Foundation
import PackageDescription
let source = ProcessInfo.processInfo.environment["LINGROVE_PAIRED_SOURCE"]!
let package = Package(name: "PairedCorpus", platforms: [.macOS(.v14)],
    dependencies: [.package(path: source + "/Packages/LingroveNotebookEngine")],
    targets: [.executableTarget(name: "PairedCorpus", dependencies: [
        .product(name: "LingroveNotebookEngine", package: "LingroveNotebookEngine")], path: "Sources")],
    swiftLanguageModes: [.v5])
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument("--before", default="b66a2537")
    parser.add_argument("--entries", type=int, default=10000)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--focus", action="store_true", help="Measure entry save and three deletion cases without a full-save window")
    args = parser.parse_args()
    assert args.entries >= 5000 and args.trials > 0
    base = ROOT / "build/corpus-data-layer-paired" / args.label
    base.mkdir(parents=True, exist_ok=False)
    tool = base / "tool"
    source = base / "baseline"
    seed = base / "seed"
    scratch = {name: ROOT / "build/DerivedData" / ("corpus-paired-" + name) for name in ("before", "after")}

    def run(name, command, environment=None):
        print("START " + name, flush=True)
        with (base / (name + ".log")).open("w") as output:
            subprocess.run(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, check=True)
        print("END " + name, flush=True)

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        print("Waiting for the shared Apple validation lock", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Acquired paired benchmark lock", flush=True)
        try:
            source.mkdir()
            archive = base / "baseline.tar"
            with archive.open("wb") as output:
                subprocess.run(["git", "archive", args.before, "Packages"], cwd=ROOT, stdout=output, check=True)
            subprocess.run(["tar", "-xf", str(archive), "-C", str(source)], check=True)
            archive.unlink()
            (tool / "Sources").mkdir(parents=True)
            (tool / "Package.swift").write_text(MANIFEST)
            fixture = ROOT / "scripts/validation/fixtures/CorpusDataLayerPaired.swift"
            shutil.copyfile(fixture, tool / "Sources/main.swift")
            files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "Packages"],
                cwd=ROOT, text=True).splitlines()
            (base / "source-hashes.json").write_text(json.dumps({path: digest(ROOT / path)
                for path in sorted(set(files)) if (ROOT / path).is_file()}, indent=2) + "\n")
            binaries = {}
            for name, path in (("before", source), ("after", ROOT)):
                environment = dict(os.environ, LINGROVE_PAIRED_SOURCE=str(path))
                common = ["swift", "build", "-c", "release", "--package-path", str(tool), "--scratch-path", str(scratch[name])]
                run("build-" + name, common + ["--jobs", "8"], environment)
                location = subprocess.check_output(common + ["--show-bin-path"], cwd=ROOT, env=environment, text=True).strip()
                binaries[name] = str(Path(location) / "PairedCorpus")
            seed.mkdir()
            run("seed", [binaries["before"], "seed", str(seed), str(args.entries)])
            seed_hash = digest(seed / "primary.sqlite")
            result = {"seedSHA256": seed_hash, "beforeCommit": args.before, "fixtureSHA256": digest(fixture),
                "configuration": "Release", "architecture": "arm64", "entries": args.entries,
                "enrolledSenses": args.entries // 5, "ratings": 1000, "samples": []}
            for trial in range(1, args.trials + 1):
                for name in ("before", "after"):
                    folder = base / (name + "-" + str(trial))
                    folder.mkdir()
                    shutil.copyfile(seed / "primary.sqlite", folder / "primary.sqlite")
                    assert digest(folder / "primary.sqlite") == seed_hash
                    label = folder.name
                    run(label, [binaries[name], "measure", str(folder), str(args.entries)],
                        dict(os.environ, LINGROVE_PAIRED_FOCUS="1" if args.focus else "0"))
                    sample = json.loads((base / (label + ".log")).read_text().splitlines()[-1])
                    result["samples"].append(dict(sample, variant=name, trial=trial))
                    shutil.rmtree(folder)
            assert digest(seed / "primary.sqlite") == seed_hash
            (base / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        finally:
            for path in [source, seed, tool, *scratch.values()]:
                shutil.rmtree(path, ignore_errors=True)
            for path in base.glob("*-*"):
                if path.is_dir() and path.name.rsplit("-", 1)[-1].isdigit():
                    shutil.rmtree(path)
            (base / "cleanup.json").write_text(json.dumps({"ownedBuildsRemoved": all(not path.exists() for path in scratch.values()),
                "syntheticSeedRemoved": not seed.exists(), "baselineSourceRemoved": not source.exists(),
                "installedAppAccessed": False}, indent=2) + "\n")
        print("Paired measurement completed; seed/source/build copies removed", flush=True)


if __name__ == "__main__":
    main()
