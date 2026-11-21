// SPDX-License-Identifier: GPL-3.0-or-later
// The driver runs each phase in a NEW process against a disposable user
// dictionary. No foreground input source, editor, or actual input history.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <rime/key_table.h>

static RimeApi *api;
static RimeSessionId session;

static void type(const char *code) {
  api->clear_composition(session);
  while (*code) assert(api->process_key(session, *code++, 0));
}
static void first(const char *code, const char *expected) {
  type(code);
  RIME_STRUCT(RimeContext, ctx);
  assert(api->get_context(session, &ctx));
  assert(ctx.menu.num_candidates > 0);
  const char *actual = ctx.menu.candidates[0].text;
  if (strcmp(actual, expected)) fprintf(stderr, "%s: expected %s, found %s\n", code, expected, actual);
  assert(!strcmp(actual, expected));
  api->free_context(&ctx);
}
static void pick(const char *word) {
  RimeCandidateListIterator cursor = {0};
  assert(api->candidate_list_begin(session, &cursor));
  int index = -1;
  while (api->candidate_list_next(&cursor)) {
    if (!strcmp(cursor.candidate.text, word)) { index = cursor.index; break; }
  }
  api->candidate_list_end(&cursor);
  assert(index >= 0 && api->select_candidate(session, index));
}
static void committed(const char *text) {
  RIME_STRUCT(RimeCommit, item);
  assert(api->get_commit(session, &item));
  assert(!strcmp(item.text, text));
  api->free_commit(&item);
}

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  // Only the test driver's private profile is accepted.
  if (strncmp(argv[2], "/private/tmp/learning-memory.", strlen("/private/tmp/learning-memory."))) return 2;
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1]; traits.user_data_dir = argv[2];
  traits.log_dir = argv[2]; traits.app_name = "rime.memory-check"; traits.min_log_level = 2;
  api = rime_get_api(); api->setup(&traits); api->initialize(NULL);
  session = api->create_session();
  assert(api->select_schema(session, "learning_flypy"));
  if (!strcmp(argv[3], "seed")) {
    first("goke", "果壳"); pick("过客"); committed("过客");
  } else if (!strcmp(argv[3], "cancel")) {
    first("goke", "过客"); first("xkvz", "行舟");
    type("xkvzbuuu"); pick("星"); assert(api->process_key(session, XK_Escape, 0));
  } else if (!strcmp(argv[3], "teach")) {
    first("xkvz", "行舟");
    type("xkvzbuuu"); pick("星"); pick("舟"); pick("部署"); committed("星舟部署");
  } else if (!strcmp(argv[3], "recall")) {
    first("xkvzbuuu", "星舟部署"); first("xkvz", "星舟");
    first("xkvzceui", "星舟测试"); first("xkvzdocker", "星舟docker"); first("goke", "过客");
    first("woysdockerbuuu", "我用docker部署"); first("ma", "吗");
  } else if (!strcmp(argv[3], "forget")) {
    first("xkvz", "星舟"); assert(api->process_key(session, XK_Delete, kShiftMask));
  } else if (!strcmp(argv[3], "check-forgot")) {
    first("xkvz", "行舟"); first("goke", "过客");
  } else return 2;
  api->clear_composition(session);
  api->destroy_session(session); api->finalize();
  printf("PASS %s\n", argv[3]); return 0;
}
