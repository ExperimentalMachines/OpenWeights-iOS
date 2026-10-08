#!/usr/bin/env python3
"""Verify public results, checksums, local links and sensitive-data exclusions."""
import hashlib,json,pathlib,re,urllib.parse,zipfile
from html.parser import HTMLParser
import reproduce
ROOT=pathlib.Path(__file__).resolve().parent
runs=reproduce.verify()
assert len(runs)==38 and sum(len(r['samples']) for r in runs)==228
assert len({r['run'] for r in runs})==38
allowed={'cohort','run','model','runtime','repetition','sourceReportSHA256','observedBackend','loadPeakFootprintBytes','samples'}
assert all(set(r)==allowed for r in runs)
manifest=json.loads((ROOT/'data/manifest.json').read_text())
for name,entry in manifest['files'].items():
 p=ROOT/name;assert p.is_file() and not p.is_symlink()
 assert p.stat().st_size==entry['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==entry['sha256'],name
text=[]
for p in ROOT.rglob('*'):
 if p.suffix in ['.json','.csv','.html','.js','.md','.py','.css'] and p.is_file():text.append(p.read_text())
for name in ['assets/reproduction.zip','data/measured-sources.zip']:
 with zipfile.ZipFile(ROOT/name) as archive:
  assert archive.testzip() is None
  for info in archive.infolist():
   assert not pathlib.PurePosixPath(info.filename).is_absolute() and '..' not in pathlib.PurePosixPath(info.filename).parts
   if pathlib.PurePosixPath(info.filename).suffix in ['.json','.csv','.swift','.cpp','.h','.c','.mm','.py','.sh','.yml','.cmake']:
    text.append(archive.read(info).decode())
# Do not print matched content, which might itself contain a credential.
sensitive=[r'/Users/[A-Za-z0-9._-]+',r'00008140-[0-9A-Fa-f]{16}',r'hf://buckets/[A-Za-z0-9]',r'test-lab-[a-z0-9-]+/',r'console\.firebase\.google\.com/project/',r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',r'\bgh[pousr]_[A-Za-z0-9]{30,}\b',r'\bgithub_pat_[A-Za-z0-9_]{40,}\b',r'\bhf_[A-Za-z0-9]{30,}\b',r'\bAKIA[A-Z0-9]{16}\b']
joined='\n'.join(text)
assert not any(re.search(pattern,joined) for pattern in sensitive),'Sensitive-data exclusion check failed.'
class Links(HTMLParser):
 def __init__(self):super().__init__();self.links=[];self.ids=[]
 def handle_starttag(self,tag,attrs):
  attrs=dict(attrs)
  if 'id' in attrs:self.ids.append(attrs['id'])
  for name in ['href','src']:
   if name in attrs:self.links.append(attrs[name])
parsed=Links();parsed.feed((ROOT/'index.html').read_text())
assert len(parsed.ids)==len(set(parsed.ids))
for link in parsed.links:
 url=urllib.parse.urlsplit(link)
 if url.scheme or url.netloc:continue
 if url.path:assert (ROOT/urllib.parse.unquote(url.path)).is_file(),link
 if not url.path and url.fragment:assert url.fragment in parsed.ids,link
print('Public allowlist, all asset hashes, ZIP CRC and local links verified.')
