#include <stddef.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "history.h"
#include "linenoise.h"

void add_history(const char *ln) { linenoiseHistoryAdd(ln); }

int write_history(const char *path) {
  int err = linenoiseHistorySave(path);
  if (err)
    return EIO;
  return 0;
}

int read_history(const char *path) {
  int err = linenoiseHistoryLoad(path);
  if (err)
    return EIO;
  return 0;
}
