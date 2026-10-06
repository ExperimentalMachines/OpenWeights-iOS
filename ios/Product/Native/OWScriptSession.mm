#import "OWScriptSession.h"
#include "OWScriptInterpreter.h"
#include <pthread.h>
#include <mutex>
@implementation OWScriptSession {
    owscript::Cancellation _cancellation;
    std::mutex _request;
}
- (NSDictionary<NSString *, id> *)runSource:(NSString *)source inputsJSON:(NSString *)inputsJSON {
    NSData *code = [source dataUsingEncoding:NSUTF8StringEncoding];
    NSData *inputs = [inputsJSON dataUsingEncoding:NSUTF8StringEncoding];
    std::unique_lock<std::mutex> lock(_request, std::try_to_lock);
    if (!lock.owns_lock()) return @{@"output": @"This interpreter session is already running.", @"failed": @YES};
    struct Work {
        std::string code, inputs;
        owscript::Cancellation *cancellation;
        owscript::Result result;
    } work{std::string((const char *)code.bytes, code.length),
           std::string((const char *)inputs.bytes, inputs.length), &_cancellation, {"The interpreter worker could not start.", true}};
    // QuickJS's 512 KiB guard must unwind before reaching the actual worker stack.
    pthread_attr_t attributes;
    pthread_t worker;
    int status = pthread_attr_init(&attributes);
    if (status == 0) {
        status = pthread_attr_setstacksize(&attributes, 2 * 1024 * 1024);
        if (status == 0) status = pthread_create(&worker, &attributes, [](void *opaque) -> void * {
            auto *work = static_cast<Work *>(opaque);
            work->result = owscript::run(work->code, work->inputs, *work->cancellation);
            return nullptr;
        }, &work);
        pthread_attr_destroy(&attributes);
        if (status == 0) pthread_join(worker, nullptr);
    }
    const auto &result = work.result;
    NSString *text = [[NSString alloc] initWithBytes:result.output.data() length:result.output.size() encoding:NSUTF8StringEncoding];
    return @{@"output": text ?: @"The interpreter returned invalid UTF-8.", @"failed": @(result.failed || text == nil)};
}
- (void)cancel { _cancellation.stopped.store(true); }
@end
