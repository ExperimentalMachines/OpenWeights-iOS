#import "OWSamplingProbe.h"
#include "llama.h"
#include <vector>

static std::vector<llama_token_data> probe_candidates(NSArray<NSNumber *> *logits) {
    std::vector<llama_token_data> result;
    for (NSUInteger index = 0; index < logits.count; ++index) {
        result.push_back({static_cast<llama_token>(index), logits[index].floatValue, 0.0f});
    }
    return result;
}

@implementation OWSamplingProbe
+ (NSDictionary<NSString *, id> *)sampleLogits:(NSArray<NSNumber *> *)logits
                                        topK:(int32_t)topK minP:(float)minP
                                        seed:(uint32_t)seed draws:(NSInteger)draws {
    auto filtered = probe_candidates(logits);
    llama_token_data_array candidates{filtered.data(), filtered.size(), -1, false};
    if (topK > 0) {
        auto *filter = llama_sampler_init_top_k(topK);
        llama_sampler_apply(filter, &candidates); llama_sampler_free(filter);
    }
    if (minP > 0) {
        auto *filter = llama_sampler_init_min_p(minP, 1);
        llama_sampler_apply(filter, &candidates); llama_sampler_free(filter);
    }
    NSMutableArray<NSNumber *> *retained = [NSMutableArray array];
    for (size_t index = 0; index < candidates.size; ++index) [retained addObject:@(candidates.data[index].id)];
    auto parameters = llama_sampler_chain_default_params(); parameters.no_perf = true;
    auto *chain = llama_sampler_chain_init(parameters);
    if (topK > 0) llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK));
    if (minP > 0) llama_sampler_chain_add(chain, llama_sampler_init_min_p(minP, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(1.0f));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(seed));
    NSMutableArray<NSNumber *> *selected = [NSMutableArray array];
    for (NSInteger draw = 0; draw < draws; ++draw) {
        auto values = probe_candidates(logits);
        llama_token_data_array current{values.data(), values.size(), -1, false};
        llama_sampler_apply(chain, &current);
        [selected addObject:@(current.data[current.selected].id)];
    }
    llama_sampler_free(chain);
    return @{@"retainedTokenIDs":retained, @"sampledTokenIDs":selected, @"seed":@(seed), @"draws":@(draws)};
}
@end
