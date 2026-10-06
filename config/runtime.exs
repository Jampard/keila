import Config
require Logger
require Keila
:ok = Application.ensure_started(:logger)
{:ok, _} = Application.ensure_all_started(:tls_certificate_check)

exit_from_exception = fn exception, message ->
  Logger.error(Exception.message(exception))
  Logger.error(message)
  Logger.flush()
  System.halt(1)
end

maybe_to_int = fn
  string when string not in [nil, ""] -> String.to_integer(string)
  _ -> nil
end

put_if_not_empty = fn
  enumerable, key, value when value not in [nil, ""] -> put_in(enumerable, [key], value)
  enumerable, _, _ -> enumerable
end

if config_env() == :prod do
  # Database
  try do
    db_url = System.fetch_env!("DB_URL")
    ssl = System.get_env("DB_ENABLE_SSL") in [1, "1", "true", "TRUE"]

    ssl_opts =
      []
      |> then(fn opts ->
        verify_peer? = System.get_env("DB_VERIFY_SSL_HOST", "TRUE") in [1, "1", "true", "TRUE"]

        if verify_peer? do
          Keyword.put(opts, :verify, :verify_peer)
        else
          Keyword.put(opts, :verify, :verify_none)
        end
      end)
      |> then(fn opts ->
        ca_cert_pem = System.get_env("DB_CA_CERT")

        cacerts =
          if ca_cert_pem not in [nil, ""] do
            ca_cert_pem
            |> :public_key.pem_decode()
            |> Enum.map(fn {_, der_or_encrypted_der, _} -> der_or_encrypted_der end)
          end

        if cacerts do
          Keyword.put(opts, :cacerts, cacerts)
        else
          opts
        end
      end)

    # Database prefix
    db_schema = System.get_env("DB_SCHEMA")

    if db_schema not in [nil, ""] do
      config :keila, Keila.Repo,
        migration_default_prefix: db_schema,
        parameters: [search_path: db_schema]

      config :keila, Oban, prefix: db_schema
    end

    config :keila, Keila.Repo,
      url: db_url,
      ssl: ssl,
      ssl_opts: ssl_opts

    # A password inside DB_URL still wins: Ecto merges the URL's own fields over these.
    db_password = Keila.SecretEnv.get("DB_PASSWORD")
    if db_password not in [nil, ""], do: config(:keila, Keila.Repo, password: db_password)
  rescue
    e ->
      exit_from_exception.(e, """
      You must provide the DB_URL environment variable in the format:
      postgres://user:password/database
      """)
  end

  # System Mailer
  try do
    mailer_type = System.get_env("MAILER_TYPE") || "smtp"

    tls_mode =
      case System.get_env("MAILER_SMTP_TLS_MODE", "") |> String.downcase() do
        "tls" ->
          :tls

        "starttls" ->
          :starttls

        "none" ->
          :none

        "auto" ->
          :default

        "" ->
          cond do
            System.get_env("MAILER_ENABLE_SSL", "FALSE") in ["1", "true", "TRUE"] ->
              :tls

            System.get_env("MAILER_ENABLE_STARTTLS") in ["1", "true", "TRUE"] ->
              :starttls

            true ->
              :default
          end
      end

    auth_method =
      case System.get_env("MAILER_SMTP_AUTH_METHOD", "auto") |> String.downcase() do
        "password" -> :password
        "none" -> :none
        "auto" -> :default
      end

    config =
      case mailer_type do
        "smtp" ->
          host = System.fetch_env!("MAILER_SMTP_HOST")
          from_email = System.fetch_env!("MAILER_SMTP_FROM_EMAIL")
          user = System.get_env("MAILER_SMTP_USER") || from_email
          password = if auth_method != :none, do: Keila.SecretEnv.fetch!("MAILER_SMTP_PASSWORD")
          port = System.get_env("MAILER_SMTP_PORT", "587") |> maybe_to_int.()

          [
            adapter: Swoosh.Adapters.SMTP,
            relay: host,
            from_email: from_email
          ]
          |> put_if_not_empty.(:username, user)
          |> put_if_not_empty.(:password, password)
          |> put_if_not_empty.(:port, port)
          |> then(fn config ->
            case auth_method do
              :password -> Keyword.put(config, :auth, :always)
              :none -> Keyword.put(config, :auth, :never)
              :default -> config
            end
          end)
          |> then(fn config ->
            case tls_mode do
              :tls ->
                config
                |> Keyword.put(:ssl, true)
                |> Keyword.put(:sockopts, :tls_certificate_check.options(host))

              :starttls ->
                config
                |> Keyword.put(:tls, :always)
                |> Keyword.put(
                  :tls_options,
                  :tls_certificate_check.options(host) ++ [versions: [:"tlsv1.2"]]
                )

              :none ->
                config
                |> Keyword.put(:tls, :never)
                |> Keyword.put(:ssl, false)

              :default ->
                config
            end
          end)
      end

    config(:keila, Keila.Auth.Emails, config)
  rescue
    e ->
      exit_from_exception.(e, """
      You must configure a mailer for system emails.

      Use the following environment variables:
      - MAILER_TYPE (defaults to "smtp")
      - MAILER_SMTP_HOST (required)
      - MAILER_SMTP_USER
      - MAILER_SMTP_PASSWORD (required unless MAILER_SMTP_AUTH_METHOD=none)
      - MAILER_SMTP_PORT (optional, defaults to 587)
      - MAILER_SMTP_AUTH_METHOD (optional, defaults to "auto", options: "password", "none", "auto")
      - MAILER_SMTP_TLS_MODE (optional, defaults to "auto", options: "tls", "starttls", "none", "auto")
      """)
  end

  # Captcha
  captcha_site_key = System.get_env("CAPTCHA_SITE_KEY") || System.get_env("HCAPTCHA_SITE_KEY")

  captcha_secret_key =
    Keila.SecretEnv.get("CAPTCHA_SECRET_KEY") || Keila.SecretEnv.get("HCAPTCHA_SECRET_KEY")

  captcha_verify_url =
    System.get_env("CAPTCHA_VERIFY_URL") || System.get_env("CAPTCHA_URL") ||
      System.get_env("HCAPTCHA_URL")

  captcha_script_url = System.get_env("CAPTCHA_SCRIPT_URL")

  if captcha_site_key not in [nil, ""] and captcha_secret_key not in [nil, ""] do
    captcha_provider =
      System.get_env("CAPTCHA_PROVIDER", "hcaptcha")
      |> String.downcase()
      |> case do
        "friendly_captcha" -> :friendly_captcha
        _other -> :hcaptcha
      end

    Logger.info("Using the #{captcha_provider} captcha provider")

    config =
      [
        secret_key: captcha_secret_key,
        site_key: captcha_site_key,
        provider: captcha_provider
      ]
      |> put_if_not_empty.(:verify_url, captcha_verify_url)
      |> put_if_not_empty.(:script_url, captcha_script_url)

    config :keila, KeilaWeb.Captcha, config
  else
    Logger.warning("""
    Captcha not configured.
    Keila will fall back to using hCaptcha’s staging configuration.

    To configure a captcha, use the following environment variables:

    - CAPTCHA_SITE_KEY
    - CAPTCHA_SECRET_KEY
    - CAPTCHA_VERIFY_URL (defaults to https://hcaptcha.com/siteverify or https://api.friendlycaptcha.com/api/v1/siteverify)
    - CAPTCHA_SCRIPT_URL (defaults to https://hcaptcha.com/1/api.js for hCaptcha or https://unpkg.com/friendly-challenge@0.9.11/widget.module.min.js for Friendly Captcha)
    - CAPTCHA_PROVIDER (defaults to hCaptcha, unless set to 'friendly_captcha')
    """)
  end

  # Secret Key Base
  try do
    secret_key_base = Keila.SecretEnv.fetch!("SECRET_KEY_BASE")

    live_view_salt =
      :crypto.hash(:sha384, secret_key_base <> "live_view_salt") |> Base.url_encode64()

    config(:keila, KeilaWeb.Endpoint,
      secret_key_base: secret_key_base,
      live_view: [signing_salt: live_view_salt]
    )
  rescue
    e ->
      exit_from_exception.(e, """
      You must set SECRET_KEY_BASE.

      This should be a strong secret with a length
      of at least 64 characters.

      One way to create a strong secret is running the following command:
      head -c 48 /dev/urandom | base64
      """)
  end

  # Hashids
  secret_key_base =
    Application.get_env(:keila, KeilaWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)

  hashid_salt =
    case Keila.SecretEnv.get("HASHID_SALT") do
      empty when empty in [nil, ""] ->
        Logger.warning("""
        You have not configured a Hashid salt. Defaulting to
        :crypto.hash(:sha256, SECRET_KEY_BASE <> "hashid_salt") |> Base.url_encode64()
        """)

        :crypto.hash(:sha256, secret_key_base <> "hashid_salt") |> Base.url_encode64()

      salt ->
        salt
    end

  config(:keila, Keila.Id, salt: hashid_salt)

  # Main Endpoint
  url_host = System.get_env("URL_HOST")
  url_port = System.get_env("URL_PORT") |> maybe_to_int.()
  url_schema = System.get_env("URL_SCHEMA")
  url_path = System.get_env("URL_PATH")

  url_port =
    cond do
      url_port not in [nil, ""] -> url_port
      url_schema == "https" -> 443
      true -> System.get_env("PORT") |> maybe_to_int.() || 4000
    end

  url_schema =
    cond do
      url_schema not in [nil, ""] -> url_schema
      url_port == 443 -> "https"
      true -> "http"
    end

  if url_host not in [nil, ""] do
    config =
      [host: url_host, scheme: url_schema]
      |> put_if_not_empty.(:port, url_port)
      |> put_if_not_empty.(:path, url_path)

    config(:keila, KeilaWeb.Endpoint, url: config)
  else
    Logger.warning("""
    You have not configured the application URL. Defaulting to http://localhost.

    Use the following environment variables:
    - URL_HOST
    - URL_PORT (defaults to PORT, or to 443 if URL_SCHEMA=https)
    - URL_SCHEMA (defaults to "https" for port 443, otherwise to "http")
    - URL_PATH (defaults to "/")
    """)
  end

  # File Storage
  user_content_dir = System.get_env("USER_CONTENT_DIR")

  default_user_content_dir =
    Application.get_env(:keila, Keila.Files.StorageAdapters.Local, []) |> Keyword.get(:dir)

  if user_content_dir not in [nil, ""] do
    config(:keila, Keila.Files.StorageAdapters.Local, dir: user_content_dir)
  else
    Logger.warning("""
    You have not configured a directory for user uploads.
    Default directory "#{default_user_content_dir}" will be used.

    If want to store uploads in a different directory you can set
    USER_CONTENT_DIR
    """)
  end

  user_content_base_url = System.get_env("USER_CONTENT_BASE_URL")

  if user_content_base_url not in [nil, ""] do
    config(:keila, Keila.Files.StorageAdapters.Local, serve: false)
    config(:keila, Keila.Files.StorageAdapters.Local, base_url: user_content_base_url)
  else
    config(:keila, Keila.Files.StorageAdapters.Local, serve: true)

    Logger.warning("""
    You have not configured a separate URL for untrusted content uploaded by
    users.

    If you serve user uploads on a different domain, you can set
    USER_CONTENT_BASE_URL
    """)
  end

  # Application Port
  port = System.get_env("PORT") |> maybe_to_int.()

  if not is_nil(port) do
    config(:keila, KeilaWeb.Endpoint, http: [port: port])
  else
    Logger.info("""
    PORT environment variable unset. Running on port 4000.
    """)
  end

  # Deployment
  config :keila,
    # Disable registration of new users via the UI
    registration_disabled:
      System.get_env("DISABLE_REGISTRATION") not in [nil, "", "0", "false", "FALSE"],
    # Disable creation of Senders not using SharedSenders.
    sender_creation_disabled:
      System.get_env("DISABLE_SENDER_CREATION") not in [nil, "", "0", "false", "FALSE"]

  # Enable sending quotas
  config :keila, Keila.Accounts,
    credits_enabled: System.get_env("ENABLE_QUOTAS") in [1, "1", "true", "TRUE"]

  # Enable update check
  config :keila,
         :update_checks_enabled,
         System.get_env("DISABLE_UPDATE_CHECKS") not in [1, "1", "true", "TRUE"]

  # Disable tz auto-update check
  if System.get_env("DISABLE_TZDATA_UPDATES") in [1, "1", "true", "TRUE"] do
    config :keila, :disable_tz_updates, true
  end

  # Precedence Bulk Header
  if System.get_env("DISABLE_PRECEDENCE_HEADER") in [1, "1", "true", "TRUE"] do
    config(:keila, Keila.Mailings, enable_precedence_header: false)
  end

  # Message body retention
  message_retention_days =
    System.get_env("MESSAGE_RETENTION_DAYS") |> maybe_to_int.()

  if message_retention_days do
    config :keila, Keila.Mailings, message_retention_days: message_retention_days
  end

  # Default to info messages in production
  case System.get_env("LOG_LEVEL") do
    level when level in ["info", "error", "debug"] ->
      config :logger, level: String.to_existing_atom(level)

    _ ->
      config :logger, level: :info
  end
