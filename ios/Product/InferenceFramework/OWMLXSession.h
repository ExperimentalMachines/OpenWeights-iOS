#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OWMLXSession : NSObject
- (nullable instancetype)initWithModelPath:(NSString *)modelPath tokenizerPath:(NSString *)tokenizerPath error:(NSError **)error;
- (nullable instancetype)initWithModelPath:(NSString *)modelPath tokenizerPath:(NSString *)tokenizerPath endOfTurnTokens:(NSArray<NSString *> *)endOfTurnTokens endOfTextToken:(NSString *)endOfTextToken error:(NSError **)error;
- (BOOL)loadWithError:(NSError **)error;
- (nullable NSNumber *)countPrompt:(NSString *)prompt error:(NSError **)error;
- (nullable NSArray<NSNumber *> *)tokenIDsForPrompt:(NSString *)prompt error:(NSError **)error;
- (nullable NSNumber *)warmPrompt:(NSString *)prompt futurePrompt:(NSString *)futurePrompt contextLimit:(NSInteger)contextLimit error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)generatePrompt:(NSString *)prompt outputLimit:(NSInteger)outputLimit temperature:(double)temperature contextLimit:(NSInteger)contextLimit callback:(void (^)(NSString *piece))callback error:(NSError **)error;
- (void)beginOperation;
- (void)stop;
- (void)reset;
@end
NS_ASSUME_NONNULL_END
