defmodule Keila.Tenancy do
  @moduledoc """
  The receiving end of the platform's tenancy push (contract v1).

  Each slug maps to one shop: an Account, a Project group under it and a Project.
  Pushed members join the Project group only and are matched by their `sub` at
  the provider whose policy is `:pushed`.
  """

  use Keila.Repo
  alias Keila.Accounts.Account
  alias Keila.Auth
  alias Keila.Auth.{Group, OidcIdentity, User, UserGroup}
  alias Keila.Auth.Oidc
  alias Keila.Projects.Project
  alias Keila.Tenancy.Tenancy

  @slug ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/
  @states ~w(live suspended purged)
  @roles ~w(merchant)
  @fields ~w(version state name domains members)
  @member_fields ~w(sub mail role)
  @max_version 9_007_199_254_740_991

  @type state :: %{
          version: pos_integer(),
          state: String.t(),
          name: String.t(),
          domains: [String.t()],
          members: [%{sub: String.t(), mail: String.t(), role: String.t()}]
        }

  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(slug), do: is_binary(slug) and Regex.match?(@slug, slug)

  @spec merchant_issuer() :: {:ok, String.t()} | {:error, :no_merchant_issuer}
  def merchant_issuer do
    case Enum.filter(Oidc.provider_names(), &(Oidc.policy(&1) == :pushed)) do
      [name] -> {:ok, Oidc.issuer(name)}
      _none_or_many -> {:error, :no_merchant_issuer}
    end
  end

  @spec holds_live_shop?(User.id()) :: boolean()
  def holds_live_shop?(user_id) do
    from(t in Tenancy,
      join: p in Project,
      on: p.id == t.project_id,
      join: ug in UserGroup,
      on: ug.group_id == p.group_id,
      where: t.state == "live" and ug.user_id == ^user_id
    )
    |> Repo.exists?()
  end

  @spec pushed_user?(User.id()) :: boolean()
  def pushed_user?(user_id) do
    case merchant_issuer() do
      {:ok, iss} ->
        Repo.exists?(from(i in OidcIdentity, where: i.user_id == ^user_id and i.issuer == ^iss))

      _error ->
        false
    end
  end

  @doc """
  Parses a raw request body strictly; the error names the first refused field.
  """
  @spec parse(binary()) :: {:ok, state()} | {:error, String.t()}
  def parse(raw) do
    with {:ok, body} <- decode(raw),
         :ok <- known_keys(body, @fields, nil),
         {:ok, version} <- version(body["version"]),
         {:ok, state} <- one_of(body["state"], "state", @states),
         {:ok, name} <- text(body["name"], "name"),
         {:ok, domains} <- texts(body["domains"]),
         {:ok, members} <- members(body["members"]) do
      {:ok, %{version: version, state: state, name: name, domains: domains, members: members}}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _other} -> {:error, "body: must be an object"}
      {:error, _reason} -> {:error, "body: not JSON"}
    end
  end

  defp known_keys(map, allowed, prefix) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, "#{field(prefix, key)}: is not a v1 field"}
    end
  end

  defp field(nil, key), do: key
  defp field(prefix, key), do: "#{prefix}.#{key}"

  defp version(v) when is_integer(v) and v >= 1 and v <= @max_version, do: {:ok, v}
  defp version(_v), do: {:error, "version: must be a positive integer"}

  defp one_of(value, field, allowed) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "#{field}: must be one of #{Enum.join(allowed, ", ")}"}
  end

  defp text(value, field) do
    if is_binary(value) and String.trim(value) != "",
      do: {:ok, value},
      else: {:error, "#{field}: must be a non-empty string"}
  end

  defp texts(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> collect(fn {value, i} -> text(value, "domains[#{i}]") end)
  end

  defp texts(_other), do: {:error, "domains: must be an array"}

  defp members(list) when is_list(list) do
    with {:ok, members} <- list |> Enum.with_index() |> collect(&member/1) do
      unique_subs(members)
    end
  end

  defp members(_other), do: {:error, "members: must be an array"}

  defp member({raw, i}) do
    at = "members[#{i}]"

    with true <- is_map(raw) || {:error, "#{at}: must be an object"},
         :ok <- known_keys(raw, @member_fields, at),
         {:ok, mail} <- text(raw["mail"], "#{at}.mail"),
         true <- String.contains?(mail, "@") || {:error, "#{at}.mail: must be an address"},
         {:ok, sub} <- text(raw["sub"], "#{at}.sub"),
         {:ok, role} <- one_of(raw["role"], "#{at}.role", @roles) do
      {:ok, %{sub: sub, mail: mail, role: role}}
    end
  end

  defp unique_subs(members) do
    members
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {%{sub: sub}, i}, seen ->
      if MapSet.member?(seen, sub),
        do: {:halt, {:error, "members[#{i}].sub: repeats #{sub}"}},
        else: {:cont, MapSet.put(seen, sub)}
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> {:ok, members}
    end
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  Applies a parsed state to `slug` in one transaction, or ignores it when its
  version is not above the last one applied (a purge tombstone included).
  """
  @spec apply_state(String.t(), state()) ::
          {:ok, :applied | :ignored} | {:error, :no_merchant_issuer | {:malformed, String.t()}}
  def apply_state(slug, next) do
    with {:ok, iss} <- merchant_issuer() do
      Repo.transaction(fn ->
        held = lock(slug)

        if next.version <= held.version do
          :ignored
        else
          held |> transition(next, iss) |> Repo.update!()
          :applied
        end
      end)
    end
  end

  # A slug never seen starts as a tombstone at version 0, so a first push is just a transition.
  defp lock(slug) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Tenancy,
      [
        %{
          slug: slug,
          version: 0,
          state: "purged",
          name: slug,
          domains: [],
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: :slug
    )

    from(t in Tenancy, where: t.slug == ^slug, lock: "FOR UPDATE") |> Repo.one!()
  end

  defp transition(held, next = %{state: "purged"}, _iss) do
    purge(held)

    change(
      held,
      Map.take(next, [:version, :state, :name, :domains])
      |> Map.merge(%{project_id: nil, account_id: nil})
    )
  end

  defp transition(held, next, iss) do
    held = ensure_shop(held, next.name)
    group_id = project_group_id(held.project_id)

    keep =
      if next.state == "live",
        do: Enum.map(next.members |> Enum.with_index(), &add_member(&1, iss, group_id)),
        else: []

    revoke_others(group_id, iss, keep)
    change(held, Map.take(next, [:version, :state, :name, :domains]))
  end

  defp ensure_shop(held = %Tenancy{project_id: nil}, name) do
    with {:ok, account} <- Keila.Accounts.create_account(),
         {:ok, group} <- Auth.create_group(%{parent_id: account.group_id}),
         {:ok, project} <-
           %{"name" => name, "group_id" => group.id}
           |> Project.creation_changeset()
           |> Repo.insert() do
      held
      |> change(%{project_id: project.id, account_id: account.id})
      |> Repo.update!()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_shop(held, name) do
    held.project_id
    |> Keila.Projects.get_project()
    |> Project.update_changeset(%{"name" => name})
    |> Repo.update!()

    held
  end

  # accounts.group_id has no ON DELETE, so the Account row goes first; dropping its group then
  # cascades to the Project group, the Project and everything the Project owns. Users stay.
  defp purge(%Tenancy{account_id: nil}), do: :ok

  defp purge(%Tenancy{account_id: account_id}) do
    group_id = Repo.one!(from(a in Account, where: a.id == ^account_id, select: a.group_id))
    Repo.delete_all(from(a in Account, where: a.id == ^account_id))
    Repo.delete_all(from(g in Group, where: g.id == ^group_id))
  end

  defp add_member({member, i}, iss, group_id) do
    user = upsert_member(member, iss, "members[#{i}].mail")

    # add_user_to_group/2 is idempotent by catching a unique violation, which aborts this transaction.
    with false <- Auth.user_in_group?(user.id, group_id),
         {:error, reason} <- Auth.add_user_to_group(user.id, group_id) do
      Repo.rollback(reason)
    end

    user.id
  end

  defp upsert_member(%{sub: sub, mail: mail}, iss, field) do
    case Repo.get_by(OidcIdentity, issuer: iss, subject: sub) do
      %OidcIdentity{user_id: user_id} -> update_mail(Auth.get_user(user_id), mail, field)
      nil -> create_member(iss, sub, mail, field)
    end
  end

  defp update_mail(user, mail, field) do
    if String.downcase(user.email) == String.downcase(mail) do
      user
    else
      refuse_taken(mail, user.id, field)

      user
      |> User.update_email_changeset(%{email: mail})
      |> Repo.update()
      |> unwrap(field)
    end
  end

  defp create_member(iss, sub, mail, field) do
    refuse_taken(mail, nil, field)
    params = %{"email" => mail, "locale" => Gettext.get_locale()}
    params |> User.oidc_creation_changeset() |> validated(field)

    user =
      params
      |> Auth.create_user(changeset: :oidc, skip_activation_email: true)
      |> unwrap(field)

    %{issuer: iss, subject: sub, user_id: user.id}
    |> OidcIdentity.changeset()
    |> Repo.insert!()

    user
  end

  defp refuse_taken(mail, user_id, field) do
    from(u in User, where: fragment("lower(?) = lower(?)", u.email, ^mail))
    |> then(fn q -> if user_id, do: where(q, [u], u.id != ^user_id), else: q end)
    |> Repo.exists?()
    |> if(do: Repo.rollback({:malformed, "#{field}: belongs to another user"}))
  end

  defp validated(changeset, field) do
    case changeset.errors[:email] do
      nil -> :ok
      {why, _opts} -> Repo.rollback({:malformed, "#{field}: #{why}"})
    end
  end

  defp unwrap({:ok, user}, _field), do: user

  defp unwrap({:error, changeset}, field),
    do: validated(changeset, field) && Repo.rollback(changeset)

  defp revoke_others(group_id, iss, keep) do
    group_id
    |> pushed_member_ids(iss)
    |> Enum.reject(&(&1 in keep))
    |> Enum.each(&Auth.remove_user_from_group(&1, group_id))
  end

  defp pushed_member_ids(group_id, iss) do
    from(ug in UserGroup,
      join: i in OidcIdentity,
      on: i.user_id == ug.user_id and i.issuer == ^iss,
      where: ug.group_id == ^group_id,
      select: ug.user_id
    )
    |> Repo.all()
  end

  defp project_group_id(project_id) do
    Repo.one!(from(p in Project, where: p.id == ^project_id, select: p.group_id))
  end

  @doc """
  Reads back what Keila holds for `slug`; a purged or unknown slug is `:not_found`.
  """
  @spec read(String.t()) ::
          {:ok, %{version: integer(), state: String.t(), members: [map()]}}
          | {:error, :not_found | :no_merchant_issuer}
  def read(slug) do
    with {:ok, iss} <- merchant_issuer(),
         %Tenancy{state: state} = held when state != "purged" <- Repo.get_by(Tenancy, slug: slug) do
      {:ok, %{version: held.version, state: held.state, members: read_members(held, iss)}}
    else
      {:error, _} = error -> error
      _purged_or_unknown -> {:error, :not_found}
    end
  end

  defp read_members(%Tenancy{project_id: nil}, _iss), do: []

  defp read_members(held, iss) do
    from(p in Project,
      join: ug in UserGroup,
      on: ug.group_id == p.group_id,
      join: i in OidcIdentity,
      on: i.user_id == ug.user_id and i.issuer == ^iss,
      where: p.id == ^held.project_id,
      order_by: i.subject,
      select: %{sub: i.subject, role: "merchant"}
    )
    |> Repo.all()
  end

  @spec list() :: [%{slug: String.t(), version: integer()}]
  def list do
    from(t in Tenancy,
      where: t.state != "purged",
      order_by: t.slug,
      select: %{slug: t.slug, version: t.version}
    )
    |> Repo.all()
  end
end
