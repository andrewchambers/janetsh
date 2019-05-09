(import unixy :prefix "")

(def is-interactive (isatty STDIN_FILENO))

# Stores the last saved tmodes of the shell.
# Set and restored when running jobs in the foreground.
(var shell-tmodes nil)

# All current jobs under control of the shell.
(var @[] jobs)

# Mapping of pid to process tables.
(var pid2proc @{})


(defn- set-interactive-and-job-signal-handlers
  [handler]
  (signal SIGINT  handler)
  (signal SIGQUIT handler)
  (signal SIGTSTP handler)
  (signal SIGTTIN handler)
  (signal SIGTTOU handler))

(defn init
  []
  (when is-interactive
  	(var shell-pgid nil)
    # loop until we are in the foreground
    # the purpose of this code is so subshells
    # play well with the parent.
    (while (not= (tcgetpgrp STDIN_FILENO) (getpgrp))
      (set shell-pgid (getpgrp))
      (kill (- shell-pgid SIGTTIN)))
    (set-interactive-and-job-signal-handlers SIG_IGN)
    (let [shell-pid (getpid)]
      (setpgid shell-pid shell-pid)
      (tcsetpgrp STDIN_FILENO shell-pgid))
    (set shell-tmodes (tcgetattr STDIN_FILENO))))

(defn- new-job []
  @{
    :procs @[]
    :tmodes nil
    :pgid nil
   })

(defn- new-proc []
  @{
    :args @[]
    :redirs @[]
    :status nil
    :exit-code nil
    :stopped false
   })

(defn update-proc-status
  [p status]
  (set p :status status)
  (set p :stopped (WIFSTOPPED status))
  (set p :exit-code
    (if (WIFEXITED status)
      (WEXITSTATUS status)
      (if (WIFSIGNALED status)
        127))))

(defn update-pid-status
  [pid status]
    (when-let [p (pid2proc pid)]
      (update-proc-status p status)))

(defn job-stopped?
  [j]
  (reduce (fn [s p] (and s (p :stopped))) true (j :procs)))

(defn job-exit-code
  [j]
  (reduce
    (fn [code p] (if (zero? code) (p :exit-code) code))
    0 (j :procs)))
