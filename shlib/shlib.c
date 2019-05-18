#define _DEFAULT_SOURCE
#include <janet.h>
#include <unistd.h>
#include <assert.h>
#include <termios.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <glob.h>
#include "shlib_linenoise.h"

#define panic_errno(NAME, e) \
  do { \
    janet_setdyn("errno", janet_wrap_integer(e));\
    janet_panicf(NAME ": %s (errno=%d)", strerror(e), e);\
  } while(0)

static Janet jfork_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  pid_t pid = fork();
  if (pid == -1)
    panic_errno("fork", errno);
  return janet_wrap_integer(pid);
}

static Janet isatty_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  int fd = janet_getnumber(argv, 0);
  int r = isatty(fd);
  if (r == 0 && errno != ENOTTY)
    panic_errno("fork", errno);
  return janet_wrap_boolean(r);
}

static Janet getpid_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  pid_t pid = getpid();
  if (pid == -1)
    panic_errno("getpid", errno);
  return janet_wrap_integer(pid);
}

static Janet setpgid_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  pid_t pid = setpgid((pid_t)janet_getnumber(argv, 0), (pid_t)janet_getnumber(argv, 1));
  if (pid == -1)
     panic_errno("setpgid", errno);
  return janet_wrap_nil();
}

static Janet getpgrp_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  pid_t pid = getpgrp();
  if (pid == -1)
    panic_errno("getpgrp", errno);
  return janet_wrap_integer(pid);
}

static Janet tcgetpgrp_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  pid_t pid = tcgetpgrp((pid_t)janet_getnumber(argv, 0));
  if (pid == -1)
    panic_errno("tcgetpgrp", errno);
  return janet_wrap_integer(pid);
}

static Janet tcsetpgrp_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  pid_t pid = tcsetpgrp((int)janet_getnumber(argv, 0), (pid_t)janet_getnumber(argv, 1));
  if (pid == -1)
    panic_errno("tcsetpgrp", errno);
  return janet_wrap_nil();
}

static Janet kill_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  pid_t pid = kill((pid_t)janet_getnumber(argv, 0), (int)janet_getnumber(argv, 1));
  if (pid == -1)
    panic_errno("kill", errno);
  return janet_wrap_integer(pid);
}

static Janet exec(int32_t argc, Janet *argv) {
    janet_arity(argc, 1, -1);
    const char **child_argv = malloc(sizeof(char *) * (argc + 1));
    if (!child_argv)
      abort();
    for (int32_t i = 0; i < argc; i++)
        child_argv[i] = janet_getcstring(argv, i);
    child_argv[argc] = NULL;
    execvp(child_argv[0], (char **)child_argv);
    int e = errno;
    free(child_argv);
    panic_errno("execvp", e);
    abort();
}

static Janet dup2_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  
  if (dup2((int)janet_getnumber(argv, 0), (int)janet_getnumber(argv, 1)) == -1)
     panic_errno("dup2", errno);
  
  return janet_wrap_nil();
}

static Janet pipe_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);

  int mypipe[2];
  if (pipe(mypipe) < 0)
    panic_errno("pipe", errno);

  Janet *t = janet_tuple_begin(2);
  t[0] = janet_wrap_number((int)mypipe[0]);
  t[1] = janet_wrap_number((int)mypipe[1]);
  return janet_wrap_tuple(janet_tuple_end(t));
}

static Janet open_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 3);
  int fd = open(janet_getcstring(argv, 0), janet_getinteger(argv, 1), janet_getinteger(argv, 2));
  if (fd == -1)
    panic_errno("open", errno);
    
  return janet_wrap_integer(fd);
}

static Janet read_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  int fd = janet_getinteger(argv, 0);
  JanetBuffer *buf = janet_getbuffer(argv, 1);
  int n = read(fd, buf->data, buf->count);
  if (fd == -1)
    panic_errno("read", errno);
    
  return janet_wrap_integer(n);
}

static Janet close_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  if (close((int)janet_getnumber(argv, 0)) == -1)
    panic_errno("close", errno);
  return janet_wrap_nil();
}

