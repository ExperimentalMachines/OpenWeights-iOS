import copy
import json
from pathlib import Path
import unittest

import benchmark
import cloud
import test_benchmark


class CloudTests(unittest.TestCase):
    def test_portable_cloud_plan_selects_only_wrapper_and_preserves_pins(self):
        artifact=json.loads(Path(cloud.__file__).with_name('comparison-models.json').read_text())['artifacts'][1]
        base={'BenchmarkTests':{'BlueprintName':'BenchmarkTests','TestHostPath':'__TESTROOT__/Release-iphoneos/app',
            'EnvironmentVariables':{'OW_STUDY_RUNTIME':'old','OW_PUBLICATION_RUNTIME':'old'}}}
        p=cloud.cloud_plan(base,artifact,{'turns':[]},'llama.cpp Metal');t=benchmark.targets(p)[0]
        self.assertEqual(t['OnlyTestIdentifiers'],['BenchmarkTests/testPublicationCloudConversation'])
        self.assertFalse(t['ParallelizationEnabled']);self.assertEqual(t['MaximumTestExecutionTimeAllowance'],600)
        self.assertNotIn('OW_STUDY_RUNTIME',t['EnvironmentVariables'])
        self.assertEqual(json.loads(t['EnvironmentVariables']['OW_PUBLICATION_ARTIFACT']),artifact)
        base['BenchmarkTests']['TestHostPath']='/Users/fixture/app'
        with self.assertRaises(ValueError):cloud.cloud_plan(base,artifact,{},'llama.cpp CPU')

    def fixture(self):
        helper=test_benchmark.PublicationTests();helper.setUp();self.addCleanup(helper.doCleanups)
        original=helper.add_report();report=json.loads((original/'report.json').read_text())
        index=json.loads((helper.batch/'index.json').read_text());index['records']=index['records'][1:3]
        for r in index['records']:r['status']='pending'
        benchmark.save(helper.batch/'index.json',index)
        import shutil
        shutil.rmtree(original)
        directories=[]
        for n,runtime in enumerate(benchmark.RUNTIMES):
            p=helper.root/('input'+str(n));p.mkdir();r=copy.deepcopy(report)
            r.update(runID='fixture'+str(n),processIdentifier=12345+n)
            r['rows'][0].update(engine=runtime,backend='CPU|CPU:2' if n==0 else 'MTL0|MTL0:2|CPU:1')
            benchmark.save(p/'report.json',r)
            a=r['rows'][0]['artifact'];f=a['files'][0]
            benchmark.save(p/'acquisition.json',[dict(artifactID=a['id'],file=f['file'],receivedFileBytes=f['bytes'],outcome='cache-verified')])
            directories.append(p)
        return helper.batch,directories

    def test_collection_uses_frozen_scores_with_single_repetition_denominators(self):
        folder,dirs=self.fixture();self.assertTrue(cloud.collect(folder,dirs,['passed','passed']))
        summary=json.loads((folder/'summary.json').read_text());self.assertEqual(summary['status'],'cloud-pilot-complete')
        for r in summary['rows']:
            self.assertEqual((r['plannedConversations'],r['plannedSamples'],r['plannedProbes']),(1,6,3))
            self.assertEqual((r['factualProbesCorrect'],r['strictProbesCorrect']),(3,2))
        with self.assertRaises(ValueError):cloud.collect(folder,dirs,['passed','passed'])

    def test_missing_acquisition_evidence_and_failed_native_are_not_pooled(self):
        folder,dirs=self.fixture();(dirs[0]/'acquisition.json').unlink()
        self.assertFalse(cloud.collect(folder,dirs,['passed','failed']))
        rows=json.loads((folder/'summary.json').read_text())['rows']
        self.assertEqual([r['completedConversations'] for r in rows],[0,0])

    def test_shared_process_rejected(self):
        folder,dirs=self.fixture();p=dirs[1]/'report.json';r=json.loads(p.read_text());r['processIdentifier']=12345;benchmark.save(p,r)
        with self.assertRaises(ValueError):cloud.collect(folder,dirs,['passed','passed'])


if __name__=='__main__':unittest.main()
