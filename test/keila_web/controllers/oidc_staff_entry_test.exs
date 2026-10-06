defmodule KeilaWeb.OidcStaffEntryTest do
  @moduledoc """
  `/staff` — the staff door, which the customer sign-in page never links to.
  """

  use KeilaWeb.ConnCase, async: false

  alias Keila.Auth.Oidc

  @staff [
    issuer: "https://idp.example.com",
    client_id: "keila",
    client_secret: "s3cret",
    policy: :entitlement,
    entitlement_claim: "keila_role",
    entitlement_value: "keila_users",
    label: "Staff SSO"
  ]

  @merchant [
    issuer: "https://shop.example.com",
    client_id: "keila-merchant",
    client_secret: "sh0p",
    policy: :pushed,
    label: "Merchant sign-in"
  ]

  defp put_oidc_config(providers) do
    previous = Application.get_env(:keila, Oidc)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:keila, Oidc)
      else
        Application.put_env(:keila, Oidc, previous)
      end
    end)

    Application.put_env(:keila, Oidc, providers: providers, oidc_only: true)
  end

  @tag :oidc_staff_entry
  test "GET /staff sends the caller to the staff provider", %{conn: conn} do
    put_oidc_config(staff: @staff, merchant: @merchant)

    conn = get(conn, "/staff")

    assert redirected_to(conn, 302) == Routes.oidc_path(conn, :authorize, :staff)
  end

  @tag :oidc_staff_entry
  test "the sign-in page links to no staff door", %{conn: conn} do
    put_oidc_config(staff: @staff, merchant: @merchant)

    html = conn |> get(Routes.auth_path(conn, :login)) |> html_response(200)

    refute html =~ "/staff"
  end

  @tag :oidc_staff_entry
  test "the staff leg is refused when no staff provider is configured", %{conn: conn} do
    put_oidc_config(merchant: @merchant)

    conn = get(conn, Routes.oidc_path(conn, :authorize, :staff))

    assert html_response(conn, 404)
  end
end
