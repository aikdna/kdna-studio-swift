#!/usr/bin/env python3
"""Build a separate public client and exercise real save/readback boundaries."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, cwd, log):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=300)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"command exited {result.returncode}; see {log}")
    return result.stdout


def check(work, configuration):
    work.mkdir(mode=0o700)
    source = work / "Sources/Consumer"
    source.mkdir(parents=True)
    shutil.copyfile(ROOT / "Examples/CreationConsumer.swift", source / "Consumer.swift")
    dependency = json.loads((ROOT / "public-contract-binding.json").read_text())["dependency_source"]
    quoted_root = json.dumps(str(ROOT), ensure_ascii=False)
    (work / "Package.swift").write_text(f'''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "StudioPublicConsumer", platforms: [.macOS("13.0")],
    dependencies: [.package(path: {quoted_root}),
                   .package(url: "{dependency['url']}", revision: "{dependency['revision']}")],
    targets: [.executableTarget(name: "Consumer", dependencies: [
        .product(name: "KDNAStudioCore", package: "{ROOT.name}"),
        .product(name: "KDNACore", package: "kdna-core-swift")])])
''')
    options = []
    for name in ("cache", "config", "security", "scratch"):
        options.extend(["--" + name + "-path", str(work / name)])
    run(["swift", "build", *options, "-c", configuration, "-j", "2"], work, work / "build.log")
    binary_dir = Path(run(["swift", "build", *options, "-c", configuration, "--show-bin-path"], work, work / "bin-path.log").strip())
    output = run([str(binary_dir / "Consumer"), str(work / "actual.kdna")], work, work / "consumer.log")
    result = json.loads(output)
    assert result == {"status": "PUBLIC_CONSUMER_PASS", "actual_saved_readback": True,
                      "static_live_context": "unavailable", "identity": "not_verified"}
    rejected = source / "Unavailable.swift"
    rejected.write_text("import KDNAStudioCore\nlet retired = KDNStudioCards.self\n")
    command = ["swift", "build", *options, "-c", configuration, "-j", "2"]
    diagnostic = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=60)
    (work / "retired-symbol.log").write_text(diagnostic.stdout + diagnostic.stderr)
    rejected.unlink()
    assert diagnostic.returncode != 0 and "cannot find 'KDNStudioCards'" in diagnostic.stdout + diagnostic.stderr
    result["configuration"] = configuration
    result["retired_symbol_rejected"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--work-dir", type=Path, help="new directory for retained build and run logs")
    args = parser.parse_args()
    if args.work_dir:
        result = check(args.work_dir.resolve(), args.configuration)
    else:
        with tempfile.TemporaryDirectory(prefix="studio-public-consumer-") as temporary:
            result = check(Path(temporary) / "consumer", args.configuration)
    print(json.dumps(result, sort_keys=True))
