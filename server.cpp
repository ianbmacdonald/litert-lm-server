// litert-lm-server — standalone OpenAI-compatible HTTP server over LiteRT-LM's C ABI.
// lemonade-AUTHORED engine wrapper. CPU backend. One model per process, serialized inference.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>
#include <mutex>
#include <random>
#include <string>

#include "engine.h"
#include "httplib.h"
#include "json.hpp"

using nlohmann::json;

namespace {

LiteRtLmEngine* g_engine = nullptr;
std::string g_model_id = "litert-lm";
std::mutex g_infer_mutex;  // serialize all inference through the single engine.

// A streaming generation that produces no token and does not finish within this
// window is treated as stalled: the request is cancelled so it cannot hold
// g_infer_mutex forever and wedge every other request (the engine's own
// blocking path already bounds the non-streaming case internally).
constexpr std::chrono::seconds kStreamIdleTimeout{60};

// Upper bound on a single request's generated tokens. Without it a client can
// ask for billions and drive KV-cache/output allocation past what a gateway has.
constexpr int kMaxOutputTokensCeiling = 8192;

// Reject request bodies larger than this before parsing. A 1-2 GB gateway must
// not try to buffer an unbounded POST.
constexpr size_t kMaxPayloadBytes = 4 * 1024 * 1024;

std::string now_id() {
  static std::atomic<uint64_t> counter{0};
  std::mt19937_64 rng(std::random_device{}());
  char buf[40];
  std::snprintf(buf, sizeof(buf), "chatcmpl-%016llx%04llx",
                (unsigned long long)rng(),
                (unsigned long long)(counter++ & 0xffff));
  return buf;
}

int64_t unix_now() {
  return (int64_t)std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

// Convert one OpenAI message's content (string OR array) into LiteRT content array.
json to_litert_content(const json& content) {
  json arr = json::array();
  if (content.is_string()) {
    arr.push_back({{"type", "text"}, {"text", content.get<std::string>()}});
  } else if (content.is_array()) {
    for (const auto& part : content) {
      if (part.is_string()) {
        arr.push_back({{"type", "text"}, {"text", part.get<std::string>()}});
      } else if (part.is_object()) {
        std::string type = part.value("type", "text");
        if (type == "text" || part.contains("text")) {
          arr.push_back(
              {{"type", "text"}, {"text", part.value("text", std::string())}});
        }
      }
    }
  }
  if (arr.empty())
    arr.push_back({{"type", "text"}, {"text", std::string()}});
  return arr;
}

json to_litert_message(const std::string& role, const json& content) {
  return json{{"role", role}, {"content", to_litert_content(content)}};
}

// Extract assistant text from a LiteRT json response string.
std::string extract_text(const char* resp_json) {
  if (!resp_json) return std::string();
  json j;
  try {
    j = json::parse(resp_json);
  } catch (...) {
    return std::string(resp_json);
  }
  std::string out;
  if (j.contains("content") && j["content"].is_array()) {
    for (const auto& part : j["content"]) {
      if (part.is_object() && part.value("type", "") == "text")
        out += part.value("text", std::string());
    }
  } else if (j.contains("content") && j["content"].is_string()) {
    out = j["content"].get<std::string>();
  }
  return out;
}

int count_tokens(const std::string& text) {
  if (!g_engine || text.empty()) return 0;
  LiteRtLmTokenizeResult* r = litert_lm_engine_tokenize(g_engine, text.c_str());
  if (!r) return 0;
  int n = (int)litert_lm_tokenize_result_get_num_tokens(r);
  litert_lm_tokenize_result_delete(r);
  return n;
}

// Owns every per-request LiteRT handle. Build once, reused by both paths.
struct RequestCtx {
  LiteRtLmSamplerParams* sp = nullptr;
  LiteRtLmSessionConfig* sc = nullptr;
  LiteRtLmConversationConfig* cc = nullptr;
  LiteRtLmConversation* conv = nullptr;
  std::string final_message_json;
  std::string prompt_text;  // for usage accounting

  ~RequestCtx() {
    if (conv) litert_lm_conversation_delete(conv);
    if (cc) litert_lm_conversation_config_delete(cc);
    if (sc) litert_lm_session_config_delete(sc);
    if (sp) litert_lm_sampler_params_delete(sp);
  }
};

// Build sampler/session/conversation from an OpenAI request body.
// Returns nullptr + error message on malformed input.
std::unique_ptr<RequestCtx> build_ctx(const json& body, std::string* err) {
  auto ctx = std::make_unique<RequestCtx>();

  double temperature = 1.0;
  if (body.contains("temperature") && body["temperature"].is_number())
    temperature = body["temperature"].get<double>();
  if (temperature < 0.05) temperature = 0.05;  // TopP degenerates at 0.

  int max_tokens = 512;
  if (body.contains("max_tokens") && body["max_tokens"].is_number_integer())
    max_tokens = body["max_tokens"].get<int>();
  else if (body.contains("max_completion_tokens") &&
           body["max_completion_tokens"].is_number_integer())
    max_tokens = body["max_completion_tokens"].get<int>();
  if (max_tokens <= 0) max_tokens = 512;
  if (max_tokens > kMaxOutputTokensCeiling) max_tokens = kMaxOutputTokensCeiling;

  // Only TopP is implemented in this engine build.
  ctx->sp = litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP);
  litert_lm_sampler_params_set_top_k(ctx->sp, 40);
  litert_lm_sampler_params_set_top_p(ctx->sp, 0.95f);
  litert_lm_sampler_params_set_temperature(ctx->sp, (float)temperature);
  litert_lm_sampler_params_set_seed(ctx->sp, (int32_t)(unix_now() & 0x7fffffff));

  ctx->sc = litert_lm_session_config_create();
  litert_lm_session_config_set_max_output_tokens(ctx->sc, max_tokens);
  litert_lm_session_config_set_sampler_params(ctx->sc, ctx->sp);

  ctx->cc = litert_lm_conversation_config_create();
  litert_lm_conversation_config_set_session_config(ctx->cc, ctx->sc);

  if (!body.contains("messages") || !body["messages"].is_array() ||
      body["messages"].empty()) {
    *err = "'messages' must be a non-empty array";
    return nullptr;
  }
  const json& messages = body["messages"];

  // Partition: system -> system_message; history -> set_messages; last -> send.
  std::string system_text;
  json history = json::array();
  int last = (int)messages.size() - 1;
  for (int i = 0; i < (int)messages.size(); ++i) {
    const json& m = messages[i];
    std::string role = m.value("role", "user");
    const json content = m.contains("content") ? m["content"] : json("");
    if (role == "system") {
      json c = to_litert_content(content);
      for (const auto& p : c)
        if (p.value("type", "") == "text") system_text += p.value("text", "");
      continue;
    }
    if (i == last) {
      ctx->final_message_json = to_litert_message(role, content).dump();
      for (const auto& p : to_litert_content(content))
        ctx->prompt_text += p.value("text", "");
    } else {
      history.push_back(to_litert_message(role, content));
      for (const auto& p : to_litert_content(content))
        ctx->prompt_text += p.value("text", "");
    }
  }
  if (ctx->final_message_json.empty()) {
    // No non-system final message (e.g. only a system prompt): synthesize empty user turn.
    ctx->final_message_json = to_litert_message("user", json("")).dump();
  }
  if (!system_text.empty()) {
    ctx->prompt_text = system_text + "\n" + ctx->prompt_text;
    // set_system_message wants the raw system text, not a message-shaped JSON
    // object (an object trips "+ operator on string and map" in the template).
    litert_lm_conversation_config_set_system_message(ctx->cc,
                                                     system_text.c_str());
  }
  if (!history.empty())
    litert_lm_conversation_config_set_messages(ctx->cc, history.dump().c_str());

  ctx->conv = litert_lm_conversation_create(g_engine, ctx->cc);
  if (!ctx->conv) {
    *err = "failed to create conversation";
    return nullptr;
  }
  return ctx;
}

json make_completion_json(const std::string& id, int64_t created,
                          const std::string& text, int prompt_tokens,
                          int completion_tokens, const std::string& finish) {
  return json{
      {"id", id},
      {"object", "chat.completion"},
      {"created", created},
      {"model", g_model_id},
      {"choices",
       json::array({json{{"index", 0},
                         {"message",
                          json{{"role", "assistant"}, {"content", text}}},
                         {"finish_reason", finish}}})},
      {"usage",
       json{{"prompt_tokens", prompt_tokens},
            {"completion_tokens", completion_tokens},
            {"total_tokens", prompt_tokens + completion_tokens}}}};
}

// ---- Streaming (SSE) support -------------------------------------------------

struct StreamState {
  std::mutex m;
  std::condition_variable cv;
  std::deque<std::string> chunks;
  bool finished = false;
  std::string error;
};

void stream_callback(void* data, const char* chunk, bool is_final,
                     const char* error_msg) {
  auto* st = static_cast<StreamState*>(data);
  std::lock_guard<std::mutex> lk(st->m);
  if (chunk && *chunk) st->chunks.emplace_back(chunk);  // copy immediately.
  if (error_msg && *error_msg) st->error = error_msg;
  if (is_final) st->finished = true;
  st->cv.notify_all();
}

// A terminal SSE frame carrying an OpenAI-shaped error, followed by [DONE].
std::string sse_error_frame(const std::string& id, int64_t created,
                            const std::string& message) {
  json err{{"id", id},
           {"object", "chat.completion.chunk"},
           {"created", created},
           {"model", g_model_id},
           {"error", {{"message", message}}},
           {"choices", json::array({json{{"index", 0},
                                         {"delta", json::object()},
                                         {"finish_reason", "error"}}})}};
  return "data: " + err.dump() + "\n\ndata: [DONE]\n\n";
}

// Owns everything whose lifetime must outlive the engine's async worker thread,
// and tears it down in the ONE safe order regardless of how the HTTP layer drops
// the stream (return false, or destroying the provider mid-wait after a client
// disconnect): cancel + JOIN the worker (conversation delete ->
// ~SessionAdvanced -> WaitUntilDone) BEFORE freeing the StreamState the worker
// calls back into, and BEFORE releasing g_infer_mutex. Encoding this as a
// destructor removes all reliance on lambda-capture destruction order and keeps
// the engine single-user until the worker is fully joined — a plain
// unlock-in-the-provider would release the mutex while the cancelled worker is
// still unwinding, letting a second request start concurrently on the engine.
struct StreamHold {
  std::shared_ptr<StreamState> st;
  std::unique_ptr<RequestCtx> ctx;    // owns the LiteRT conversation
  std::unique_lock<std::mutex> lock;  // holds g_infer_mutex for the request

