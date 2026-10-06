# Shared-session cache regression tests

These host tests exercise the actual `Session`, its chat template, tokenizer and
two greedy generations. They cover user/system quotations of an assistant reply,
identical replies with different token boundaries, regeneration, edited messages,
reasoning offsets, media text offsets, ambiguous templates, and cache-only versus
fresh-chat resets.
ASan and UBSan check the reply-offset lookup that previously accessed the wrong
record before checking its bounds. No multimodal model inference is performed.

Use the same Qwen3 0.6B Q4_K_M GGUF as the iPhone pilot. Its SHA256 is
`ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a`.
The model stays outside source control. From the repository root, replacing the
model path with its absolute location:

```sh
cmake -G Ninja -S core/engine/src/test/cpp -B build/session-cache-tests \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DOW_CACHE_SANITIZERS=ON -DOW_CACHE_TEST_MODEL=/absolute/path/to/Qwen3-0.6B-Q4_K_M.gguf
cmake --build build/session-cache-tests -j 6
ctest --test-dir build/session-cache-tests --output-on-failure
```

The tests use the repository's pinned llama.cpp submodule and a CPU backend.
CMake applies the hash-guarded graph-offset patch before building. It avoids
null-pointer arithmetic during graph-size planning and refuses unexpected
source rather than suppressing UBSan. Ninja also handles workspace paths
containing spaces.
They require a host compiler supporting `-fsanitize=address,undefined` when
sanitizers are enabled. Without a model path, the executable builds but CTest
is not registered.
