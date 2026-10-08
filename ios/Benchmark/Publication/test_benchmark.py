import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import sys
import time
import shutil

import benchmark


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = json.loads(Path(benchmark.__file__).with_name("pilot-models.json").read_text())
        self.models = self.root / "models.json"
        self.models.write_text(json.dumps(self.manifest))
        self.base = self.root / "base.xctestrun"
        self.base.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "BenchmarkTests", "TestHostPath": "__TESTROOT__/Release-iphoneos/app",
            "EnvironmentVariables": {"OW_STUDY_RUNTIME": "obsolete"}}]}]}))
        self.batch = self.root / "batch"

    def prepare(self):
        benchmark.prepare(self.base, self.batch, self.models)
        return json.loads((self.batch / "index.json").read_text())

    def test_three_repetitions_rotated_without_replays(self):
        index = self.prepare()
        calls = index["records"]
        self.assertEqual(len(calls), 7)
        self.assertEqual([c["runtime"] for c in calls[1:]], benchmark.RUNTIMES + benchmark.RUNTIMES[::-1] + benchmark.RUNTIMES)
        target = benchmark.targets(plistlib.loads((self.batch / calls[1]["plan"]).read_bytes()))[0]
        self.assertEqual(target["OnlyTestIdentifiers"], ["BenchmarkTests/testPublicationConversation"])
        self.assertFalse(target["ParallelizationEnabled"])
        self.assertNotIn("OW_STUDY_RUNTIME", target["EnvironmentVariables"])
        self.assertNotIn("__TESTROOT__", target["TestHostPath"])

    def test_reject_unpinned_url_or_unsafe_filename(self):
        for changed in [{"file": "../bad.gguf"}, {"url": "https://huggingface.co/repo/resolve/main/model.gguf"},
                        {"sha256": "unknown"}]:
            manifest = copy.deepcopy(self.manifest)
            manifest["artifacts"][0]["files"][0].update(changed)
            with self.assertRaises(ValueError):
                benchmark.validate_manifest(manifest)

    def test_budget_and_overwrite_rejected(self):
        with self.assertRaises(ValueError):
            benchmark.prepare(self.base, self.batch, self.models, 3601)
        self.prepare()
        with self.assertRaises(FileExistsError):
            self.prepare()

    def test_missing_data_remains_visible(self):
        self.prepare()
        benchmark.summarize(self.batch)
        rows = json.loads((self.batch / "summary.json").read_text())["rows"]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["plannedConversations"], 3)
        self.assertEqual(rows[0]["completedConversations"], 0)
        self.assertIsNone(rows[0]["firstTextSeconds"])
        self.assertEqual(rows[0]["plannedProbes"], 9)

    def add_report(self, thermal=0, status="passed"):
        index = self.prepare()
        index["records"][1]["status"] = status
        benchmark.save(self.batch / "index.json", index)
        workload = json.loads((self.batch / "workload.json").read_text())
        samples = [dict(turn=t, firstCallbackMs=100, streamTokensPerSecond=20, generatedTokens=16,
                        peakFootprintBytes=1048576, stopReason="eos", thermalStart=thermal, thermalEnd=thermal,
                        output="acknowledged") for t in range(1, 7)]
        samples[2].update(output='```json\n{"codename":"Birch","budget":620}\n```', memoryProbePassed=False)
        samples[4].update(output="vegan", memoryProbePassed=True, generatedTokens=1, streamTokensPerSecond=900)
        samples[5].update(output='{"codename":"Birch","venue":"Porto","budget":620,"diet":"vegan"}', memoryProbePassed=True)
        report = dict(purpose="publication-conversation-v1", runID="fixture-only", completed=True,
                      processIdentifier=12345,
                      lowPowerMode=False, multiTurnWorkload=workload, study=dict(protocolID=benchmark.PROTOCOL, block=0),
                      rows=[dict(artifact=self.manifest["artifacts"][0], engine=benchmark.RUNTIMES[0],
                                 backend="CPU|CPU:2",
                                 loadPeakFootprintBytes=2097152, samples=samples)])
        attachment = self.batch / "001-attachments"
        attachment.mkdir()
        benchmark.save(attachment / "report.json", report)
        return attachment

    def test_short_output_excluded_and_format_separated(self):
        self.add_report()
        benchmark.summarize(self.batch)
        row = json.loads((self.batch / "summary.json").read_text())["rows"][0]
        self.assertEqual(row["streamingTokensPerSecond"], 20)
        self.assertEqual(row["peakProcessMiB"], 2)
        self.assertEqual(row["factualProbesCorrect"], 3)
        self.assertEqual(row["strictProbesCorrect"], 2)
        self.assertEqual(row["completedConversations"], 1)

    def test_failed_or_warm_run_not_pooled(self):
        self.add_report(thermal=1)
        benchmark.summarize(self.batch)
        row = json.loads((self.batch / "summary.json").read_text())["rows"][0]
        self.assertEqual(row["nominalSamples"], 0)
        self.assertIsNone(row["peakProcessMiB"])
        index = json.loads((self.batch / "index.json").read_text())
        index["records"][1]["status"] = "failed"
        benchmark.save(self.batch / "index.json", index)
        benchmark.summarize(self.batch)
        self.assertEqual(json.loads((self.batch / "summary.json").read_text())["rows"][0]["completedConversations"], 0)

    def test_mismatched_artifact_rejected(self):
        attachment = self.add_report()
        report = json.loads((attachment / "report.json").read_text())
        report["rows"][0]["artifact"]["revision"] = "0" * 40
        benchmark.save(attachment / "report.json", report)
        with self.assertRaises(ValueError):
            benchmark.summarize(self.batch)

    def test_contradictory_or_malformed_facts_not_credited(self):
        self.assertTrue(benchmark.factual_grade("dietary rule: vegan", {"expectedText": "vegan"}))
        self.assertFalse(benchmark.factual_grade("dietary rule: omnivore", {"expectedText": "vegan"}))
        self.assertIsNone(benchmark.factual_grade("dietary rule: not vegan", {"expectedText": "vegan"}))
        self.assertIsNone(benchmark.factual_grade("not vegan", {"expectedText": "vegan"}))
        self.assertFalse(benchmark.factual_grade("omnivore", {"expectedText": "vegan"}))
        self.assertIsNone(benchmark.factual_grade('{"budget":620', {"expectedFields": {"budget": "620"}}))

    def test_phone_ready_gate(self):
        with self.assertRaises(ValueError):
            benchmark.run(self.batch, "no-device", "measure", False)

    def test_calibration_counts_toward_final_batch_without_replay(self):
        index = self.prepare()
        selected = benchmark.select_records(index, "calibrate")
        self.assertEqual(selected, [1, 2])
        for n in selected:
            index["records"][n].update(status="passed", reportPresent=True, hostElapsedSeconds=10)
        index.update(status="calibrate-complete", measurementSpentSeconds=21)
        index["durationEstimate"] = benchmark.calibration_estimate(index)
        self.assertEqual(index["durationEstimate"]["projectedThreeRepetitionsSeconds"], 94.5)
        self.assertEqual(benchmark.select_records(index, "measure"), [3, 4, 5, 6])
        with self.assertRaises(ValueError):
            benchmark.select_records(index, "calibrate")

    def test_calibration_budget_gate_and_failure_prevent_further_launches(self):
        index = self.prepare()
        index.update(status="calibrate-complete", measurementSpentSeconds=1000)
        for n in [1, 2]:
            index["records"][n].update(status="passed", reportPresent=True, hostElapsedSeconds=500)
        index["durationEstimate"] = benchmark.calibration_estimate(index)
        self.assertFalse(index["durationEstimate"]["fitsBudget"])
        with self.assertRaises(ValueError):
            benchmark.select_records(index, "measure")
        index["status"] = "stopped-after-failure"
        with self.assertRaises(ValueError):
            benchmark.select_records(index, "measure")

    def test_stalled_host_command_is_stopped(self):
        started = time.monotonic()
        code, expired = benchmark.bounded_command(
            [sys.executable, "-c", "import time; time.sleep(60)"], self.root / "timeout.log", 0.1)
        self.assertTrue(expired)
        self.assertNotEqual(code, 0)
        self.assertLess(time.monotonic() - started, 10)

    def test_reused_process_id_rejected(self):
        attachment = self.add_report()
        report = json.loads((attachment / "report.json").read_text())
        report["rows"][0]["engine"] = benchmark.RUNTIMES[1]
        report["runID"] = "second-fixture-only"
        other = self.batch / "002-attachments"
        other.mkdir()
        benchmark.save(other / "report.json", report)
        with self.assertRaises(ValueError):
            benchmark.summarize(self.batch)

    def test_backend_selection_requires_native_observation(self):
        self.assertTrue(benchmark.backend_matches("llama.cpp Metal", "Metal|Metal:320|CPU:8"))
        self.assertTrue(benchmark.backend_matches("llama.cpp Metal", "MTL0|MTL0:320|CPU:8"))
        self.assertFalse(benchmark.backend_matches("llama.cpp Metal", "CPU|CPU:320"))
        self.assertFalse(benchmark.backend_matches("llama.cpp CPU", "Metal|Metal:320"))
        self.assertFalse(benchmark.backend_matches("llama.cpp CPU", ""))

    def test_summary_reproduces_after_large_attachments_evicted(self):
        attachment = self.add_report()
        benchmark.summarize(self.batch)
        before = (self.batch / "summary.json").read_bytes()
        shutil.rmtree(attachment)
        benchmark.summarize(self.batch)
        self.assertEqual((self.batch / "summary.json").read_bytes(), before)

    def test_xcode_export_manifest_is_not_a_report(self):
        attachment = self.add_report()
        benchmark.save(attachment / "manifest.json", [{"testName": "testPublicationConversation", "attachments": []}])
        benchmark.summarize(self.batch)
        self.assertEqual(json.loads((self.batch / "summary.json").read_text())["rows"][0]["completedConversations"], 1)

    def test_codable_omitted_optional_is_equivalent_to_null(self):
        attachment = self.add_report()
        report = json.loads((attachment / "report.json").read_text())
        report["multiTurnWorkload"].pop("interruptionBeforeTurn", None)
        benchmark.save(attachment / "report.json", report)
        benchmark.summarize(self.batch)
        self.assertEqual(json.loads((self.batch / "summary.json").read_text())["rows"][0]["completedConversations"], 1)
        report["multiTurnWorkload"]["interruptionBeforeTurn"] = 2
        benchmark.save(attachment / "report.json", report)
        with self.assertRaises(ValueError):
            benchmark.summarize(self.batch)


if __name__ == "__main__":
    unittest.main()