static Janet waitpid_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  int status = 0;
  pid_t pid = waitpid(janet_getinteger(argv, 0), &status, janet_getinteger(argv, 1));
  if (pid == -1)
    panic_errno("waitpid", errno);
  
  Janet *t = janet_tuple_begin(2);
  t[0] = janet_wrap_number(pid);
  t[1] = janet_wrap_number(status);
  return janet_wrap_tuple(janet_tuple_end(t));
}

#define STATUS_FUNC_INT(X) static Janet X##_(int32_t argc, Janet *argv) { \
  janet_fixarity(argc, 1); \
  return janet_wrap_integer(X(janet_getinteger(argv, 0))); \
}

STATUS_FUNC_INT(WEXITSTATUS);
STATUS_FUNC_INT(WTERMSIG);
STATUS_FUNC_INT(WSTOPSIG);

#define STATUS_FUNC_BOOL(X) static Janet X##_(int32_t argc, Janet *argv) { \
  janet_fixarity(argc, 1); \
  return janet_wrap_boolean(X(janet_getinteger(argv, 0))); \
}

STATUS_FUNC_BOOL(WIFEXITED);
STATUS_FUNC_BOOL(WIFCONTINUED);
STATUS_FUNC_BOOL(WIFSIGNALED);
STATUS_FUNC_BOOL(WIFSTOPPED);

static Janet glob_(int32_t argc, Janet *argv) {
  glob_t g;

  janet_fixarity(argc, 1);
  const char *pattern = janet_getcstring(argv, 0);
  if (glob(pattern, GLOB_ERR|GLOB_NOCHECK, NULL, &g) != 0)
    panic_errno("glob", errno);

  char **p = g.gl_pathv;
  JanetArray *a = janet_array(g.gl_pathc);

  for (int i = 0; i < g.gl_pathc; i++)
     janet_array_push(a, janet_cstringv(p[i]));
  
  globfree(&g);

  return janet_wrap_array(a);
}

static struct JanetAbstractType Termios_jt = {
    "shlib.termios",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
};

static Janet tcgetattr_(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    struct termios *t = janet_abstract(&Termios_jt, sizeof(struct termios));
    if(tcgetattr(janet_getinteger(argv, 0), t) == -1)
        janet_panic("tcgetattr error");
    return janet_wrap_abstract(t);
}

static Janet tcsetattr_(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 3);
    int fd = janet_getinteger(argv, 0);
    int actions = janet_getinteger(argv, 1);
    struct termios *t = janet_getabstract(argv, 2, &Termios_jt);
    if(tcsetattr(fd, actions, t) == -1)
        janet_panic("tcsetattr error");
    return janet_wrap_nil();
}


static struct JanetAbstractType Completions_jt = {
    "shlib.completions",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
};

struct completions {
  int stale;
  linenoiseCompletions *lc;
};

static Janet shlib_linenoiseAddCompletion_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);

  struct completions *c = janet_getabstract(argv, 0, &Completions_jt);
  const char *line = janet_getcstring(argv, 1);
  if (!c->stale) {
    shlib_linenoiseAddCompletion(c->lc, line);
  }
  return janet_wrap_nil();
}


static JanetFunction *completion_janet_function = NULL;
static void shlib_linenoise_completion(const char *buf, linenoiseCompletions *lc) {
  if (!completion_janet_function)
    return;

  struct completions *c = janet_abstract(&Completions_jt, sizeof(struct completions));
  c->stale = 0;
  c->lc = lc;
  Janet out;
  JanetFiber *fiber = NULL;
  const int nargs = 2;
  Janet *args = janet_tuple_begin(nargs);
  args[0] = janet_cstringv(buf);
  args[1] = janet_wrap_abstract(c);
  janet_tuple_end(args);

  janet_gcroot(janet_wrap_tuple(args));
  janet_gcroot(janet_wrap_function(completion_janet_function));
  // We can't do anything with the status, if we panic we might
  // mess up linenoise. We don't need to do anything with out either.
  janet_pcall(completion_janet_function, nargs, args, &out, &fiber);
  
  janet_gcunroot(janet_wrap_tuple(args));
  janet_gcunroot(janet_wrap_function(completion_janet_function));
  c->stale = 1;
}

