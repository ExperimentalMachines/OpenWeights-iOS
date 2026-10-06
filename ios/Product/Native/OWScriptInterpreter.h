#pragma once
#include <atomic>
#include <cstddef>
#include <string>

namespace owscript {
struct Limits {
    size_t memoryBytes = 32 * 1024 * 1024;
    size_t stackBytes = 512 * 1024;
    int millis = 2000;
    size_t outputBytes = 2000;
};
struct Result { std::string output; bool failed; };
// The caller owns this token until run returns. No runtime object crosses threads.
struct Cancellation { std::atomic<bool> stopped{false}; };
Result run(const std::string &source, const std::string &inputsJSON,
           Cancellation &cancellation, Limits limits = {});
}
