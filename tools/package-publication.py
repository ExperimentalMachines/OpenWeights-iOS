#!/usr/bin/env python3
"""Freeze the public static assets and standalone reproduction bundle."""
import hashlib,json,pathlib,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]/'site'
with zipfile.ZipFile(ROOT/'assets/reproduction.zip','w',zipfile.ZIP_DEFLATED) as bundle:
 files=[ROOT/'reproduce.py']+[p for p in sorted((ROOT/'data').iterdir()) if p.suffix in ['.csv','.json'] and p.name!='manifest.json']
 for p in files:bundle.write(p,str(p.relative_to(ROOT)))
with zipfile.ZipFile(ROOT/'assets/reproduction.zip') as bundle:assert bundle.testzip() is None
files={str(p.relative_to(ROOT)):dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(ROOT.rglob('*')) if p.is_file() and not p.name.startswith('.') and '__pycache__' not in p.parts and p!=ROOT/'data/manifest.json'}
(ROOT/'data/manifest.json').write_text(json.dumps(dict(schemaVersion=1,measuredDate='2026-10-07',publishedDate='2026-10-08',files=files),indent=2,sort_keys=True)+'\n')
print('Packaged reproducible public bundle and checksummed',len(files),'static files.')
