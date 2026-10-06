#!/usr/bin/env python3
"""Run the actual product PTE bridge with the pinned XNNPACK artifact on macOS."""
import hashlib
import json
import os
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[2]
repo = root.parents[1]
benchmark = repo / 'ios/Benchmark'
build = root / '.build/native-runner-harness'
build.mkdir(parents=True, exist_ok=True)
artifact = next(a for a in json.loads((root / 'Resources/model-catalogue.json').read_text())['artifacts'] if a['id'] == 'executorch')
model = root / '.build/pte-host-model'
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''): h.update(block)
    return h.hexdigest()
for file in artifact['files']:
    path = model / file['file']
    assert path.stat().st_size == file['bytes'] and digest(path) == file['sha256'], file['file']
names = ['executorch_llm', 'executorch', 'backend_xnnpack', 'kernels_llm', 'kernels_optimized', 'kernels_quantized', 'kernels_torchao', 'threadpool']
libraries = [benchmark / f'.build/packages/artifacts/executorch/{name}/{name}.xcframework/macos-arm64/lib{name}_macos.a' for name in names]
deps = benchmark / '.build/deps/tokenizers'
regex = [deps / f'src/{name}.cpp' for name in ['pcre2_regex', 'regex_lookahead', 'std_regex']]
core = libraries[1].parent / 'Headers'
bridge_sources = [root / f'Native/{name}.mm' for name in ['OWExecuTorchRunner', 'OWExecuTorchTokenizer']]
inputs = bridge_sources + [root / f'Native/{name}.h' for name in ['OWExecuTorchRunner', 'OWExecuTorchTokenizer']]
inputs += [Path(__file__), Path(__file__).with_name('Checks.mm'), Path(__file__).with_name('Reference.py'), root / 'Resources/model-catalogue.json']
inputs += [p for p in (root / 'Native/Vendor').rglob('*') if p.is_file()] + libraries + regex
inputs += [p for p in core.rglob('*') if p.is_file()] + list((deps / 'include').rglob('*.h'))
inputs += [model / file['file'] for file in artifact['files']]
hashes = {str(p.relative_to(repo)): digest(p) for p in inputs}
(build / 'input-shas-before.json').write_text(json.dumps(hashes, indent=2, sort_keys=True) + '\n')
clang = subprocess.check_output(['xcrun', '--find', 'clang++'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
swift_support = Path(clang).parent.parent / 'lib/swift/macosx'
common = [clang, '-isysroot', sdk, '-fobjc-arc', '-g', '-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
objects = [build / f'{p.stem}.o' for p in bridge_sources]
executable = build / 'checks'
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', '--static', 'libpcre2-8'], text=True))
with (build / 'build.log').open('w') as log:
    for source, obj in zip(bridge_sources, objects):
        subprocess.run([*common, '-std=c++17', '-I', str(root / 'Native/Vendor'), '-I', str(core), '-c', str(source), '-o', str(obj)], stdout=log, stderr=subprocess.STDOUT, check=True)
    command = [*common, '-std=c++20', '-I', str(root / 'Native'), '-I', str(deps / 'include'), str(Path(__file__).with_name('Checks.mm')),
               *map(str, objects), *map(str, regex), str(libraries[0]), *[f'-Wl,-force_load,{p}' for p in libraries[1:]], *flags,
               '-L', str(swift_support), '-lswiftCompatibility56',
               '-framework', 'Foundation', '-framework', 'Accelerate', '-framework', 'CoreImage', '-o', str(executable)]
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:halt_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
report = build / 'checks.json'
with (build / 'execution.log').open('w') as log:
    result = subprocess.run([str(executable), str(model / 'xnnpack/Qwen3-0.6B-8da4w-2k.pte'), str(model / 'tokenizer.json'), str(report)],
                            stdout=log, stderr=subprocess.STDOUT, env=environment, timeout=600)
checks = json.loads(report.read_text()) if report.exists() else {}
reference_file = build / 'reference.json'
reference_result = subprocess.run([str(benchmark / '.build/export-env/bin/python'), str(Path(__file__).with_name('Reference.py')),
                                   str(model / 'tokenizer.json'), str(report), str(reference_file)], check=False)
reference = json.loads(reference_file.read_text()) if reference_file.exists() else {}
assert hashes == {str(p.relative_to(repo)): digest(p) for p in inputs}, 'Inputs changed during native validation.'
passed = result.returncode == 0 and reference_result.returncode == 0
proof = {'status': 'native-pte-runner-host-verified' if passed else 'native-pte-runner-host-failed',
         'recordedAtUTC': datetime.now(timezone.utc).isoformat(), 'exitCode': result.returncode,
         'artifact': artifact, 'inputsSHA256': hashes, **checks, 'independentDecodeReference': reference,
         'referenceExitCode': reference_result.returncode,
         'executableSHA256': digest(executable), 'buildLogSHA256': digest(build / 'build.log'), 'executionLogSHA256': digest(build / 'execution.log'),
         'compiler': subprocess.check_output([clang, '--version'], text=True).strip(),
         'limitations': ['Actual macOS CPU XNNPACK inference through the canonical product bridge, not iPhone execution or performance.',
                         'ASan/UBSan instrument the bridge, harness and regex addon. Pinned prebuilt ExecuTorch/backend/kernel libraries are not instrumented.',
                         'Synthetic prompts check cache/output equivalence. They do not establish general model quality, energy or other-family compatibility.',
                         'Timed warming Stop does not establish an iPhone cancellation-latency bound.']}
identity = hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()[:12]
output = root / f'Results/native-pte-runner-host-{identity}.json'
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(f'{len(proof.get("passedChecks", []))} native runner checks passed. {output.name}')
raise SystemExit(0 if passed else 1)
