(import sh)

(sh/$ $TEST_CASE/trap &)
(os/sleep 0.2)
(os/exit 0)
