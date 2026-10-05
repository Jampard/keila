{
  description = "Keila development environment: Elixir, PostgreSQL and a local kanidm for OIDC SSO";

  inputs = {
    clan-core.url = "git+https://git.clan.lol/clan/clan-core.git";
    nixpkgs.follows = "clan-core/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    systems.url = "github:nix-systems/default";

    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      systems,
      devenv,
      ...
    }@inputs:
    flake-utils.lib.eachSystem (import systems) (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        beam = pkgs.beam27Packages;

        # Off 5432/8443/8444 and below platform's 8600+ worktree lattice: shared CI runners host both.
        # dev.exs takes the port via PGPORT (Postgrex), the test env via DB_URL (runtime.exs).
        ports = {
          postgres = 7432;
          kanidm = 7443;
          keila = 4000;
        };

        kanidmPkg = pkgs.kanidm_1_11;
        origin = "http://localhost:${toString ports.keila}";
        issuer = "https://localhost:${toString ports.kanidm}";
      in
      {
        devShells.default = devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              packages = [
                beam.elixir_1_18
                beam.erlang
                pkgs.nodejs
                pkgs.dprint
                pkgs.python3
                kanidmPkg
              ];

              env = {
                PGPORT = toString ports.postgres;
                DB_URL = "ecto://postgres:postgres@localhost:${toString ports.postgres}/keila_test";
                KEILA_KANIDM_URL = issuer;
                KEILA_ORIGIN = origin;
              };

              services.postgres = {
                enable = true;
                package = pkgs.postgresql_18;
                port = ports.postgres;
                listen_addresses = "127.0.0.1";
                # ICU collation, so a locale-dependent ordering bug shows up in dev too.
                initdbArgs = [
                  "--locale-provider=icu"
                  "--icu-locale=und-x-icu"
                ];
                initialDatabases = [
                  { name = "keila_dev"; }
                  { name = "keila_test"; }
                ];
                initialScript = ''
                  CREATE ROLE postgres SUPERUSER LOGIN PASSWORD 'postgres';
                '';
              };

              processes.kanidm.exec = ''
                set -euo pipefail
                W="$DEVENV_STATE/kanidm"
                mkdir -p "$W"
                # The admin socket lives OUTSIDE the tree: `nix develop path:.` copies the whole
                # directory and dies on a socket ("unsupported type"), and /tmp keeps it under SUN_LEN.
                SOCK="/tmp/keila-kanidm-$(printf '%s' "$W" | cksum | cut -d' ' -f1).sock"
                cat > "$W/server.toml" <<EOF
                version = "2"
                bindaddress = "127.0.0.1:${toString ports.kanidm}"
                db_path = "$W/kanidm.db"
                tls_chain = "$W/chain.pem"
                tls_key = "$W/key.pem"
                domain = "localhost"
                origin = "${issuer}"
                adminbindpath = "$SOCK"
                EOF
                if [ -z "$(find "$W/chain.pem" -mtime -7 2>/dev/null)" ]; then
                  ${kanidmPkg}/bin/kanidmd cert-generate -c "$W/server.toml"
                fi
                exec ${kanidmPkg}/bin/kanidmd server -c "$W/server.toml"
              '';

              processes.kanidm-provision = {
                exec = ''
                  KEILA_KANIDM_WORK="$DEVENV_STATE/kanidm" \
                  KANIDMD=${kanidmPkg}/bin/kanidmd \
                  ${pkgs.python3}/bin/python3 "$DEVENV_ROOT/nix/kanidm-dev.py"
                '';
                process-compose = {
                  depends_on.kanidm.condition = "process_started";
                  availability.restart = "no";
                };
              };

              enterShell = ''
                export MIX_HOME="$DEVENV_ROOT/.nix/mix"
                export HEX_HOME="$DEVENV_ROOT/.nix/hex"
                export PATH="$MIX_HOME/bin:$HEX_HOME/bin:$PATH"
                export ERL_AFLAGS="-kernel shell_history enabled"
                mix local.hex --if-missing --force >/dev/null 2>&1 || true
                mix local.rebar --if-missing --force >/dev/null 2>&1 || true

                export KEILA_KANIDM_WORK="$DEVENV_STATE/kanidm"
                export KEILA_TEST_KANIDM_ENV="$KEILA_KANIDM_WORK/keila.env"
                export KEILA_TEST_KANIDM_IDM_PW="$KEILA_KANIDM_WORK/idm_admin.pw"

                echo "keila dev — devenv up -D, then:"
                echo "  mix setup && mix assets.build"
                echo "  set -a; . \"$KEILA_TEST_KANIDM_ENV\"; set +a; mix phx.server   # ${origin}"
              '';
            }
          ];
        };
      }
    );
}
