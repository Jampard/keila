defmodule KeilaWeb.TenancyControllerTest do
  use KeilaWeb.ConnCase, async: false

  alias Keila.Auth.Oidc

  @secret "tenancy-test-secret"
  @merchant [
    issuer: "https://shop.example.com/oidc",
    client_id: "keila-merchant",
    client_secret: "sh0p",
    policy: :pushed
  ]

  setup do
    previous = {Application.get_env(:keila, Oidc), Application.get_env(:keila, Keila.Tenancy)}

    on_exit(fn ->
      {oidc, tenancy} = previous
      Application.put_env(:keila, Oidc, oidc || [])
      Application.put_env(:keila, Keila.Tenancy, tenancy || [])
    end)

    Application.put_env(:keila, Oidc, providers: [merchant: @merchant])
    Application.put_env(:keila, Keila.Tenancy, secret: @secret)
    with_seed()
    :ok
  end

  defp body(
         version,
         state,
         members \\ [%{sub: "s1", mail: "s1@shop.example.com", role: "merchant"}]
       ) do
    Jason.encode!(%{
      version: version,
      state: state,
      name: "Acme",
      domains: ["acme.example.com"],
      members: members
    })
  end

  defp gate(conn, secret \\ @secret) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(&if secret, do: put_req_header(&1, "authorization", "Bearer " <> secret), else: &1)
  end

  test "an unset secret makes every route a 404", %{conn: conn} do
    Application.put_env(:keila, Keila.Tenancy, secret: nil)

    assert conn |> gate() |> put("/tenancy/acme", body(1, "live")) |> response(404)
    assert conn |> gate() |> get("/tenancy") |> response(404)
    assert conn |> gate() |> get("/tenancy/acme") |> response(404)
  end

  test "a missing or wrong secret is 401 unauthorised on every route, nothing applied", %{
    conn: conn
  } do
    for secret <- [nil, @secret <> "-wrong"] do
      assert %{"error" => "unauthorised"} =
               conn |> gate(secret) |> put("/tenancy/acme", body(1, "live")) |> json_response(401)

      assert %{"error" => "unauthorised"} =
               conn |> gate(secret) |> get("/tenancy") |> json_response(401)

      assert %{"error" => "unauthorised"} =
               conn |> gate(secret) |> get("/tenancy/acme") |> json_response(401)
    end

    assert conn |> gate() |> get("/tenancy/acme") |> response(404)
  end

  test "a live push is applied, listed and read back", %{conn: conn} do
    assert %{"applied" => true} =
             conn |> gate() |> put("/tenancy/acme", body(1, "live")) |> json_response(200)

    assert [%{"slug" => "acme", "version" => 1}] =
             conn |> gate() |> get("/tenancy") |> json_response(200)

    assert %{
             "version" => 1,
             "state" => "live",
             "members" => [%{"sub" => "s1", "role" => "merchant"}]
           } =
             conn |> gate() |> get("/tenancy/acme") |> json_response(200)

    assert %{"ignored" => true} =
             conn |> gate() |> put("/tenancy/acme", body(1, "live", [])) |> json_response(200)
  end

  test "a body that is not JSON is 422, not Plug.Parsers' 400", %{conn: conn} do
    assert %{"error" => "body: not JSON"} =
             conn |> gate() |> put("/tenancy/acme", "{not json") |> json_response(422)

    assert conn |> gate() |> get("/tenancy/acme") |> response(404)
  end

  test "a malformed body is 422 naming the field", %{conn: conn} do
    bad =
      Jason.encode!(%{
        version: 1,
        state: "live",
        name: "Acme",
        domains: [],
        members: [],
        tools: []
      })

    assert %{"error" => "tools: is not a v1 field"} =
             conn |> gate() |> put("/tenancy/acme", bad) |> json_response(422)
  end

  test "a bad slug is 422 on PUT and 404 on GET", %{conn: conn} do
    assert %{"error" => "slug: must be a DNS label"} =
             conn |> gate() |> put("/tenancy/Not_A_Label", body(1, "live")) |> json_response(422)

    assert conn |> gate() |> get("/tenancy/Not_A_Label") |> response(404)
  end

  test "a purged slug is 404 and unlisted", %{conn: conn} do
    conn |> gate() |> put("/tenancy/acme", body(1, "live"))
    conn |> gate() |> put("/tenancy/acme", body(2, "purged", []))

    assert conn |> gate() |> get("/tenancy/acme") |> response(404)
    assert [] = conn |> gate() |> get("/tenancy") |> json_response(200)
  end

  test "without a single pushed provider a PUT is 503 and nothing is applied", %{conn: conn} do
    Application.put_env(:keila, Oidc, providers: [])

    assert conn |> gate() |> put("/tenancy/acme", body(1, "live")) |> json_response(503)
    assert [] = conn |> gate() |> get("/tenancy") |> json_response(200)
  end

  describe "a pushed member in the app" do
    setup %{conn: conn} do
      conn |> gate() |> put("/tenancy/shop-a", body(1, "live"))

      conn
      |> gate()
      |> put(
        "/tenancy/shop-b",
        body(1, "live", [%{sub: "s2", mail: "s2@shop.example.com", role: "merchant"}])
      )

      user =
        Keila.Repo.get_by!(Keila.Auth.OidcIdentity, subject: "s1")
        |> Map.fetch!(:user_id)
        |> Keila.Auth.get_user()

      %{project_id: b_project} = Keila.Repo.get_by!(Keila.Tenancy.Tenancy, slug: "shop-b")
      %{project_id: a_project} = Keila.Repo.get_by!(Keila.Tenancy.Tenancy, slug: "shop-a")
      {:ok, token} = Keila.Auth.create_token(%{scope: "web.session", user_id: user.id})
      member = build_conn() |> Plug.Test.init_test_session(token: token.key)
      %{member: member, a_project: a_project, b_project: b_project}
    end

    test "proof 3: GET /projects/:id on another shop's project is refused", %{
      member: member,
      a_project: a,
      b_project: b
    } do
      assert member |> get(Routes.project_path(member, :show, a)) |> html_response(200)
      assert member |> get(Routes.project_path(member, :show, b)) |> Map.fetch!(:status) == 404
    end

    test "cannot create a project or delete the shop's", %{member: member, a_project: a} do
      assert member |> get(Routes.project_path(member, :new)) |> response(403)
      assert member |> get(Routes.project_path(member, :delete, a)) |> response(403)
    end
  end
end
