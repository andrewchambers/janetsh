(import shlib :prefix "")

# This file is the main implementation of janetsh.
# The best reference I have found so far is here [1].

(var initialized false)

(var on-tty nil)

# Stores the last saved tmodes of the shell.
# Set and restored when running jobs in the foreground.
(var shell-tmodes nil)

# All current jobs under control of the shell.
(var jobs nil)

# Mapping of pid to process tables.
(var pid2proc nil)

# Extremely unsafe table. Don't touch this unless
# you know what you are doing.
#
# It holds the pid cleanup table for signals and an atexit
# handler and must only ever be updated after signals are disabled.
#
# It is even a janet implementation detail that READING
# a table doesn't modify it's structure, as such it is
# better to not even read this table without cleanup
# signals disabled...
(var unsafe-child-cleanup-array nil)

# Reentrancy counter for shell signals...
(var disable-cleanup-signals-count 0)

(defn- disable-cleanup-signals []
  (when (= 1 (++ disable-cleanup-signals-count))
    (mask-cleanup-signals SIG_BLOCK)))

(defn- enable-cleanup-signals []
  (when (= 0 (-- disable-cleanup-signals-count))
    (mask-cleanup-signals SIG_UNBLOCK))
  (when (< disable-cleanup-signals-count 0)
    (error "BUG: unbalanced signal enable/disable pair.")))

(defn- force-enable-cleanup-signals []
  (set disable-cleanup-signals-count 0)
  (mask-cleanup-signals SIG_UNBLOCK))

(defn init
  [&opt is-subshell]
  (when initialized
    (break))

  (set jobs @[])
  (set pid2proc @{})
  
  (disable-cleanup-signals)
  (set unsafe-child-cleanup-array @[])
  (register-unsafe-child-cleanup-array unsafe-child-cleanup-array)
  (enable-cleanup-signals)
  (register-atexit-cleanup)
  
  (set on-tty
    (and (isatty STDIN_FILENO)
         (= (tcgetpgrp STDIN_FILENO) (getpgrp))))
  (if is-subshell
    (set-noninteractive-signal-handlers)
    (set-interactive-signal-handlers))
  
  (set initialized true)
  nil)

(defn deinit
  []
  (when (not initialized)
    (break))
  (set initialized false)
  (reset-signal-handlers)
  (force-enable-cleanup-signals))

(defn- new-job []
  # Don't manpulate job tables directly, instead
  # use provided job management functions.
  @{
    :procs @[]    # A list of processes in the pipeline.
    :tmodes nil   # Saved terminal modes of the job if it was stopped.
    :pgid nil     # Job process group id.
    :cleanup true # Cleanup on job on exit.
   })

(defn- new-proc []
  @{
    :args @[]         # A list of arguments used to start the proc. 
    :env @{}          # New environment variables to set in proc.
    :redirs @[]       # A list of 3 tuples. [fd|path ">"|"<"|">>" fd|path] 
    :pid nil          # PID of process after it has been started.
    :termsig nil      # Signal used to terminate job.
    :exit-code nil    # Exit code of the process when it has exited, or 127 on signal exit.
    :stopped false    # If the process has been stopped (Ctrl-Z).
    :stopsig nil      # Signal that stopped the process.
   })

(defn update-proc-status
  [p status]
  (when (WIFSTOPPED status)
    (put p :stopped true)
    (put p :stopsig (WSTOPSIG status)))
  (when (WIFCONTINUED status)
    (put p :stopped false))
  (when (WIFEXITED status)
    (put p :exit-code (WEXITSTATUS status)))
  (when (WIFSIGNALED status)
    (put p :exit-code 129)
    (put p :termsig (WTERMSIG status))))

(defn update-pid-status
  "Given a pid and status, update the corresponding process
   in the global job/process tables with the new status."
  [pid status]
  (when-let [p (pid2proc pid)]
    (update-proc-status p status)))

(defn job-stopped?
  [j]
  (reduce (fn [s p] (and s (p :stopped))) true (j :procs)))

