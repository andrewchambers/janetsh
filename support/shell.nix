let
  pkgs = (import <nixpkgs>) {};
in
  pkgs.stdenv.mkDerivation {
    name = "janetsh";

    buildInputs = with pkgs; [
      pkgconfig
      /* janet */
      asciinema
      tmux
      expect
      meson
      ninja
      readline80
      libedit
    ];
  }
