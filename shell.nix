with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    gdb
    zlib
    valgrind
    # For linter script on push hook
    python3
  ];
}