(defn job-exit-code
  "Return the exit code of the first failed process
   in the job. Ignores processes that failed due to SIGPIPE
   unless they are the last process in the pipeline.
   Returns nil if any job has not exited."
  [j]
  (def last-proc (last (j :procs)))
  (reduce
    (fn [code p]
      (and
        code
        (p :exit-code)
        (if (and (zero? code)
                 (or (not= (p :termsig) SIGPIPE) (= p last-proc)))
          (p :exit-code)
          code)))
    0 (j :procs)))

(defn job-complete?
  "Returns true when all processes in the job have exited."
  [j]
  (number? (job-exit-code j)))

(defn signal-job 
  [j sig]
  (try
    (kill (- (j :pgid)) sig)
  ([e] 
    (when (not= ESRCH (dyn :errno))
      (error e)))))

(defn- continue-job
  [j]
  (each p (j :procs)
    (put p :stopped false))
  (signal-job j SIGCONT))

(defn- mark-missing-job-as-complete
  [j]
  (each p (j :procs)
    (when (not (p :exit-code))
      # Last ditch effort to wait for PID (not pgid).
      # of missing process so we don't leak processes.
      # One example where this may happen is if the child
      # dies before it has a chance to call setpgid.
      (try 
        (waitpid (p :pid) (bor WUNTRACED WNOHANG))
        ([e] nil))
      (put p :exit-code 129))))

(defn wait-for-job
  [j]
  (try
    (while (not (or (job-stopped? j) (job-complete? j)))
      (let [[pid status] (waitpid (- (j :pgid)) (bor WUNTRACED WCONTINUED))]
        (update-pid-status pid status)))
  ([err]
    (if (= ECHILD (dyn :errno))
      (mark-missing-job-as-complete j)
      (error err))))
  j)

(defn update-job-status
  "Poll and update the status and exit codes of the job without blocking."
  [j]
  (try
    (while true
      (let [[pid status] (waitpid (- (j :pgid)) (bor WUNTRACED WNOHANG WCONTINUED))]
        (when (= pid 0) (break))
        (update-pid-status pid status)))
    ([err]
      (if (= ECHILD (dyn :errno))
        (mark-missing-job-as-complete j)
        (error err)))))

(defn update-all-jobs-status
  "Poll all active jobs and update their status information without blocking."
  []
  (each j jobs
    (when (not (job-complete? j))
      (update-job-status j)))
  jobs)

(defn terminate-job
  [j]
  (when (not (job-complete? j))
    (signal-job j SIGTERM)
    (wait-for-job j))
  j)

(defn job-from-pgid [pgid]
  (find (fn [j] (= (j :pgid)) pgid) jobs))

(defn terminate-all-jobs
  []
  (each j jobs (terminate-job j)))

(defn- rebuild-unsafe-child-cleanup-array
  []
  (var new-unsafe-child-cleanup-array @[])
  (disable-cleanup-signals)
  (each j jobs
    (when (j :cleanup)
      (each p (j :procs)
        (array/push new-unsafe-child-cleanup-array (p :pid)))))
  (set unsafe-child-cleanup-array new-unsafe-child-cleanup-array)
  (register-unsafe-child-cleanup-array unsafe-child-cleanup-array)
  (enable-cleanup-signals))

(defn prune-complete-jobs
  "Poll active jobs without blocking and then remove completed jobs
   from the jobs table."
  []
  (update-all-jobs-status)
  (set jobs (filter (complement job-complete?) jobs))
  (set pid2proc @{})
  
  (rebuild-unsafe-child-cleanup-array)

  (each j jobs
    (each p (j :procs)
      (put pid2proc (p :pid) p)))
  jobs)

(defn disown-job
  [j]
  (put j :cleanup false)
  (rebuild-unsafe-child-cleanup-array))

(defn fg-job
  "Shift job into the foreground and give it control of the terminal."
  [j]
  (when (not on-tty)
    (error "cannot move job to foreground when not on a tty."))
  (set shell-tmodes (tcgetattr STDIN_FILENO))
  (when (j :tmodes)
    (tcsetattr STDIN_FILENO TCSADRAIN (j :tmodes)))
  (tcsetpgrp STDIN_FILENO (j :pgid))
  (update-job-status j)
  (when (job-stopped? j)
    (continue-job j))
  (wait-for-job j)
  (tcsetpgrp STDIN_FILENO (getpgrp))
  (put j :tmodes (tcgetattr STDIN_FILENO))
  (tcsetattr STDIN_FILENO TCSADRAIN shell-tmodes)
  (job-exit-code j))

