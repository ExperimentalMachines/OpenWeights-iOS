#import "OWExecuTorchTokenizer.h"
#include "Vendor/ExecuTorchTokenizerFactory.h"

static void tokenizer_error(NSError **out, NSString *message) {
    if (out) *out = [NSError errorWithDomain:@"OpenWeights.Tokenizer" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
@implementation OWExecuTorchTokenizer {
    std::unique_ptr<tokenizers::Tokenizer> _tokenizer;
}
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (self) {
        // Imported tokenizer JSON is an input boundary. Native parser exceptions
        // must become a Swift error rather than unwind through Objective-C.
        try { _tokenizer = executorch::extension::llm::load_tokenizer(path.UTF8String ?: ""); }
        catch (...) { tokenizer_error(error, @"The native ExecuTorch tokenizer could not parse this artifact."); return nil; }
        if (!_tokenizer) { tokenizer_error(error, @"The native ExecuTorch tokenizer could not load this artifact."); return nil; }
    }
    return self;
}
- (NSNumber *)countPrompt:(NSString *)prompt error:(NSError **)error {
    // These are the same factory, artifact and zero BOS/EOS settings used by
    // TextRunner.generate. Calls are serialized with the product runner.
    unichar zero = 0;
    NSString *nullCharacter = [NSString stringWithCharacters:&zero length:1];
    const char *bytes = prompt.UTF8String;
    if (!bytes || [prompt rangeOfString:nullCharacter].location != NSNotFound) {
        tokenizer_error(error, @"The native runner cannot preserve a null character or invalid UTF-8. Edit the message before sending.");
        return nil;
    }
    try {
        auto encoded = _tokenizer->encode(bytes, 0, 0);
        if (!encoded.ok()) { tokenizer_error(error, @"The native ExecuTorch tokenizer could not encode this prompt."); return nil; }
        return @(encoded.get().size());
    } catch (...) { tokenizer_error(error, @"The native ExecuTorch tokenizer could not encode this prompt."); return nil; }
}
@end
