# The release boots on a fresh database, runs its migrations and serves the login page, through nixosModules.keila.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "keila-smoke";
  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        module
        {
          options.services.keila.package = lib.mkOption { type = lib.types.package; };
        }
      ];
      virtualisation.memorySize = 2048;
      services.postgresql = {
        enable = true;
        ensureDatabases = [ "keila" ];
        ensureUsers = [
          {
            name = "keila";
            ensureDBOwnership = true;
          }
        ];
        authentication = "host keila keila 127.0.0.1/32 trust";
      };
      systemd.services.keila = {
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          DB_URL = "ecto://keila@127.0.0.1/keila";
          SECRET_KEY_BASE = "smoke-test-secret-key-base-smoke-test-secret-key-base-smoke-test";
          URL_HOST = "localhost";
          URL_SCHEMA = "http";
          URL_PORT = "4000";
          PORT = "4000";
          MAILER_SMTP_HOST = "127.0.0.1";
          MAILER_SMTP_FROM_EMAIL = "keila@localhost";
          MAILER_SMTP_AUTH_METHOD = "none";
          RELEASE_TMP = "/var/lib/keila/tmp";
          RELEASE_DISTRIBUTION = "none";
          RELEASE_COOKIE = "keila";
          HOME = "/var/lib/keila";
        };
        serviceConfig = {
          DynamicUser = true;
          StateDirectory = "keila";
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/keila/tmp";
          ExecStart = "${config.services.keila.package}/bin/keila start";
        };
      };
    };
  testScript = ''
    machine.wait_for_unit("keila.service")
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:4000/auth/login | grep -q '<form'", timeout=180)
  '';
}
