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
    (send-keys (char-to-key-name char-str))
    (os/sleep 0.2)
    (when  (= char-str  "\n")
      (os/sleep 4))))

(defn see-it-in-action-demo
  []
  (type-string "echo Welcome to $PWD.\n")
  (type-string "(var all-files (string/split \"\\n\" ($$ find ./)))\n")
  (type-string "echo We just made an array of all our files.\n")
  (type-string "(type all-files)\n")
  (type-string "echo We have (- (length all-files) 1) files.\n")
  (type-string "(var janet-files \n")
  (type-string "  (filter (fn [f] (string/has-suffix? \".janet\" f)) all-files))\n")
  (type-string "echo We have (length janet-files) janet files.\n")
  (type-string "echo This is the first file: (first janet-files)\n")
  (type-string "echo We can do MUCH more... but this is a bad place.\n")
  (type-string "echo Thank you for watching!\n"))

(defn record
  [f out-path] 
  (type-string "asciinema rec -q -c ./janetsh --overwrite /tmp/demo.cast\n")
  (f)
  (send-keys "C-d")
  (os/sleep 2)
  (sh/$ cp /tmp/demo.cast (identity out-path)))

(defn cast2gif
  [cast]
  # A shame this needs to be docker, but this is so hard to install, even on nixos.
  (sh/$ sudo docker run --rm -v $PWD:/data asciinema/asciicast2gif -s 2 -t solarized-dark (identity cast) (string cast ".gif")))

(record see-it-in-action-demo "./demos/seeitinaction.cast")
(cast2gif "./demos/seeitinaction.cast")
