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
      (os/sleep 2))))

(defn shell-demo
  []
  (type-string "ls -la | head -n 3\n")
  (type-string "echo foo > /dev/null\n")
  (type-string "sleep 5 &\n"))

(defn functional-demo
  []
  (type-string "(map string/ascii-upper [\"functional\" \"programming\"])\n")
  (type-string "(defn lines [s] (string/split \"\\n\" s))\n")
  (type-string "(lines ($$ ls | head -n 3))\n")
  (type-string "echo (reduce + 0 [1 2 3])\n"))

(defn capture-demo
  []
  (type-string "(string/ascii-upper ($$ echo command string capture))\n")
  (type-string "(if (= 0 ($? touch /tmp/test.txt)) (print \"success\"))\n"))

(defn subshell-demo
  []
  (type-string "ls | head -n 3 | (out-lines string/ascii-upper)\n"))

(defn record
  [f out-path] 
  (sh/$ tmux -S (identity *tmux-sock*) resize-pane -x 80 -y 40)
  (type-string "asciinema rec -q -c ./janetsh --overwrite /tmp/demo.cast\n")
  (f)
  (send-keys "C-d")
  (os/sleep 2)
  (sh/$ cp /tmp/demo.cast (identity out-path)))

(defn cast2gif
  [cast]
  # A shame this needs to be docker, but this is so hard to install, even on nixos.
  (sh/$ sudo docker run --rm -v $PWD:/data asciinema/asciicast2gif -s 2 -t solarized-dark (identity cast) (string cast ".gif")))

#(record shell-demo "./demos/shelldemo.cast")
#(record functional-demo "./demos/functionaldemo.cast")
#(record capture-demo "./demos/capturedemo.cast")
#(record subshell-demo "./demos/subshelldemo.cast")

#(cast2gif "./demos/shelldemo.cast")
#(cast2gif "./demos/functionaldemo.cast")
#(cast2gif "./demos/capturedemo.cast")
#(cast2gif "./demos/subshelldemo.cast")