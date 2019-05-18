(import sh)

(defn subshell
  [&]
  (sh/$ $TEST_CASE/trap ))

(sh/$ (identity subshell) &)
# ensure the subshell child starts.
(os/sleep 0.5)
(os/exit 0)
