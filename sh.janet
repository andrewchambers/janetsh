(import shlib :prefix "")

# This file is the main implementation of janetsh.
# The best reference I have found so far is here [1].

(var initialized false)

(var is-interactive nil)

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
# It holds the pid cleanup table for signals
# and must only ever be updated after signals are disabled.
#
# It is even a janet implementation detail that READING
# a table doesn't modify it's structure, as such it is
# better to not even read this table without cleanup
# signals disabled...
(var unsafe-child-array nil)

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
  (set unsafe-child-array @[])
  (register-unsafe-child-array unsafe-child-array)
  (enable-cleanup-signals)

  (if (and (isatty STDIN_FILENO) (not is-subshell) (= (tcgetpgrp STDIN_FILENO) (getpgrp)))
    (do 
      (set is-interactive true)
      (set-interactive-signal-handlers))
    (do
      (set is-interactive false)
      (set-noninteractive-signal-handlers)))
  (set initialized true)
  nil)

(defn deinit
  []
  (when (not initialized)
    (break))
  (reset-signal-handlers)
  (set initialized false)
  (force-enable-cleanup-signals))

(defn- new-job []
  @{
    :procs @[]   # A list of processes in the pipeline.
    :tmodes nil  # Saved terminal modes of the job if it was stopped.
    :pgid nil    # Job process group id.
   })

(defn- new-proc []
  @{
    :args @[]      # A list of arguments used to start the proc. 
    :redirs @[]    # A list of 3 tuples. [fd|path ">"|"<"|">>" fd|path] 
    :pid nil       # PID of process after it has been started.
    :termsig nil   # Signal used to terminate job.
    :exit-code nil # Exit code of the process when it has exited, or 127 on signal exit.
    :stopped false # If the process has been stopped (Ctrl-Z).
    :stopsig nil   # Signal that stopped the process.
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
    (put p :exit-code 127)
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
      (put p :exit-code 129)))) # POSIX requires >128

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

(defn prune-complete-jobs
  []
  (update-all-jobs-status)
  (set jobs (filter (complement job-complete?) jobs))
  (set pid2proc @{})
  (var new-unsafe-child-array @[])
  
  (disable-cleanup-signals)
  (each j jobs
    (each p (j :procs)
      (put pid2proc (p :pid) p)
      (array/push new-unsafe-child-array (p :pid))))
  (set unsafe-child-array new-unsafe-child-array)
  (register-unsafe-child-array unsafe-child-array)
  (enable-cleanup-signals)
  jobs)

(defn make-job-fg
  [j]
  (when (not is-interactive)
    (error "cannot move job to foreground in non-interactive mode."))
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

(defn make-job-bg
  [j]
  (when (job-stopped? j)
    (continue-job j)))

(defn- exec-proc
  [args redirs]
  (each r redirs
    (var sinkfd (get r 0))
    (var srcfd  (get r 2))
    (when (string? srcfd)
      (set srcfd (match (r 1)
        ">"  (open srcfd (bor O_WRONLY O_CREAT O_TRUNC)  (bor S_IWUSR S_IRUSR S_IRGRP))
        ">>" (open srcfd (bor O_WRONLY O_CREAT O_APPEND) (bor S_IWUSR S_IRUSR S_IRGRP))
        "<"  (open srcfd (bor O_RDONLY) 0)
        (error "unhandled redirect"))))
      (dup2 srcfd sinkfd))
  (if (function? (first args))
    (do
      # This is a subshell inside a job.
      # Clear jobs, they aren't the subshell's jobs.
      # The subshells should be able to run jobs
      # of it's own if it wants to.
      (init true)

      ((first args) ;(tuple/slice args 1))
      (file/flush stdout)
      # Terminate any jobs the subshell started.
      (terminate-all-jobs)
      (os/exit 0))
    (do
      (exec ;(map string (flatten args)))
      (error "exec failed!"))))

(defn launch-job
  [j in-foreground]
  (when (not initialized)
    (error "uninitialized janetsh runtime."))
  (try
    (do
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
              (when (not= (dyn :errno) EACCES)
                (error e))))
            (put proc :pid pid)
            (put pid2proc pid proc)
            (when (and is-interactive in-foreground)
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
                # we need to reset them.
                (reset-signal-handlers)
                (force-enable-cleanup-signals)

                (def redirs (array/concat @[
                    @[STDIN_FILENO  "<"  infd]
                    @[STDOUT_FILENO ">" outfd]
                    @[STDERR_FILENO ">"  errfd]] (proc :redirs)))
                
                (exec-proc (proc :args) redirs)
                (error "unreachable"))
            ([e] (os/exit 1))))

          (post-fork pid)

          (when (not= infd STDIN_FILENO)
            (close infd))
          (when (not= outfd STDOUT_FILENO)
            (close outfd))
          (when pipes
            (set infd (pipes 0)))))

      (if in-foreground
        (if is-interactive
          (make-job-fg j)
          (wait-for-job j))
        (make-job-bg j))
      (array/push jobs j)
      (prune-complete-jobs)
      (enable-cleanup-signals)
      j)
    ([e] # This error is unrecoverable to ensure things like running out of FD's
         # don't leave the terminal in an undefined state.
      (file/write stderr "unrecoverable internal error:") 
      (file/write stderr (string e))
      (file/flush stderr)
      (terminate-all-jobs)
      (os/exit 1))))

