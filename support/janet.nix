{ stdenv, fetchFromGitHub }:

stdenv.mkDerivation rec {
  name = "janet";
  version = "1.0.0-prerelease";

  src = fetchFromGitHub {
    owner = "janet-lang";
    repo = "janet";
    rev = "4d5a95784a076a03a437b2aeff19cd0544f19f50";
    sha256 = "0v121y8hga1rmjzcm0ydjfv0v9d60hhlyy73ql1p2wxccsnzjll7";
  };

  JANET_BUILD=''\"release\"'';
  PREFIX = placeholder "out";

  doCheck = true;

  meta = with stdenv.lib; {
    description = "Janet programming language";
    homepage = https://janet-lang.org/;
    license = stdenv.lib.licenses.mit;
    platforms = platforms.all;
    maintainers = with stdenv.lib.maintainers; [ andrewchambers ];
  };
}
