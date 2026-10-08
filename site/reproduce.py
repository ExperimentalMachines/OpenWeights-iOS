#!/usr/bin/env python3
"""Reproduce published medians, exclusions and recall from public observations.
Python 3.9+, standard library only. Run: python3 site/reproduce.py
"""
import csv, hashlib, json, math, pathlib, re, statistics
ROOT=pathlib.Path(__file__).resolve().parent
def factual_grade(output, turn):
    """Ignore JSON fences/prose around an object, but do not infer facts from malformed JSON."""
    if "expectedText" in turn:
        # Accept the one-word fact or an unambiguous positive diet label, not arbitrary prose.
        normalized = output.strip().strip('"\' .!\n\r').lower()
        label = re.fullmatch(r"(?:the\s+)?(?:dietary rule|diet)(?:\s*:\s*|\s+is\s+)([\w-]+)", normalized)
        if label:
            normalized = label[1]
        if re.fullmatch(r"[\w-]+", normalized):
            return normalized == turn["expectedText"].lower()
        return None
    if "expectedFields" in turn:
        decoder = json.JSONDecoder()
        objects = []
        for match in re.finditer(r"\{", output):
            try:
                value, _ = decoder.raw_decode(output[match.start():])
                if isinstance(value, dict):
                    objects.append(value)
            except ValueError:
                pass
        if len(objects) != 1:
            return None
        return all(str(objects[0].get(k, "")).lower() == str(v).lower() for k, v in turn["expectedFields"].items())
    return None




def summarize(runs, repetitions, workload):
 groups={}
 for run in runs:groups.setdefault((run['model'],run['runtime']),[]).append(run)
 rows=[];turns=[]
 for (model,runtime),selected in groups.items():
  samples=[];peaks=[]
  for run in selected:
   assert [s['turn'] for s in run['samples']]==list(range(1,7))
   nominal=[s for s in run['samples'] if s['thermalStart']==0 and s['thermalEnd']==0]
   samples+=nominal
   if len(nominal)==6:peaks.append(max([run['loadPeakFootprintBytes']]+[s['peakFootprintBytes'] for s in nominal])/1048576)
  probes=[s for s in samples if s.get('memoryProbePassed') is not None]
  facts=[factual_grade(s['output'],workload['turns'][s['turn']-1]) for s in probes]
  median=lambda values:statistics.median(values) if values else None
  rows.append(dict(model=model,runtime=runtime,completedConversations=len(selected),plannedConversations=repetitions,
   nominalSamples=len(samples),plannedSamples=repetitions*6,firstTextSeconds=median([s['firstCallbackMs']/1000 for s in samples]),
   streamingTokensPerSecond=median([s['streamTokensPerSecond'] for s in samples if s['generatedTokens']>=8 and s.get('streamTokensPerSecond') is not None]),
   peakProcessMiB=median(peaks),factualProbesCorrect=sum(v is True for v in facts),factualProbesScorable=sum(v is not None for v in facts),
   factualProbesUnscorable=sum(v is None for v in facts),strictProbesCorrect=sum(s['memoryProbePassed'] for s in probes),
   observedProbes=len(probes),plannedProbes=repetitions*3))
  for turn in range(1,7):
   part=[s for s in samples if s['turn']==turn]
   turns.append(dict(model=model,runtime=runtime,turn=turn,nominalSamples=len(part),firstTextSeconds=median([s['firstCallbackMs']/1000 for s in part]),
    streamingTokensPerSecond=median([s['streamTokensPerSecond'] for s in part if s['generatedTokens']>=8 and s.get('streamTokensPerSecond') is not None])))
 return rows,turns

def verify():
 runs=json.loads((ROOT/'data/observations.json').read_text());workload=json.loads((ROOT/'data/workload.json').read_text())
 cohorts=json.loads((ROOT/'data/cohorts.json').read_text())
 for cohort,meta in cohorts.items():
  selected=[r for r in runs if r['cohort']==cohort]
  summary,turns=summarize(selected,meta['repetitions'],workload)
  for suffix,computed in [('summary',summary),('turns',turns)]:
   with (ROOT/f'data/{cohort}-{suffix}.csv').open() as stream:expected=list(csv.DictReader(stream))
   key=lambda r:(r['model'],r['runtime'],str(r.get('turn','')))
   computed=sorted(computed,key=key);expected=sorted(expected,key=key)
   assert len(computed)==len(expected)
   for actual,published in zip(computed,expected):
    for name,value in actual.items():
     if isinstance(value,(int,float)):assert math.isclose(value,float(published[name]),rel_tol=1e-12,abs_tol=1e-12),(cohort,name,value,published[name])
     else:assert ('' if value is None else value)==published[name]
  print(f'{cohort}: {len(selected)} conversations, {sum(len(r["samples"]) for r in selected)} turns; summary and turn tables reproduce.')
 return runs
if __name__=='__main__':verify()
