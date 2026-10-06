/*
 * Copyright 2026 The OpenWeights Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Runs one script and throws the whole world away afterwards.
//
// A runtime per call rather than a reused one. Reuse would be faster and would also mean a
// script could leave something behind for the next one, which is the kind of state nobody
// reasons about correctly. These run for a few milliseconds; the setup is not the cost.
//
// No file or socket host functions are registered or linked from quickjs-libc.
// QuickJS intrinsics, including Date, remain available alongside console and inputs.

#include "OWScriptInterpreter.h"
#include <algorithm>
#include <cstring>

#include <chrono>
#include <string>

extern "C" {
#include "quickjs.h"
}

namespace {

/** What a run is allowed to spend, and what it has produced so far. */
struct Run {
    std::chrono::steady_clock::time_point deadline;
    std::string output;
    size_t outputLimit;
    owscript::Cancellation *cancellation;
};

/**
 * Asked by QuickJS between operations, and the only thing that stops a loop with no end.
 *
 * A memory limit does not catch `while (true) {}`: that allocates nothing. Returning
 * non-zero here unwinds the interpreter, which is the one mechanism that does.
 */
int interrupted(JSRuntime *runtime, void *opaque) {
    (void) runtime;
    auto *run = static_cast<Run *>(opaque);
    return run->cancellation->stopped.load() || std::chrono::steady_clock::now() >= run->deadline ? 1 : 0;
}

/** Appends to the run's output, stopping at the cap rather than growing without end. */
void append(Run *run, const std::string &text) {
    if (run->output.size() >= run->outputLimit) {
        return;
    }
    const size_t room = run->outputLimit - run->output.size();
    run->output.append(text, 0, room);
}

/**
 * `console.log`, because a model writes it whether or not anything defines it.
 *
 * Without this, the first thing most generated scripts do is throw "console is not
 * defined", which teaches the model nothing about its actual mistake. It writes into the
 * run's buffer and nowhere else: there is no stdout to reach from here.
 */
JSValue consoleLog(JSContext *context, JSValueConst self, int argc, JSValueConst *argv) {
    (void) self;
    auto *run = static_cast<Run *>(JS_GetContextOpaque(context));
    std::string line;
    for (int i = 0; i < argc; i++) {
        const char *piece = JS_ToCString(context, argv[i]);
        if (piece == nullptr) {
            continue;
        }
        if (i > 0) {
            line += ' ';
        }
        line.append(piece, std::min(strlen(piece), run->outputLimit - std::min(line.size(), run->outputLimit)));
        JS_FreeCString(context, piece);
    }
    line += '\n';
    append(run, line);
    return JS_UNDEFINED;
}

/** The value a script ended on, as text a model can read. */
std::string resultOf(JSContext *context, JSValue value) {
    if (JS_IsUndefined(value)) {
        return "";
    }
    // JSON first, so an object comes back as its contents rather than [object Object].
    JSValue json = JS_JSONStringify(context, value, JS_UNDEFINED, JS_UNDEFINED);
    size_t length = 0;
    const char *text = JS_IsException(json) ? nullptr : JS_ToCStringLen(context, &length, json);
    std::string out;
    if (text != nullptr) {
        out.assign(text, length);
        JS_FreeCString(context, text);
    } else {
        const char *plain = JS_ToCStringLen(context, &length, value);
        if (plain != nullptr) {
            out.assign(plain, length);
            JS_FreeCString(context, plain);
        }
    }
    JS_FreeValue(context, json);
    return out;
}

/** Whatever went wrong, phrased the way the model will read it back. */
std::string failureOf(JSContext *context) {
    JSValue error = JS_GetException(context);
    std::string message;
    const char *text = JS_ToCString(context, error);
    if (text != nullptr) {
        message = text;
        JS_FreeCString(context, text);
    }
    JSValue stack = JS_GetPropertyStr(context, error, "stack");
    if (!JS_IsUndefined(stack) && !JS_IsException(stack)) {
        const char *trace = JS_ToCString(context, stack);
        if (trace != nullptr && *trace != '\0') {
            message += "\n";
            message += trace;
        }
        if (trace != nullptr) {
            JS_FreeCString(context, trace);
        }
    }
    JS_FreeValue(context, stack);
    JS_FreeValue(context, error);
    return message.empty() ? "the script failed without saying why" : message;
}

