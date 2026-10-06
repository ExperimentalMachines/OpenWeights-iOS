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
            retry.write_text(json.dumps(copied))
            with self.assertRaises(ValueError):
                study.analyze([primary, retry], 5)
            copied['study']['attempt'] = 1
            retry.write_text(json.dumps(copied))
            result = study.analyze([primary, retry], 5)
            self.assertEqual(len(result['retryRows']), 5)
            self.assertTrue(all(cell['independentReports'] == 1 for cell in result['cells']))

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
            other.write_text(json.dumps(copied))
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
            partial.write_text(json.dumps(copied))
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


if __name__ == '__main__':
    unittest.main()
