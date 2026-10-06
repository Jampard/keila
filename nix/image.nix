{
  pkgs,
  beam,
  sourceUrl,
  revision,
}:
let
  inherit (pkgs) lib;
  elixir = beam.elixir_1_18;
  version = "0.30.3";
  home = "/opt/app";
  port = 4000;

  # extra/ is not AGPL and must never reach the build; the gitignored generated dirs would mask a fetch.
  src = lib.fileset.toSource {
    root = ../.;
    fileset =
      lib.fileset.difference
        (lib.fileset.unions [
          ../mix.exs
          ../mix.lock
          ../config
          ../lib
          ../priv
          ../assets
          ../LICENSE.md
          ../NOTICE
        ])
        (
          lib.fileset.unions [
            (lib.fileset.maybeMissing ../priv/cldr)
            (lib.fileset.maybeMissing ../assets/node_modules)
          ]
        );
  };

  # ex_cldr downloads these at compile time, which the sandbox forbids; the tag is ex_cldr's version in mix.lock.
  cldrLocales =
    lib.mapAttrs
      (
        locale: hash:
        pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/elixir-cldr/cldr/v2.47.0/priv/cldr/locales/${locale}.json";
          inherit hash;
        }
      )
      {
        bg = "sha256-dhM6pDUheC8/c/82t5e5CQ4+oeXytljTqJ6lDbto1Ec=";
        de = "sha256-Jo31iIRRHqDXWMhiw00tTOQhJJ7ANCg8I/WX6F8Hdlk=";
        es = "sha256-n3mTASnZuMTYe2BNmJccVS6ZpcPQKnwgivCd3Un6GLQ=";
        fr = "sha256-3OtBXxqvSLx/xVOD5KofWmOR71QvGR/aUmw5QelsdBw=";
        hu = "sha256-quLGT1sPY4bvGkn9rZNAKu88X+OinCqZtD+7gkElHwY=";
        it = "sha256-yv/rwZmZzhmlrKmkyaWyJAhqh1My1wCIEpK6o4Vv2eM=";
        pt = "sha256-7hY8NYRkEtn9iE+JVWrR2zhFwrl1f3JScqbtzviH1Qc=";
      };

  mixFodDeps = beam.fetchMixDeps {
    pname = "keila-mix-deps";
    inherit version elixir;
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../mix.exs
        ../mix.lock
        ../config
      ];
    };
    hash = "sha256-4huudt8UH2GtRbFl2OseXX/ZRBfEJJ/wWHfFZGZzCKU=";
  };

  npmDeps = pkgs.fetchNpmDeps {
    name = "keila-npm-deps";
    src = ../assets;
    # @editorjs/editorjs is a git dependency of upstream's fork; its install scripts are not run.
    forceGitDeps = true;
    hash = "sha256-jDFHIeqoKCW3OgqNHgXsbVlJcuGD++bkpWMxSRVJ6Ec=";
  };

  # mjml's NIF is precompiled and downloaded at compile time; the hashes are its checksum-Elixir.Mjml.Native.exs.
  mjmlNif =
    let
      file = "libmjml_nif-v5.3.1-nif-2.16-${pkgs.stdenv.hostPlatform.parsed.cpu.name}-unknown-linux-gnu.so.tar.gz";
    in
    pkgs.linkFarm "mjml-nif" {
      ${file} = pkgs.fetchurl {
        url = "https://github.com/adoptoposs/mjml_nif/releases/download/v5.3.1/${file}";
        hash =
          {
            x86_64 = "sha256-VV/ZTNHkhc0A6umjl+KRS99Mv6Jrs1KNyLjeWMVyLfA=";
            aarch64 = "sha256-cFfmHBFTmK67PNx6eKJ/REHrO3i63c15Iu1AxLy410Q=";
          }
          .${pkgs.stdenv.hostPlatform.parsed.cpu.name};
      };
    };

  keila = beam.mixRelease {
    pname = "keila";
    inherit
      version
      src
      elixir
      mixFodDeps
      npmDeps
      ;

    npmRoot = "assets";
    makeCacheWritable = true;
    forceGitDeps = true;
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.npmHooks.npmConfigHook
      pkgs.cmake
    ];
    # fast_html's Makefile runs cmake itself; the setup hook would hijack mixRelease's configurePhase.
    dontUseCmakeConfigure = true;

    env = {
      MIX_ESBUILD_PATH = lib.getExe pkgs.esbuild;
      RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = mjmlNif;
    };

    # assets/package.json resolves phoenix* as file:../deps/*, so the deps must be in place before npm runs.
    postPatch = ''
      ln -s "$MIX_DEPS_PATH" deps
      mkdir -p priv/cldr/locales
      ${lib.concatStrings (
        lib.mapAttrsToList (locale: file: "cp ${file} priv/cldr/locales/${locale}.json\n") cldrLocales
      )}
    '';

    # fetchMixDeps strips .git from git deps, so their lock check must be skipped once for the alias' tasks.
    postBuild = ''
      mix do loadpaths --no-deps-check + assets.deploy
    '';

    postInstall = ''
      install -Dm644 LICENSE.md NOTICE -t "$out/share/licenses/keila"
    '';
  };

  image = pkgs.dockerTools.buildLayeredImage {
    name = "keila";
    tag = if revision == null then "dev" else revision;
    contents = [
      pkgs.busybox
      pkgs.cacert
      pkgs.curl
      pkgs.openssl
      pkgs.tzdata
    ];

    fakeRootCommands = ''
      mkdir -p .${home}/tmp ./tmp ./etc
      chown -R 1001:0 .${home}
      chmod 1777 ./tmp
      echo 'root:x:0:0:root:/root:/bin/sh' > ./etc/passwd
      echo 'default:x:1001:0:keila:${home}:/bin/sh' >> ./etc/passwd
      echo 'root:x:0:' > ./etc/group
    '';
    enableFakechroot = false;

    config = {
      User = "1001";
      WorkingDir = home;
      Entrypoint = [ "${keila}/bin/keila" ];
      Cmd = [ "start" ];
      ExposedPorts."${toString port}/tcp" = { };
      Env = [
        "PATH=/bin"
        "HOME=${home}"
        "LANG=C.UTF-8"
        "MIX_ENV=prod"
        "PORT=${toString port}"
        "RELEASE_TMP=${home}/tmp"
        "RELEASE_DISTRIBUTION=none"
        # The release lives in the read-only store, where Tz's updater cannot write; a rebuild refreshes it.
        "DISABLE_TZDATA_UPDATES=1"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "TZDIR=${pkgs.tzdata}/share/zoneinfo"
        "KEILA_SOURCE_URL=${sourceUrl}"
      ]
      # A dirty tree has no commit to link, so the footer links the repository instead.
      ++ lib.optional (revision != null) "KEILA_SOURCE_REVISION=${revision}";
      Labels = {
        "org.eklipse.secret-files" = "1";
        "org.opencontainers.image.source" = sourceUrl;
        "org.opencontainers.image.licenses" = "AGPL-3.0-only";
      }
      // lib.optionalAttrs (revision != null) { "org.opencontainers.image.revision" = revision; };
      Healthcheck = {
        Test = [
          "CMD-SHELL"
          "wget -qO- http://127.0.0.1:$PORT/ >/dev/null || exit 1"
        ];
        Interval = 30000000000;
        Timeout = 5000000000;
        StartPeriod = 20000000000;
        Retries = 3;
      };
    };
  };
in
{
  inherit keila image;
}
