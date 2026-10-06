#import "OWSession.h"
#include "engine_session.h"
#include <mach/mach.h>
#include <os/proc.h>
#include <memory>

uint64_t OWFootprintBytes(void) {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}
uint64_t OWAvailableMemoryBytes(void) { return os_proc_available_memory(); }

static void set_error(NSError **out, const std::string &message) {
    if (out) *out = [NSError errorWithDomain:@"OpenWeightsBenchmark" code:1
                                   userInfo:@{NSLocalizedDescriptionKey: @(message.c_str())}];
}

@implementation OWSession {
    std::unique_ptr<openweights::Session> _session;
}
- (instancetype)initWithPath:(NSString *)path gpuLayers:(int32_t)gpuLayers error:(NSError **)error {
    self = [super init];
    if (self) {
        std::string message;
        _session.reset(openweights::Session::load(path.UTF8String, "", 2048, 4, 4,
            gpuLayers, true, gpuLayers != 0, false, false, 0, 512, 128, message));
        if (!_session) { set_error(error, message); return nil; }
    }
    return self;
}
- (NSDictionary *)generateMessages:(NSArray<NSDictionary *> *)messages
                             tools:(NSArray<NSDictionary *> *)tools
                         maxTokens:(int32_t)maxTokens onToken:(BOOL (^)(NSString *))onToken
                             error:(NSError **)error {
    std::vector<openweights::ChatMessage> chat;
    for (NSDictionary *m in messages) {
        openweights::ChatMessage entry;
        entry.role = [m[@"role"] UTF8String];
        entry.content = [m[@"content"] UTF8String];
        chat.push_back(std::move(entry));
    }
    std::vector<openweights::ToolDefinition> definitions;
    for (NSDictionary *t in tools) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:t[@"parameters"] options:NSJSONWritingSortedKeys error:error];
        if (!json) return nil;
        definitions.push_back({[t[@"name"] UTF8String], [t[@"description"] UTF8String],
            std::string(static_cast<const char *>(json.bytes), json.length)});
    }
    openweights::SamplerConfig sampler;
    sampler.temperature = 0;
    sampler.repeat_penalty = 1;
    sampler.max_tokens = maxTokens;
    openweights::ReasoningConfig reasoning;
    reasoning.enabled = false;
    openweights::GenerationStats stats;
    openweights::ParsedReply reply;
    std::string message;
    const auto reason = _session->generate(chat, definitions, sampler, reasoning,
        [&](const char *piece, float) { return onToken(@(piece)); }, stats, reply, message);
    if (reason == openweights::StopReason::ERROR) { set_error(error, message); return nil; }
    NSMutableArray *calls = [NSMutableArray array];
    for (const auto &call : reply.tool_calls) {
        [calls addObject:@{@"name": @(call.name.c_str()), @"arguments": @(call.arguments_json.c_str())}];
    }
    return @{@"content": @(reply.content.c_str()),
        @"toolCalls": calls, @"promptTokens": @(stats.prompt_tokens),
        @"generatedTokens": @(stats.generated_tokens), @"cachedTokens": @(stats.cached_tokens),
        @"prefillMs": @(stats.prefill_ms), @"decodeMs": @(stats.decode_ms),
        @"engineTTFTMs": @(stats.time_to_first_token_ms), @"stopReason": @((int)reason)};
}
- (void)cancel { if (_session) _session->cancel(); }
- (void)reset { _session->reset_conversation(); }
- (NSString *)backend { return @(_session->offload_summary().c_str()); }
@end