end

source_link =
  []
  |> put_if_not_empty.(:url, System.get_env("KEILA_SOURCE_URL"))
  |> put_if_not_empty.(:revision, System.get_env("KEILA_SOURCE_REVISION"))

config :keila, KeilaWeb.SourceLink, source_link

# OIDC SSO
split_list = fn
  value when value in [nil, ""] -> []
  value -> value |> String.split([",", " ", "\t", "\n"], trim: true) |> Enum.reject(&(&1 == ""))
end

oidc_provider_names = System.get_env("KEILA_OIDC_PROVIDERS") |> split_list.()

if oidc_provider_names != [] do
  oidc_providers =
    Enum.flat_map(oidc_provider_names, fn name ->
      key = name |> String.downcase() |> String.to_atom()
      prefix = "KEILA_OIDC_#{String.upcase(name)}_"

      issuer = System.get_env(prefix <> "ISSUER")
      client_id = System.get_env(prefix <> "CLIENT_ID")
      client_secret = Keila.SecretEnv.get(prefix <> "CLIENT_SECRET")

      missing =
        [{"ISSUER", issuer}, {"CLIENT_ID", client_id}, {"CLIENT_SECRET", client_secret}]
        |> Enum.filter(fn {_, value} -> value in [nil, ""] end)
        |> Enum.map(fn {suffix, _} -> prefix <> suffix end)

      policy =
        case System.get_env(prefix <> "POLICY", "entitlement") |> String.downcase() do
          "entitlement" -> :entitlement
          "tenant_spn" -> :tenant_spn
          other -> {:unknown, other}
        end

      cond do
        missing != [] ->
          Logger.warning("""
          OIDC provider "#{name}" is not configured and will be skipped.
          Missing environment variables: #{Enum.join(missing, ", ")}
          """)

          []

        match?({:unknown, _}, policy) ->
          {:unknown, other} = policy

          Logger.warning("""
          OIDC provider "#{name}" has an unknown #{prefix}POLICY value "#{other}" and will be skipped.
          Accepted values: entitlement, tenant_spn
          """)

          []

        true ->
          # An explicitly empty SCOPES must fall back to the default, not request no scopes:
          # dropping `openid` turns the whole flow into a confusing token error.
          scopes = System.get_env(prefix <> "SCOPES") |> split_list.()

          opts =
            [
              issuer: issuer,
              client_id: client_id,
              client_secret: client_secret,
              policy: policy
            ]
            |> then(fn opts ->
              if scopes == [], do: opts, else: Keyword.put(opts, :scopes, scopes)
            end)
            |> put_if_not_empty.(:label, System.get_env(prefix <> "LABEL"))
            |> put_if_not_empty.(
              :entitlement_claim,
              System.get_env(prefix <> "ENTITLEMENT_CLAIM")
            )
            |> put_if_not_empty.(
              :entitlement_value,
              System.get_env(prefix <> "ENTITLEMENT_VALUE")
            )
            |> put_if_not_empty.(:admin_value, System.get_env(prefix <> "ADMIN_VALUE"))
            |> put_if_not_empty.(:tenant_prefix, System.get_env(prefix <> "TENANT_PREFIX"))
            |> put_if_not_empty.(:tenant_claim, System.get_env(prefix <> "TENANT_CLAIM"))
            |> put_if_not_empty.(:cacertfile, System.get_env(prefix <> "CACERTFILE"))

          [{key, opts}]
      end
    end)

  config :keila, Keila.Auth.Oidc,
    providers: oidc_providers,
    oidc_only: System.get_env("KEILA_OIDC_ONLY") not in [nil, "", "0", "false", "FALSE"]
