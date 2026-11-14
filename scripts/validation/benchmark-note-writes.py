#!/usr/bin/env python3
"""Paired Release Note writers on closed synthetic 10k/20k notebooks; never installed Dev data."""
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
let package = Package(name: "NoteWrites", platforms: [.macOS(.v14)],
 dependencies: [.package(path: source + "/Packages/LingroveNotebookEngine")],
 targets: [.executableTarget(name: "NoteWrites", dependencies: [.product(name: "LingroveNotebookEngine", package: "LingroveNotebookEngine")], path: "Sources")], swiftLanguageModes: [.v5])
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument("--phase", choices=["before", "after", "final"], required=True,
                        help="before/after share a closed seed; final measures the current tree on a fresh equivalent seed")
    parser.add_argument("--sizes", default="10000,20000")
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--source-root", type=Path, default=ROOT, help="Source to preserve for the before variant")
    parser.add_argument("--operations", default="note_edit,type_edit_one,type_edit_shared")
    args = parser.parse_args()
    base = ROOT / "build/note-write-benchmark" / args.label
    base.mkdir(parents=True, exist_ok=True)
    tool = base / "tool"
    baseline = base / "baseline"
    scratch = ROOT / "build/DerivedData/note-writes"
    def run(name, command, env=None):
        print("START " + name, flush=True)
        with (base / (name + ".log")).open("w") as log:
            subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        print("END " + name, flush=True)
    with open("/tmp/lingrove-mobile-validation.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.phase in ["before", "final"]:
            assert not baseline.exists()
            if args.phase == "before":
                shutil.copytree(args.source_root / "Packages", baseline / "Packages", ignore=shutil.ignore_patterns(".build", ".swiftpm"))
            (tool / "Sources").mkdir(parents=True)
            (tool / "Package.swift").write_text(MANIFEST)
            fixture = (ROOT / "scripts/validation/fixtures/CorpusDataLayerPaired.swift").read_text()
            fixture = fixture.replace('try measureCandidate(args[1], engine: db, count: count)', 'try measureNoteWrite(args[1], engine: db)')
            (tool / "Sources/main.swift").write_text(fixture)
            for name in ["CorpusCandidateOperations.swift", "ReviewNoteWriteOperations.swift"]:
                shutil.copyfile(ROOT / "scripts/validation/fixtures" / name, tool / "Sources" / name)
        source = baseline if args.phase == "before" else ROOT
        files = sorted((source / "Packages").rglob("*.swift"))
        (base / (args.phase + "-sources.json")).write_text(json.dumps({str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, indent=2))
        env = dict(os.environ, LINGROVE_PAIRED_SOURCE=str(source), LINGROVE_PAIRED_CANDIDATES="1")
        if scratch.exists():
            shutil.rmtree(scratch)
        command = ["swift", "build", "-c", "release", "--package-path", str(tool), "--scratch-path", str(scratch)]
        run(args.phase + "-build", command + ["--jobs", "8"], env)
        location = subprocess.check_output(command + ["--show-bin-path"], cwd=ROOT, env=env, text=True).strip()
        binary = str(Path(location) / "NoteWrites")
        samples = []
        for size in map(int, args.sizes.split(",")):
            seed = base / ("seed-" + str(size))
            if args.phase in ["before", "final"]:
                seed.mkdir()
                run("seed-" + str(size), [binary, "seed", str(seed), str(size)], env)
            seed_hash = hashlib.sha256((seed / "primary.sqlite").read_bytes()).hexdigest()
            for trial in range(1, args.trials + 1):
                for operation in args.operations.split(","):
                    case = base / (args.phase + "-trial")
                    shutil.copytree(seed, case)
                    label = args.phase + "-" + str(size) + "-" + operation + "-" + str(trial)
                    run(label, [binary, operation, str(case), str(size)], env)
                    sample = json.loads((base / (label + ".log")).read_text().splitlines()[-1])
                    samples.append(dict(sample, entries=size, trial=trial, seedSHA256=seed_hash))
                    shutil.rmtree(case)
            assert hashlib.sha256((seed / "primary.sqlite").read_bytes()).hexdigest() == seed_hash
        (base / (args.phase + ".json")).write_text(json.dumps({"configuration": "Release", "samples": samples, "installedAppAccessed": False}, indent=2))
        shutil.rmtree(scratch)
        if not any((ROOT / "build/DerivedData").iterdir()):
            (ROOT / "build/DerivedData").rmdir()
        if args.phase in ["after", "final"]:
            if baseline.exists():
                shutil.rmtree(baseline)
            for size in map(int, args.sizes.split(",")):
                shutil.rmtree(base / ("seed-" + str(size)))
            shutil.rmtree(tool)


if __name__ == "__main__":
    main()
