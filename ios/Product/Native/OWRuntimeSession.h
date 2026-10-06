#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OWRuntimeSession : NSObject
+ (NSArray<NSString *> *)registeredArchitectureNames;
+ (NSNumber *)availableMemoryBytes;
+ (NSDictionary<NSString *, id> *)computeDiagnostics;
- (nullable instancetype)initWithPath:(NSString *)path projector:(NSString *)projector
                              context:(int32_t)context threads:(int32_t)threads
                            gpuLayers:(int32_t)gpuLayers error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)generateMessages:(NSArray<NSDictionary *> *)messages
                                                     tools:(NSArray<NSDictionary *> *)tools
                                                   options:(NSDictionary *)options
                                                   onToken:(BOOL (^)(NSString *))onToken error:(NSError **)error;
- (BOOL)warmMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools
            thinking:(BOOL)thinking error:(NSError **)error;
- (BOOL)warmMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools
            thinking:(BOOL)thinking reasoningEffort:(NSString *)effort error:(NSError **)error;
- (NSDictionary<NSString *, id> *)capabilities;
- (nullable NSNumber *)countMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools
                            thinking:(BOOL)thinking error:(NSError **)error;
- (nullable NSNumber *)countMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools
                            thinking:(BOOL)thinking reasoningEffort:(NSString *)effort error:(NSError **)error;
- (nullable NSNumber *)countMediaMessages:(NSArray<NSDictionary *> *)messages tools:(NSArray<NSDictionary *> *)tools
                                 thinking:(BOOL)thinking reasoningEffort:(NSString *)effort error:(NSError **)error;
- (void)cancel;
- (void)reset;
@end
NS_ASSUME_NONNULL_END
