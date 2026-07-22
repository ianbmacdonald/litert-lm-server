#include <cstdio>
#include <string>
#include "engine.h"

static LiteRtLmEngine* g_engine;

bool try_sys(const char* label, const char* sysjson) {
  LiteRtLmSamplerParams* sp = litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP);
  litert_lm_sampler_params_set_top_k(sp, 40);
  litert_lm_sampler_params_set_top_p(sp, 0.95f);
  litert_lm_sampler_params_set_temperature(sp, 1.0f);
  LiteRtLmSessionConfig* sc = litert_lm_session_config_create();
  litert_lm_session_config_set_max_output_tokens(sc, 8);
  litert_lm_session_config_set_sampler_params(sc, sp);
  LiteRtLmConversationConfig* cc = litert_lm_conversation_config_create();
  litert_lm_conversation_config_set_session_config(cc, sc);
  if (sysjson) litert_lm_conversation_config_set_system_message(cc, sysjson);
  LiteRtLmConversation* conv = litert_lm_conversation_create(g_engine, cc);
  const char* msg = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Hi\"}]}";
  LiteRtLmJsonResponse* resp = litert_lm_conversation_send_message(conv, msg, nullptr, nullptr);
  bool ok = resp != nullptr && litert_lm_json_response_get_string(resp) != nullptr;
  fprintf(stdout, "[%s] sys=%s => %s\n", label, sysjson ? sysjson : "(null)",
          ok ? "OK" : "NULL");
  if (resp) litert_lm_json_response_delete(resp);
  litert_lm_conversation_delete(conv);
  litert_lm_conversation_config_delete(cc);
  litert_lm_session_config_delete(sc);
  litert_lm_sampler_params_delete(sp);
  return ok;
}

int main(int argc, char** argv) {
  litert_lm_set_min_log_level(4);  // ERROR only
  LiteRtLmEngineSettings* s = litert_lm_engine_settings_create(argv[1], "cpu", nullptr, nullptr);
  g_engine = litert_lm_engine_create(s);
  if (!g_engine) { fprintf(stderr, "engine create failed\n"); return 1; }
  try_sys("1 raw-string", "You are terse.");
  try_sys("2 obj role+string", "{\"role\":\"system\",\"content\":\"You are terse.\"}");
  try_sys("3 obj content-only string", "{\"content\":\"You are terse.\"}");
  try_sys("4 obj content parts", "{\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"You are terse.\"}]}");
  try_sys("5 content-only parts", "{\"content\":[{\"type\":\"text\",\"text\":\"You are terse.\"}]}");
  try_sys("0 no-system(control)", nullptr);
  litert_lm_engine_delete(g_engine);
  litert_lm_engine_settings_delete(s);
  return 0;
}