(defn bg-job
  "Resume a stopped job in the background."
  [j]
  (when (job-stopped? j)
    (continue-job j)))

(defn- exec-proc
  [args env redirs]
  
  (each ev (pairs env)
    (os/setenv (ev 0) (ev 1)))

  (each r redirs
    (var sinkfd (get r 0))
    (var src  (get r 2))
    (var srcfd nil)
    
    (when (or (tuple? src) (array? src))
      (when (not= (length src) 1)
        (error "redirect target tuple has more than one member."))
      (set src (first src)))

    (match (type src)
      :string
        (set srcfd (match (r 1)
          ">"  (open src (bor O_WRONLY O_CREAT O_TRUNC)  (bor S_IWUSR S_IRUSR S_IRGRP))
          ">>" (open src (bor O_WRONLY O_CREAT O_APPEND) (bor S_IWUSR S_IRUSR S_IRGRP))
          "<"  (open src (bor O_RDONLY) 0)
          (error "unhandled redirect")))
      :number
        (set srcfd src)
      (error "unsupported redirect target type"))
    
    (dup2 srcfd sinkfd))
  
  (defn- run-subshell-proc [f args]
    # This is a subshell inside a job.
    # Clear jobs, they aren't the subshell's jobs.
    # The subshells should be able to run jobs
    # of it's own if it wants to.
    (init true)
    
    (var rc 0)
    (try
      (f args)
      ([e]
        (set rc 1)
        (file/write stderr (string "error: " e "\n"))))
    
    (file/flush stdout)
    (file/flush stderr)
    (os/exit rc))

  (var entry-point (first args))
  (cond
    (function? entry-point)
      (run-subshell-proc entry-point (tuple/slice args 1))
    (table? entry-point)
      (run-subshell-proc (fn [eargs] (:post-fork entry-point eargs)) (tuple/slice args 1))
    (exec ;(map string args))))
    
(defn launch-job
  [j in-foreground]
  (when (not initialized)
    (error "uninitialized janetsh runtime."))
  (try
    (do
      # Disable cleanup signals
      # so our cleanup code doesn't
      # miss any pid's and doesn't
      # interrupt us setting up the pgid.
      (disable-cleanup-signals)
      
      # Flush output files before we fork.
      (file/flush stdout)
      (file/flush stderr)
      
      (def procs (j :procs))
      (var pipes nil)
      (var infd  STDIN_FILENO)
      (var outfd STDOUT_FILENO)
      (var errfd STDERR_FILENO)

      (for i 0 (length procs)
        (let 
          [proc (get procs i)
           has-next (not= i (dec (length procs)))]
          
          (if has-next
            (do
              (set pipes (pipe))
              (set outfd (pipes 1)))
            (do
              (set pipes nil)
              (set outfd STDOUT_FILENO)))

          (when (table? (first (proc :args)))
            (:pre-fork (first (proc :args)) (tuple/slice (proc :args) 1)))

          # As mentioned in [2] we must set the right pgid
          # in both the parent and the child to avoid a race
          # condition when we start waiting on the process group.
          (defn 
            post-fork [pid]
            (when (not (j :pgid))
              (put j :pgid pid))
            (try
              (setpgid pid (j :pgid))
            ([e]
              # EACCES If the parent is so slow
              # the child has run execv, we will
              # get this error. If we get this
              # error in the parent,
              # it means the child itself
              # has done setpgid, so it is safe to
              # ignore. We should never get
              # this error in the child according to
              # the conditions in the man pages.
              #
              # ESRCH can happen on BSD's (at least) 
              # under a similar situation. The child has 
              # died before we got here in a race with our fork.
              # It seems we can ignore that error.
              #
              # The worse case of ignoring this error seem to
              # be that this child was really killed before it called setpgid.
              # This should make a missing job which we will detect later.
              (when (and (not= (dyn :errno) EACCES)
                         (not= (dyn :errno) ESRCH))
                (error e))))
            (put proc :pid pid)
            (put pid2proc pid proc)
            (when (and on-tty in-foreground)
              (tcsetpgrp STDIN_FILENO (j :pgid))))

          (var pid (fork))
          
          (when (zero? pid)
            (try # Prevent a child from ever returning after an error.
              (do
                (set pid (getpid))
                
                # TODO XXX.
                # We want to discard any buffered input after we fork.
                # There is currently no way to do this. (fpurge stdin)
                (post-fork pid)

                (when pipes
                  (close (pipes 0)))

                # The child doesn't want our signal handlers
                # or any other stuff like job control.
                (deinit)

                (def redirs (array/concat @[
                    @[STDIN_FILENO  "<"  infd]
                    @[STDOUT_FILENO ">" outfd]
                    @[STDERR_FILENO ">"  errfd]] (proc :redirs)))
                
                (exec-proc (proc :args) (proc :env) redirs)
                (error "unreachable"))
            ([e] (do (file/write stderr (string e "\n")) (os/exit 1)))))

          (post-fork pid)

          (when (not= infd STDIN_FILENO)
            (close infd))
          (when (not= outfd STDOUT_FILENO)
            (close outfd))
          (when pipes
            (set infd (pipes 0)))))

      (array/push jobs j)
      # Since we inserted a new job
      # we chould prune the old jobs
      # add configure the cleanup array.
      (prune-complete-jobs)
      (enable-cleanup-signals)
      
      (if in-foreground
        (if on-tty
          (fg-job j)
          (wait-for-job j))
        (bg-job j))
      j)
    ([e] # This error is unrecoverable to ensure things like running out of FD's
         # don't leave the terminal in an undefined state.
      (file/write stderr (string "unrecoverable internal error: " e)) 
      (file/flush stderr)
      (os/exit 1))))

