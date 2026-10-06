#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build Models/coreml Models/executorch-mlx
uv venv --python 3.12 --allow-existing .build/export-env
uv pip sync --python .build/export-env/bin/python Export/requirements.txt
hf download Qwen/Qwen3-0.6B --revision c1899de289a04d12100db370d81485cdf75e47ca \
  --include '*.json' --include '*.safetensors' --local-dir .build/source-model --max-workers 4
python=.build/export-env/bin/python
"$python" Export/prepare.py checkpoint
"$python" -m executorch.extension.llm.export.export_llm --config Export/mlx.yaml
"$python" Export/coreml_export.py --config Export/coreml.yaml
"$python" Export/prepare.py manifest
