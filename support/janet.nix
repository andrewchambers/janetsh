{ stdenv, fetchFromGitHub }:

stdenv.mkDerivation rec {
  name = "janet";
  version = "prerelease";

  src = fetchFromGitHub {
    owner = "janet-lang";
    repo = "janet";
    rev = "c21eaa5474bb84a25c5d06645632aa851b37ef20";
    sha256 = "0agbq0spdjj79mx4y5awa6b4k2jj8j0xv2if594h81jlsi3dwb83";
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
