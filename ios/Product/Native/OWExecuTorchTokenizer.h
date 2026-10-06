#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OWExecuTorchTokenizer : NSObject
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;
- (nullable NSNumber *)countPrompt:(NSString *)prompt error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