(defn- job-output-rc [j]
  (let [[fd-a fd-b] (pipe)
        output (buffer/new 1024)
        readbuf (buffer/new-filled 1024)] 
    (array/push ((last (j :procs)) :redirs) @[STDOUT_FILENO ">" fd-b])
    (launch-job j false)
    (close fd-b)
    (while true
      (let [n (read fd-a readbuf)]
        (if (= 0 n)
          (break)
          (buffer/push-string output (buffer/slice readbuf 0 n)))))
    (close fd-a)
    (wait-for-job j)
    [(string output) (job-exit-code j)]))

(defn- job-output [j]
  (let [[output rc] (job-output-rc j)]
    (if (= 0 rc)
      output
      (error (string "job failed! (status=" rc ")")))))

(defn- get-home
  []
  (or (os/getenv "HOME") ""))

(defn- expand-getenv 
  [s]
  (or 
    (match s
      "PWD" (os/cwd)
      (os/getenv s))
    ""))

(defn- tildhome
  [s] 
  (string (get-home) "/"))

(def- expand-parser (peg/compile
  ~{
    :env-esc (replace (<- "$$") "$")
    :env-seg (* "$" (replace
                      (+ (* "{" (<- (some (* (not "}") 1)) ) "}" )
                         (<- (some (+ "_" (range "az") (range "AZ"))))) ,expand-getenv))
    :lit-seg (<- (some (* (not "$") 1)))
    :main (* (? (replace (<- "~/") ,tildhome)) (any (choice :env-esc :env-seg :lit-seg)))
  }))

(defn expand
  "Perform shell expansion on the provided string.
  Will expand a leading tild, environment variables
  in the form '$VAR '${VAR}' and path globs such
  as '*.txt'. Returns an array with the expansion."
  [s]
  (var s s)
  (when (= s "~") (set s (get-home)))
  (glob (string ;(peg/match expand-parser s))))

(defn- norm-redir
  [& r]
  (var @[a b c] r)
  (when (and (= "" a) (= "<" b))
    (set a 0))
  (when (and (= "" a) (or (= ">" b) (= ">>" b)))
    (set a 1))
  (when (= c "")
    (set c nil))
  (when (string? c)
    (set c (tuple first (tuple expand c))))
  @[a b c])

(def- redir-parser (peg/compile
  ~{
    :fd (replace (<- (some (range "09"))) ,scan-number)
    :redir
      (* (+ :fd (<- "")) (<- (+ ">>" ">" "<")) (+ (* "&" :fd ) (<- (any 1))))
    :main (replace :redir ,norm-redir)
  }))