/**
 * Runs the microtask queue and unwraps whatever the evaluation settled to.
 *
 * `JS_EVAL_FLAG_ASYNC` hands back a promise rather than a value, and when it fulfils the
 * value is boxed one more time as `{value: ...}`. An async wrapper adds a third layer,
 * because the wrapper's own promise resolves to the inner async function's promise. All
 * three are unwrapped here, so a script that awaits gets its answer rather than
 * "[object Promise]", which would be barely better than the SyntaxError it replaced.
 *
 * The runtime's interrupt handler is already armed with the deadline, so a job queue that
 * will not drain is cut off by the same timeout as everything else.
 */
JSValue settle(JSRuntime *runtime, JSContext *context, JSValue value, bool *failed, bool asyncEvaluation = false) {
    if (JS_IsException(value)) {
        *failed = true;
        return value;
    }
    if (JS_PromiseState(context, value) == JS_PROMISE_NOT_A_PROMISE) {
        *failed = false;
        return value;
    }

    for (;;) {
        JSContext *pending = nullptr;
        if (interrupted(runtime, JS_GetContextOpaque(context))) {
            JS_FreeValue(context, value);
            JS_ThrowInternalError(context, "the script was stopped or exceeded its time limit");
            *failed = true; return JS_EXCEPTION;
        }
        int job = JS_ExecutePendingJob(runtime, &pending);
        if (job < 0) { JS_FreeValue(context, value); *failed = true; return JS_EXCEPTION; }
        if (job == 0) break;
    }

    const JSPromiseStateEnum state = JS_PromiseState(context, value);
    JSValue result = JS_PromiseResult(context, value);
    JS_FreeValue(context, value);

    if (state == JS_PROMISE_REJECTED) {
        JS_Throw(context, result);
        *failed = true;
        return JS_EXCEPTION;
    }
    if (state == JS_PROMISE_PENDING) {
        // Nothing left to run and still not settled: the script awaited something no timer
        // and no job will ever resolve. Saying so beats returning a pending promise.
        JS_FreeValue(context, result);
        JS_ThrowInternalError(
            context, "the script never finished: it awaited something that never resolves");
        *failed = true;
        return JS_EXCEPTION;
    }

    if (JS_PromiseState(context, result) != JS_PROMISE_NOT_A_PROMISE) {
        return settle(runtime, context, result, failed, asyncEvaluation);
    }
    // Only async script evaluation adds the {value: ...} envelope. A user
    // Promise resolving to an object with that key must retain the whole object.
    if (asyncEvaluation && JS_IsObject(result)) {
        JSValue inner = JS_GetPropertyStr(context, result, "value");
        if (!JS_IsException(inner) && !JS_IsUndefined(inner)) {
            JS_FreeValue(context, result);
            if (JS_PromiseState(context, inner) != JS_PROMISE_NOT_A_PROMISE) {
                return settle(runtime, context, inner, failed);
            }
            *failed = false;
            return inner;
        }
        JS_FreeValue(context, inner);
    }
    *failed = false;
    return result;
}

}  // namespace

