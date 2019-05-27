

typedef char **rl_completion_func_t(const char *, int, int);

extern rl_completion_func_t *rl_attempted_completion_function;
extern int rl_attempted_completion_over;
extern int rl_completion_append_character;
extern char *rl_line_buffer;

char *readline(const char *prompt);
