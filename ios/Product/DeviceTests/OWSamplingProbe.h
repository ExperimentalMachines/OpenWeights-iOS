#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface OWSamplingProbe : NSObject
+ (NSDictionary<NSString *, id> *)sampleLogits:(NSArray<NSNumber *> *)logits
                                        topK:(int32_t)topK minP:(float)minP
                                        seed:(uint32_t)seed draws:(NSInteger)draws;
@end
NS_ASSUME_NONNULL_END
