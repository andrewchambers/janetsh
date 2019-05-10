(import shlib :prefix "")

# This file is the main implementation of janetsh.
# The best reference I have found so far is here [1].


(var is-interactive nil)

# Stores the last saved tmodes of the shell.
# Set and restored when running jobs in the foreground.
(var shell-tmodes nil)

# All current jobs under control of the shell.
(var jobs nil)

# Mapping of pid to process tables.
(var pid2proc nil)


(defn- set-interactive-and-job-signal-handlers
  [handler]
  (signal SIGINT  handler)
  (signal SIGQUIT handler)
  (signal SIGTSTP handler)
  (signal SIGTTIN handler)
  (signal SIGTTOU handler))

# See here [2] for an explanation of what this function accomplishes
# and why. Init should be called before job control functions are used.
(defn init
  [&opt is-subshell]
  (set is-interactive (isatty STDIN_FILENO))
  (set jobs @[])
  (set pid2proc @{})
  (when (and is-interactive (not is-subshell))
  	(var shell-pgid (getpgrp))
    (while (not= (tcgetpgrp STDIN_FILENO) shell-pgid)
      (set shell-pgid (getpgrp))
      (kill (- shell-pgid SIGTTIN)))
    (set-interactive-and-job-signal-handlers SIG_IGN)
    (let [shell-pid (getpid)]
      (setpgid shell-pid shell-pid)
      (tcsetpgrp STDIN_FILENO shell-pgid))
    (set shell-tmodes (tcgetattr STDIN_FILENO)))
  nil)

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
    :status nil    # Last status returned from waitpid.
    :exit-code nil # Exit code of the process when it has exited.
    :stopped false # If the process has been stopped (Ctrl-Z).
   })

(defn update-proc-status
  [p status]
  (put p :status status)
  (put p :stopped (WIFSTOPPED status))
  (put p :exit-code
    (if (WIFEXITED status)
      (WEXITSTATUS status)
      (if (WIFSIGNALED status)
        127))))

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
   in the job. Returns nil if any job has not exited."
  [j]
  (reduce
    (fn [code p]
      (and
        code
        (p :exit-code)
        (if (zero? code)
          (p :exit-code)
          code)))
    0 (j :procs)))

(defn job-complete?
  [j]
  (number? (job-exit-code j)))

(defn- continue-job
  [j]
  (each p (j :procs)
    (put p :stopped false))
  (kill (- (j :pgid)) SIGCONT))

(defn wait-for-job
  [j]
  (while (not (or (job-stopped? j) (job-complete? j)))
    (let [[pid status] (waitpid (- (j :pgid)) WUNTRACED)]
      (update-pid-status pid status))))

(defn update-all-jobs-status
  []
  (each j jobs
    (when (not (job-complete? j))
      (try
        (while true
          (let [[pid status] (waitpid (- (j :pgid)) (bor WUNTRACED WNOHANG))]
            (when (= pid 0) (break))
            (update-pid-status pid status)))
        ([err]
          (when (not= ECHILD (dyn :errno))
            (error err)))))))

(defn terminate-job
  [j]
   (when (not (job-complete? j))
      (each p (j :procs)
        (kill (p :pid) SIGTERM))
      (wait-for-job j)))

(defn terminate-all-jobs
  []
  (each j jobs (terminate-job j)))

(defn prune-complete-jobs
  []
  (update-all-jobs-status)
  (set jobs (filter (complement job-complete?) jobs))
  (set pid2proc @{})
  (each j jobs
    (each p (j :procs)
      (put pid2proc (p :pid) p)))
  jobs)

(defn make-job-fg
  [j]
  (when (not is-interactive)
    (error "cannot move job to foreground in non-interactive."))
  (set shell-tmodes (tcgetattr STDIN_FILENO))
  (when (j :tmodes)
    (tcsetattr STDIN_FILENO TCSADRAIN (j :tmodes)))
  (tcsetpgrp STDIN_FILENO (j :pgid))
  (when (job-stopped? j)
    (continue-job j))
  (wait-for-job j)
  (tcsetpgrp STDIN_FILENO (getpgrp))
  (put j :tmodes (tcgetattr STDIN_FILENO))
  (tcsetattr STDIN_FILENO TCSADRAIN shell-tmodes))

