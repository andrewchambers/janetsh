(import sh)

(var tmux-job nil)

(var *tmux-sock* "./tmuxdemo.sock")

(defn launch-tmux
  []
  (set tmux-job (sh/$ tmux -S (identity *tmux-sock*) new -d &)))

(defn stop-tmux
  []
  (sh/$ tmux -S (identity *tmux-sock*) kill-server)
  (sh/wait-for-job tmux-job)
  (os/rm *tmux-sock*))

(def keymap @{"\n" "Enter" " " "Space"})

(defn char-to-key-name
  [c]
  (or (keymap c) c))

(defn send-keys
  [& keys]
  (sh/$ tmux -S (identity *tmux-sock*) send-keys (identity keys)))

(defn type-string
  [s]
  (each c s
    (def char-str (string/from-bytes c))
    (when (= char-str "\n")
      (os/sleep 2))
    (send-keys (char-to-key-name char-str))
    (os/sleep 0.05)
    (when (= char-str "\n")
      (os/sleep 2))))

(defn see-it-in-action-demo
  []
  (type-string "echo Welcome to janetsh.\n")
  (type-string "cd ./src/janetsh\n")
  (type-string "echo We are in $PWD.\n")
  (type-string "ls -la | head -n 3\n")
  (type-string "echo This is a shell AND a janet repl...\n")
  (type-string "(var all-files (string/split \"\\n\" (sh/$$_ find ./)))\n")
  (type-string "echo We just made an array of all our files.\n")
  (type-string "echo We have (length all-files) files.\n")
  (type-string "(defn janet-file?\n")
  (type-string "  \"return true if f is a janet file.\"\n")
  (type-string "  [f]\n")
  (type-string "  (string/has-suffix? \".janet\" f))\n")
  (type-string "(doc janet-file?)\n")
  (type-string "(var janet-files \n")
  (type-string "  (filter janet-file? all-files))\n")
  (type-string "echo This is the first janet file: (first janet-files)\n")
  (type-string "echo We can count how many lines they have:\n")
  (type-string "(each f janet-files \n")
  (type-string "  (sh/$ wc -l [f]))\n")
  (type-string "echo Janetsh is also very customizable.\n")
  (type-string "(set *get-prompt* (fn [] \"$ \"))\n")
  (type-string "echo There is more to do and learn...\n")
  (type-string "echo Thank you for watching\n"))

(defn record
  [f out-path] 
  (type-string "asciinema rec -q -c (find-bin \"janetsh\") --overwrite /tmp/demo.cast\n")
  (f)
  (send-keys "C-d")
  (os/sleep 2)
  (sh/$ cp /tmp/demo.cast (identity out-path)))

(record see-it-in-action-demo "./www/demos/seeitinaction.cast")
