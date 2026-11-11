#!/usr/bin/env python3
"""Compare complete, passing remaining-path runs; never infer success from partial samples."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics


def read_run(root):
    summary = json.loads((root / "remaining-summary.log").read_text())
    assert summary["result"] == "Passed" and summary["passedTests"] > 0
    assert summary["failedTests"] == 0 and summary["skippedTests"] == 0
    identity = json.loads((root / "identity.json").read_text())
    identity["sourceManifestSHA256"] = hashlib.sha256((root / "source-hashes.json").read_bytes()).hexdigest()
    identity["sourceManifestEntries"] = len(json.loads((root / "source-hashes.json").read_text()))
    assert identity["configuration"] == "Release" and identity["installedAppAccessed"] is False
    samples = [json.loads(line) for line in (root / "remaining/samples.jsonl").read_text().splitlines()]
    groups = {}
    for sample in samples:
        key = (sample["entries"], sample["operation"])
        groups.setdefault(key, []).append(sample)
        assert sample["milliseconds"] >= 0 and sample.get("outcome", "success") == "success"
    for key, values in groups.items():
        assert len(values) == identity["trials"], key
        assert sorted(row["trial"] for row in values) == list(range(1, identity["trials"] + 1)), key
        assert len({row["layer"] for row in values}) == 1, key
    fixture = {size: json.loads((root / f"remaining/fixture-{size}.json").read_text())
               for size in {key[0] for key in groups}}
    return identity, samples, groups, fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    before, old_samples, old, old_fixture = read_run(args.before)
    after, new_samples, new, new_fixture = read_run(args.after)
    harness = "LingroveTests/Services/Vocabulary/VocabularyOperationBenchmarkTests.swift"
    manifests = [json.loads((root / "source-hashes.json").read_text()) for root in (args.before, args.after)]
    if harness in manifests[0]:
        assert manifests[0][harness] == manifests[1][harness], "Timing harness changed"
    assert old.keys() == new.keys() and len(old) == 43
    for key in ("configuration", "architecture", "hardware", "sizes", "trials"):
        assert before[key] == after[key], key
    for size in old_fixture:
        counts = lambda fixture: {key: value for key, value in fixture.items() if key != "databaseBytes"}
        assert counts(old_fixture[size]) == counts(new_fixture[size])
    rows = []
    for (size, operation), values in old.items():
        current = new[(size, operation)]
        assert values[0]["layer"] == current[0]["layer"]
        a = statistics.median(row["milliseconds"] for row in values)
        b = statistics.median(row["milliseconds"] for row in current)
        rows.append(dict(entries=size, operation=operation, layer=values[0]["layer"],
                         beforeMedianMs=a, afterMedianMs=b,
                         beforeMaxMs=max(row["milliseconds"] for row in values),
                         afterMaxMs=max(row["milliseconds"] for row in current),
                         reductionPercent=100 * (1 - b / a) if a else None))
    provenance = "The source manifests include the same timing-harness SHA-256."
    if not manifests[0]:
        provenance = (f"Archived {before['commit']} product; the baseline script copied the current timing harness before product edits. "
                      "The archive run recorded an empty source manifest; its build log, binary hash and archive procedure remain available. "
                      "Harness hash equality cannot be checked from that empty manifest.")
    result = dict(before=before, after=after, beforeFixture=old_fixture, afterFixture=new_fixture,
                  method="43 production command/projection windows, 3 trials, separately generated equivalent seeds; no UI input or frames",
                  baselineProvenance=provenance,
                  rows=rows, beforeSamples=old_samples, afterSamples=new_samples)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    for row in rows:
        print(f"{row['operation']:<36} {row['beforeMedianMs']:10.3f} -> {row['afterMedianMs']:10.3f} ms ({row['reductionPercent']:+.1f}%)")


if __name__ == "__main__":
    main()
