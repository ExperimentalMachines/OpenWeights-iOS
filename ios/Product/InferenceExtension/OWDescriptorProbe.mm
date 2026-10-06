#import "OWDescriptorProbe.h"
#include <executorch/extension/data_loader/buffer_data_loader.h>
#include <executorch/extension/llm/runner/text_llm_runner.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <TargetConditionals.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>

namespace ext = executorch::extension;
namespace llm = executorch::extension::llm;
using executorch::runtime::Error;

uint64_t OWDescriptorAvailableMemory(void) {
#if TARGET_OS_IOS
  return os_proc_available_memory();
#else
  return 0;
#endif
}

NSDictionary<NSString *, id> *OWRunMLXCanonicalPathProbe(NSString *modelPath, NSString *tokenizerPath) {
  namespace llm = executorch::extension::llm;
  using executorch::runtime::Error;
  try {
    auto tokenizer = llm::load_tokenizer(tokenizerPath.UTF8String);
    if (!tokenizer || !tokenizer->is_loaded()) return @{ @"stage":@"tokenizer-load", @"error":@"Canonical tokenizer did not load." };
    auto runner = llm::create_text_llm_runner(modelPath.UTF8String, std::move(tokenizer), std::vector<std::string>{}, 0.0f);
    if (!runner) return @{ @"stage":@"create-runner", @"error":@"Canonical C++ runner did not initialize." };
    auto loaded = runner->load();
    if (loaded != Error::Ok) return @{ @"stage":@"load", @"error":[NSString stringWithFormat:@"Canonical load error: %u", unsigned(loaded)] };
    llm::GenerationConfig config;
    config.temperature = 0; config.seq_len = 2048; config.max_new_tokens = 32;
    config.num_bos = 0; config.num_eos = 0; config.echo = false;
    std::string text;
    const std::string prompt = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\nWhat is 2 + 2? Reply with only the number.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    auto result = runner->generate(prompt, config, [&](const std::string &piece) { text += piece; });
    NSString *output = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
    return @{ @"stage":result == Error::Ok ? @"generated" : @"generate", @"text":output,
      @"error":result == Error::Ok ? @"" : [NSString stringWithFormat:@"Canonical generation error: %u", unsigned(result)] };
  } catch (const std::exception &error) {
    return @{ @"stage":@"native-exception", @"error":[NSString stringWithUTF8String:error.what()] ?: @"Unknown native exception." };
  }
}

namespace {
struct Mapping {
  void *data = MAP_FAILED;
  size_t size = 646789248;
  ~Mapping() { if (data != MAP_FAILED) munmap(data, size); }
};
struct TokenizerFile {
  std::string path;
  int fd = -1;
  ~TokenizerFile() { if (fd >= 0) close(fd); if (!path.empty()) unlink(path.c_str()); }
};
NSDictionary *failure(NSString *stage, NSString *message) {
  return @{ @"stage":stage, @"error":message, @"text":@"" };
}
}

NSDictionary<NSString *, id> *OWRunMLXDescriptorProbe(int modelFD, int tokenizerFD) {
  return OWRunMLXDescriptorProbeWithProgress(modelFD, tokenizerFD, nil);
}

