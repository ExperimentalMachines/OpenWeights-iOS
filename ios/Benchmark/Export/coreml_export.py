"""Adapt Qwen's cache boundaries and causal mask for the Core ML exporter."""
import torch
from executorch.examples.models.llama import export_llama_lib
from executorch.backends.apple.coreml.partition.coreml_partitioner import (
    _OperatorsSupportedForCoreMLBackend,
)
from executorch.extension.llm.export.export_llm import main


original_override = _OperatorsSupportedForCoreMLBackend.should_override_support
original_transforms = export_llama_lib._get_source_transforms


def rejects_symbolic_boundary(self, node):
    values = [node.meta.get("val")]
    values.extend(argument.meta.get("val") for argument in node.all_input_nodes)
    if any(isinstance(value, (torch.SymInt, torch.SymFloat, torch.SymBool)) for value in values):
        return True
    return original_override(self, node)


_OperatorsSupportedForCoreMLBackend.should_override_support = rejects_symbolic_boundary


def additive_causal_masks(model):
    # Apple's runtime rejects the int8 gather produced from a boolean mask.
    # The float mask keeps the same attention rule without that conversion.
    for module in model.modules():
        if "mask" in module._buffers and module.mask.dtype == torch.bool:
            module.mask = torch.where(module.mask, 0.0, float("-inf"))
    return model


def coreml_transforms(**kwargs):
    return original_transforms(**kwargs) + [additive_causal_masks]


export_llama_lib._get_source_transforms = coreml_transforms

if __name__ == "__main__":
    torch.manual_seed(0)
    q, k, v = [torch.randn(1, 2, 4, 8) for _ in range(3)]
    mask = torch.ones(4, 4, dtype=torch.bool).tril()
    additive = torch.where(mask, 0.0, float("-inf"))
    torch.testing.assert_close(
        torch.nn.functional.scaled_dot_product_attention(q, k, v, attn_mask=mask),
        torch.nn.functional.scaled_dot_product_attention(q, k, v, attn_mask=additive),
    )
    main()
