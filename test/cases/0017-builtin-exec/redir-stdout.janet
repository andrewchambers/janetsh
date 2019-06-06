(import sh)

(sh/$ exec > redir-stdout.txt)
(print "hello world.")
