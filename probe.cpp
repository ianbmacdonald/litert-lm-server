#include <cstdio>
#include "engine.h"

int main(int argc, char** argv) {
  const char* model = argv[1];
  litert_lm_set_min_log_level(2);
  LiteRtLmEngineSettings* settings =
      litert_lm_engine_settings_create(model, "cpu", nullptr, nullptr);
  printf("settings=%p\n", (void*)settings);
  LiteRtLmEngine* engine = litert_lm_engine_create(settings);
  printf("engine=%p\n", (void*)engine);
  if (!engine) return 1;

  LiteRtLmSamplerParams* sp =
      litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP);
  litert_lm_sampler_params_set_top_k(sp, 40);
  litert_lm_sampler_params_set_top_p(sp, 0.95f);
  litert_lm_sampler_params_set_temperature(sp, 1.0f);
  litert_lm_sampler_params_set_seed(sp, 42);
  LiteRtLmSessionConfig* sc = litert_lm_session_config_create();
  litert_lm_session_config_set_max_output_tokens(sc, 64);
  litert_lm_session_config_set_sampler_params(sc, sp);
  LiteRtLmConversationConfig* cc = litert_lm_conversation_config_create();
  litert_lm_conversation_config_set_session_config(cc, sc);
  LiteRtLmConversation* conv = litert_lm_conversation_create(engine, cc);
  printf("conv=%p\n", (void*)conv);

  const char* msg =
      "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"In one "
      "sentence, what is a router?\"}]}";
  LiteRtLmJsonResponse* resp =
      litert_lm_conversation_send_message(conv, msg, nullptr, nullptr);
  printf("resp=%p\n", (void*)resp);
  const char* s = litert_lm_json_response_get_string(resp);
  printf("=====RAW RESPONSE BEGIN=====\n%s\n=====RAW RESPONSE END=====\n",
         s ? s : "(null)");

  litert_lm_json_response_delete(resp);
  litert_lm_conversation_delete(conv);
  litert_lm_conversation_config_delete(cc);
  litert_lm_session_config_delete(sc);
  litert_lm_sampler_params_delete(sp);
  litert_lm_engine_delete(engine);
  litert_lm_engine_settings_delete(settings);
  return 0;
}
