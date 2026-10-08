#!/usr/bin/env python3
"""Export only allowlisted benchmark observations and frozen public inputs."""
import csv, hashlib, importlib.util, json, pathlib, shutil, zipfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE = ROOT / 'ios/Benchmark/Publication'
OUT = ROOT / 'site/data'
COHORTS = {
 'iphone16-five-models': ('five-models-20261007-attempt0', 3, 'iPhone 16', 'iOS 26.6.2, build 23G90'),
 'qwen-protocol-pilot': ('qwen-pilot-20261007-attempt2', 3, 'iPhone 16', 'iOS 26.6.2, build 23G90'),
 'firebase-lfm-pilot': ('firebase-lfm-pilot-20261007-attempt0', 1, 'Two iPhone 16 Pro units', 'iOS 18.3.2, build 22D82'),
}
FIELDS = ['turn','firstCallbackMs','streamTokensPerSecond','generatedTokens','peakFootprintBytes',
          'thermalStart','thermalEnd','memoryProbePassed','output','stopReason','totalPromptTokens',
          'cachedTokens','cachePolicy']
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path, value): path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')
runs = []
for cohort,(name,reps,device,os) in COHORTS.items():
 folder = PROFILE/'outputs'/name
 index = json.loads((folder/'index.json').read_text())
 for n,record in enumerate(index['records']):
  if record['stage'] != 'measure': continue
  path = folder/record['rawReportPath']; assert sha(path) == record['rawReportSHA256']
  report = json.loads(path.read_text()); row = report['rows'][0]
  assert record['status']=='passed' and report['completed'] and not report['lowPowerMode'] and not row.get('error')
  assert report['contextTokens']==2048 and report['maxOutputTokens']==64
  runs.append(dict(cohort=cohort,run=f'{cohort}-{n:03d}',model=record['model'],runtime=record['runtime'],
   repetition=record['repetition'],sourceReportSHA256=record['rawReportSHA256'],
   observedBackend=row['backend'],loadPeakFootprintBytes=row['loadPeakFootprintBytes'],
   samples=[{k:s[k] for k in FIELDS if k in s} for s in row['samples']]))
 shutil.copyfile(folder/'summary.csv',OUT/(cohort+'-summary.csv'))
 shutil.copyfile(folder/'turns.csv',OUT/(cohort+'-turns.csv'))
 models=json.loads((folder/'models.json').read_text())
 write(OUT/(cohort+'-models.json'),models)
 receipt=json.loads((folder/'build-receipt.json').read_text())
 write(OUT/(cohort+'-build.json'),{k:receipt[k] for k in ['benchmarkVariant','deploymentTarget','llamaRevision','sdk','xcode','executables','sources']})
write(OUT/'observations.json',runs)
write(OUT/'cohorts.json',{k:dict(repetitions=v[1],device=v[2],os=v[3],measuredDate='2026-10-07') for k,v in COHORTS.items()})
shutil.copyfile(PROFILE/'outputs/five-models-20261007-attempt0/workload.json',OUT/'workload.json')
write(OUT/'denominators.json',json.loads((PROFILE/'outputs/five-models-20261007-attempt0/analysis-denominators.json').read_text())['denominators'])
# Share the exact measured source inputs, without binaries, provisioning or host paths.
source = PROFILE/'outputs/five-models-20261007-attempt0/sources'
receipt=json.loads((PROFILE/'outputs/five-models-20261007-attempt0/build-receipt.json').read_text())
with zipfile.ZipFile(OUT/'measured-sources.zip','w',zipfile.ZIP_DEFLATED) as archive:
 for name,expected in receipt['sources'].items():
  path=source/name
  assert sha(path)==expected
  assert path.suffix in ['.swift','.mm','.cpp','.h','.c','.cmake','.yml','.json','.py','.sh','.txt'], name
  archive.write(path,name)
# Publish a self-contained copy of the frozen collector's scoring and aggregation functions.
collector=(PROFILE/'outputs/five-models-20261007-attempt0/benchmark.py').read_text()
scoring=collector[collector.index('def factual_grade('):collector.index('def median(')]
repro=ROOT/'site/reproduce.py'
repro.write_text(repro.read_text().replace('# FROZEN_SCORER',scoring))
print(f'Exported {len(runs)} conversations and {sum(len(r["samples"]) for r in runs)} turns, without device IDs or private storage paths.')
