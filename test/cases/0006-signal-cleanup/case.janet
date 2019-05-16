(import sh)

(sh/wait-for-job (sh/$ $TEST_CASE/trap &))
