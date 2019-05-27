#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "readline.h"
#include "linenoise.h"

rl_completion_func_t *rl_attempted_completion_function = NULL;
int rl_attempted_completion_over = 0;
int rl_completion_append_character = 0;
char *rl_line_buffer = 0;

static void completion(const char *buf, linenoiseCompletions *lc) {
  if (!rl_attempted_completion_function)
    return;

  rl_line_buffer = (char *)buf;

  int len = strlen(buf);
  if (!len)
    return;

  int start = 0;
  for (int i = len; i >= 0; i--) {
    if (buf[i] == ' ') {
      break;
    }
    start = i;
  }

  char **matches = rl_attempted_completion_function(buf + start, start, len);
  if (matches) {
    for (int i = 0; matches[i]; i++) {
      // Add completion...
      size_t match_len = strlen(matches[i]);
      size_t completion_len = start + match_len;
      char *completion = malloc(completion_len + 1);
      if (!completion)
        abort();

      memcpy(completion, buf, start);
      memcpy(completion + start, matches[i], match_len);
      completion[completion_len] = 0;
      linenoiseAddCompletion(lc, completion);
      free(completion);
      free(matches[i]);
    }
    free(matches);
  }
}

char *readline(const char *prompt) {
  linenoiseSetCompletionCallback(completion);
  rl_attempted_completion_over = 0;
  return linenoise(prompt);
}
