/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * EXECUTORCH-LICENSE file in this directory.
 */
#pragma once
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <pytorch/tokenizers/tokenizer.h>

// Public declaration from the pinned release's llm_runner_helper.h. Keeping
// only this declaration avoids requiring inference-module headers that the
// Apple binary package does not ship. See tokenizer-provenance.json.
namespace executorch::extension::llm {
std::unique_ptr<tokenizers::Tokenizer> load_tokenizer(
    const std::string & tokenizer_path,
    std::unique_ptr<std::vector<std::string>> special_tokens = nullptr,
    std::optional<std::string> pattern = std::nullopt,
    size_t bos_token_index = 0,
    size_t eos_token_index = 1);
}