  ~StreamHold() {
    if (ctx && ctx->conv)
      litert_lm_conversation_cancel_process(ctx->conv);  // no-op if already done
    ctx.reset();  // conversation delete blocks on WaitUntilDone: worker joined here
    st.reset();   // safe now: the worker can no longer fire the callback
    // lock releases last, AFTER the worker is joined.
  }
};

// Extract "prompt" from a legacy /v1/completions body into a chat body so both
// endpoints share one code path. Accepts a string or an array of strings; a
// tokenized (numeric/object) prompt is rejected rather than silently dropped.
json completions_body_to_chat(const json& body) {
  if (body.contains("messages"))
    throw std::runtime_error(
        "send either 'prompt' (completions) or 'messages' (chat), not both");
  std::string prompt;
  if (body.contains("prompt")) {
    const json& p = body["prompt"];
    if (p.is_string()) {
      prompt = p.get<std::string>();
    } else if (p.is_array()) {
      for (const auto& part : p) {
        if (!part.is_string())
          throw std::runtime_error(
              "tokenized ('prompt' as non-string array) is not supported");
        prompt += part.get<std::string>();
      }
    } else {
      throw std::runtime_error("'prompt' must be a string or array of strings");
    }
  }
  json chat = body;
  chat.erase("prompt");
  chat["messages"] = json::array({json{{"role", "user"}, {"content", prompt}}});
  return chat;
}

// Core handler. `req_body` is already-parsed and chat-shaped. Throws nlohmann
// exceptions on malformed fields; handle_chat catches them and returns 400.
void handle_chat_parsed(const json& body, httplib::Response& res) {
  bool stream = body.value("stream", false);
  std::string id = now_id();
  int64_t created = unix_now();

  if (!stream) {
    std::lock_guard<std::mutex> lk(g_infer_mutex);
    std::string err;
    auto ctx = build_ctx(body, &err);
    if (!ctx) {
      res.status = 400;
      res.set_content(json{{"error", {{"message", err}}}}.dump(),
                      "application/json");
      return;
    }
    LiteRtLmJsonResponse* resp = litert_lm_conversation_send_message(
        ctx->conv, ctx->final_message_json.c_str(), nullptr, nullptr);
    if (!resp) {
      res.status = 500;
      res.set_content(
          R"({"error":{"message":"engine returned no response"}})",
          "application/json");
      return;
    }
    std::string text = extract_text(litert_lm_json_response_get_string(resp));
    litert_lm_json_response_delete(resp);
    int pt = count_tokens(ctx->prompt_text);
    int ct = count_tokens(text);
    res.set_content(
        make_completion_json(id, created, text, pt, ct, "stop").dump(),
        "application/json");
    return;
  }

  // Streaming path. A StreamHold owns the engine lock + conversation + stream
  // state and guarantees teardown order (cancel+join the worker BEFORE releasing
  // the engine), so the engine stays single-user and there is no callback UAF
  // however the HTTP layer drops the stream.
  auto hold = std::make_shared<StreamHold>();
  hold->lock = std::unique_lock<std::mutex>(g_infer_mutex);
  std::string err;
  auto ctx_raw = build_ctx(body, &err);
  if (!ctx_raw) {
    res.status = 400;
    res.set_content(json{{"error", {{"message", err}}}}.dump(),
                    "application/json");
    return;  // ~StreamHold releases the lock (no conversation started).
  }
  hold->ctx = std::move(ctx_raw);
  hold->st = std::make_shared<StreamState>();

  int rc = litert_lm_conversation_send_message_stream(
      hold->ctx->conv, hold->ctx->final_message_json.c_str(), nullptr, nullptr,
      stream_callback, hold->st.get());
  if (rc != 0) {
    res.status = 500;
    res.set_content(R"({"error":{"message":"failed to start stream"}})",
                    "application/json");
    return;  // ~StreamHold cancels + joins + releases.
  }

  auto sent_role = std::make_shared<bool>(false);
  auto done = std::make_shared<bool>(false);

  res.set_chunked_content_provider(
      "text/event-stream",
      [id, created, hold, sent_role, done](
          size_t /*offset*/, httplib::DataSink& sink) -> bool {
        if (*done) return false;
        StreamState* st = hold->st.get();

        // End the stream (optionally with an error frame). The engine cancel +
        // worker join + mutex release happen in ~StreamHold when the HTTP layer
        // drops this provider (right after we return false), in the one safe
        // order; we also cancel here so a departed client stops the box now
        // rather than at teardown. cancel is idempotent.
        auto stop = [&](const std::string& err_message) -> bool {
          litert_lm_conversation_cancel_process(hold->ctx->conv);
          if (!err_message.empty()) {
            // Best-effort error frame; must not throw (it can be called from the
            // catch block below, and sse_error_frame allocates). A failure here
            // just means the client does not get the error text — the stream
            // still ends cleanly and ~StreamHold still tears down safely.
            try {
              std::string ev = sse_error_frame(id, created, err_message);
              sink.write(ev.data(), ev.size());
            } catch (...) {
            }
          }
          sink.done();
          *done = true;
          return false;
        };

        // The provider runs AFTER handle_chat's try/catch has unwound, so any
        // throw here (json::dump under memory pressure, etc.) must be contained
        // as an SSE error frame — it cannot become a clean 500 once the
        // text/event-stream response is already on the wire.
        try {
          if (!*sent_role) {
            *sent_role = true;
            json first{
                {"id", id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", g_model_id},
                {"choices", json::array({json{
                                {"index", 0},
                                {"delta", json{{"role", "assistant"}}},
                                {"finish_reason", nullptr}}})}};
            std::string ev = "data: " + first.dump() + "\n\n";
            if (!sink.write(ev.data(), ev.size())) return stop("");
          }

          std::unique_lock<std::mutex> lk(st->m);
          // Bounded wait: a stalled engine (no token, no is_final) must not park
          // here forever holding the engine and wedging every other request.
          // Wake on an error too: the engine may report one with neither a chunk
          // nor is_final, and it must be surfaced below rather than mistimed as a
          // stall for the full idle window.
          if (!st->cv.wait_for(lk, kStreamIdleTimeout,
                               [&] {
                                 return !st->chunks.empty() || st->finished ||
                                        !st->error.empty();
                               })) {
            lk.unlock();
            return stop("inference stalled: no output within timeout");
          }
          while (!st->chunks.empty()) {
            std::string raw = std::move(st->chunks.front());
            st->chunks.pop_front();
            lk.unlock();
            // Each streamed chunk is a full LiteRT message JSON; pull its text.
            std::string piece = extract_text(raw.c_str());
            json chunk{
                {"id", id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", g_model_id},
                {"choices", json::array({json{
                                {"index", 0},
                                {"delta", json{{"content", piece}}},
                                {"finish_reason", nullptr}}})}};
            std::string ev = "data: " + chunk.dump() + "\n\n";
            if (!sink.write(ev.data(), ev.size())) return stop("");
            lk.lock();
          }
          // An engine error may arrive with or without is_final; surface it
          // instead of emitting a false "stop".
          if (!st->error.empty()) {
            std::string msg = st->error;
            lk.unlock();
            return stop(msg);
          }
          if (st->finished) {
            lk.unlock();
            json fin{
                {"id", id},
                {"object", "chat.completion.chunk"},
                {"created", created},
                {"model", g_model_id},
                {"choices", json::array({json{{"index", 0},
                                              {"delta", json::object()},
                                              {"finish_reason", "stop"}}})}};
            std::string ev = "data: " + fin.dump() + "\n\ndata: [DONE]\n\n";
            if (!sink.write(ev.data(), ev.size())) return stop("");
            sink.done();
            *done = true;
            return false;  // ~StreamHold joins the worker + releases the engine.
          }
          return true;
        } catch (const std::exception& e) {
          return stop(std::string("stream error: ") + e.what());
        }
      });
}

void handle_chat(const httplib::Request& req, httplib::Response& res) {
  json body;
  try {
    body = json::parse(req.body);
  } catch (...) {
    res.status = 400;
    res.set_content(R"({"error":{"message":"invalid JSON body"}})",
                    "application/json");
    return;
  }
  // value()/get() on present-but-wrong-type fields throw; a malformed but
  // syntactically-valid body must return 400, never escape to std::terminate.
  try {
    handle_chat_parsed(body, res);
  } catch (const std::exception& e) {
    res.status = 400;
    res.set_content(
        json{{"error", {{"message", std::string("bad request: ") + e.what()}}}}
            .dump(),
        "application/json");
  }
}

void handle_completions(const httplib::Request& req, httplib::Response& res) {
  json body;
  try {
    body = json::parse(req.body);
  } catch (...) {
    res.status = 400;
    res.set_content(R"({"error":{"message":"invalid JSON body"}})",
                    "application/json");
    return;
  }
  try {
    handle_chat_parsed(completions_body_to_chat(body), res);
  } catch (const std::exception& e) {
    res.status = 400;
    res.set_content(
        json{{"error", {{"message", std::string("bad request: ") + e.what()}}}}
            .dump(),
        "application/json");
  }
}

}  // namespace

int main(int argc, char** argv) {
  // Bind loopback by default: this is a backend the lemonade forwarder reaches
  // on the same host. Exposing an unauthenticated inference API to the LAN of a
  // gateway is not a default we want; --host can widen it deliberately.
  std::string model_path, host = "127.0.0.1";
  int port = 8080;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      return (i + 1 < argc) ? argv[++i] : std::string();
    };
    if (a == "--model")
      model_path = next();
    else if (a == "--port")
      port = std::atoi(next().c_str());
    else if (a == "--host")
      host = next();
    else if (a == "--model-id")
      g_model_id = next();
    else if (a == "-h" || a == "--help") {
      std::printf(
          "Usage: litert-lm-server --model <path> [--port N] [--host H] "
          "[--model-id ID]\n");
      return 0;
    }
  }
  if (model_path.empty()) {
    std::fprintf(stderr, "error: --model <path> is required\n");
    return 2;
  }
  if (g_model_id == "litert-lm") {
    auto slash = model_path.find_last_of('/');
    g_model_id =
        (slash == std::string::npos) ? model_path : model_path.substr(slash + 1);
  }