static Janet shlib_linenoise_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  // Setting this every time doesn't hurt much.
  // and may help if it is linked as a shared library.
  shlib_linenoiseSetCompletionCallback(shlib_linenoise_completion);
  // This won't be GC'd while argv is alive.
  completion_janet_function = janet_getfunction(argv, 1);
  char *ln = shlib_linenoise(janet_getcstring(argv, 0));
  if (!ln)
    return janet_wrap_nil();
  Janet jln = janet_cstringv(ln);
  shlib_linenoiseFree(ln);
  return jln;
}

static Janet shlib_linenoiseSetMultiLine_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  shlib_linenoiseSetMultiLine(janet_getboolean(argv, 0));
  return janet_wrap_nil();
}

static Janet shlib_linenoiseClearScreen_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  shlib_linenoiseClearScreen();
  return janet_wrap_nil();
}

static Janet shlib_linenoiseHistoryAdd_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  return janet_wrap_integer(shlib_linenoiseHistoryAdd(janet_getcstring(argv, 0)));
}

static Janet shlib_linenoiseHistorySetMaxLen_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  if (!shlib_linenoiseHistorySetMaxLen(janet_getinteger(argv, 0)))
    janet_panic("shlib_linenoiseHistorySetMaxLen: error");
  return janet_wrap_nil();
}

static Janet shlib_linenoiseHistorySave_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  if (shlib_linenoiseHistorySave(janet_getcstring(argv, 0)) != 0)
    janet_panic("shlib_linenoiseHistorySave: error");
  return janet_wrap_nil();
}

static Janet shlib_linenoiseHistoryLoad_(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  if (shlib_linenoiseHistoryLoad(janet_getcstring(argv, 0)) != 0)
    janet_panic("shlib_linenoiseHistoryLoad: error");
  return janet_wrap_nil();
}

static Janet reset_signal_handlers(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  struct sigaction act;
  memset(&act, 0, sizeof(act));
  act.sa_handler = SIG_DFL;
  if (  (sigaction(SIGINT,  &act, NULL) == -1)
     || (sigaction(SIGQUIT, &act, NULL) == -1)
     || (sigaction(SIGTSTP, &act, NULL) == -1)
     || (sigaction(SIGTTIN, &act, NULL) == -1)
     || (sigaction(SIGTTOU, &act, NULL) == -1)
     || (sigaction(SIGHUP,  &act, NULL) == -1)
     || (sigaction(SIGPIPE, &act, NULL) == -1)
     || (sigaction(SIGTERM, &act, NULL) == -1))
    janet_panic("signal_action: error");
  return janet_wrap_nil();
}

static Janet mask_cleanup_signals(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  int action = janet_getinteger(argv, 0);
  sigset_t block_mask;
  sigemptyset(&block_mask);
  sigaddset(&block_mask, SIGINT);
  sigaddset(&block_mask, SIGTERM);
  sigaddset(&block_mask, SIGHUP);
  if (sigprocmask(action, &block_mask, NULL) == -1) 
    janet_panic("sigprocmask: error");
  return janet_wrap_nil();
}

// WARNING Highly unsafe janet table.
// This depends on the fact the janet GC is non moving.
// We store a reference to this unsafe table, and (hopefully) guarantee
// it is not modified when signals are enabled.
//
// We should then should be able to *read* this table from
// the signal handler to get a list of children to cleanup.
static JanetArray *unsafe_child_array  = 0; 

static Janet register_unsafe_child_array(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  // We could root the table, but something would be going horribly
  // wrong before this is needed.
  unsafe_child_array = janet_getarray(argv, 0);
  return janet_wrap_nil();
}

static int cleanup_registered = 0;
static int pid_at_cleaup_registration = 0;

