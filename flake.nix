{
  description = "Keila: the deployed release (packages.<linux>.keila) and its image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
    {
      nixosModules.keila =
        { lib, pkgs, ... }:
        {
          options.services.keila.package = lib.mkOption {
            type = lib.types.package;
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.keila;
            defaultText = lib.literalExpression "keila.packages.\${system}.keila";
            description = "The Keila release a host runs; `passthru.erlangVersion` names the OTP it was built on.";
          };
        };
      nixosModules.default = self.nixosModules.keila;
    }
    // flake-utils.lib.eachSystem (import systems) (
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
        checks = {
          public-inputs = import ./nix/public-inputs.nix {
            inherit pkgs;
            locks = [
              ./flake.lock
              ./dev/flake.lock
            ];
          };
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          inherit (image) test;
          release = image.keila;
          smoke = import ./nix/smoke-test.nix {
            inherit pkgs;
            module = self.nixosModules.keila;
          };
        };
      }
    );
}
