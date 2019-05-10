let
  pkgs = (import <nixpkgs>) {};
in
  pkgs.stdenv.mkDerivation {
    name = "janetsh";

    buildInputs = with pkgs; [
      pkg-config
      janet
      linenoise
    ];
  }