static void
signal_children (int signal) {
  // After a fork (subshell), we shouldn't try to signal, unless
  // the atexit cleanup has been re-registered.
  if (getpid() != pid_at_cleaup_registration)
    return;

  if (!unsafe_child_array)
    return;

  for (int i = 0; i < unsafe_child_array->count; i++) {
    int status;
    
    pid_t child = janet_unwrap_number(unsafe_child_array->data[i]);
    // Check if the child really is ours and if it is still alive.
    // This info may be stale so we double check here before sending
    // a signal.
    if (waitpid(child, &status, WNOHANG) == 0) {
      // This process was indeed our child.
      // The zero return confirms it is still alive

      // if the kill fails
      // there is not much we can do.
      kill(child, signal);
    }
  }
}

static void
wait_children () {
  if (!unsafe_child_array)
    return;

  for (int i = 0; i < unsafe_child_array->count; i++) {
    int status;
    pid_t child = janet_unwrap_number(unsafe_child_array->data[i]);
    // Can't do much when this fails.
    waitpid(child, &status, 0);
  }
}

static void
cleanup_children(void) {
  signal_children(SIGCONT);
  signal_children(SIGTERM);
  wait_children();
}

static void
cleanup_sig_handler (int signum)
{
  exit(1);
}

static Janet register_atexit_cleanup(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  pid_at_cleaup_registration = getpid();
  if (!cleanup_registered) {
    atexit(cleanup_children);
    cleanup_registered = 1;
  }
  
  return janet_wrap_nil();
}

static Janet set_interactive_signal_handlers(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);

  struct sigaction act;
  memset(&act, 0, sizeof(act));
  act.sa_handler = SIG_IGN;

  if ( (sigaction(SIGINT,  &act, NULL) == -1)
    || (sigaction(SIGQUIT, &act, NULL) == -1)
    || (sigaction(SIGTSTP, &act, NULL) == -1)
    || (sigaction(SIGTTIN, &act, NULL) == -1)
    || (sigaction(SIGTTOU, &act, NULL) == -1)
    || (sigaction(SIGPIPE, &act, NULL) == -1))
    janet_panic("sigaction: error");
  
  sigset_t block_mask;
  sigemptyset(&block_mask);
  sigaddset(&block_mask, SIGINT);
  sigaddset(&block_mask, SIGTERM);
  sigaddset(&block_mask, SIGHUP);
  act.sa_handler = cleanup_sig_handler;
  act.sa_mask = block_mask;

  if ( (sigaction(SIGTERM, &act, NULL) == -1)
    || (sigaction(SIGHUP, &act, NULL) == -1))
    janet_panic("sigaction: error");

  return janet_wrap_nil();
}


static Janet set_noninteractive_signal_handlers(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 0);
  reset_signal_handlers(argc, argv);

  struct sigaction act;
  memset(&act, 0, sizeof(act));
  act.sa_handler = SIG_IGN;

  if (sigaction(SIGPIPE, &act, NULL) == -1)
    janet_panic("sigaction: error");
  
  sigset_t block_mask;
  sigemptyset(&block_mask);
  sigaddset(&block_mask, SIGINT);
  sigaddset(&block_mask, SIGTERM);
  sigaddset(&block_mask, SIGHUP);
  memset(&act, 0, sizeof(act));
  
  act.sa_handler = cleanup_sig_handler;
  act.sa_mask = block_mask;

  if ( (sigaction(SIGTERM, &act, NULL) == -1)
    || (sigaction(SIGINT, &act, NULL) == -1)
    || (sigaction(SIGHUP, &act, NULL) == -1))
    janet_panic("sigaction: error");

  return janet_wrap_nil();
}