(defn- parse-redir
  [r]
  (let [match (peg/match redir-parser r)]
    (when match (first match))))

(def- env-var-parser (peg/compile
  ~{
    :main (sequence (capture (some (sequence (not "=") 1))) "=" (capture (any 1)))
  }))

(defn- parse-env-var
  [s]
  (peg/match env-var-parser s))

(defn- arg-symbol?
  [f]
  (match (type f)
    :symbol true
    :keyword true
    false))

(defn- form-to-arg
  "Convert a form to a form that is
   shell expanded at runtime."
  [f]
  (match (type f)
    :tuple
      (if (= (tuple/type f) :brackets)
        f
        (if (and # Somewhat ugly special case. Check for the quasiquote so we can use ~/ nicely.
              (= (first f) 'quasiquote)
              (= (length f) 2)
              (= (type (f 1)) :symbol))
          (tuple expand (string "~" (f 1)))
          f))
    :keyword
      (tuple expand (string f))
    :symbol
      (tuple expand (string f))
    :number
      (string f)
    :boolean
      (string f)
    :string
      f
    :array
      f
    :nil
      "nil"
    (error (string "unsupported shell argument type: " (type f)))))

# Table of builtin name to constructor
# function for builtin objects.
#
# A builtin has two methods:
# :pre-fork [self args]
# :post-fork [self args]
(var *builtins* nil) # intialized after builtin definitions.

(defn- replace-builtins
  [args]
  (when-let [bi (*builtins* (first args))]
    (put args 0 (bi)))
  args)

# Stores defined aliases in the form @{"ls" ["ls" "-la"]}
# Can be changed directly, or with the helper macro.
(var *aliases* @{})

(defmacro alias
  [& cmds]
  "Install an alias while following normal process argument expansion.
   Example:  (sh/alias ls ls -la)
   "
  ~(if-let [expanded (map string (flatten ,(map form-to-arg cmds)))
            name (first expanded)
            rest (tuple/slice expanded 1)
            _ (not (empty? rest))]
      (put ',*aliases* name rest)
      (error "alias expects at least two expanded arguments")))

(defn unalias [name]
  (put *aliases* name nil))

(defn- replace-aliases
  [args]
  (if-let [alias (*aliases* (first args))]
    (array/concat (array ;alias) (array/slice args 1))
    args))

(defn parse-job
  [& forms]
  (var state :env)
  (var job (new-job))
  (var proc (new-proc))
  (var fg true)
  (var pending-redir nil)
  (var pending-env-assign nil)
  
  (defn handle-proc-form
    [f]
    (cond
      (= '| f) (do 
                 (array/push (job :procs) proc)
                 (set state :env)
                 (set proc (new-proc)))
      (= '& f) (do (set fg false) (set state :done))
      
      (let [redir (parse-redir (string f))]
        (if (and (arg-symbol? f) redir)
          (if (redir 2)
            (array/push (proc :redirs) redir)
            (do (set pending-redir redir) (set state :redir)))
          (array/push (proc :args) (form-to-arg f))))))
  
  (each f forms
    (match state
      :env
        (if-let [ev (and (symbol? f) (parse-env-var (string f)))
                 [e v] ev]
          (if (empty? v)
            (do (set pending-env-assign e)
                (set state :env2))
            (put (proc :env) e v))
          (do
            (set state :proc)
            (handle-proc-form f)))
      :env2
         (do
          (put (proc :env) pending-env-assign 
            (if (arg-symbol? f)
              (string f)
              (tuple string f)))
          (set state :env))
      :proc 
        (handle-proc-form f)
      :redir
        (do
          (put pending-redir 2 (form-to-arg f))
          (array/push (proc :redirs) pending-redir)
          (set state :proc))
      :done (error "unexpected input after command end")
      (error "bad parser state")))
  (when (= state :redir)
    (error "redirection missing target"))
  (when (< 0 (length (proc :args)))
      (array/push (job :procs) proc))
  (when (empty? (job :procs))
    (error "empty shell job"))
  
  (each proc (job :procs)
    (put proc :args
      (tuple replace-builtins
        (tuple replace-aliases (tuple flatten (proc :args))))))
  [job fg])

(defn do-lines
  "Return a function that calls f on each line of stdin.\n\n
   Primarily useful for subshells."
  [f]
  (fn [args]
    (while true
      (if-let [ln (file/read stdin :line)]
        (f ln)
        (break)))))

(defn out-lines
  "Return a function that calls f on each line of stdin.\n\n
   writing the result to stdout if it is not nil.\n\n 
   
   Example: \n\n

   (sh/$ echo \"a\\nb\\nc\" | (out-lines string/ascii-upper))"
  [f]
  (do-lines 
    (fn [ln]
      (when-let [xln (f ln)]
        (file/write stdout xln)))))

(def escape identity)

(defmacro $
  "Execute a shell job (pipeline) in the foreground or background with 
   a set of optional redirections for each process.\n\n
  
   If the job is a foreground job, this macro waits till the 
   job either stops, or exits. If the job exits with an error
   status the job raises an error.\n\n

   If the job is a background job, this macro returns a the job table entry 
   that can be used to manage the job.\n\n

   Jobs take the exit code of the first failed process in the job with one
   exception, processes that terminate due to SIGPIPE do not count towards the 
   job exit code.\n\n

   Symbols inside the $ are treated more or less like a traditional shell with 
   some exceptions:\n\n
   
   - Janet keywords can be used to escape janet symbol rules. \n\n
   - A Janet call inside a job are treated as janet code janet mode.
     Escaped janet code can return either a function in the place of a process name, strings, 
     or nested arrays of strings which are flattened on invocation. \n\n
   - The quasiquote operator ~ is handled specially for convenience in simple cases, but 
    for complex cases string quoting may be needed. \n\n
   
   Examples:\n\n

   (sh/$ ls *.txt | cat )\n
   (sh/$ ls @[\"/\" [\"/usr\"]])\n
   (sh/$ ls (os/cwd))
   (sh/$ ls (os/cwd) >/dev/null :2>'1 )\n
   (sh/$ (fn [args] (pp args)) hello world | cat )\n
   (sh/$ \"ls\" (sh/expand \"*.txt\"))\n
   (sh/$ sleep (+ 1 5) &)\n"

  [& forms]
  (let [[j fg] (parse-job ;forms)]
  ~(do
    (let [j ,j]
      (,launch-job j ,fg)
      (if ,fg
        (let [rc (,job-exit-code j)]
          (when (not= 0 rc)
            (error rc)))
        j)))))

(defn- fn-$?
  [forms]
    (let [[j fg] (parse-job ;forms)]
    ~(do
      (let [j ,j]
        (,launch-job j ,fg)
        (if ,fg
          (,job-exit-code j)
          j)))))

(defmacro $?
  "Execute a shell job (pipeline) in the foreground or background with 
   a set of optional redirections for each process returning the job exit code.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (fn-$? forms))

(defmacro $??
  "Execute a shell job (pipeline) in the foreground or background with 
   a set of optional redirections for each process returning true or false
   depending on whether the job was a success.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (let [rc-forms (fn-$? forms)]
    ~(= 0 ,rc-forms)))

(defn- fn-$$
  [forms]
    (let [[j fg] (parse-job ;forms)]
      (when (not fg)
        (error "$$ does not support background jobs"))
      ~(,job-output ,j)))

(defmacro $$
  "Execute a shell job (pipeline) in the foreground with 
   a set of optional redirections for each process returning the job stdout as a string.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (fn-$$ forms))

(defmacro $$_
  "Execute a shell job (pipeline) in the foreground with 
   a set of optional redirections for each process returning
   the job stdout as a trimmed string.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (let [out-forms (fn-$$ forms)]
    ~(,string/trimr ,out-forms)))

(defn- fn-$$?
  [forms]
    (let [[j fg] (parse-job ;forms)]
      (when (not fg)
        (error "$$? does not support background jobs"))
      ~(,job-output-rc ,j)))

(defmacro $$?
  "Execute a shell job (pipeline) in the foreground with 
   a set of optional redirections for each process returning
   a tuple of stdout and the job exit code.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (fn-$$? forms))

(defmacro $$_?
  "Execute a shell job (pipeline) in the foreground with 
   a set of optional redirections for each process returning
   a tuple of the trimmed stdout and the job exit code.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  ~(let [[out rc] ,(fn-$$? forms)]
    [(,string/trimr out) rc]))

(defn in-env*
  "Function form of in-env."
  [env-vars f]
  (let [old-vars @{}]
    (each k (keys env-vars)
      (def new-v (env-vars k))
      (def old-v (os/getenv k))
      (when (string? new-v)
        (put old-vars k (if old-v old-v :unset))
        (os/setenv k new-v)))
    (var haderr false)
    (var err nil)
    (var result nil)
    (try
      (set result (f))
      ([e] (set haderr true) (set err e)))
    (each k (keys old-vars)
      (def old-v (old-vars k))
      (os/setenv k (if (= old-v :unset) nil old-v)))
    (when haderr
      (error err))
    result))

(defmacro in-env
  "Run forms with os environment variables set
   to the keys and values of env-vars. The os environment
   is restored before returning the result."
  [env-vars & forms]
  (tuple in-env* env-vars (tuple 'fn [] ;forms)))

(defn- make-cd-builtin
  []
  @{
    :pre-fork
      (fn builtin-cd
        [self args]
        (try
          (os/cd ;
            (if (empty? args)
               [(or (os/getenv "HOME") (error "cd: HOME not set"))]
               args))
          ([e] (put self :error e))))
    :post-fork
      (fn builtin-cd
        [self args]
        (when (self :error)
          (error (self :error))))
    :error nil
  })

(defn- make-clear-builtin
  []
  @{
    :pre-fork
      (fn builtin-clear [self args] nil)
    :post-fork
      (fn builtin-clear
        [self args]
        (file/write stdout "\x1b[H\x1b[2J"))
  })

(defn- make-exit-builtin
  []
  @{
    :pre-fork
      (fn builtin-exit
        [self args]
        (try
          (do
            (when (empty? args)
              (os/exit 0))
            (if-let [code (and (= (length args) 1) (scan-number (first args)))]
              (os/exit code)
              (error "expected: exit NUM")))
        ([e] (put self :error e))))
    :post-fork
      (fn builtin-exit
        [self args]
        (error (self :error)))
    :error nil
  })

(defn- make-alias-builtin
  []
  @{
    :pre-fork
      (fn builtin-alias [self args]
        (var fst (first args))
        (cond
           (= fst "-h") nil
           (empty? args) nil
           (and (= (length args) 1) (= (*aliases* fst) nil))
             (put self :error (string "alias: " fst " not found"))
           (= (length args) 1) nil

           # put specific alias
           (when-let [alias fst
                      cmd (tuple/slice args 1)]
             (put *aliases* alias cmd))))
    :post-fork
      (fn builtin-alias [self args]
        (var fst (first args))
        (cond
          (self :error) (error (self :error))
          (= fst "-h")
            (file/write stdout "alias name [commands]\n")
          (empty? args)
            (each [alias cmd] (pairs *aliases*)
              (file/write stdout
                (string "alias " alias " " (string/join cmd " ") "\n")))
          (= (length args) 1)
            (when-let [alias fst
                       cmd (*aliases* alias)]
              (file/write stdout
                (string "alias " alias " " (string/join cmd " ") "\n")))))
    :error nil
  })

(defn- make-unalias-builtin
  []
  (def help "unalias [-a] name [name ...]")
  @{
    :pre-fork
      (fn builtin-unalias [self args]
        (var fst (first args))
        (case fst
          nil nil
          "-h" nil
          "-a"
            # unalias all
            (each alias (keys *aliases*)
              (put *aliases* alias nil))

          (each alias args
            (if (*aliases* alias)
              (put *aliases* alias nil)
              (put self :error (string "unalias: " fst " not found"))))))
    :post-fork
      (fn builtin-unalias [self args]
        (var fst (first args))
        (when (self :error)
          (error (self :error)))
        (case fst
          nil
            (print help)
          "-h"
            (print help)))
    :error nil
  })

(set *builtins* @{
  "clear" make-clear-builtin
  "cd" make-cd-builtin
  "alias" make-alias-builtin
  "unalias" make-unalias-builtin
  "exit" make-exit-builtin
})

# References
# [1] https://www.gnu.org/software/libc/manual/html_node/Implementing-a-Shell.html
# [2] https://www.gnu.org/software/libc/manual/html_node/Launching-Jobs.html#Launching-Jobs