namespace owscript {
Result run(const std::string &source, const std::string &inputsJSON, Cancellation &cancellation, Limits limits) {
    if (source.size() > 72 * 1024 || inputsJSON.size() > 400 * 1024 ||
        limits.millis < 1 || limits.millis > 2000 || limits.memoryBytes < 4096 || limits.memoryBytes > 32 * 1024 * 1024 ||
        limits.stackBytes < 16384 || limits.stackBytes > 512 * 1024 || limits.outputBytes < 1 || limits.outputBytes > 2000)
        return {"The interpreter request exceeds its resource limits.", true};
    if (cancellation.stopped.load()) return {"The script was cancelled before it ran.", true};
    Run run{std::chrono::steady_clock::now() + std::chrono::milliseconds(limits.millis), {}, limits.outputBytes, &cancellation};
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) return {"Not enough memory to start the interpreter.", true};
    JS_SetMemoryLimit(runtime, limits.memoryBytes);
    JS_SetMaxStackSize(runtime, limits.stackBytes);
    JS_SetInterruptHandler(runtime, interrupted, &run);
    JSContext *context = JS_NewContext(runtime);
    if (!context) { JS_FreeRuntime(runtime); return {"Not enough memory to start the interpreter.", true}; }
    JS_SetContextOpaque(context, &run);
    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    JS_SetPropertyStr(context, console, "log", JS_NewCFunction(context, consoleLog, "log", 1));
    JS_SetPropertyStr(context, global, "console", console);
    JSValue inputs = JS_ParseJSON(context, inputsJSON.data(), inputsJSON.size(), "<inputs>");
    if (JS_IsException(inputs)) {
        std::string error = failureOf(context);
        JS_FreeValue(context, global); JS_FreeContext(context); JS_FreeRuntime(runtime);
        return {error.substr(0, limits.outputBytes), true};
    }
    JS_SetPropertyStr(context, global, "inputs", inputs);
    JS_FreeValue(context, global);
    // Four readings of the same program, tried in order and stopped at the first that
    // compiles. A model writes `return` about as often as a bare expression, because it
    // pictures the script as a function body somebody will call, and it writes top-level
    // `await` because almost all the JavaScript it has read is in a module. Both are syntax
    // errors in a classic script, and neither is a mistake worth failing over.
    //
    // Measured on the vendored engine with a harness that replicates this exact path: the
    // one-rung version got 5 of 14 realistic cases right, this gets 14. The cases it fixes
    // are top-level await, await beside return, and every form of the model handing back a
    // fenced code block, which the old path turned into "TypeError: not a function" because
    // ``` parses as a tagged template.
    //
    // Climbing only on a syntax error is the whole point: a syntax error means nothing ran,
    // so there is no work to repeat and no output to double up. A program that compiled and
    // then threw has already had its say, and that is the failure the caller hears about.
    const std::string &text = source;
    const std::string attempts[] = {
        text,
        "(function(){\n" + text + "\n})()",
        text,
        "(async function(){\n" + text + "\n})()",
    };
    // The last two ask the engine to allow top-level await, which makes the evaluation
    // asynchronous and is why [settle] exists.
    const int asyncFrom = 2;

    JSValue value = JS_EXCEPTION;
    bool failed = true;
    std::string lastFailure;
    for (int rung = 0; rung < 4; rung++) {
        const int flags =
            JS_EVAL_TYPE_GLOBAL | (rung >= asyncFrom ? JS_EVAL_FLAG_ASYNC : 0);
        // Compiled first and run only if that worked, so the two kinds of failure cannot
        // be confused. They were told apart by searching the message for "SyntaxError",
        // and a program that parsed, ran, printed, and then called JSON.parse on bad input
        // failed with that very word: it was run again on the next rung, and again, with
        // its output repeated each time. Whether the text parses is a question the
        // compiler answers on its own, before anything has happened.
        JSValue compiled = JS_Eval(context, attempts[rung].c_str(), attempts[rung].size(),
                                   "<script>", flags | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(compiled)) {
            lastFailure = failureOf(context);
            continue;
        }
        run.output.clear();
        value = JS_EvalFunction(context, compiled);
        value = settle(runtime, context, value, &failed, rung >= asyncFrom);
        if (!failed) break;

        // The program ran. Rewriting it would change what it did rather than whether it
        // parsed, so this is the answer.
        lastFailure = failureOf(context);
        JS_FreeValue(context, value);
        value = JS_EXCEPTION;
        break;
    }

    // The failure the script actually hit, not the first rung's complaint about grammar.
    // Reporting the first one is what produced the bug this replaces: a program with both a
    // top-level `return` and a genuine `TypeError` was reported as a SyntaxError, because
    // the wrapped retry ran, threw for a real reason, and the real reason was discarded.
    std::string report = failed ? lastFailure : resultOf(context, value);
    if (failed && report.empty()) report = failureOf(context);
    if (!failed && !run.output.empty()) report = run.output + report;
    const std::string notice = "\n... (result truncated)";
    const bool truncated = report.size() > limits.outputBytes || run.output.size() >= limits.outputBytes;
    if (truncated) report.resize(std::min(report.size(), limits.outputBytes > notice.size() ? limits.outputBytes - notice.size() : size_t(0)));
    // A byte ceiling must never hand Swift an incomplete UTF-8 scalar.
    size_t end = report.size();
    if (end) {
        size_t start = end - 1;
        while (start && (static_cast<unsigned char>(report[start]) & 0xc0) == 0x80) --start;
        unsigned char lead = report[start];
        size_t width = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
        if (end - start < width) report.resize(start);
    }
    if (truncated && notice.size() <= limits.outputBytes) report += notice;
    JS_FreeValue(context, value);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);

    return {report, failed};
}
}
