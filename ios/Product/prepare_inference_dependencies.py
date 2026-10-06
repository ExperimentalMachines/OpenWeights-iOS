#!/usr/bin/env python3
"""Stage pinned device-only ET 1.5 dependencies outside the app's ET 1.4 package."""
import hashlib
import json
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent
lock = json.loads((root / 'InferenceExtension/dependencies.json').read_text())
cached = root.parent / 'Benchmark/.build/packages-delegates'
destination = root / '.build/inference-deps'
destination.mkdir(parents=True, exist_ok=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def valid(folder, files):
    return all((folder / name).is_file() and sha(folder / name) == value for name, value in files.items())


for name, entry in lock['libraries'].items():
    target = destination / name
    if valid(target, entry['files']):
        continue
    source = cached / 'artifacts/executorch' / name / (name + '.xcframework') / 'ios-arm64'
    if valid(source, entry['files']):
        shutil.copytree(source, target, dirs_exist_ok=True)
    else:
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / 'library.zip'
            urllib.request.urlretrieve('https://ossci-ios.s3.amazonaws.com/executorch/' + name + '-' + lock['version'] + '.zip', package)
            if sha(package) != entry['zipSHA256']:
                raise SystemExit('Pinned archive checksum failed: ' + name)
            with zipfile.ZipFile(package) as archive:
                archive.extractall(temporary)
            source = Path(temporary) / (name + '.xcframework') / 'ios-arm64'
            if not valid(source, entry['files']):
                raise SystemExit('Pinned device slice checksum failed: ' + name)
            shutil.copytree(source, target, dirs_exist_ok=True)
    if not valid(target, entry['files']):
        raise SystemExit('Staged dependency checksum failed: ' + name)

bundle = destination / 'executorch_backend_mlx_resources.bundle'
bundle.mkdir(exist_ok=True)
metal = bundle / 'mlx-ios.metallib'
if not metal.exists() or sha(metal) != lock['metalLibrarySHA256']:
    source = cached / 'checkouts/executorch/.Package.swift/backend_mlx_resources/mlx-ios.metallib'
    if source.exists() and sha(source) == lock['metalLibrarySHA256']:
        shutil.copy2(source, metal)
    else:
        urllib.request.urlretrieve('https://raw.githubusercontent.com/pytorch/executorch/' + lock['revision'] + '/.Package.swift/backend_mlx_resources/mlx-ios.metallib', metal)
if sha(metal) != lock['metalLibrarySHA256']:
    raise SystemExit('Pinned Metal library checksum failed.')
# Xcode exposes the app's ET 1.4 modules to extension compilers. The native
# helper imports exact 1.5 headers without introducing a duplicate Clang module.
headers = destination / 'core-headers'
headers.mkdir(exist_ok=True)
for relative in lock['libraries']['executorch']['files']:
    if relative.startswith('Headers/') and not relative.endswith('.modulemap'):
        target = headers / Path(relative).relative_to('Headers')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(destination / 'executorch' / relative, target)
provenance = json.loads((root / 'InferenceExtension/header-provenance.json').read_text())
for relative, expected in provenance['vendoredHeaderSHA256'].items():
    if sha(root / 'InferenceExtension/Vendor' / relative) != expected:
        raise SystemExit('Vendored release header checksum failed: ' + relative)
print('Pinned ExecuTorch 1.5 device slices and MLX Metal library verified.')
