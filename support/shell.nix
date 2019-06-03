let
  pkgs = (import <nixpkgs>) {};
  janet =  ((pkgs.callPackage ./janet.nix) {});
  mendoza = ((pkgs.callPackage ./mendoza.nix) { inherit janet; });
in
  pkgs.stdenv.mkDerivation {
    name = "janetsh";

    buildInputs = with pkgs; [
      asciinema
      expect
      inotify-tools
      clang-tools
      janet
      libedit
      mendoza
      meson
      ninja
      pkgconfig
      readline80
      tmux
    ];
  }
