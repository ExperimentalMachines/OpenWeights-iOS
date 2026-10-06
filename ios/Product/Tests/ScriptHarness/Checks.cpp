#include "OWScriptInterpreter.h"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
using namespace owscript;
void require(bool value, const char *why) { if (!value) throw std::runtime_error(why); }
int main() {
    std::vector<std::string> passed;
    auto check = [&](const std::string &source, const std::string &expected, const char *name) {
        Cancellation token; auto result = run(source, "{}", token);
        if (result.failed || result.output != expected) { std::cerr << name << ": " << result.output << "\n"; throw std::runtime_error(name); }
        passed.push_back(name);
    };
    check("2 + 3", "5", "arithmetic");
    check("return {total: 7, city: 'Osaka'}", "{\"total\":7,\"city\":\"Osaka\"}", "top-level-return");
    check("await Promise.resolve(11)", "11", "top-level-await");
    check("const n = await Promise.resolve(13); return n * 2", "26", "await-and-return");
    check("(async function(){return {value:19, city:'Osaka'}})()", "{\"value\":19,\"city\":\"Osaka\"}", "promise-object-value-key");
    check("const n = await Promise.resolve(19); return {value:n, city:'Osaka'}", "{\"value\":19,\"city\":\"Osaka\"}", "async-wrapper-object-value-key");
    check("console.log('Cedar'); 17", "Cedar\n17", "console-and-last-expression");
    check("globalThis.poison = 23; 23", "23", "first-world");
    check("typeof poison", "\"undefined\"", "fresh-world");
    check("[typeof fetch, typeof process, typeof std, typeof os, typeof Worker, typeof require]", "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]", "no-host-bindings");
    check("'a\\0b'", "\"a\\u0000b\"", "embedded-null-json");
    Cancellation inputToken; auto input = run("JSON.parse(inputs['sales.json']).total + 1", "{\"sales.json\":\"{\\\"total\\\":29}\"}", inputToken);
    require(!input.failed && input.output == "30", "file-json-data"); passed.push_back("file-json-data");
    for (auto source : {"while (true) {}", "const p = new Promise(()=>{}); await p", "function f(){return f()} f()", "let a=[]; while(true) a.push('x'.repeat(1000000))", "Promise.resolve().then(function f(){Promise.resolve().then(f)}); await new Promise(()=>{})"}) {
        Cancellation token; Limits limits; limits.millis = 80;
        auto start = std::chrono::steady_clock::now(); auto result = run(source, "{}", token, limits);
        require(result.failed && !result.output.empty(), "resource-failure");
        require(std::chrono::steady_clock::now() - start < std::chrono::seconds(2), "resource-deadline");
        passed.push_back("bounded-resource-failure-" + std::to_string(passed.size()));
    }
    Cancellation cancel; Result cancelled;
    std::thread worker([&] { cancelled = run("while(true) {}", "{}", cancel); });
    std::this_thread::sleep_for(std::chrono::milliseconds(30)); cancel.stopped.store(true); worker.join();
    require(cancelled.failed, "cancellation"); passed.push_back("cancellation");
    Cancellation pre; pre.stopped.store(true); require(run("7", "{}", pre).failed, "pre-cancellation"); passed.push_back("pre-cancellation");
    Cancellation cap; auto capped = run("console.log('😀'.repeat(10000)); '漢'.repeat(10000)", "{}", cap);
    require(!capped.failed && capped.output.size() <= 2000 && capped.output.find("truncated") != std::string::npos, "aggregate-output-cap"); passed.push_back("aggregate-output-cap");
    Cancellation error; auto failed = run("console.log('once'); JSON.parse('bad')", "{}", error);
    require(failed.failed && failed.output.find("SyntaxError") != std::string::npos && failed.output.find("once") == std::string::npos, "runtime-error-no-replay"); passed.push_back("runtime-error-no-replay");
    Cancellation invalid; require(run("7", "{bad", invalid).failed, "invalid-input-json"); passed.push_back("invalid-input-json");
    for (const auto &name : passed) std::cout << "PASS " << name << "\n";
}
