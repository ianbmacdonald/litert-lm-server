// LiteRT-LM >= 0.19 C ABI compatibility: every C API call returns a
// LiteRtLmStatusCode and hands its result back through an out-parameter.
// server.cpp is written against the older pointer-returning calls, so these
// C++ overloads restore that shape: nullptr (or 0/false) on failure, with the
// library's thread-local error message logged. Calls whose parameters did not
// change (the setters, cancel, send_message_stream) need no overload: their
// status is discarded or, for send_message_stream, compared against 0
// (kLiteRtLmStatusOk).
#pragma once

#include <cstddef>
#include <cstdio>

#include "conversation.h"
#include "engine.h"
#include "error_reporter.h"

namespace litert_lm_compat {

inline bool ok(LiteRtLmStatusCode s, const char* what) {
  if (s == kLiteRtLmStatusOk) return true;
  const char* msg = litert_lm_get_last_error_message();
  std::fprintf(stderr, "[litert-lm-server] %s failed (status %d): %s\n", what,
               static_cast<int>(s), msg ? msg : "(no message)");
  return false;
}

template <typename T, typename F>
T* create(const char* what, F&& f) {
  T* out = nullptr;
  if (!ok(f(&out), what)) return nullptr;
  return out;
}

}  // namespace litert_lm_compat

inline LiteRtLmEngineSettings* litert_lm_engine_settings_create(
    const char* model_path, const char* backend, const char* vision_backend,
    const char* audio_backend) {
  return litert_lm_compat::create<LiteRtLmEngineSettings>(
      "engine_settings_create", [&](LiteRtLmEngineSettings** o) {
        return litert_lm_engine_settings_create(model_path, backend,
                                                vision_backend, audio_backend, o);
      });
}

inline LiteRtLmEngine* litert_lm_engine_create(const LiteRtLmEngineSettings* settings) {
  return litert_lm_compat::create<LiteRtLmEngine>(
      "engine_create",
      [&](LiteRtLmEngine** o) { return litert_lm_engine_create(settings, o); });
}

inline LiteRtLmTokenizeResult* litert_lm_engine_tokenize(LiteRtLmEngine* engine,
                                                         const char* text) {
  return litert_lm_compat::create<LiteRtLmTokenizeResult>(
      "engine_tokenize", [&](LiteRtLmTokenizeResult** o) {
        return litert_lm_engine_tokenize(engine, text, o);
      });
}

inline size_t litert_lm_tokenize_result_get_num_tokens(const LiteRtLmTokenizeResult* r) {
  size_t n = 0;
  if (!litert_lm_compat::ok(litert_lm_tokenize_result_get_num_tokens(r, &n),
                            "tokenize_result_get_num_tokens"))
    return 0;
  return n;
}

inline LiteRtLmSamplerParams* litert_lm_sampler_params_create(LiteRtLmSamplerType type) {
  return litert_lm_compat::create<LiteRtLmSamplerParams>(
      "sampler_params_create",
      [&](LiteRtLmSamplerParams** o) { return litert_lm_sampler_params_create(type, o); });
}

inline LiteRtLmSessionConfig* litert_lm_session_config_create() {
  return litert_lm_compat::create<LiteRtLmSessionConfig>(
      "session_config_create",
      [&](LiteRtLmSessionConfig** o) { return litert_lm_session_config_create(o); });
}

inline LiteRtLmConversationConfig* litert_lm_conversation_config_create() {
  return litert_lm_compat::create<LiteRtLmConversationConfig>(
      "conversation_config_create", [&](LiteRtLmConversationConfig** o) {
        return litert_lm_conversation_config_create(o);
      });
}

inline LiteRtLmConversation* litert_lm_conversation_create(
    LiteRtLmEngine* engine, LiteRtLmConversationConfig* config) {
  return litert_lm_compat::create<LiteRtLmConversation>(
      "conversation_create", [&](LiteRtLmConversation** o) {
        return litert_lm_conversation_create(engine, config, o);
      });
}

inline LiteRtLmJsonResponse* litert_lm_conversation_send_message(
    LiteRtLmConversation* conversation, const char* message_json,
    const char* extra_context, const LiteRtLmConversationOptionalArgs* args) {
  return litert_lm_compat::create<LiteRtLmJsonResponse>(
      "conversation_send_message", [&](LiteRtLmJsonResponse** o) {
        return litert_lm_conversation_send_message(conversation, message_json,
                                                   extra_context, args, o);
      });
}

inline const char* litert_lm_json_response_get_string(const LiteRtLmJsonResponse* r) {
  const char* s = nullptr;
  if (!litert_lm_compat::ok(litert_lm_json_response_get_string(r, &s),
                            "json_response_get_string"))
    return nullptr;
  return s;
}

// The stream-chunk accessors run on the engine's worker thread, inside the
// stream callback; a failure there reads as "no text / not final / no error".
inline const char* litert_lm_stream_chunk_get_text(const LiteRtLmStreamChunk* c) {
  const char* s = nullptr;
  return litert_lm_stream_chunk_get_text(c, &s) == kLiteRtLmStatusOk ? s : nullptr;
}

inline const char* litert_lm_stream_chunk_get_error(const LiteRtLmStreamChunk* c) {
  const char* s = nullptr;
  return litert_lm_stream_chunk_get_error(c, &s) == kLiteRtLmStatusOk ? s : nullptr;
}

inline bool litert_lm_stream_chunk_is_final(const LiteRtLmStreamChunk* c) {
  bool f = false;
  return litert_lm_stream_chunk_is_final(c, &f) == kLiteRtLmStatusOk && f;
}
