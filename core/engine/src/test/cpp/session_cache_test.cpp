#include "engine_session.h"
#include "common.h"
#include "chat.h"

#include <algorithm>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace openweights {
struct SessionCacheTestAccess {
    static const llama_vocab * vocab(Session & session) { return llama_model_get_vocab(session.model_); }
    static std::vector<llama_token> tokens(Session & session, const std::string & text,
                                         bool special = false, size_t offset = 0) {
        return session.tokenize_prompt(text, special, offset);
    }
    static void remember(Session & session, const std::string & text,
                         const std::vector<llama_token> & tokens, size_t index) {
        session.remember_reply(text, tokens, index);
    }
    static size_t count(Session & session) { return session.replies_.size(); }
    static std::string render(Session & session, const std::vector<ChatMessage> & messages) {
        std::string prompt, error;
        if (!session.render_prompt(messages, {}, {false, ""}, prompt, error)) throw std::runtime_error(error);
        return prompt;
    }
    static std::pair<size_t, size_t> field(Session & session, size_t index) {
        for (const auto & span : session.assistant_spans_) {
            if (span.message_index == index) return {span.start, span.end};
        }
        throw std::runtime_error("assistant field was not verified");
    }
    static void thinking_end(Session & session, const std::string & tag) { session.thinking_end_tag_ = tag; }
    static void template_source(Session & session, const std::string & source) {
        auto replacement = common_chat_templates_init(session.model_, source);
        common_chat_templates_free(static_cast<common_chat_templates *>(session.chat_templates_));
        session.chat_templates_ = replacement.release();
    }
};
}  // namespace openweights

using namespace openweights;
using Access = SessionCacheTestAccess;

static void require(bool value, const std::string & message) {
    if (!value) throw std::runtime_error(message);
}

static std::vector<llama_token> plain(Session & session, const std::string & text, bool special = false) {
    return common_tokenize(Access::vocab(session), text, special, true);
}

static std::vector<llama_token> letters(Session & session, const std::string & text) {
    std::vector<llama_token> result;
    for (char letter : text) {
        auto piece = plain(session, std::string(1, letter));
        result.insert(result.end(), piece.begin(), piece.end());
    }
    return result;
}

static std::string pieces(Session & session, const std::vector<llama_token> & tokens) {
    std::string result;
    for (auto token : tokens) result += common_token_to_piece(Access::vocab(session), token, true);
    return result;
}

static void append(std::vector<llama_token> & target, const std::vector<llama_token> & source) {
    target.insert(target.end(), source.begin(), source.end());
}

static ChatMessage message(const std::string & role, const std::string & content) { return {role, content, "", {}}; }