(defn make-job-bg
  [j]
  (when (job-stopped? j)
    (continue-job j)))

(defn- exec-proc
  [args redirs]
  (try
    (do 
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
  ([e]
    (file/write stderr (string e))
    (file/flush stderr)
    (os/exit 1))))

(defn launch-job
  [j in-foreground]
  
  # Flush output files before we fork.
  (file/flush stdout)
  (file/flush stderr)

  (array/push jobs j)
  
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

      # As mentioned in [3] we must set the right pgid
      # in both the parent and the child to avoid a race
      # condition when we start waiting on the process group.
      (defn 
        post-fork [pid] 
        (when (not (j :pgid))
          (put j :pgid pid))
        (setpgid pid (j :pgid))
        (put proc :pid pid)
        (put pid2proc pid proc))

      (var pid (fork))
      
      (when (zero? pid)
        (set pid (getpid))
        
        # TODO XXX.
        # We want to discard any buffered input after we fork.
        # There is currently no way to do this. (fpurge stdin)
        
        (post-fork pid)

        (when is-interactive
          (when in-foreground
            (tcsetpgrp STDIN_FILENO (j :pgid))))

        (set-interactive-and-job-signal-handlers SIG_DFL)

        (def redirs (array/concat @[
            @[STDIN_FILENO  "<"  infd]
            @[STDOUT_FILENO ">" outfd]
            @[STDERR_FILENO ">"  errfd]] (proc :redirs)))
        
        (exec-proc (proc :args) redirs)
        (error "unreachable"))

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
  (prune-complete-jobs))

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
  ~{
    :fd (replace (<- (some (range "09"))) ,scan-number)
    :redir
      (* (+ :fd (<- "")) (<- (+ ">>" ">" "<")) (+ (* "&" :fd ) (<- (any 1))))
    :main (replace :redir ,norm-redir)
   })

(def- redir-parser (peg/compile redir-grammar))

(defn parse-redir
  [r]
  (let [match (peg/match redir-parser (string r))]
    (when match (first match))))

(defn- form-to-arg
  [f]
  (match (type f)
    :tuple
      (if (and # Somewhat ugly special case. Check for the quasiquote so we can use ~/ nicely.
            (= (first f) 'quasiquote)
            (= (length f) 2)
            (= (type (f 1)) :symbol))
        (wordexp (string "~" (f 1)))
        f)
    :keyword
      (wordexp (string f))
    :symbol
      (wordexp (string f))
    (string f)))

(defn- arg-symbol?
  [f]
  (match (type f)
    :symbol true
    :keyword true
    false))

(defn parse-builtin
  [f]
  (when-let [bi (first f)]
    (cond
      (= 'cd bi) (tuple 'os/cd ;(flatten (map form-to-arg (tuple/slice f 1))))
      (= 'clear bi) '(sh/clear)
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

(defn expand
  [s]
  (wordexp s))

(defn clear
  []
  (ln/clear-screen))

(defn do-lines
  [f]
  (fn []
    (while true
      (if-let [ln (file/read stdin :line)]
        (f ln)
        (break)))))

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
        (sh/launch-job j ,fg)
        (when ,fg
          (let [rc (sh/job-exit-code j)]
            (when (not= 0 rc)
              (error rc)))))))))

(defmacro $?
  [& forms]
  (if-let [builtin (parse-builtin forms)]
    builtin
    (let [[j fg] (parse-job ;forms)]
    ~(do
      (let [j ,j]
        (sh/launch-job j ,fg)
        (when ,fg
          (sh/job-exit-code j)))))))

(defmacro $$
  [& forms]
  (if-let [builtin (parse-builtin forms)]
    builtin
    (let [[j fg] (parse-job ;forms)]
      ~(sh/job-output ,j))))

# References
# [1] https://www.gnu.org/software/libc/manual/html_node/Implementing-a-Shell.html
# [2] https://www.gnu.org/software/libc/manual/html_node/Initializing-the-Shell.html#Initializing-the-Shell
# [3] https://www.gnu.org/software/libc/manual/html_node/Launching-Jobs.html#Launching-Jobs