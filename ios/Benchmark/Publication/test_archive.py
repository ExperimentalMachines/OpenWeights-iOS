import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import archive
import benchmark


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / "outputs/batch"
        self.folder.mkdir(parents=True)
        benchmark.save(self.folder / "index.json", {"status": "stopped-after-failure", "records": [{"status": "failed"}]})
        (self.folder / "one.xcresult").mkdir()
        (self.folder / "one.xcresult/data").write_bytes(b"fixture result bytes")
        attachments = self.folder / "001-attachments"
        attachments.mkdir()
        benchmark.save(attachments / "raw.json", {"purpose": "publication-conversation-v1", "runID": "fixture"})

    def test_pack_validates_members_and_preserves_local_tree(self):
        # Test the normal scope check using an isolated synthetic module path.
        with patch.object(archive, "__file__", str(self.root / "archive.py")), patch.object(archive, "WORKSPACE", self.root):
            package, plan, manifest = archive.package(self.folder)
        with zipfile.ZipFile(package) as bundle:
            self.assertIsNone(bundle.testzip())
            self.assertEqual(json.loads(bundle.read("member-manifest.json")), manifest)
        self.assertTrue((self.folder / "one.xcresult/data").exists())
        self.assertEqual(json.loads(plan.read_text())["bucket"], "zeraphim/openweights-ios-artifacts")

    def test_changed_evidence_never_evicted(self):
        manifest = {str(p.relative_to(self.folder)): {"bytes": p.stat().st_size, "sha256": archive.digest(p)}
                    for p in self.folder.rglob("*") if p.is_file()}
        (self.folder / "one.xcresult/data").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            archive.evict_verified_large_files(self.folder, manifest)
        self.assertTrue((self.folder / "one.xcresult").exists())

    def test_eviction_retains_raw_reports_and_small_index(self):
        manifest = {str(p.relative_to(self.folder)): {"bytes": p.stat().st_size, "sha256": archive.digest(p)}
                    for p in self.folder.rglob("*") if p.is_file()}
        archive.evict_verified_large_files(self.folder, manifest)
        self.assertTrue((self.folder / "index.json").exists())
        self.assertFalse((self.folder / "one.xcresult").exists())
        self.assertEqual(len(list((self.folder / "retained-reports").glob("*.json"))), 1)

    def test_running_batch_not_packaged(self):
        benchmark.save(self.folder / "index.json", {"status": "measure-running", "records": [{"status": "running"}]})
        with patch.object(archive, "__file__", str(self.root / "archive.py")), patch.object(archive, "WORKSPACE", self.root):
            with self.assertRaises(ValueError):
                archive.package(self.folder)


if __name__ == "__main__":
    unittest.main()
