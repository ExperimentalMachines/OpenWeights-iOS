#!/usr/bin/env python3
"""Retain exact uncommitted study sources alongside their executable receipt."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def snapshot(delegates=False, gguf_only=False):
    root = Path(__file__).resolve().parents[1]
    repo = root.parents[1]
    derived = 'DerivedData-gguf16' if gguf_only else 'DerivedData-delegates' if delegates else 'DerivedData'
    receipt_path = root / '.build' / derived / 'Build/Products/openweights-build.json'
    receipt = json.loads(receipt_path.read_text())
    canonical = json.dumps(receipt, sort_keys=True).encode()
    tag = hashlib.sha256(canonical).hexdigest()[:12]
    target = root / 'Results' / f"study-{'gguf16' if gguf_only else 'delegates' if delegates else 'baseline'}-sources-{tag}.zip"
    if not target.exists():
        with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('build-receipt.json', json.dumps(receipt, indent=2, sort_keys=True) + '\n')
            for relative, expected in receipt['sources'].items():
                path = repo / relative
                if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                    raise ValueError(f'Source changed since build: {relative}')
                archive.write(path, relative)
    return {'file': target.name, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    variant = parser.add_mutually_exclusive_group()
    variant.add_argument('--delegates', action='store_true')
    variant.add_argument('--gguf-only', action='store_true')
    args = parser.parse_args()
    print(json.dumps(snapshot(args.delegates, args.gguf_only)))
