#!/usr/bin/env python3
"""Check current targets and exact historical/contract fixture inventories."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HISTORICAL = (
    "Sources/BlankCreation", "Tests/BlankCreationTests",
    "Sources/KDNAStudioCore", "Tests/KDNAStudioCoreTests",
)


def read_json(root, name):
    return json.loads((root / name).read_text())


def files(root, prefix):
    result = []
    directory = root / prefix
    assert directory.is_dir() and not directory.is_symlink(), prefix
    for item in directory.rglob("*"):
        assert not item.is_symlink(), f"symlink in source inventory: {item}"
        if item.is_file():
            result.append(item.relative_to(root).as_posix())
    return sorted(result)


def verify_inventory(root, rows, actual):
    names = [row["path"] for row in rows]
    assert names == sorted(set(names)), "inventory must be unique and sorted"
    assert names == sorted(actual), "unregistered or missing inventory member"
    for row in rows:
        assert set(row) == {"path", "sha256"}
        assert re.fullmatch(r"[a-f0-9]{64}", row["sha256"])
        assert hashlib.sha256((root / row["path"]).read_bytes()).hexdigest() == row["sha256"], row["path"]


def verify(root=ROOT, manifest=None):
    root = Path(root)
    surface = read_json(root, "surface-disposition.json")
    binding = read_json(root, "public-contract-binding.json")
    assert surface["schema_version"] == "1.0.0"
    assert surface["version"] == binding["version"] == "0.6.0-rc.components.1"
    assert surface["public_product"] == binding["product"] == "KDNAStudioCore"
    assert surface["compiled_source_path"] == "Sources/ComponentCreation"
    assert surface["compiled_test_path"] == "Tests/ComponentCreationTests"
    assert surface["current_source_files"] == files(root, "Sources/ComponentCreation")
    assert len(surface["current_source_files"]) == 11
    public_types = []
    for name in surface["current_source_files"]:
        public_types.extend(re.findall(r"^public (?:enum|struct|actor|typealias) (\w+)", (root / name).read_text(), re.MULTILINE))
    assert sorted(public_types) == sorted(surface["public_types"]), "unregistered public type"
    verify_inventory(root, surface["historical_files"], [name for prefix in HISTORICAL for name in files(root, prefix)])
    verify_inventory(root, surface["current_fixture_files"], files(root, "Tests/ComponentCreationTests/Resources"))
    assert len(surface["historical_files"]) == 23
    assert len(surface["current_fixture_files"]) == 15
    assert sorted(group["path"] for group in surface["historical_source_groups"]) == sorted(HISTORICAL)
    for legacy in surface["legacy"]:
        assert legacy["source"] in {row["path"] for row in surface["historical_files"]}
        assert "excluded" in legacy["disposition"] and "no compatibility alias" in legacy["disposition"]
    specs = binding["studio_evidence"]["specs"]
    assert len(specs) == 4
    assert sorted(spec["name"] for spec in specs) == sorted(Path(n).name for n in files(root, "docs/current-creation"))
    for spec in specs:
        data = (root / "docs/current-creation" / spec["name"]).read_bytes()
        assert len(data) == spec["bytes"]
        assert hashlib.sha256(data).hexdigest() == spec["sha256"], spec["name"]
    package = (root / "Package.swift").read_text()
    assert package.count('path: "Sources/ComponentCreation"') == 1
    assert package.count('path: "Tests/ComponentCreationTests"') == 1
    assert package.count(".target(") == package.count(".testTarget(") == 1
    assert not any(prefix in package for prefix in HISTORICAL)
    dependency = binding["dependency_source"]
    assert dependency["url"] == "https://github.com/aikdna/kdna-core-swift.git"
    assert re.fullmatch(r"[a-f0-9]{40}", dependency["revision"])
    assert f'url: "{dependency["url"]}", revision: "{dependency["revision"]}"' in package
    assert package.count(".package(") == 1 and "../kdna-core-swift" not in package
    if manifest is not None:
        assert [p["name"] for p in manifest["products"]] == ["KDNAStudioCore"]
        assert [(t["name"], t["path"], t["type"]) for t in manifest["targets"]] == [
            ("KDNAStudioCore", "Sources/ComponentCreation", "regular"),
            ("KDNAStudioCoreTests", "Tests/ComponentCreationTests", "test"),
        ]
        deps = manifest["dependencies"]
        assert len(deps) == 1
        remote = deps[0]["sourceControl"][0]
        assert remote["location"]["remote"][0]["urlString"] == dependency["url"]
        assert remote["requirement"] == {"revision": [dependency["revision"]]}
    return {"status": "SOURCE_SURFACE_VALID", "current_sources": 11,
            "historical_files": 23, "current_fixtures": 15,
            "frozen_contracts": 4, "swiftpm_manifest_checked": manifest is not None}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftpm", action="store_true", help="also inspect SwiftPM's actual evaluated manifest")
    args = parser.parse_args()
    manifest = None
    if args.swiftpm:
        with tempfile.TemporaryDirectory(prefix="studio-manifest-") as temporary:
            command = ["swift", "package"]
            for option in ("cache", "config", "security", "scratch"):
                command.extend(["--" + option + "-path", str(Path(temporary) / option)])
            result = subprocess.run(command + ["dump-package"], cwd=ROOT, capture_output=True, text=True, timeout=60, check=True)
            manifest = json.loads(result.stdout)
    print(json.dumps(verify(manifest=manifest), sort_keys=True))
