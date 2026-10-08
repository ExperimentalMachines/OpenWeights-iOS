import json
import unittest
from pathlib import Path

from report_study import render


class SourceBuildReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[1] / 'Results/study-analysis-source-build-separated-schema5-grading3-2026-10-07.json'
        cls.analysis = json.loads(path.read_text())
        cls.report = render(cls.analysis)

    def test_corrected_coverage_is_visible(self):
        self.assertIn('9 of 63 planned cells', self.report)
        self.assertIn('historical 19-cell count pooled builds and is superseded', self.report)
        self.assertIn('1 local artifact configuration has', self.report)

    def test_separated_rows_expose_build_and_sample_count(self):
        lines = [line for line in self.report.splitlines() if line.startswith('| iPhone17,3') and 'O3 llama.cpp Metal' in line]
        self.assertEqual(len(lines), 5)  # One S1 cohort, two S2 and two S3 cohorts.
        self.assertEqual(sorted(line.split('|')[4].strip() for line in lines), ['1', '1', '4', '4', '5'])
        self.assertTrue(all(len(line.split('|')[3].strip()) == 12 for line in lines))

    def test_mixed_build_figures_do_not_claim_current_replication(self):
        self.assertNotIn('![Updated facts:', self.report)
        self.assertNotIn('![Interruption and recovery:', self.report)
        self.assertIn('S2/S3 six-configuration figures pooled different source/build cohorts', self.report)
        self.assertIn('![Stable facts: seven replicated local configurations]', self.report)

    def test_all_source_proofs_remain_in_reproduction_index(self):
        for source in self.analysis['sources']:
            self.assertIn(source['file'], self.report)
            self.assertIn(source['sha256'], self.report)
            self.assertIn(source['sourceProofFile'], self.report)
            self.assertIn(source['sourceProofSHA256'], self.report)
            self.assertIn(source['buildCohortSHA256'], self.report)


if __name__ == '__main__':
    unittest.main()
