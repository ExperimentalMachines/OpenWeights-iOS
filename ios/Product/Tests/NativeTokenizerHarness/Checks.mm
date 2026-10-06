#import <Foundation/Foundation.h>
#import "OWExecuTorchTokenizer.h"

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        NSError *error = nil;
        OWExecuTorchTokenizer *counter = [[OWExecuTorchTokenizer alloc] initWithPath:@(argv[1]) error:&error];
        if (!counter) { NSLog(@"%@", error); return 3; }
        NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
        NSArray *probes = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!probes) return 4;
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *probe in probes) {
            error = nil;
            NSNumber *count = [counter countPrompt:probe[@"prompt"] error:&error];
            BOOL refused = [probe[@"refused"] boolValue];
            BOOL passed = refused ? count == nil && error != nil : count != nil && [count isEqual:probe[@"expectedTokens"]];
            [results addObject:@{@"id": probe[@"id"], @"passed": @(passed), @"refused": @(count == nil),
                @"nativeTokens": count ?: [NSNull null], @"referenceTokens": probe[@"expectedTokens"] ?: [NSNull null],
                @"error": error.localizedDescription ?: @""}];
        }
        NSString *directory = [@(argv[2]) stringByDeletingLastPathComponent];
        for (NSString *name in @[@"malformed-tokenizer.json", @"missing-tokenizer.json"]) {
            error = nil;
            OWExecuTorchTokenizer *invalid = [[OWExecuTorchTokenizer alloc] initWithPath:[directory stringByAppendingPathComponent:name] error:&error];
            [results addObject:@{@"id": name, @"passed": @(invalid == nil && error != nil), @"error": error.localizedDescription ?: @""}];
        }
        NSData *output = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (![output writeToFile:@(argv[3]) options:NSDataWritingAtomic error:&error]) return 5;
        for (NSDictionary *result in results) if (![result[@"passed"] boolValue]) return 1;
        return 0;
    }
}
