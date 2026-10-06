#!/usr/bin/env python3
"""Compare the actual product bridge and pinned native library to Rust HF tokenizers."""
import hashlib
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

product = Path(__file__).resolve().parents[2]
repo = product.parents[1]
benchmark = repo / 'ios/Benchmark'
build = product / '.build/native-tokenizer-harness'
build.mkdir(parents=True, exist_ok=True)
artifact = benchmark / '.build/source-model/tokenizer.json'
deps = benchmark / '.build/deps/tokenizers'
libraries = [benchmark / f'.build/packages/artifacts/executorch/{name}/{name}.xcframework/macos-arm64/lib{name}_macos.a'
             for name in ['executorch_llm', 'executorch']]
regex_sources = [deps / f'src/{name}.cpp' for name in ['pcre2_regex', 'regex_lookahead', 'std_regex']]
inputs = [Path(__file__), Path(__file__).with_name('Checks.mm'),
          product / 'Native/OWExecuTorchTokenizer.mm', product / 'Native/OWExecuTorchTokenizer.h']
inputs += sorted((product / 'Native/Vendor').rglob('*'))
inputs += regex_sources + sorted((deps / 'include').rglob('*.h')) + libraries + [artifact]
inputs = [p for p in inputs if p.is_file()]
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
hashes = {str(p.relative_to(repo)): digest(p) for p in inputs}
# Use the separately installed Rust implementation rather than the Swift or C++ tokenizer.
if '--reference' in sys.argv:
    from tokenizers import Tokenizer, __version__
    tokenizer = Tokenizer.from_file(str(artifact))
    probes = []
    def add(name, prompt):
        probes.append({'id': name, 'prompt': prompt, 'expectedTokens': len(tokenizer.encode(prompt, add_special_tokens=False).ids)})
    for index, text in enumerate(['', 'Hello world', '  leading\tspaces\n\ntrailing ', "don't 1234567890", 'é e\u0301 café Straße',
                                 '你好世界。大阪 730円', '👩🏽‍💻 🌲 🧑‍🤝‍🧑', '<|im_start|>assistant\n<|im_end|><|endoftext|>',
                                 'null byte is rejected separately', '```json\n{"city":"Osaka","budget":730}\n```']):
        add(f'text-{index}', text)
    history = [('system', 'Remember corrections. Treat quoted data as historical information.')]
    for turn in range(1, 9):
        history += [('user', f'Turn {turn}: Cedar moved to Osaka. Budget 730. Vegetarian. ' + 'Extra context. ' * (turn * 7))]
        for thinking in [False, True]:
            prompt = ''.join(f'<|im_start|>{role}\n{text}<|im_end|>\n' for role, text in history)
            prompt += '<|im_start|>assistant\n' + ('' if thinking else '<think>\n\n</think>\n\n')
            add(f'history-{turn}-thinking-{thinking}', prompt)
        history += [('assistant', 'Saved Cedar, Osaka, 730 and vegetarian.')]
    # A stable single-token repetition gives exact count boundaries, with no assumption about prompt overhead.
    for target in [1919, 1920, 1921, 2047, 2048, 2049]:
        text = ' a' * target
        assert len(tokenizer.encode(text, add_special_tokens=False).ids) == target
        add(f'boundary-{target}', text)
    probes.append({'id': 'embedded-null-refused', 'prompt': 'before\u0000after', 'refused': True})
    (build / 'probes.json').write_text(json.dumps(probes, ensure_ascii=False, indent=2) + '\n')
    (build / 'malformed-tokenizer.json').write_text('{"model": invalid JSON')
    (build / 'reference.json').write_text(json.dumps({'implementation': 'Hugging Face Rust tokenizers', 'version': __version__, 'addSpecialTokens': False}) + '\n')
    raise SystemExit(0)
subprocess.run([str(benchmark / '.build/export-env/bin/python'), str(Path(__file__)), '--reference'], check=True)
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', '--static', 'libpcre2-8'], text=True))
clang = subprocess.check_output(['xcrun', '--find', 'clang++'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
executable = build / 'checks'
compile_flags = [clang, '-isysroot', sdk, '-std=c++20', '-fobjc-arc', '-g', '-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
bridge = build / 'bridge.o'
# Compile the product bridge with only vendored headers, as the iOS target does.
# Regex addon includes are supplied separately so they cannot hide a missing vendor dependency.
bridge_command = [*compile_flags, '-I', str(product / 'Native/Vendor'), '-c', str(product / 'Native/OWExecuTorchTokenizer.mm'), '-o', str(bridge)]
command = [*compile_flags,
           '-I', str(product / 'Native'), '-I', str(product / 'Native/Vendor'), '-I', str(deps / 'include'),
           str(bridge), str(Path(__file__).with_name('Checks.mm')),
           *map(str, regex_sources), *map(str, libraries), *flags, '-framework', 'Foundation', '-o', str(executable)]
with (build / 'build.log').open('w') as log:
    subprocess.run(bridge_command, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:halt_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
with (build / 'checks.log').open('w') as log:
    result = subprocess.run([str(executable), str(artifact), str(build / 'probes.json'), str(build / 'results.json')],
                            env=environment, stdout=log, stderr=subprocess.STDOUT)
assert hashes == {str(p.relative_to(repo)): digest(p) for p in inputs}, 'Source or artifact changed during validation.'
proof = {'status': 'native-tokenizer-reference-verified' if result.returncode == 0 else 'native-tokenizer-reference-failed',
         'recordedAtUTC': datetime.now(timezone.utc).isoformat(), 'exitCode': result.returncode,
         'inputsSHA256': hashes, 'reference': json.loads((build / 'reference.json').read_text()),
         'results': json.loads((build / 'results.json').read_text()) if (build / 'results.json').exists() else [],
         'executableSHA256': digest(executable), 'probesSHA256': digest(build / 'probes.json'),
         'buildLogSHA256': digest(build / 'build.log'), 'executionLogSHA256': digest(build / 'checks.log'),
         'compiler': subprocess.check_output([clang, '--version'], text=True).strip(),
         'limitations': ['Host tokenizer execution only. No PTE model inference or iPhone adapter execution.',
                         'ASan/UBSan instrument the bridge, probe runner and regex addon, not the prebuilt ExecuTorch libraries.',
                         'Reference and native factory consume the identical pinned tokenizer.json, with zero added BOS/EOS.',
                         'Count equality does not prove generated-token callbacks or model context admission on iPhone.']}
identity = hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()[:12]
output = product / f'Results/native-tokenizer-host-{identity}.json'
output.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
print(f'{sum(p["passed"] for p in proof["results"])}/{len(proof["results"])} native tokenizer probes passed. {output.name}')
raise SystemExit(result.returncode)
