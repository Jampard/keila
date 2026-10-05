defmodule KeilaWeb.SourceLinkTest do
  use KeilaWeb.ConnCase, async: false
  alias Keila.Contacts

  @upstream "https://github.com/pentacent/keila"

  setup do
    previous = Application.get_env(:keila, KeilaWeb.SourceLink)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:keila, KeilaWeb.SourceLink, previous),
        else: Application.delete_env(:keila, KeilaWeb.SourceLink)
    end)

    :ok
  end

  defp put_source(config), do: Application.put_env(:keila, KeilaWeb.SourceLink, config)

  @tag :source_link
  test "source_url/0 falls back to upstream when unconfigured" do
    put_source([])
    assert KeilaWeb.SourceLink.source_url() == @upstream
  end

  @tag :source_link
  test "source_url/0 ignores a revision without a configured repository" do
    put_source(revision: "abc123")
    assert KeilaWeb.SourceLink.source_url() == @upstream
  end

  @tag :source_link
  test "source_url/0 links the configured repository at the configured revision" do
    put_source(url: "https://example.com/keila/", revision: "abc123")
    assert KeilaWeb.SourceLink.source_url() == "https://example.com/keila/tree/abc123"
  end

  @tag :source_link
  test "source_url/0 links the configured repository alone without a revision" do
    put_source(url: "https://example.com/keila")
    assert KeilaWeb.SourceLink.source_url() == "https://example.com/keila"
  end

  @tag :source_link
  test "the login page links the running revision", %{conn: conn} do
    with_seed()
    put_source(url: "https://example.com/keila", revision: "abc123")

    html = conn |> get(Routes.auth_path(conn, :login)) |> html_response(200)
    assert html =~ ~s{href="https://example.com/keila/tree/abc123"}
    assert html =~ "Source code (modified)"
  end

  @tag :source_link
  test "the login page links upstream when unconfigured", %{conn: conn} do
    with_seed()
    put_source([])

    html = conn |> get(Routes.auth_path(conn, :login)) |> html_response(200)
    assert html =~ ~s{href="#{@upstream}"}
  end

  @tag :source_link
  test "a public form page links the running revision", %{conn: conn} do
    {conn, project} = with_login_and_project(conn)
    {:ok, form} = Contacts.create_empty_form(project.id)
    put_source(url: "https://example.com/keila", revision: "abc123")

    html = conn |> get(Routes.public_form_path(conn, :show, form.id)) |> html_response(200)
    assert html =~ ~s{href="https://example.com/keila/tree/abc123"}
    assert html =~ "Source code (modified)"
  end

  @tag :source_link
  test "a public form page links upstream when unconfigured", %{conn: conn} do
    {conn, project} = with_login_and_project(conn)
    {:ok, form} = Contacts.create_empty_form(project.id)
    put_source([])

    html = conn |> get(Routes.public_form_path(conn, :show, form.id)) |> html_response(200)
    assert html =~ ~s{href="#{@upstream}"}
  end
end