else
  # Outside prod an unconfigured OIDC is the normal case, so the notice would be pure noise.
  if config_env() == :prod do
    Logger.warning("""
    OIDC SSO not configured. Password authentication will be used.

    To enable OIDC, set KEILA_OIDC_PROVIDERS to a space- or comma-separated
    list of provider names, e.g. "staff merchant", and configure each provider
    with the following environment variables (NAME is the upper-cased name):

    - KEILA_OIDC_<NAME>_ISSUER (required)
    - KEILA_OIDC_<NAME>_CLIENT_ID (required)
    - KEILA_OIDC_<NAME>_CLIENT_SECRET (required)
    - KEILA_OIDC_<NAME>_SCOPES (defaults to "openid email profile")
    - KEILA_OIDC_<NAME>_LABEL (defaults to the capitalized provider name)
    - KEILA_OIDC_<NAME>_POLICY ("entitlement" or "tenant_spn", defaults to "entitlement")
    - KEILA_OIDC_<NAME>_ENTITLEMENT_CLAIM (for the entitlement policy)
    - KEILA_OIDC_<NAME>_ENTITLEMENT_VALUE (for the entitlement policy)
    - KEILA_OIDC_<NAME>_ADMIN_VALUE (entitlement policy: holders of this value on the
      same claim gain Keila admin, reconciled on every sign-in)
    - KEILA_OIDC_<NAME>_TENANT_PREFIX (for the tenant_spn policy)
    - KEILA_OIDC_<NAME>_TENANT_CLAIM (for the tenant_spn policy, defaults to "groups")
    - KEILA_OIDC_<NAME>_CACERTFILE (PEM to verify the IdP against, for a private CA;
      it replaces the system trust store for this provider rather than adding to it)

    Set KEILA_OIDC_ONLY to disable password login, registration and password
    resets once at least one OIDC provider is configured.
    """)
  end
end

if config_env() == :test do
  db_url = System.get_env("DB_URL")

  if db_url do
    db_url = db_url <> "#{System.get_env("MIX_TEST_PARTITION")}"
    config(:keila, Keila.Repo, url: db_url)
  end
end

Keila.if_cloud do
  use KeilaCloud.RuntimeConfig
end
