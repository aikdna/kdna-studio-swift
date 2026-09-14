import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("source_surface", ROOT / "scripts/check-source-surface.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class SourceSurfaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="studio-surface-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout"
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns(".git", ".build", ".swiftpm", "__pycache__", "Package.resolved"))

    def change_json(self, name, change):
        path = self.root / name
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def assert_rejected(self):
        with self.assertRaises((AssertionError, FileNotFoundError)):
            GATE.verify(self.root)

    def test_current_inventory(self):
        self.assertEqual(GATE.verify(self.root)["historical_files"], 23)

    def test_missing_historical_entry(self):
        self.change_json("surface-disposition.json", lambda v: v["historical_files"].pop())
        self.assert_rejected()

    def test_altered_historical_test(self):
        path = self.root / "Tests/BlankCreationTests/StudioSessionTests.swift"
        path.write_text(path.read_text() + "\n// changed historical expectation\n")
        self.assert_rejected()

    def test_historical_source_is_not_recompiled(self):
        path = self.root / "Package.swift"
        path.write_text(path.read_text().replace("Sources/ComponentCreation", "Sources/BlankCreation"))
        self.assert_rejected()

    def test_unregistered_source(self):
        (self.root / "Sources/ComponentCreation/Extra.swift").write_text("import Foundation\n")
        self.assert_rejected()

    def test_unregistered_public_type(self):
        path = self.root / "Sources/ComponentCreation/CreationAPI.swift"
        path.write_text(path.read_text() + "\npublic struct UnexpectedCapability {}\n")
        self.assert_rejected()

    def test_fixture_tampering(self):
        path = self.root / "Tests/ComponentCreationTests/Resources/JavaScript/ordinary/asset.kdna"
        data = bytearray(path.read_bytes())
        data[-1] ^= 1
        path.write_bytes(data)
        self.assert_rejected()

    def test_contract_tampering(self):
        path = self.root / "docs/current-creation/API.d.ts"
        path.write_bytes(path.read_bytes() + b"\n")
        self.assert_rejected()

    def test_symlink_does_not_replace_source(self):
        path = self.root / "Sources/ComponentCreation/CreationAPI.swift"
        captured = Path(self.temporary.name) / "captured.swift"
        path.rename(captured)
        path.symlink_to(captured)
        self.assert_rejected()

    def test_dependency_pin_drift(self):
        self.change_json("public-contract-binding.json", lambda v: v["dependency_source"].update(revision="0" * 40))
        self.assert_rejected()


class ResponsibilityNameTests(unittest.TestCase):
    setUp = SourceSurfaceTests.setUp
    def run_names(self):
        return subprocess.run(["bash", "scripts/check-responsibility-names.sh", "working-tree"], cwd=self.root, capture_output=True, text=True, timeout=30)

    def test_platform_spelling_is_allowed(self):
        result = self.run_names()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_platform_line_does_not_exempt_other_names(self):
        path = self.root / "Package.swift"
        line = next(line for line in path.read_text().splitlines() if "platforms:" in line)
        path.write_text(path.read_text().replace(line, line + " // runtime" + "V" + "9"))
        result = self.run_names()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_file_names_are_checked(self):
        (self.root / ("unexpected" + "V" + "9.swift")).write_text("// empty fixture\n")
        result = self.run_names()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
