#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT uint64_t OWFootprintBytes(void);
FOUNDATION_EXPORT uint64_t OWAvailableMemoryBytes(void);

@interface OWSession : NSObject
- (nullable instancetype)initWithPath:(NSString *)path
                           gpuLayers:(int32_t)gpuLayers
                               error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)generateMessages:(NSArray<NSDictionary *> *)messages
                                                     tools:(NSArray<NSDictionary *> *)tools
                                                 maxTokens:(int32_t)maxTokens
                                                   onToken:(BOOL (^)(NSString *))onToken
                                                     error:(NSError **)error;
- (void)cancel;
- (void)reset;
- (NSString *)backend;
@end
NS_ASSUME_NONNULL_END
