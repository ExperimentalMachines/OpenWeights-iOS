#!/usr/bin/env python3
"""Fetch exact native revisions without borrowing the Android working tree."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent
lock = json.loads((root / 'native-dependencies.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='Verify existing dependencies without fetching or patching.')
args = parser.parse_args()
for dependency in lock['dependencies']:
    target = root / dependency['path']
    if not (target / '.git').exists():
        if args.check:
            raise SystemExit('Dependency not prepared: ' + dependency['path'])
        if target.exists() and any(target.iterdir()):
            raise SystemExit('Refusing to replace a nonempty directory: ' + dependency['path'])
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'init', str(target)], check=True)
        subprocess.run(['git', '-C', str(target), 'remote', 'add', 'origin', dependency['url']], check=True)
        subprocess.run(['git', '-C', str(target), 'fetch', '--depth=1', 'origin', dependency['revision']], check=True)
        subprocess.run(['git', '-C', str(target), 'checkout', '--detach', dependency['revision']], check=True)
    actual = subprocess.check_output(['git', '-C', str(target), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != dependency['revision']:
        raise SystemExit('Unexpected native revision: ' + dependency['path'])
if not args.check:
    subprocess.run(['cmake', '-P', str(root / lock['llamaGraphOffsetPatch'])], check=True)
ggml = root / 'core/engine/src/main/cpp/llama.cpp/ggml/src/ggml.c'
if hashlib.sha256(ggml.read_bytes()).hexdigest() != lock['patchedGGMLSHA256']:
    raise SystemExit('Pinned GGML graph-offset patch is missing or changed.')
print('Pinned native revisions and GGML graph-offset patch verified.')
