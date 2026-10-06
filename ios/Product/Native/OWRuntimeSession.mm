#import "OWRuntimeSession.h"
#include "engine_session.h"
#include <memory>
#include "../../../core/engine/src/main/cpp/llama.cpp/src/llama-arch.h"
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#include <os/proc.h>
#endif

static void runtime_error(NSError **out, const std::string &message) {
    if (out) *out = [NSError errorWithDomain:@"OpenWeights" code:1 userInfo:@{NSLocalizedDescriptionKey: @(message.c_str())}];
}
static std::vector<openweights::ChatMessage> chat_messages(NSArray<NSDictionary *> *messages) {
    std::vector<openweights::ChatMessage> result;
    for (NSDictionary *item in messages) {
        openweights::ChatMessage message;
        message.role = [item[@"role"] UTF8String]; message.content = [item[@"content"] UTF8String];
        if (item[@"tool_call_id"]) message.tool_call_id = [item[@"tool_call_id"] UTF8String];
        for (NSString *path in item[@"media_paths"]) message.media_paths.push_back(path.UTF8String);
        result.push_back(std::move(message));
    }
    return result;
}
static bool tool_definitions(NSArray<NSDictionary *> *tools, std::vector<openweights::ToolDefinition> &result, NSError **error) {
    for (NSDictionary *item in tools) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:item[@"parameters"] options:NSJSONWritingSortedKeys error:error];
        if (!json) return false;
        result.push_back({[item[@"name"] UTF8String], [item[@"description"] UTF8String],
            std::string(static_cast<const char *>(json.bytes), json.length)});
    }
    return true;
}
@implementation OWRuntimeSession {
    std::unique_ptr<openweights::Session> _session;
}
+ (NSArray<NSString *> *)registeredArchitectureNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (const auto architecture : llm_arch_all()) {
        if (architecture == LLM_ARCH_UNKNOWN || architecture == LLM_ARCH_CLIP) continue;
        [names addObject:@(llm_arch_name(architecture))];
    }
    return names;
}
+ (NSDictionary<NSString *, id> *)computeDiagnostics {
    NSMutableArray *devices = [NSMutableArray array];
    for (const auto &device : openweights::compute_devices()) {
        NSString *kind;
        switch (device.type) {
            case GGML_BACKEND_DEVICE_TYPE_CPU: kind = @"Processor"; break;
            case GGML_BACKEND_DEVICE_TYPE_GPU: kind = @"Graphics"; break;
            case GGML_BACKEND_DEVICE_TYPE_IGPU: kind = @"Built in graphics"; break;
            case GGML_BACKEND_DEVICE_TYPE_ACCEL: kind = @"Accelerator"; break;
            default: kind = @"Other"; break;
        }
        [devices addObject:@{@"id": @(device.id.c_str()), @"description": @(device.description.c_str()),
                             @"kind": kind, @"totalMemoryBytes": @(device.total_memory)}];
    }
    return @{@"devices": devices, @"engineInfo": @(openweights::system_info().c_str())};
}
+ (NSNumber *)availableMemoryBytes {
#if TARGET_OS_IOS
    return @(os_proc_available_memory());
#else
    return @0;
#endif
}
- (instancetype)initWithPath:(NSString *)path projector:(NSString *)projector context:(int32_t)context
                      threads:(int32_t)threads gpuLayers:(int32_t)gpuLayers error:(NSError **)error {
    self = [super init];
    if (self) {
        std::string message;
        _session.reset(openweights::Session::load(path.UTF8String, projector.UTF8String, context, threads, threads,
            gpuLayers, true, gpuLayers != 0, false, false, 0, 512, 128, message));
        if (!_session) { runtime_error(error, message); return nil; }
    }
    return self;
}
- (NSDictionary *)generateMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools
                            options:(NSDictionary *)options onToken:(BOOL (^)(NSString *))onToken error:(NSError **)error {
    std::vector<openweights::ToolDefinition> definitions;
    if (!tool_definitions(tools, definitions, error)) return nil;
    openweights::SamplerConfig sampler;
    sampler.temperature = [options[@"temperature"] floatValue]; sampler.top_p = [options[@"topP"] floatValue];
    if (options[@"topK"]) sampler.top_k = [options[@"topK"] intValue];
    if (options[@"minP"]) sampler.min_p = [options[@"minP"] floatValue];
    sampler.repeat_penalty = [options[@"repeatPenalty"] floatValue]; sampler.max_tokens = [options[@"maxTokens"] intValue];
    openweights::ReasoningConfig reasoning; reasoning.enabled = [options[@"thinking"] boolValue];
    if (options[@"reasoningEffort"]) reasoning.effort = [options[@"reasoningEffort"] UTF8String];
    openweights::GenerationStats stats; openweights::ParsedReply reply; std::string message;
    const auto reason = _session->generate(chat_messages(messages), definitions, sampler, reasoning,
        [&](const char *piece, float) { return onToken(@(piece)); }, stats, reply, message);
    if (reason == openweights::StopReason::ERROR) { runtime_error(error, message); return nil; }
    NSMutableArray *calls = [NSMutableArray array];
    for (const auto &call : reply.tool_calls) [calls addObject:@{@"id": @(call.id.c_str()), @"name": @(call.name.c_str()), @"arguments": @(call.arguments_json.c_str())}];
    return @{@"content": @(reply.content.c_str()), @"reasoning": @(reply.reasoning.c_str()), @"toolCalls": calls,
        @"generatedTokens": @(stats.generated_tokens), @"cachedTokens": @(stats.cached_tokens), @"promptTokens": @(stats.prompt_tokens),
        @"contextUsed": @(stats.context_used), @"contextSize": @(stats.context_size), @"decodeMs": @(stats.decode_ms), @"prefillMs": @(stats.prefill_ms),
        @"firstTextMs": @(stats.time_to_first_token_ms), @"stopReason": @((int)reason)};
}
- (BOOL)warmMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools thinking:(BOOL)thinking error:(NSError **)error {
    return [self warmMessages:messages tools:tools thinking:thinking reasoningEffort:@"" error:error];
}
- (BOOL)warmMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools thinking:(BOOL)thinking reasoningEffort:(NSString *)effort error:(NSError **)error {
    std::vector<openweights::ToolDefinition> definitions;
    if (!tool_definitions(tools, definitions, error)) return NO;
    openweights::ReasoningConfig reasoning; reasoning.enabled = thinking;
    reasoning.effort = effort.UTF8String;
    openweights::WarmStats stats; std::string message;
    if (!_session->warm(chat_messages(messages), definitions, reasoning, false, nullptr, stats, message)) {
        runtime_error(error, message); return NO;
    }
    return YES;
}
- (NSDictionary *)capabilities {
    const auto media = _session->media_support();
    return @{@"backend": @(_session->offload_summary().c_str()), @"tools": @(_session->supports_tools()),
        @"toolResults": @(_session->supports_tool_results()), @"thinking": @(_session->supports_thinking()),
        @"reasoningEffort": @(_session->supports_reasoning_effort()),
        @"vision": @(media.vision), @"audio": @(media.audio), @"mediaMarker": @(_session->media_marker().c_str()),
        @"contextTokens": @(_session->context_size())};
}
- (NSNumber *)countMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools thinking:(BOOL)thinking error:(NSError **)error {
    return [self countMessages:messages tools:tools thinking:thinking reasoningEffort:@"" error:error];
}
- (NSNumber *)countMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools thinking:(BOOL)thinking reasoningEffort:(NSString *)effort error:(NSError **)error {
    std::vector<openweights::ToolDefinition> definitions;
    if (!tool_definitions(tools, definitions, error)) return nil;
    openweights::ReasoningConfig reasoning; reasoning.enabled = thinking;
    reasoning.effort = effort.UTF8String;
    int32_t count = 0; std::string message;
    if (!_session->count_prompt_tokens(chat_messages(messages), definitions, reasoning, count, message)) {
        runtime_error(error, message); return nil;
    }
    return @(count);
}
- (NSNumber *)countMediaMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools thinking:(BOOL)thinking reasoningEffort:(NSString *)effort error:(NSError **)error {
    std::vector<openweights::ToolDefinition> definitions;
    if (!tool_definitions(tools, definitions, error)) return nil;
    openweights::ReasoningConfig reasoning; reasoning.enabled = thinking;
    reasoning.effort = effort.UTF8String;
    int32_t count = 0; std::string message;
    if (!_session->count_prompt_cells(chat_messages(messages), definitions, reasoning, count, message)) {
        runtime_error(error, message); return nil;
    }
    return @(count);
}
- (void)cancel { _session->cancel(); }
- (void)reset { _session->reset_conversation(); }
@end
