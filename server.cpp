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

  // Streaming path. Hold engine mutex for the whole inference lifetime; the
  // C ABI has no join, so a heap lock is released by the provider at is_final.
  auto lock = std::make_shared<std::unique_lock<std::mutex>>(g_infer_mutex);
  std::string err;
  auto ctx_raw = build_ctx(body, &err);
  if (!ctx_raw) {
    res.status = 400;
    res.set_content(json{{"error", {{"message", err}}}}.dump(),
                    "application/json");
    return;
  }
  std::shared_ptr<RequestCtx> ctx = std::move(ctx_raw);
  auto st = std::make_shared<StreamState>();

  int rc = litert_lm_conversation_send_message_stream(
      ctx->conv, ctx->final_message_json.c_str(), nullptr, nullptr,
      stream_callback, st.get());
  if (rc != 0) {
    res.status = 500;
    res.set_content(R"({"error":{"message":"failed to start stream"}})",
                    "application/json");
    return;
  }

  auto sent_role = std::make_shared<bool>(false);
  auto done = std::make_shared<bool>(false);

  res.set_chunked_content_provider(
      "text/event-stream",
      [id, created, st, ctx, lock, sent_role, done](
          size_t /*offset*/, httplib::DataSink& sink) -> bool {
        if (*done) return false;

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
          sink.write(ev.data(), ev.size());
        }

        std::unique_lock<std::mutex> lk(st->m);
        st->cv.wait(lk, [&] { return !st->chunks.empty() || st->finished; });
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
          sink.write(ev.data(), ev.size());
          lk.lock();
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
          sink.write(ev.data(), ev.size());
          sink.done();
          *done = true;
          if (lock->owns_lock()) lock->unlock();  // release engine for next req.
          return false;
        }
        return true;
      });
}

}  // namespace

int main(int argc, char** argv) {
  std::string model_path, host = "0.0.0.0";
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

  std::fprintf(stderr, "[litert-lm-server] listening on %s:%d\n", host.c_str(),
               port);
  if (!svr.listen(host.c_str(), port)) {
    std::fprintf(stderr, "error: failed to bind %s:%d\n", host.c_str(), port);
    return 1;
  }
  litert_lm_engine_delete(g_engine);
  return 0;
}
