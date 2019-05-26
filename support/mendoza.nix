{ stdenv, fetchFromGitHub, janet }:

stdenv.mkDerivation rec {
  pname = "mendoza";
  version = "0.0.1";

  src = fetchFromGitHub {
    owner = "bakpakin";
    repo = "mendoza";
    rev = "97caeebac9b2bdc69ccc1408722f537575846662";
    sha256 = "0mkrb7xpp6x6a2fbnasjdc9012dg1ajk206p0jqdyazl6sasyal9";
  };

  PREFIX = placeholder "out";

  installPhase = ''
    mkdir -p "$PREFIX/bin/"
    mkdir -p "$PREFIX/lib/janet"
    cp -r ./mendoza "$PREFIX/lib/janet/"
    head -n 1 ./mdz > "$PREFIX/bin/mdz"
    echo "(array/concat module/paths [" >> "$PREFIX/bin/mdz"
    echo "  [\"$PREFIX/lib/janet/:all:.janet\" :source]" >> "$PREFIX/bin/mdz"
    echo "  [\"$PREFIX/lib/janet/:all:/init.janet\" :source]" >> "$PREFIX/bin/mdz"
    echo "  [\"$PREFIX/lib/janet/:all:.:native:\" :native]])" >> "$PREFIX/bin/mdz"
    tail -n +2 ./mdz >> "$PREFIX/bin/mdz"
    chmod +x "$PREFIX/bin/mdz"
  '';

  buildInputs = [janet];

  meta = with stdenv.lib; {
    description = "Mendoza static site generator";
    homepage = https://github.com/bakpakin/mendoza;
    license = stdenv.lib.licenses.mit;
    platforms = platforms.all;
    maintainers = with stdenv.lib.maintainers; [ andrewchambers ];
  };
}
