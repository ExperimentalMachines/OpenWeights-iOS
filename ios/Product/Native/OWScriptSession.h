#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OWScriptSession : NSObject
// One session per request. Cancellation is terminal for this session.
- (NSDictionary<NSString *, id> *)runSource:(NSString *)source inputsJSON:(NSString *)inputsJSON;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