(defn job-output [j]
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
    (if (= 0 (job-exit-code j))
      (string output)
      (error "job failed!"))))


(defn- norm-redir
  [& r]
  (var @[a b c] r)
  (when (and (= "" a) (= "<" b))
    (set a 0))
  (when (and (= "" a) (or (= ">" b) (= ">>" b)))
    (set a 1))
  (when (= c "")
    (set c nil))
  @[a b c])

(def- redir-grammar
  )

(def- redir-parser (peg/compile
  ~{
    :fd (replace (<- (some (range "09"))) ,scan-number)
    :redir
      (* (+ :fd (<- "")) (<- (+ ">>" ">" "<")) (+ (* "&" :fd ) (<- (any 1))))
    :main (replace :redir ,norm-redir)
  }))

(defn parse-redir
  [r]
  (let [match (peg/match redir-parser (string r))]
    (when match (first match))))

(defn- get-home
  []
  (os/getenv "HOME"))

(defn- expand-getenv 
  [s]
  (or 
    (match s
      "HOME" (get-home)
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
  [s]
  (var s s)
  (when (= s "~") (set s (get-home)))
  (glob (string ;(peg/match expand-parser s))))

(defn- form-to-arg
  [f]
  (match (type f)
    :tuple
      (if (and # Somewhat ugly special case. Check for the quasiquote so we can use ~/ nicely.
            (= (first f) 'quasiquote)
            (= (length f) 2)
            (= (type (f 1)) :symbol))
        (tuple expand (string "~" (f 1)))
        f)
    :keyword
      (tuple expand (string f))
    :symbol
      (tuple expand (string f))
    (string f)))

(defn- arg-symbol?
  [f]
  (match (type f)
    :symbol true
    :keyword true
    false))

(defn clear
  []
  (ln/clear-screen))

(defn parse-builtin
  [f]
  (when-let [bi (first f)]
    (cond
      (= 'cd bi) (tuple os/cd ;(flatten (map form-to-arg (tuple/slice f 1))))
      (= 'clear bi) (tuple clear)
      nil)))
  
(defn parse-job
  [& forms]
  (var state :proc)
  (var job (new-job))
  (var proc nil)
  (var fg true)
  (var pending-redir nil)
  (defn reset-proc [] 
    (set proc (new-proc)))
  (reset-proc)
  (each f forms
    (match state
      :proc 
        (cond
          (= '| f) (do 
                     (array/push (job :procs) proc)
                     (reset-proc))
          (= '& f) (do (set fg false) (set state :done))
          
          (do 
            (let [redir (parse-redir f)]
              (if (and (arg-symbol? f) redir)
                (if (redir 2)
                  (array/push (proc :redirs) redir)
                  (do (set pending-redir redir) (set state :redir)))
                (array/push (proc :args) (form-to-arg f))))))
      :redir (do
               (put pending-redir 2 (string f))
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
  [job fg])

(defn do-lines
  [f]
  (fn []
    (while true
      (let [ln (file/read stdin :line)]
        (if (not (empty? ln))
          (f ln)
          (break))))))

(defn out-lines
  [f]
  (do-lines 
    (fn [ln] (file/write stdout (f ln)))))

(defmacro $
  [& forms]
  (if-let [builtin (parse-builtin forms)]
    builtin
    (let [[j fg] (parse-job ;forms)]
    ~(do
      (let [j ,j]
        (,launch-job j ,fg)
        (if ,fg
          (let [rc (,job-exit-code j)]
            (when (not= 0 rc)
              (error rc)))
          j))))))

(defmacro $?
  [& forms]
  (if-let [builtin (parse-builtin forms)]
    builtin
    (let [[j fg] (parse-job ;forms)]
    ~(do
      (let [j ,j]
        (,launch-job j ,fg)
        (if ,fg
          (,job-exit-code j)
          j))))))

(defmacro $??
  [& forms]
  # This is probably my inexperience with macros
  # I'm not sure we should be calling macex. Make this
  # nicer...
  (let [rc-forms ($? ;forms)]
    ~(= 0 ,rc-forms)))

(defmacro $$
  [& forms]
  (if-let [builtin (parse-builtin forms)]
    builtin
    (let [[j fg] (parse-job ;forms)]
      (when (not fg)
        (error "$$ does not support background jobs"))
      ~(,job-output ,j))))

(defmacro $$_
  [& forms]
  (let [out-forms ($$ ;forms)]
    ~(string/trimr ,out-forms)))

# References
# [1] https://www.gnu.org/software/libc/manual/html_node/Implementing-a-Shell.html
# [2] https://www.gnu.org/software/libc/manual/html_node/Launching-Jobs.html#Launching-Jobs
