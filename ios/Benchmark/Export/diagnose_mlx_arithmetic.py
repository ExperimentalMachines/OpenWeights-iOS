"""Local-only greedy reference controls for the retained MLX export failures."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=['fp32', 'fp16', 'int4'], required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = Path('ios/Benchmark/.build/source-model')
artifact = Path('ios/Benchmark/Models/executorch-mlx/model.pte')

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

pins = {str(path): digest(path) for path in [source/'model.safetensors', source/'config.json', source/'tokenizer.json', artifact]}
assert pins[str(source/'model.safetensors')] == 'f47f71177f32bcd101b7573ec9171e6a57f4f4d31148d38e382306f42996874b'
assert pins[str(source/'tokenizer.json')] == 'aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4'
assert pins[str(artifact)] == '9035e10cd708d03c5a3788aa2893f7ccabfa34302eae44c9be1bfe80c7dc5737'
torch.set_num_threads(6)
tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True)
model = AutoModelForCausalLM.from_pretrained(source, local_files_only=True,
    dtype=torch.float32 if args.mode == 'fp32' else torch.float16, attn_implementation='eager').eval()
if args.mode == 'int4':
    from executorch.extension.llm.export.quantize import quantize_model_
    quantize_model_(model, qlinear_config='4w', qlinear_group_size=32)

cases = [
    ('retained-strict-arithmetic', 'You are a helpful assistant.', 'What is 2 + 2? Reply with only the number.', '4'),
    ('pilot-system-arithmetic', "You are a helpful assistant. Follow the user's instructions precisely.", 'What is 2 + 2? Reply with only the number.', '4'),
    ('independent-arithmetic', 'You are a helpful assistant.', 'What is 3 + 5? Reply with only the number.', '8'),
    ('Cedar-control', 'You are a helpful assistant.', 'My project is Cedar. Reply with only the project name.', 'Cedar'),
]
record = {'mode': args.mode, 'device': 'Mac CPU eager reference', 'sourceSHA256': pins,
    'versions': {name: importlib.metadata.version(name) for name in ['torch', 'transformers', 'torchao', 'executorch', 'tokenizers']},
    'sourceScriptSHA256': digest(Path(__file__)), 'maximumNewTokens': 32, 'temperature': 0, 'observations': [],
    'limitations': ['HF eager attention implementation and CPU execution, not the converted/exported model or iPhone runtime.',
        'The int4 control uses the same declared TorchAO 4w group-32 transform on the HF model. It is not proof of identical transformed tensors or backend kernels in the PTE.',
        'Fixed diagnostic prompts are not general quality, performance, energy or A2 replication evidence. Historical strict tests remain unchanged.']}
for name, system, user, expected in cases:
    prompt = f'<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
    ids = tokenizer.encode(prompt, add_special_tokens=False)
    generated, steps, cache = [], [], None
    inputs = torch.tensor([ids])
    with torch.inference_mode():
        for _ in range(32):
            result = model(inputs, past_key_values=cache, use_cache=True)
            cache = result.past_key_values
            logits = result.logits[0, -1].float()
            values, indices = torch.topk(logits, 5)
            token = int(indices[0])
            steps.append({'top5': [{'id': int(i), 'text': tokenizer.decode([int(i)]), 'logit': float(v)} for i, v in zip(indices, values)],
                'allLogitsFinite': bool(torch.isfinite(logits).all())})
            generated.append(token)
            if token in [151643, 151645]:
                break
            inputs = torch.tensor([[token]])
    answer = tokenizer.decode(generated, skip_special_tokens=True)
    observation = {'case': name, 'prompt': prompt, 'promptSHA256': hashlib.sha256(prompt.encode()).hexdigest(),
        'promptTokenIDs': ids, 'sampledTokenIDs': generated, 'answer': answer, 'expectedAnswer': expected,
        'strictPassed': answer == expected, 'steps': steps}
    record['observations'].append(observation)
    args.output.write_text(json.dumps(record, indent=2, sort_keys=True)+'\n')
    print(name, repr(answer), 'expected', repr(expected), 'strictPassed', answer == expected, flush=True)
assert pins == {path: digest(Path(path)) for path in pins}
record['inputsRevalidatedAfterRun'] = True
args.output.write_text(json.dumps(record, indent=2, sort_keys=True)+'\n')
# Preserve quality failures in the process status as well as the saved checkpoint.
raise SystemExit(0 if all(item['strictPassed'] for item in record['observations']) else 1)
