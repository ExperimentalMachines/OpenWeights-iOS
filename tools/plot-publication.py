#!/usr/bin/env python3
"""Export standalone scientific figures from the published CSV."""
import csv,pathlib
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=pathlib.Path(__file__).resolve().parents[1]
with (ROOT/'site/data/iphone16-five-models-summary.csv').open() as f:rows=list(csv.DictReader(f))
models=list(dict.fromkeys(r['model'] for r in rows));labels=['Gemma 3 1B IT','LFM2.5 1.2B Instruct','Qwen3 1.7B','Llama 3.2 3B Instruct','SmolLM3 3B']
plt.rcParams.update({'font.family':'DejaVu Sans','font.size':11,'svg.fonttype':'none'})
for metric,name,title,unit in [('streamingTokensPerSecond','streaming','Streaming speed','tokens/s; higher is faster'),('firstTextSeconds','first-text','First-text delay','seconds; lower is faster')]:
 fig,ax=plt.subplots(figsize=(10,5.5));y=list(range(5));barheight=.32
 for backend,offset,color in [('CPU',-.18,'#526775'),('Metal',.18,'#027474')]:
  values=[float(next(r for r in rows if r['model']==model and r['runtime'].endswith(backend))[metric]) for model in models]
  ax.barh([v+offset for v in y],values,height=barheight,label=backend,color=color)
  for pos,value in zip(y,values):ax.text(value+max(float(r[metric]) for r in rows)*.015,pos+offset,f'{value:.3f}' if name=='first-text' else f'{value:.1f}',va='center',fontsize=10)
 ax.set_yticks(y,labels);ax.invert_yaxis();ax.set_xlim(0,max(float(r[metric]) for r in rows)*1.16);ax.set_xlabel(unit);ax.set_title(title+' on iPhone 16',loc='left',fontweight='bold',pad=18)
 ax.legend(loc='lower right',frameon=False);ax.spines[['top','right','left']].set_visible(False);ax.grid(axis='x',alpha=.15);ax.set_axisbelow(True)
 fig.text(.02,.025,'S1 six-turn conversation × 3 repeats/backend · nominal samples only · differing thermal exclusions\nMeasured 2026-10-07 · llama.cpp CPU vs Metal · Qwen3 1.7B Q8_0, other models Q4_K_M',fontsize=9,color='#4d6064')
 fig.tight_layout(rect=(0,.1,1,1));fig.savefig(ROOT/f'site/assets/{name}.svg',metadata={'Date':None});fig.savefig(ROOT/f'site/assets/{name}.png',dpi=180);plt.close(fig)
print('Exported SVG and PNG figures from exact published CSV values.')
