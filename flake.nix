{
  description = "Keila: the deployed release (packages.<linux>.keila) and its image";

  inputs = {
    toolchain.url = "git+ssh://forgejo@git.build-eklipse.internal:2222/eklipsetech/toolchain.git?ref=main";
    nixpkgs.follows = "toolchain/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      systems,
      ...
    }:
    flake-utils.lib.eachSystem (import systems) (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # nixpkgs moved elixir/erlang/hex from mixRelease/fetchMixDeps call args to
        # callPackage-scope params; beam29Packages.overrideScope sets them instead.
        scopedBeam = pkgs.beam29Packages.overrideScope (final: prev: { elixir = prev.elixir_1_20; });
        beam = scopedBeam // {
          mixRelease =
            args:
            scopedBeam.mixRelease (
              removeAttrs args [
                "elixir"
                "erlang"
                "hex"
                "forceGitDeps"
              ]
              // {
                env = (args.env or { }) // {
                  forceGitDeps = "1";
                };
                postPatch = (args.postPatch or "") + ''
                  export stdenv="${pkgs.stdenv}"
                '';
              }
            );
          fetchMixDeps =
            args:
            scopedBeam.fetchMixDeps (
              removeAttrs args [
                "elixir"
                "hex"
              ]
            );
        };

        image = import ./nix/image.nix {
          # editorjs (git dep) needs fetcherVersion 2 under newer nixpkgs' fetchNpmDeps.
          pkgs = pkgs // {
            fetchNpmDeps = args: pkgs.fetchNpmDeps (args // { npmDepsFetcherVersion = 2; });
          };
          inherit beam;
          sourceUrl = "https://github.com/Jampard/keila";
          revision = self.rev or null;
        };
      in
      {
        packages = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          inherit (image) keila image;
          default = image.image;
        };
        checks = nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          inherit (image) test;
          release = image.keila;
        };
      }
    );
}
