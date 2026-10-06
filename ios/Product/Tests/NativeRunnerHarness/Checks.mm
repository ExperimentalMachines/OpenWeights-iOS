#import <Foundation/Foundation.h>
#import "OWExecuTorchRunner.h"
#import "OWExecuTorchTokenizer.h"
#include <thread>
#include <chrono>

static NSString *prompt(NSArray<NSDictionary *> *messages) {
    NSMutableString *value = [NSMutableString string];
    for (NSDictionary *message in messages) [value appendFormat:@"<|im_start|>%@\n%@<|im_end|>\n", message[@"role"], message[@"content"]];
    [value appendString:@"<|im_start|>assistant\n<think>\n\n</think>\n\n"];
    return value;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        NSString *outputFile = @(argv[3]);
        NSMutableArray *checks = [NSMutableArray array];
        NSMutableArray *observations = [NSMutableArray array];
        __block NSError *error = nil;
        void (^save)(void) = ^{
            NSDictionary *proof = @{@"passedChecks": checks, @"observations": observations};
            [[NSJSONSerialization dataWithJSONObject:proof options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil] writeToFile:outputFile atomically:YES];
        };
        BOOL (^check)(BOOL, NSString *) = ^BOOL(BOOL passed, NSString *name) {
            if (passed) [checks addObject:name]; else [observations addObject:@{@"failedCheck": name, @"error": error.localizedDescription ?: @""}];
            save(); return passed;
        };
        OWExecuTorchRunner *runner = [[OWExecuTorchRunner alloc] initWithModelPath:@(argv[1]) tokenizerPath:@(argv[2]) error:&error];
        if (!check(runner != nil, @"native-runner-tokenizer-initialization")) return 1;
        OWExecuTorchTokenizer *reference = [[OWExecuTorchTokenizer alloc] initWithPath:@(argv[2]) error:&error];
        BOOL equal = reference != nil;
        for (NSString *text in @[@"", @"Cedar Osaka 730 vegetarian", @"你好。👩🏽‍💻 café e\u0301", @"<|im_start|>user\n<|im_end|>"]) {
            NSNumber *a = [runner countPrompt:text error:&error], *b = [reference countPrompt:text error:&error];
            equal = equal && a != nil && [a isEqual:b];
        }
        if (!check(equal, @"runner-owned-tokenizer-counts-match-pinned-native-counter")) return 1;
        reference = nil;
        NSError *markerError = nil;
        OWExecuTorchRunner *wrong = [[OWExecuTorchRunner alloc] initWithModelPath:@(argv[1]) tokenizerPath:@(argv[2]) endOfTurnTokens:@[@"<|eot_id|>"] endOfTextToken:@"<|end_of_text|>" error:&markerError];
        if (!check(wrong == nil && markerError != nil, @"declared-family-marker-mismatch-refuses-before-model-load")) return 1;
        if (!check([runner loadWithError:&error], @"pinned-xnnpack-model-loads-on-macos")) return 1;
        NSArray *history = @[@{@"role": @"system", @"content": [@"Remember corrected facts. " stringByAppendingString:[@"The project needs one short written briefing. " stringByPaddingToLength:1800 withString:@"The project needs one short written briefing. " startingAtIndex:0]]},
                             @{@"role": @"user", @"content": @"Project Cedar. City Porto. Budget 620. Vegetarian food."},
                             @{@"role": @"assistant", @"content": @"Saved Cedar, Porto, 620 and vegetarian."}];
        NSArray *messages = [history arrayByAddingObject:@{@"role": @"user", @"content": @"Return the project, city, budget and diet in one short sentence."}];
        NSDictionary *(^generate)(NSString *, NSInteger, NSInteger) = ^NSDictionary *(NSString *text, NSInteger limit, NSInteger stopAfter) {
            error = nil; [runner beginOperation];
            __block NSInteger callbacks = 0; NSMutableString *streamed = [NSMutableString string];
            NSDictionary *result = [runner generatePrompt:text outputLimit:limit temperature:0 contextLimit:2048 callback:^(NSString *piece) {
                [streamed appendString:piece]; callbacks += 1;
                if (stopAfter > 0 && callbacks >= stopAfter) [runner stop];
            } error:&error];
            if (result) {
                NSMutableDictionary *record = [result mutableCopy]; record[@"callbacks"] = @(callbacks); record[@"streamMatchesReply"] = @([streamed isEqual:result[@"content"]]);
                [observations addObject:record]; save();
            }
            return result;
        };
        NSDictionary *fresh = generate(prompt(messages), 48, 0);
        if (!check(fresh != nil && [fresh[@"cachedTokens"] integerValue] == 0 && [fresh[@"content"] length] > 0, @"fresh-native-generation-has-no-cache-and-completes")) return 1;
        [runner reset]; [runner beginOperation]; error = nil;
        NSNumber *warmed = [runner warmPrompt:prompt(history) futurePrompt:prompt([history arrayByAddingObject:@{@"role": @"user", @"content": @"OpenWeights warm prefix probe"}]) contextLimit:2048 error:&error];
        NSNumber *again = [runner warmPrompt:prompt(history) futurePrompt:prompt([history arrayByAddingObject:@{@"role": @"user", @"content": @"OpenWeights warm prefix probe"}]) contextLimit:2048 error:&error];
        NSDictionary *warm = generate(prompt(messages), 48, 0);
        if (!check(warmed != nil && warmed.integerValue > 128 && [warmed isEqual:again] && warm != nil && [warm[@"cachedTokens"] isEqual:warmed] && [warm[@"content"] isEqual:fresh[@"content"]], @"chunked-warming-is-idempotent-and-matches-fresh-generation")) return 1;
        NSString *continuedPrompt = [prompt(messages) stringByAppendingFormat:@"%@<|im_end|>\n<|im_start|>user\nReturn Cedar only.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", warm[@"content"]];
        NSDictionary *retained = generate(continuedPrompt, 32, 0);
        [runner reset]; NSDictionary *retainedFresh = generate(continuedPrompt, 32, 0);
        if (!check(retained != nil && retainedFresh != nil && [retained[@"cachedTokens"] integerValue] > warmed.integerValue && [retained[@"content"] isEqual:retainedFresh[@"content"]], @"actual-decoded-token-ids-retain-a-reply-and-match-fresh-continuation")) return 1;

        // Same prompt after a capped one-token reply has no saved prediction.
        // It must reset rather than call generate("") on an invalid checkpoint.
        [runner reset]; NSDictionary *one = generate(prompt(messages), 1, 0);
        NSDictionary *oneAgain = generate(prompt(messages), 1, 0);
        if (!check(one != nil && oneAgain != nil && [one[@"stopReason"] integerValue] == 1 && [oneAgain[@"cachedTokens"] integerValue] == 0 && [one[@"content"] isEqual:oneAgain[@"content"]], @"one-token-cap-resets-an-equal-prompt-without-a-prefill-prediction")) return 1;

        NSMutableArray *edited = [messages mutableCopy]; edited[1] = @{@"role": @"user", @"content": @"Project Cedar. City Osaka. Budget 730. Vegetarian food."};
        NSDictionary *changed = generate(prompt(edited), 48, 0);
        [runner reset]; NSDictionary *changedFresh = generate(prompt(edited), 48, 0);
        if (!check(changed != nil && changedFresh != nil && [changed[@"cachedTokens"] integerValue] == 0 && [changed[@"content"] isEqual:changedFresh[@"content"]], @"edited-history-invalidates-forward-only-cache-and-matches-fresh")) return 1;

        [runner reset]; NSDictionary *cancelled = generate(prompt(messages), 128, 3);
        NSDictionary *recovered = generate(prompt(messages), 48, 0);
        if (!check(cancelled != nil && [cancelled[@"cancelled"] boolValue] && [cancelled[@"stopReason"] integerValue] == 3 && recovered != nil && [recovered[@"cachedTokens"] integerValue] == 0 && [recovered[@"content"] isEqual:fresh[@"content"]], @"native-generation-stop-clears-cache-and-next-request-recovers")) return 1;

        [runner reset]; [runner beginOperation]; error = nil;
        std::thread stopper([runner] { std::this_thread::sleep_for(std::chrono::milliseconds(10)); [runner stop]; });
        NSNumber *interrupted = [runner warmPrompt:prompt(history) futurePrompt:prompt(messages) contextLimit:2048 error:&error];
        stopper.join(); BOOL warmStopped = interrupted == nil && error != nil;
        NSDictionary *afterWarmStop = generate(prompt(messages), 48, 0);
        if (!check(warmStopped && afterWarmStop != nil && [afterWarmStop[@"cachedTokens"] integerValue] == 0 && [afterWarmStop[@"content"] isEqual:fresh[@"content"]], @"stop-during-native-warming-discards-state-and-recovers")) return 1;

        error = nil; [runner beginOperation];
        NSDictionary *oversized = [runner generatePrompt:[@" a" stringByPaddingToLength:4096 withString:@" a" startingAtIndex:0] outputLimit:32 temperature:0 contextLimit:2048 callback:^(NSString *piece) {} error:&error];
        BOOL refused = oversized == nil && error != nil;
        NSDictionary *afterRefusal = generate(prompt(messages), 48, 0);
        if (!check(refused && afterRefusal != nil && [afterRefusal[@"cachedTokens"] integerValue] == 0 && [afterRefusal[@"content"] isEqual:fresh[@"content"]], @"native-context-refusal-does-not-generate-and-recovery-is-fresh")) return 1;
        [runner reset];
        NSDictionary *unicode = generate(prompt(@[@{@"role": @"user", @"content": @"Reply exactly with this text and nothing else: 你好大阪 café 👩🏽‍💻"}]), 64, 0);
        // Generated IDs, not the requested spelling, establish decoding fidelity.
        // The independent Rust decoder compares every recorded reply afterward.
        if (!check(unicode != nil && [unicode[@"content"] containsString:@"你好"] && [unicode[@"content"] containsString:@"👩🏽‍💻"], @"native-multibyte-output-survives-valid-utf8-streaming")) return 1;
        for (NSDictionary *record in observations) if (record[@"streamMatchesReply"] && ![record[@"streamMatchesReply"] boolValue]) return 1;
        return 0;
    }
}
