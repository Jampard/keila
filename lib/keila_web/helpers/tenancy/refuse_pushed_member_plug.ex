defmodule KeilaWeb.Tenancy.RefusePushedMemberPlug do
  @moduledoc """
  Answers 403 to a pushed member: what it guards is the platform's to manage (docs/oidc-sso.md,
  Tenancy push). Projects are created and purged by the push; senders are provisioned by the
  operator, since an SMTP sender names its own relay and From and so could send through the
  host's no-auth loopback relay as any domain it signs.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [text: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if Keila.Tenancy.pushed_user?(conn.assigns.current_user.id),
      do: conn |> put_status(403) |> text("Forbidden") |> halt(),
      else: conn
  end
end
