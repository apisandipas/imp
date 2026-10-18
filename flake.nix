{
  description = "imp: an extensible, Vim-first editor with a Scheme core";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.rustPlatform.buildRustPackage {
          pname = "imp";
          version = "0.1.0";
          src = self;
          cargoLock.lockFile = ./Cargo.lock;
          # The runtime Scheme files are embedded at build time.
          meta.mainProgram = "imp";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ cargo rustc rustfmt clippy rust-analyzer ];
          # Load runtime/*.scm from the checkout, so editing them needs only a
          # restart of imp, not a rebuild.
          shellHook = ''
            export IMP_RUNTIME="$PWD/runtime"
          '';
        };
      });
    };
}
