(import sh)
(sh/disown-job (sh/$ sh -c "sleep 0.3 ; touch success.txt" &))
(os/exit 0)