int main(int argc, char ** argv) try {
    require(argc == 2, "Usage: session-cache-tests /path/to/Qwen3-0.6B-Q4_K_M.gguf");
    std::string error;
    std::unique_ptr<Session> session(Session::load(argv[1], "", 2048, 4, 4, 0, true, false, false, false, 0, 512, 128, error));
    require(session != nullptr, error);
    const std::string answer = "vegetarian";
    const auto generated = letters(*session, answer);
    const auto merged = plain(*session, answer);
    require(generated != merged && pieces(*session, generated) == answer, "fixture needs two valid tokenizations");

    std::vector<ChatMessage> history = {
        message("system", "The word vegetarian is a dietary restriction."),
        message("user", "Our dietary restriction is vegetarian. Remember it."),
        message("assistant", answer),
        message("user", "I quoted your reply: vegetarian. What was the restriction?")};
    Access::remember(*session, answer, generated, 2);
    const auto prompt = Access::render(*session, history);
    const auto field = Access::field(*session, 2);
    auto expected = plain(*session, prompt.substr(0, field.first), true);
    append(expected, generated);
    append(expected, plain(*session, prompt.substr(field.second)));
    require(Access::tokens(*session, prompt, true) == expected,
            "system/user quotations must stay plain, only the owning assistant field may splice");
    const size_t offset = prompt.find("<|im_start|>assistant");
    auto stretch_expected = plain(*session, prompt.substr(offset, field.first - offset));
    append(stretch_expected, generated);
    append(stretch_expected, plain(*session, prompt.substr(field.second)));
    require(Access::tokens(*session, prompt.substr(offset), false, offset) == stretch_expected,
            "media text stretches must honor absolute template offsets");
    require(Access::tokens(*session, prompt.substr(field.first + 1), false, field.first + 1) ==
            plain(*session, prompt.substr(field.first + 1)), "partial fields must not splice");
    std::cout << "PASS assistant ownership, user quotations and media offsets\n";

    history.push_back(message("assistant", answer));
    history.push_back(message("user", "Repeat it again."));
    Access::remember(*session, answer, merged, 4);
    const auto repeated = Access::render(*session, history);
    const auto first = Access::field(*session, 2), second = Access::field(*session, 4);
    expected = plain(*session, repeated.substr(0, first.first), true);
    append(expected, generated);
    append(expected, plain(*session, repeated.substr(first.second, second.first - first.second)));
    append(expected, merged);
    append(expected, plain(*session, repeated.substr(second.second)));
    require(Access::tokens(*session, repeated, true) == expected, "identical replies must keep distinct token owners");
    Access::remember(*session, answer, merged, 2);
    require(Access::count(*session) == 2, "regeneration must replace the old record");
    const auto regenerated = Access::render(*session, history);
    expected = plain(*session, regenerated.substr(0, first.first), true);
    append(expected, merged);
    append(expected, plain(*session, regenerated.substr(first.second, second.first - first.second)));
    append(expected, merged);
    append(expected, plain(*session, regenerated.substr(second.second)));
    require(Access::tokens(*session, regenerated, true) == expected, "regeneration must use the latest tokens");
    std::cout << "PASS identical replies and regeneration\n";

    session->reset_conversation();
    Access::remember(*session, answer, generated, 2);
    history.resize(4);
    history[2].content = "Your earlier answer was vegetarian, but I changed this message.";
    const auto edited = Access::render(*session, history);
    require(Access::tokens(*session, edited, true) == plain(*session, edited, true),
            "a quotation in an edited assistant field must not inherit the original reply tokens");
    history[2].role = "user";
    const auto changed_role = Access::render(*session, history);
    require(Access::tokens(*session, changed_role, true) == plain(*session, changed_role, true),
            "a changed role must not inherit assistant tokens");
    std::cout << "PASS edited messages and changed roles\n";

    // The old owner search indexed a preceding short record with this long reply's offsets.
    session->reset_conversation();
    Access::remember(*session, "Yes.", plain(*session, "Yes."), 2);
    const std::string thought = std::string(200, 'x') + "</think>\n\n";
    auto reasoning_tokens = letters(*session, thought);
    append(reasoning_tokens, generated);
    Access::remember(*session, thought + answer, reasoning_tokens, 4);
    history = {message("system", "Be concise."), message("user", "Ready?"), message("assistant", "Yes."),
               message("user", "Diet?"), message("assistant", answer), message("user", "Remember it.")};
    const auto reasoning_prompt = Access::render(*session, history);
    Access::thinking_end(*session, "</think>");
    const auto answer_field = Access::field(*session, 4);
    expected = plain(*session, reasoning_prompt.substr(0, answer_field.first), true);
    append(expected, generated);
    append(expected, plain(*session, reasoning_prompt.substr(answer_field.second)));
    require(Access::tokens(*session, reasoning_prompt, true) == expected,
            "answer-only reasoning splice must keep the correct owner's offset table");
    session->reset();
    require(Access::count(*session) == 2, "cache-only reset must retain same-conversation records");
    require(Access::tokens(*session, reasoning_prompt, true) == expected, "cache-only re-read must preserve tokens");
    session->reset_conversation();
    require(Access::count(*session) == 0, "fresh conversation must clear reply records");
    const auto fresh = Access::render(*session, history);
    require(Access::tokens(*session, fresh, true) == plain(*session, fresh, true), "fresh chat must use plain tokenization");
    std::cout << "PASS reasoning offsets and cache/fresh reset separation\n";

    session->reset_conversation();
    history = {message("system", "Follow instructions exactly. Be concise."),
               message("user", "The dietary restriction is vegetarian. Reply with only that word, without punctuation.")};
    SamplerConfig sampler;
    sampler.temperature = 0;
    sampler.repeat_penalty = 1;
    sampler.max_tokens = 16;
    GenerationStats initial{}, followup{};
    ParsedReply reply;
    auto stop = session->generate(history, {}, sampler, {false, ""},
        [](const char *, float) { return true; }, initial, reply, error);
    require(stop != StopReason::ERROR, error);
    require(reply.content == answer, "end-to-end fixture must produce the repeated word");
    require(Access::count(*session) == 1 && initial.cached_tokens == 0,
            "generation must remember the reply at its assistant message index");
    history.push_back(message("assistant", reply.content));
    history.push_back(message("user", "What is the dietary restriction? Reply with only that word."));
    const auto before_count_context = session->context_used();
    const auto before_count_records = Access::count(*session);
    int32_t counted = 0;
    require(session->count_prompt_tokens(history, {}, {false, ""}, counted, error), error);
    require(counted > 0 && session->context_used() == before_count_context &&
            Access::count(*session) == before_count_records,
            "prompt counting must not decode or discard cached replies");
    int32_t counted_cells = 0;
    require(session->count_prompt_cells(history, {}, {false, ""}, counted_cells, error) && counted_cells == counted,
            "cell counter must retain the text counter's native reply boundaries");
    require(session->context_used() == before_count_context && Access::count(*session) == before_count_records,
            "cell counting must not decode or discard cached replies");
    stop = session->generate(history, {}, sampler, {false, ""},
        [](const char *, float) { return true; }, followup, reply, error);
    require(stop != StopReason::ERROR, error);
    require(counted == followup.prompt_tokens + followup.cached_tokens,
            "counted prompt must equal actual generation's fresh and reused tokens");
    require(followup.cached_tokens >= initial.prompt_tokens - 8,
            "actual generation must retain the initial user prefix despite its repeated reply text");
    session->reset_conversation();
    require(session->context_used() == 0 && Access::count(*session) == 0,
            "fresh reset must clear both decoded context and generated reply records");
    std::cout << "PASS end-to-end generation and decoded-context reset\n";
    auto media_history = history;
    media_history.back().media_paths.push_back("unopened-test-image");
    require(!session->count_prompt_tokens(media_history, {}, {false, ""}, counted, error) && counted == 0,
            "text counting must refuse media rather than undercount embeddings");
    require(!session->count_prompt_cells(media_history, {}, {false, ""}, counted_cells, error) && counted_cells == 0,
            "media cell counting must reject a missing projector before opening a file");
    require(session->context_used() == 0 && Access::count(*session) == 0,
            "failed media preparation must not decode or remember replies");
    std::cout << "PASS non-decoding text/cell prompt count and media refusal\n";

    Access::template_source(*session,
        "{% for message in messages %}{{ message['role'] }}:{{ message['content'] }}"
        "{% if message['role'] == 'assistant' %}{{ message['content'] }}{% endif %}\n{% endfor %}"
        "{% if add_generation_prompt %}assistant:{% endif %}");
    Access::remember(*session, answer, generated, 2);
    history = {message("system", "Be concise."), message("user", "vegetarian"),
               message("assistant", answer), message("user", "Continue.")};
    const auto duplicated = Access::render(*session, history);
    require(Access::tokens(*session, duplicated, true) == plain(*session, duplicated, true),
            "a template duplicating assistant fields must safely fall back to plain tokenization");
    std::cout << "PASS ambiguous template fallback\n";
    return 0;
} catch (const std::exception & failure) {
    std::cerr << "FAIL " << failure.what() << '\n';
    return 1;
}
