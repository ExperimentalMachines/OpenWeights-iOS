import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('study_analysis', Path(__file__).with_name('analyze_study.py'))
study = importlib.util.module_from_spec(spec)
spec.loader.exec_module(study)


class AnalysisTests(unittest.TestCase):
    def write_bound_report(self, path, report, *, source_hash=None, executable_hash=None, xcode=None):
        path.write_text(json.dumps(report))
        proof = json.loads((ROOT / 'Results/iphone16-study-S3-block0-source.json').read_text())
        proof['rawResultsFile'] = path.name
        proof['rawResultsSHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        if source_hash is not None:
            first = next(iter(proof['buildReceipt']['sources']))
            proof['buildReceipt']['sources'][first] = source_hash
        if executable_hash is not None:
            first = next(iter(proof['buildReceipt']['executables']))
            proof['buildReceipt']['executables'][first] = executable_hash
        if xcode is not None:
            proof['buildReceipt']['xcode'] = xcode
        path.with_name(path.stem + '-source.json').write_text(json.dumps(proof))
        return path

    def test_independent_block_statistics(self):
        result = study.summary([1, 2, 3, 4, 5])
        self.assertEqual((result['n'], result['median'], result['p25'], result['p75']), (5, 3, 2, 4))

    def test_facts_remain_separate_from_format_and_misspellings(self):
        self.assertTrue(study.facts({'expectedText': 'pescatarian'}, 'dietary rule: pescatarian'))
        self.assertFalse(study.facts({'expectedText': 'pescatarian'}, 'dietary rule: pescantarian'))
        self.assertFalse(study.facts({'expectedText': 'vegetarian'}, 'non-vegetarian'))
        self.assertFalse(study.facts({'expectedText': 'vegetarian'}, 'not vegetarian'))
        self.assertTrue(study.facts({'expectedFields': {'budget': '730'}}, '```json\n{"budget":730}\n```'))
        self.assertFalse(study.facts({'expectedFields': {'budget': '730'}}, '{"budget":480}'))

    def test_formatting_is_independent_of_correct_values(self):
        fields = {'expectedFields': {'diet': 'pescatarian'}}
        wrong = '{"diet":"pescantarian"}'
        self.assertFalse(study.facts(fields, wrong))
        self.assertTrue(study.formatting(fields, wrong))
        fenced = '```json\n{"diet":"pescatarian"}\n```'
        self.assertTrue(study.facts(fields, fenced))
        self.assertFalse(study.formatting(fields, fenced))
        word = {'expectedText': 'pescatarian'}
        self.assertFalse(study.facts(word, 'pescantarian'))
        self.assertTrue(study.formatting(word, 'pescantarian'))
        self.assertFalse(study.formatting(word, 'dietary rule: pescatarian'))
        self.assertFalse(study.formatting(word, 'pescatarian.'))
        self.assertTrue(study.formatting({'expectedText': '350'}, '480'))
        self.assertFalse(study.formatting({'expectedText': '350'}, '480 euros'))
        self.assertFalse(study.formatting(fields, '{"other":"pescatarian"}'))

    def test_retries_do_not_inflate_primary_replication(self):
        primary = ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json'
        copied = json.loads(primary.read_text())
        copied['runID'] = 'new-attempt-same-planned-block'
        with tempfile.TemporaryDirectory() as directory:
            retry = Path(directory) / 'retry.json'
            self.write_bound_report(retry, copied)
            with self.assertRaises(ValueError):
                study.analyze([primary, retry], 5)
            copied['study']['attempt'] = 1
            self.write_bound_report(retry, copied)
            result = study.analyze([primary, retry], 5)
            self.assertEqual(len(result['retryRows']), 5)
            self.assertTrue(all(cell['independentReports'] == 1 for cell in result['cells']))

    def test_different_builds_cannot_supply_five_matching_blocks(self):
        template = json.loads((ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for block in range(5):
                report = copy.deepcopy(template)
                report['runID'] = f'build-separation-{block}'
                report['study']['block'] = block
                path = Path(directory) / f'block-{block}.json'
                paths.append(self.write_bound_report(path, report,
                    source_hash=('a' if block < 3 else 'b') * 64))
            result = study.analyze(paths, 5)
            self.assertEqual(len({s['buildCohortSHA256'] for s in result['sources']}), 2)
            self.assertTrue(all(c['belowPlannedReplication'] for c in result['cells']))
            self.assertEqual({c['fullyCompletedReports'] for c in result['cells']}, {2, 3})
            for c in result['loadCells']:
                self.assertIn(c['metrics']['loadMs']['n'], [2, 3])

    def test_executable_and_toolchain_changes_split_cohorts(self):
        template = json.loads((ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for i, options in enumerate([{}, {'executable_hash': 'c' * 64}, {'xcode': 'different Xcode'}]):
                report = copy.deepcopy(template)
                report['runID'] = f'compile-change-{i}'
                report['study']['block'] = i
                path = Path(directory) / f'block-{i}.json'
                paths.append(self.write_bound_report(path, report, **options))
            result = study.analyze(paths, 3)
            self.assertEqual(len({s['buildCohortSHA256'] for s in result['sources']}), 3)
            self.assertTrue(all(c['fullyCompletedReports'] == 1 for c in result['cells']))

    def test_missing_or_mismatched_source_proof_is_refused(self):
        template = json.loads((ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'unbound.json'
            path.write_text(json.dumps(template))
            with self.assertRaisesRegex(ValueError, 'Missing retained source proof'):
                study.analyze([path], 5)
            self.write_bound_report(path, template)
            template['rows'][0]['samples'][0]['output'] = 'altered raw evidence'
            path.write_text(json.dumps(template))
            with self.assertRaisesRegex(ValueError, 'exact raw report'):
                study.analyze([path], 5)

    def test_duplicate_report_is_rejected(self):
        primary = ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json'
        with self.assertRaises(ValueError):
            study.analyze([primary, primary], 5)

    def test_build_variants_do_not_pool_the_same_device_os_and_block(self):
        primary = ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json'
        copied = json.loads(primary.read_text())
        copied['runID'] = 'same-device-distinct-gguf-package-variant'
        copied['runtimeVersions'] = {'llama.cpp': copied['runtimeVersions']['llama.cpp'],
                                     'benchmarkVariant': 'gguf-ios16.6-v1', 'minimumIOS': '16.6'}
        copied['rows'] = [row for row in copied['rows'] if row['artifact']['id'] == 'gguf']
        with tempfile.TemporaryDirectory() as directory:
            other = Path(directory) / 'variant.json'
            self.write_bound_report(other, copied)
            result = study.analyze([primary, other], 5)
            self.assertEqual(len(result['loadCells']), 8)
            self.assertTrue(all(cell['independentReports'] == 1 for cell in result['cells']))
            variants = [cell for cell in result['cells'] if cell['runtimeVersions'].get('benchmarkVariant')]
            self.assertTrue(variants)
            self.assertEqual({cell['engine'] for cell in variants},
                             {'llama.cpp CPU', 'llama.cpp Metal', 'llama.cpp partial Metal'})

    def test_partial_reports_keep_measurements_without_counting_as_complete(self):
        primary = ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json'
        copied = json.loads(primary.read_text())
        copied['runID'] = 'partial-independent-block'
        copied['study']['block'] = 1
        copied['completed'] = False
        with tempfile.TemporaryDirectory() as directory:
            partial = Path(directory) / 'partial.json'
            self.write_bound_report(partial, copied)
            result = study.analyze([primary, partial], 2)
            self.assertEqual(len(result['loadCells']), 5)
            for cell in result['cells']:
                self.assertEqual(cell['independentReports'], 2)
                self.assertEqual(cell['fullyCompletedReports'], 1)
                self.assertEqual(cell['metrics']['firstCallbackMs']['n'], 2)
                self.assertEqual(cell['completeReportMetrics']['firstCallbackMs']['n'], 1)
                self.assertTrue(cell['belowPlannedReplication'])
                self.assertEqual(cell['factualRecall']['graded'], 2 * cell['completeReportFactualRecall']['graded'])
                self.assertEqual(cell['strictFormatting']['graded'], 2 * cell['completeReportStrictFormatting']['graded'])

    def test_failed_load_defaults_are_not_measured_zero_values(self):
        primary = ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json'
        copied = json.loads(primary.read_text())
        copied['runID'] = 'failed-before-load-measurement'
        copied['study']['block'] = 1
        copied['rows'] = [copied['rows'][0]]
        row = copied['rows'][0]
        row.update(phase='failed', error='compiled model disk write failed',
                   loadMs=0, loadPeakFootprintBytes=0, samples=[])
        with tempfile.TemporaryDirectory() as directory:
            failed = Path(directory) / 'failed-load.json'
            self.write_bound_report(failed, copied)
            result = study.analyze([primary, failed], 5)
            load = next(c for c in result['loadCells'] if c['engine'] == row['engine'])
            self.assertEqual(load['independentReports'], 2)
            self.assertEqual(load['fullyCompletedReports'], 1)
            self.assertEqual(load['metrics']['loadMs']['n'], 1)
            self.assertGreater(load['metrics']['loadMs']['minimum'], 0)
            self.assertEqual(load['metrics']['loadPeakFootprintBytes']['n'], 1)
            self.assertEqual(load['unmeasuredLoadMetrics'], {'loadMs': 1, 'loadPeakFootprintBytes': 1})
            self.assertEqual(len(result['failedRows']), 1)
            self.assertEqual(result['failedRows'][0]['retainedSamples'], 0)

    def test_measured_load_survives_later_generation_failure(self):
        primary = ROOT / 'Results/iphone16-study-S3-block0-2026-10-02.json'
        copied = json.loads(primary.read_text())
        copied['runID'] = 'failed-after-measured-load'
        copied['study']['block'] = 1
        copied['rows'] = [copied['rows'][0]]
        row = copied['rows'][0]
        row.update(phase='failed', error='generation failed')
        with tempfile.TemporaryDirectory() as directory:
            failed = Path(directory) / 'failed-generation.json'
            self.write_bound_report(failed, copied)
            result = study.analyze([primary, failed], 5)
            load = next(c for c in result['loadCells'] if c['engine'] == row['engine'])
            self.assertEqual(load['fullyCompletedReports'], 1)
            self.assertEqual(load['metrics']['loadMs']['n'], 2)
            self.assertEqual(load['metrics']['loadPeakFootprintBytes']['n'], 2)
            self.assertEqual(load['unmeasuredLoadMetrics'], {'loadMs': 0, 'loadPeakFootprintBytes': 0})
            self.assertEqual(len(result['failedRows']), 1)


if __name__ == '__main__':
    unittest.main()