NSDictionary<NSString *, id> *OWRunMLXDescriptorProbeWithProgress(int modelFD, int tokenizerFD, OWDescriptorProgress progress) {
  auto report = [&](NSString *stage) {
    if (!progress) return;
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const auto result = task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count);
    progress(stage, result == KERN_SUCCESS ? info.phys_footprint : 0);
  };
  try {
    report(@"native-entered");
    // Map the transferred descriptor directly. A /dev/fd reopen is subject to
    // path sandbox rules and does not preserve the capability we received.
    Mapping mapping;
    mapping.data = mmap(nullptr, mapping.size, PROT_READ, MAP_PRIVATE, modelFD, 0);
    if (mapping.data == MAP_FAILED) return failure(@"model-mmap", [NSString stringWithFormat:@"mmap failed: %s", strerror(errno)]);
    report(@"model-mapped");

    // The release tokenizer only exposes a path loader. Stage its bounded bytes
    // inside the helper's own private temporary directory and remove on all exits.
    TokenizerFile tokenizerFile;
    std::string pattern = [NSTemporaryDirectory() UTF8String];
    pattern += "ow-tokenizer-XXXXXX.json";
    std::vector<char> path(pattern.begin(), pattern.end()); path.push_back('\0');
    tokenizerFile.fd = mkstemps(path.data(), 5);
    if (tokenizerFile.fd < 0) return failure(@"tokenizer-staging", @"Cannot create a private tokenizer file.");
    tokenizerFile.path = path.data();
    char block[65536];
    size_t offset = 0;
    while (offset < 11422654) {
      const size_t amount = std::min(sizeof(block), size_t(11422654) - offset);
      ssize_t readBytes;
      do { readBytes = pread(tokenizerFD, block, amount, offset); } while (readBytes < 0 && errno == EINTR);
      if (readBytes <= 0) return failure(@"tokenizer-staging", @"The transferred tokenizer ended early or could not be read.");
      size_t written = 0;
      while (written < size_t(readBytes)) {
        ssize_t count;
        do { count = write(tokenizerFile.fd, block + written, size_t(readBytes) - written); } while (count < 0 && errno == EINTR);
        if (count <= 0) return failure(@"tokenizer-staging", @"The private tokenizer could not be written.");
        written += count;
      }
      offset += readBytes;
    }
    report(@"tokenizer-staged");
    auto tokenizer = llm::load_tokenizer(tokenizerFile.path);
    if (!tokenizer || !tokenizer->is_loaded()) return failure(@"tokenizer-load", @"The pinned tokenizer did not load from its private helper file.");
    report(@"tokenizer-loaded");
    auto module = std::make_unique<ext::Module>(std::make_unique<ext::BufferDataLoader>(mapping.data, mapping.size));
    auto metadata = llm::get_llm_metadata(tokenizer.get(), module.get());
    if (!metadata.ok()) return failure(@"model-metadata", [NSString stringWithFormat:@"Model metadata error: %u", unsigned(metadata.error())]);
    auto values = metadata.get();
    report(@"model-metadata-loaded");
    auto eos = std::make_unique<std::unordered_set<uint64_t>>(llm::get_eos_ids(tokenizer.get(), module.get()));
    report(@"before-io-manager");
    auto io = std::make_unique<llm::IOManager>(*module);
    report(@"io-manager-created");
    auto stats = std::make_unique<llm::Stats>();
    auto decoder = std::make_unique<llm::TextDecoderRunner>(module.get(), io.get(), llm::kForwardMethod,
        std::make_unique<llm::Sampler>(int32_t(values.at(llm::kVocabSize)), 0.0f), stats.get());
    auto prefiller = std::make_unique<llm::TextPrefiller>(decoder.get(), values.at(llm::kUseKVCache),
        values.at(llm::kEnableDynamicShape), values.at(llm::kMaxSeqLen));
    auto generator = std::make_unique<llm::TextTokenGenerator>(tokenizer.get(), decoder.get(), values.at(llm::kUseKVCache), std::move(eos), stats.get());
    auto runner = std::make_unique<llm::TextLLMRunner>(std::move(values), std::move(tokenizer), std::move(module),
        std::move(decoder), std::move(prefiller), std::move(io), std::move(generator), std::move(stats));
    report(@"before-runner-load");
    auto loaded = runner->load();
    if (loaded != Error::Ok) return failure(@"load", [NSString stringWithFormat:@"Runner load error: %u", unsigned(loaded)]);
    report(@"runner-loaded");
    llm::GenerationConfig config;
    config.temperature = 0; config.seq_len = 2048; config.max_new_tokens = 32;
    config.num_bos = 0; config.num_eos = 0; config.echo = false;
    std::string text;
    const std::string prompt = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\nWhat is 2 + 2? Reply with only the number.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    report(@"before-generate");
    auto result = runner->generate(prompt, config, [&](const std::string &piece) { if (text.empty()) report(@"first-piece"); text += piece; });
    report(@"generation-returned");
    NSString *output = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
    return @{ @"stage":result == Error::Ok ? @"generated" : @"generate", @"text":output,
        @"error":result == Error::Ok ? @"" : [NSString stringWithFormat:@"Generation error: %u", unsigned(result)] };
  } catch (const std::exception &error) {
    return failure(@"native-exception", [NSString stringWithUTF8String:error.what()] ?: @"Unknown native exception.");
  }
}
