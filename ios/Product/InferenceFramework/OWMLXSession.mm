#import "OWMLXSession.h"
#include <executorch/extension/llm/runner/text_llm_runner.h>
#include <atomic>
#include <mutex>
#include <unordered_set>
#include <stdexcept>
#include <cmath>
#include <limits>

using IDs = std::vector<uint64_t>;
namespace llm = executorch::extension::llm;
static const std::string token_input = "OpenWeights MLX exact token input";
static void runner_error(NSError **out, NSString *message) {
    if (out) *out = [NSError errorWithDomain:@"OpenWeights.ExecuTorchMLX" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static std::string prompt_bytes(NSString *text) {
    unichar zero = 0;
    if ([text rangeOfString:[NSString stringWithCharacters:&zero length:1]].location != NSNotFound || !text.UTF8String)
        throw std::runtime_error("The native runner cannot preserve a null character or invalid UTF-8. Edit the message before sending.");
    return text.UTF8String;
}

// The public tokenizer interface is the runner's dependency-injection point.
// Exact token batches bypass string re-tokenization at chunk boundaries. Decode
// records the actual sampled IDs, including the final token that is not in KV.
class MLXRecordingTokenizer final : public tokenizers::Tokenizer {
public:
    explicit MLXRecordingTokenizer(std::unique_ptr<tokenizers::Tokenizer> base) : base_(std::move(base)) {
        initialized_ = base_->is_loaded(); vocab_size_ = base_->vocab_size(); bos_tok_ = base_->bos_tok(); eos_tok_ = base_->eos_tok();
    }
    tokenizers::Error load(const std::string &path) override { return base_->load(path); }
    tokenizers::Result<std::string> id_to_piece(uint64_t id) const override { return base_->id_to_piece(id); }
    tokenizers::Result<uint64_t> piece_to_id(const std::string &piece) const override { return base_->piece_to_id(piece); }
    tokenizers::Result<IDs> encode(const std::string &text, int8_t bos = 0, int8_t eos = 0) const override {
        if (input_) {
            if (text != token_input || bos != 0 || eos != 0) return tokenizers::Error::EncodeFailure;
            IDs result = std::move(*input_); input_.reset(); return result;
        }
        return base_->encode(text, bos, eos);
    }
    tokenizers::Result<std::string> decode(uint64_t previous, uint64_t id, bool skip = false) const override {
        auto result = base_->decode(previous, id, skip);
        if (result.ok() && capturing_) generated_.push_back(id);
        return result;
    }
    IDs tokenize(const std::string &text) const {
        auto result = base_->encode(text, 0, 0);
        if (!result.ok()) throw std::runtime_error("The native tokenizer could not encode this prompt.");
        return std::move(result.get());
    }
    void input(IDs ids) { if (ids.empty() || input_) throw std::runtime_error("Invalid native token batch."); input_ = std::move(ids); }
    void clearInput() { input_.reset(); }
    void capture(bool value) { generated_.clear(); capturing_ = value; }
    void endCapture() { capturing_ = false; }
    const IDs &generated() const { return generated_; }
private:
    std::unique_ptr<tokenizers::Tokenizer> base_;
    mutable std::optional<IDs> input_;
    mutable IDs generated_;
    bool capturing_ = false;
};

@implementation OWMLXSession {
    std::string _modelPath;
    std::unique_ptr<MLXRecordingTokenizer> _unloadedTokenizer;
    MLXRecordingTokenizer *_tokenizer;
    std::unique_ptr<llm::TextLLMRunner> _runner;
    std::mutex _pointerMutex;
    std::atomic<bool> _stopped;
    IDs _committed;
    bool _predictionReady;
    std::unordered_set<uint64_t> _endOfTurns;
    std::optional<uint64_t> _endOfText;
}
- (instancetype)initWithModelPath:(NSString *)modelPath tokenizerPath:(NSString *)tokenizerPath error:(NSError **)error {
    return [self initWithModelPath:modelPath tokenizerPath:tokenizerPath endOfTurnTokens:@[@"<|im_end|>"] endOfTextToken:@"<|endoftext|>" error:error];
}
- (instancetype)initWithModelPath:(NSString *)modelPath tokenizerPath:(NSString *)tokenizerPath endOfTurnTokens:(NSArray<NSString *> *)turnTokens endOfTextToken:(NSString *)textToken error:(NSError **)error {
    self = [super init];
    if (self) {
        try {
            _modelPath = prompt_bytes(modelPath);
            auto tokenizer = llm::load_tokenizer(prompt_bytes(tokenizerPath));
            if (!tokenizer) throw std::runtime_error("The native tokenizer could not load this artifact.");
            _unloadedTokenizer = std::make_unique<MLXRecordingTokenizer>(std::move(tokenizer)); _tokenizer = _unloadedTokenizer.get();
            if (turnTokens.count == 0 || turnTokens.count > 8) throw std::runtime_error("A compiled family requires its declared end-of-turn tokens.");
            for (NSString *piece in turnTokens) {
                auto token = _tokenizer->piece_to_id(prompt_bytes(piece));
                const IDs encoded = _tokenizer->tokenize(prompt_bytes(piece));
                if (!token.ok() || encoded.size() != 1 || encoded.front() != token.get())
                    throw std::runtime_error("This tokenizer is missing a declared family end-of-turn token.");
                _endOfTurns.insert(token.get());
            }
            auto other = _tokenizer->piece_to_id(prompt_bytes(textToken)); if (other.ok()) _endOfText = other.get();
            _stopped = false; _predictionReady = false;
        } catch (const std::exception &failure) { runner_error(error, @(failure.what())); return nil; }
        catch (...) { runner_error(error, @"The native runner could not initialize this artifact."); return nil; }
    }
    return self;
}
- (BOOL)loadWithError:(NSError **)error {
    try {
        if (_runner) return YES;
        if (!_unloadedTokenizer) throw std::runtime_error("Reopen this model after its failed load.");
        auto runner = llm::create_text_llm_runner(_modelPath, std::move(_unloadedTokenizer), std::nullopt);
        if (!runner) { _tokenizer = nullptr; throw std::runtime_error("The native runner could not open this model."); }
        auto result = runner->load();
        if (result != executorch::runtime::Error::Ok) { _tokenizer = nullptr; throw std::runtime_error("The native runner could not load this model."); }
        std::lock_guard<std::mutex> lock(_pointerMutex); _runner = std::move(runner);
        return YES;
    } catch (const std::exception &failure) { if (!_runner) _tokenizer = nullptr; runner_error(error, @(failure.what())); return NO; }
    catch (...) { _tokenizer = nullptr; runner_error(error, @"The native runner could not load this model."); return NO; }
}
- (NSNumber *)countPrompt:(NSString *)prompt error:(NSError **)error {
    try {
        if (!_tokenizer) throw std::runtime_error("Load the tokenizer first.");
        return @(_tokenizer->tokenize(prompt_bytes(prompt)).size());
    } catch (const std::exception &failure) { runner_error(error, @(failure.what())); return nil; }
    catch (...) { runner_error(error, @"The native tokenizer could not encode this prompt."); return nil; }
}
- (NSArray<NSNumber *> *)tokenIDsForPrompt:(NSString *)prompt error:(NSError **)error {
    try {
        if (!_tokenizer) throw std::runtime_error("Load the tokenizer first.");
        const IDs tokens = _tokenizer->tokenize(prompt_bytes(prompt));
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:tokens.size()];
        for (auto token : tokens) [values addObject:@(token)];
        return values;
    } catch (const std::exception &failure) { runner_error(error, @(failure.what())); return nil; }
    catch (...) { runner_error(error, @"The native tokenizer could not encode this prompt."); return nil; }
}
- (void)beginOperation { _stopped.store(false); }
- (void)stop {
    _stopped.store(true);
    std::lock_guard<std::mutex> lock(_pointerMutex); if (_runner) _runner->stop();
}
- (void)reset {
    if (_runner) _runner->reset();
    if (_tokenizer) { _tokenizer->clearInput(); _tokenizer->endCapture(); }
    _committed.clear(); _predictionReady = false;
}
- (BOOL)prefillIDs:(const IDs &)ids error:(NSError **)error {
    if (_stopped.load()) { runner_error(error, @"Cancelled while preparing this conversation."); return NO; }
    _tokenizer->input(ids);
    auto result = _runner->prefill(token_input, 0, 0); _tokenizer->clearInput();
    if (!result.ok()) { runner_error(error, @"The native runner could not prefill this conversation."); return NO; }
    _committed.insert(_committed.end(), ids.begin(), ids.end()); _predictionReady = true;
    if (_stopped.load()) { runner_error(error, @"Cancelled while preparing this conversation."); return NO; }
    return YES;
}
- (NSNumber *)warmPrompt:(NSString *)prompt futurePrompt:(NSString *)futurePrompt contextLimit:(NSInteger)limit error:(NSError **)error {
    try {
        if (!_runner || !_tokenizer) throw std::runtime_error("Load a model first.");
        IDs tokens = _tokenizer->tokenize(prompt_bytes(prompt)), future = _tokenizer->tokenize(prompt_bytes(futurePrompt));
        if (limit != 2048) throw std::runtime_error("This MLX export requires a 2,048-token context.");
        size_t common = 0; while (common < std::min(tokens.size(), future.size()) && tokens[common] == future[common]) ++common;
        tokens.resize(common);
        if (tokens.size() >= static_cast<size_t>(limit)) throw std::runtime_error("The warm prefix exceeds this compiled context.");
        if (_committed.size() > tokens.size() || !std::equal(_committed.begin(), _committed.end(), tokens.begin())) [self reset];
        while (_committed.size() < tokens.size()) {
            const size_t start = _committed.size(), end = std::min(tokens.size(), start + 128);
            if (![self prefillIDs:IDs(tokens.begin() + start, tokens.begin() + end) error:error]) { [self reset]; return nil; }
        }
        if (_stopped.load()) { [self reset]; runner_error(error, @"Cancelled while preparing this conversation."); return nil; }
        return @(_committed.size());
    } catch (const std::exception &failure) { [self reset]; runner_error(error, @(failure.what())); return nil; }
    catch (...) { [self reset]; runner_error(error, @"The native runner could not prepare this conversation."); return nil; }
}
- (NSDictionary<NSString *, id> *)generatePrompt:(NSString *)prompt outputLimit:(NSInteger)outputLimit temperature:(double)temperature contextLimit:(NSInteger)limit callback:(void (^)(NSString *))callback error:(NSError **)error {
    try {
        if (!_runner || !_tokenizer) throw std::runtime_error("Load a model first.");
        IDs promptIDs = _tokenizer->tokenize(prompt_bytes(prompt));
        if (limit != 2048) throw std::runtime_error("This MLX export requires a 2,048-token context.");
        if (!std::isfinite(temperature) || temperature < 0 || temperature > std::numeric_limits<float>::max())
            throw std::runtime_error("Temperature must be finite and nonnegative.");
        if (outputLimit <= 0 || outputLimit >= 2048 || promptIDs.empty() || promptIDs.size() + static_cast<size_t>(outputLimit) > static_cast<size_t>(limit))
            throw std::runtime_error("The native prompt and output budget exceed this compiled context. Fold earlier turns or reduce the output budget.");
        if (_committed.size() > promptIDs.size() || !std::equal(_committed.begin(), _committed.end(), promptIDs.begin()) || (_committed.size() == promptIDs.size() && !_predictionReady)) [self reset];
        const size_t reused = _committed.size();
        while (promptIDs.size() - _committed.size() > 128) {
            const size_t start = _committed.size();
            if (![self prefillIDs:IDs(promptIDs.begin() + start, promptIDs.begin() + start + 128) error:error]) { [self reset]; return nil; }
        }
        if (_stopped.load()) { [self reset]; runner_error(error, @"Cancelled before generating."); return nil; }
        const IDs tail(promptIDs.begin() + _committed.size(), promptIDs.end());
        if (!tail.empty()) _tokenizer->input(tail);
        llm::GenerationConfig config; config.echo = false; config.num_bos = 0; config.num_eos = 0;
        config.seq_len = static_cast<int32_t>(limit); config.max_new_tokens = static_cast<int32_t>(outputLimit); config.temperature = temperature;
        _tokenizer->capture(true);
        std::string output, pending; int64_t nativeGenerated = -1; bool endSeen = false; bool invalidAfterEnd = false;
        auto result = _runner->generate(tail.empty() ? "" : token_input, config, [&](const std::string &piece) {
            const auto id = _tokenizer->generated().back();
            const bool specialEnd = _endOfTurns.count(id) != 0 || (_endOfText && id == *_endOfText);
            if (specialEnd) endSeen = true;
            else if (endSeen) invalidAfterEnd = true;
            else if (!_stopped.load()) {
                output += piece; pending += piece;
                NSString *text = [[NSString alloc] initWithBytes:pending.data() length:pending.size() encoding:NSUTF8StringEncoding];
                if (text) { if (text.length) callback(text); pending.clear(); }
            }
            // The upstream decode loop resets its stop flag after prefill. Reissue
            // Stop from callbacks so a request made before that reset survives.
            if (_stopped.load() || endSeen) _runner->stop();
        }, [&](const llm::Stats &stats) { nativeGenerated = stats.num_generated_tokens; });
        _tokenizer->clearInput(); _tokenizer->endCapture(); _predictionReady = false;
        const IDs generated = _tokenizer->generated();
        if (result != executorch::runtime::Error::Ok || nativeGenerated < 0 || generated.size() != static_cast<size_t>(nativeGenerated + 1)) {
            [self reset]; throw std::runtime_error("The native runner did not return a consistent token checkpoint.");
        }
        if (!pending.empty()) { [self reset]; throw std::runtime_error("The model ended with incomplete UTF-8 output. Retry this message."); }
        const bool stopped = _stopped.load();
        const bool ended = !generated.empty() && _endOfTurns.count(generated.back()) != 0 && !invalidAfterEnd;
        size_t textTokens = 0; for (auto id : generated) if (_endOfTurns.count(id) == 0 && (!_endOfText || id != *_endOfText)) ++textTokens;
        if (stopped || invalidAfterEnd) [self reset];
        else {
            _committed = promptIDs;
            // The final sampled token has not been fed back through the model.
            _committed.insert(_committed.end(), generated.begin(), generated.end() - 1);
        }
        NSString *content = [[NSString alloc] initWithBytes:output.data() length:output.size() encoding:NSUTF8StringEncoding];
        NSMutableArray *sampledIDs = [NSMutableArray arrayWithCapacity:generated.size()];
        for (auto id : generated) [sampledIDs addObject:@(id)];
        NSInteger reason = stopped ? 3 : ended ? 0 : generated.size() >= static_cast<size_t>(outputLimit) ? 1 : 5;
        return @{@"content": content ?: @"", @"sampledTokenIDs": sampledIDs, @"promptTokens": @(promptIDs.size()), @"generatedTokens": @(textTokens),
                 @"cachedTokens": @(reused), @"contextUsed": @(promptIDs.size() + textTokens), @"cancelled": @(stopped), @"stopReason": @(reason)};
    } catch (const std::exception &failure) { [self reset]; runner_error(error, @(failure.what())); return nil; }
    catch (...) { [self reset]; runner_error(error, @"The native runner could not complete this reply."); return nil; }
}
@end
