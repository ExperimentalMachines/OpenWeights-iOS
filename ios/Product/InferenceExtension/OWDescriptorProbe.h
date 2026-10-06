#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
NSDictionary<NSString *, id> *OWRunMLXDescriptorProbe(int modelFD, int tokenizerFD);
typedef void (^OWDescriptorProgress)(NSString *stage, uint64_t footprintBytes);
NSDictionary<NSString *, id> *OWRunMLXDescriptorProbeWithProgress(int modelFD, int tokenizerFD, OWDescriptorProgress _Nullable progress);
uint64_t OWDescriptorAvailableMemory(void);
NSDictionary<NSString *, id> *OWRunMLXCanonicalPathProbe(NSString *modelPath, NSString *tokenizerPath);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