  litert_lm_set_min_log_level(3);  // WARNING+
  std::fprintf(stderr, "[litert-lm-server] loading model: %s\n",
               model_path.c_str());
  LiteRtLmEngineSettings* settings =
      litert_lm_engine_settings_create(model_path.c_str(), "cpu", nullptr, nullptr);
  if (!settings) {
    std::fprintf(stderr, "error: failed to create engine settings\n");
    return 1;
  }
  g_engine = litert_lm_engine_create(settings);
  litert_lm_engine_settings_delete(settings);
  if (!g_engine) {
    std::fprintf(stderr, "error: failed to create engine\n");
    return 1;
  }
  std::fprintf(stderr, "[litert-lm-server] engine ready (model_id=%s)\n",
               g_model_id.c_str());

  httplib::Server svr;

  svr.set_payload_max_length(kMaxPayloadBytes);

  // Backstop: any exception escaping a handler returns 500 instead of
  // terminating the process. handle_chat/handle_completions catch their own
  // json errors as 400; this covers anything else.
  svr.set_exception_handler(
      [](const httplib::Request&, httplib::Response& res, std::exception_ptr ep) {
        std::string msg = "internal error";
        try {
          std::rethrow_exception(ep);
        } catch (const std::exception& e) {
          msg = e.what();
        } catch (...) {
        }
        res.status = 500;
        res.set_content(json{{"error", {{"message", msg}}}}.dump(),
                        "application/json");
      });

  svr.Get("/health", [](const httplib::Request&, httplib::Response& res) {
    res.set_content(R"({"status":"ok"})", "application/json");
  });

  auto models_handler = [](const httplib::Request&, httplib::Response& res) {
    json j{{"object", "list"},
           {"data", json::array({json{{"id", g_model_id},
                                      {"object", "model"},
                                      {"created", unix_now()},
                                      {"owned_by", "litert-lm"}}})}};
    res.set_content(j.dump(), "application/json");
  };
  svr.Get("/v1/models", models_handler);
  svr.Get("/models", models_handler);

  svr.Post("/v1/chat/completions", handle_chat);
  svr.Post("/chat/completions", handle_chat);
  svr.Post("/v1/completions", handle_completions);
  svr.Post("/completions", handle_completions);

  std::fprintf(stderr, "[litert-lm-server] listening on %s:%d\n", host.c_str(),
               port);
  if (!svr.listen(host.c_str(), port)) {
    std::fprintf(stderr, "error: failed to bind %s:%d\n", host.c_str(), port);
    return 1;
  }
  litert_lm_engine_delete(g_engine);
  return 0;
}