static const JanetReg cfuns[] = {
    // Unistd / Libc
    {"glob", glob_, NULL},
    {"fork", jfork_, NULL},
    {"exec", exec, NULL},
    {"isatty", isatty_, NULL},
    {"getpgrp", getpgrp_, NULL},
    {"getpid", getpid_, NULL},
    {"setpgid", setpgid_, NULL},
    {"tcgetpgrp", tcgetpgrp_, NULL},
    {"tcsetpgrp", tcsetpgrp_, NULL},
    {"dup2", dup2_, NULL},
    {"kill", kill_, NULL},
    {"open", open_, NULL},
    {"read", read_, NULL},
    {"close", close_, NULL},
    {"pipe", pipe_, NULL},
    {"waitpid", waitpid_, NULL},
    {"WIFEXITED", WIFEXITED_, NULL},
    {"WEXITSTATUS", WEXITSTATUS_, NULL},
    {"WIFSIGNALED", WIFSIGNALED_, NULL},
    {"WTERMSIG", WTERMSIG_, NULL},
    {"WSTOPSIG", WSTOPSIG_, NULL},
    {"WIFSTOPPED", WIFSTOPPED_, NULL},
    {"WIFCONTINUED", WIFCONTINUED_, NULL},
  
    // signal handlers
    {"register-unsafe-child-array", register_unsafe_child_array, NULL},
    {"mask-cleanup-signals", mask_cleanup_signals, NULL},
    {"reset-signal-handlers", reset_signal_handlers, NULL},
    {"set-interactive-signal-handlers", set_interactive_signal_handlers, NULL},
    {"set-noninteractive-signal-handlers", set_noninteractive_signal_handlers, NULL},
    {"register-atexit-cleanup", register_atexit_cleanup, NULL},
    
    // Termios    
    {"tcgetattr", tcgetattr_, NULL},
    {"tcsetattr", tcsetattr_, NULL},
    
    // linenoise - Slightly renamed to make it look nicer.
    {"ln/get-line", shlib_linenoise_, NULL},
    {"ln/add-completion", shlib_linenoiseAddCompletion_, NULL},
    {"ln/clear-screen", shlib_linenoiseClearScreen_, NULL},
    {"ln/set-multiline", shlib_linenoiseSetMultiLine_, NULL},
    {"ln/history-set-max-len", shlib_linenoiseHistorySetMaxLen_, NULL},
    {"ln/history-add", shlib_linenoiseHistoryAdd_, NULL},
    {"ln/history-load", shlib_linenoiseHistoryLoad_, NULL},
    {"ln/history-save", shlib_linenoiseHistorySave_, NULL},

    {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_cfuns(env, "shlib", cfuns);

    // This code assumes pid_t will fit in a janet number.
    assert(sizeof(int32_t) == sizeof(pid_t));

    #define DEF_CONSTANT_INT(X) janet_def(env, #X, janet_wrap_integer(X), NULL)
    DEF_CONSTANT_INT(STDIN_FILENO);
    DEF_CONSTANT_INT(STDERR_FILENO);
    DEF_CONSTANT_INT(STDOUT_FILENO);
    
    DEF_CONSTANT_INT(SIGINT);
    DEF_CONSTANT_INT(SIGCONT);
    DEF_CONSTANT_INT(SIGQUIT);
    DEF_CONSTANT_INT(SIGTSTP);
    DEF_CONSTANT_INT(SIGTTIN);
    DEF_CONSTANT_INT(SIGTTOU);
    DEF_CONSTANT_INT(SIGCHLD);
    DEF_CONSTANT_INT(SIGTERM);
    DEF_CONSTANT_INT(SIGPIPE);

    DEF_CONSTANT_INT(SIG_BLOCK);
    DEF_CONSTANT_INT(SIG_UNBLOCK);

    DEF_CONSTANT_INT(O_RDONLY);
    DEF_CONSTANT_INT(O_WRONLY);
    DEF_CONSTANT_INT(O_RDWR);
    DEF_CONSTANT_INT(O_APPEND);
    DEF_CONSTANT_INT(O_CREAT);
    DEF_CONSTANT_INT(O_TRUNC);

    DEF_CONSTANT_INT(S_IWUSR);
    DEF_CONSTANT_INT(S_IRUSR);
    DEF_CONSTANT_INT(S_IRGRP);

    DEF_CONSTANT_INT(TCSADRAIN);

    DEF_CONSTANT_INT(WUNTRACED);
    DEF_CONSTANT_INT(WNOHANG);
    DEF_CONSTANT_INT(WCONTINUED);

    DEF_CONSTANT_INT(ECHILD);
    DEF_CONSTANT_INT(ESRCH);
    DEF_CONSTANT_INT(EACCES);

    #undef DEF_CONSTANT_INT
}
