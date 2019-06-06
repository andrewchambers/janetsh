(import sh)

(sh/$ exec echo "goodbye world.")
(error "unreachable")
