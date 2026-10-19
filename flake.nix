{
  description = "imp: an extensible, Vim-first editor with a Scheme core";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          imp = { gui ? true }: pkgs.rustPlatform.buildRustPackage {
            pname = if gui then "imp" else "imp-tui";
            version = "0.1.0-alpha.1";
            src = self;
            cargoLock.lockFile = ./Cargo.lock;
            buildNoDefaultFeatures = !gui;
            # The git interface's tests make real repositories.
            nativeCheckInputs = [ pkgs.git ];
            # winit and wgpu load the windowing and graphics libraries at
            # run time; an rpath (not LD_LIBRARY_PATH, which programs imp
            # starts would inherit) lets them find these.
            postFixup = pkgs.lib.optionalString (gui && pkgs.stdenv.isLinux) ''
              patchelf --add-rpath ${pkgs.lib.makeLibraryPath (with pkgs; [
                vulkan-loader libGL libxkbcommon wayland
                xorg.libX11 xorg.libXcursor xorg.libXi xorg.libXrandr
              ])} $out/bin/imp
            '';
            # The runtime Scheme files are embedded at build time.
            meta.mainProgram = "imp";
            meta.license = pkgs.lib.licenses.gpl3Plus;
          };
        in
        {
          # imp opens a window when there is a display, else uses the
          # terminal (imp --tui forces it).
          default = imp { };
          # Terminal only, without the graphics dependencies.
          tui = imp { gui = false; };
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
