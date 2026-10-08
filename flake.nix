{
  description = "Keila: the deployed image (packages.<linux>.image)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/b6c98e9e6633ee64753b594ff4a5febf0367fc00";
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
        # callPackage-scope params; beam27Packages.overrideScope sets them instead.
        scopedBeam = pkgs.beam27Packages.overrideScope (final: prev: { elixir = prev.elixir_1_18; });
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
      }
    );
}
