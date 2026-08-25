defmodule Arbor.Security.IdentityAliasTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.IdentityAlias

  @moduletag :fast

  defmodule OkResolver do
    @behaviour Arbor.Security.IdentityAlias
    @impl true
    def resolve("human_alias"), do: {:ok, "human_primary"}
    def resolve("human_other"), do: {:ok, "human_primary"}
    def resolve("human_unrelated"), do: {:ok, "human_unrelated"}
    def resolve(id), do: {:ok, id}
  end

  defmodule DownResolver do
    @behaviour Arbor.Security.IdentityAlias
    @impl true
    def resolve(_id), do: {:error, :alias_store_unavailable}
  end

  defmodule RaisingResolver do
    @behaviour Arbor.Security.IdentityAlias
    @impl true
    def resolve(_id), do: raise("boom")
  end

  defmodule MalformedResolver do
    @behaviour Arbor.Security.IdentityAlias
    @impl true
    def resolve(_id), do: "not a tuple"
  end

  setup do
    prior = Application.get_env(:arbor_security, :identity_alias_resolver)
    on_exit(fn -> Application.put_env(:arbor_security, :identity_alias_resolver, prior) end)
    :ok
  end

  defp with_resolver(mod),
    do: Application.put_env(:arbor_security, :identity_alias_resolver, mod)

  describe "resolve/1" do
    test "an unconfigured resolver is an ERROR, never a fallback to the input id" do
      Application.delete_env(:arbor_security, :identity_alias_resolver)

      # The tempting fallback — return the id unchanged — is unsafe by
      # construction: a caller treating "resolved" as "authorized" would grant
      # on an outage, because an unresolvable id looks like a valid primary.
      assert {:error, :identity_alias_resolver_unconfigured} = IdentityAlias.resolve("human_a")
    end

    test "an unavailable store is an error" do
      with_resolver(DownResolver)
      assert {:error, :alias_store_unavailable} = IdentityAlias.resolve("human_a")
    end

    test "a raising resolver is contained as an error" do
      with_resolver(RaisingResolver)
      assert {:error, {:identity_alias_raised, _}} = IdentityAlias.resolve("human_a")
    end

    test "a malformed return is an error, not a pass-through" do
      with_resolver(MalformedResolver)
      assert {:error, :identity_alias_malformed} = IdentityAlias.resolve("human_a")
    end

    test "an id with no alias resolves to itself — that is success, not failure" do
      with_resolver(OkResolver)
      assert {:ok, "human_unrelated"} = IdentityAlias.resolve("human_unrelated")
    end
  end

  describe "same_principal?/2" do
    test "identical ids match WITHOUT consulting the store" do
      # No resolver configured at all: an outage must not break the common case.
      Application.delete_env(:arbor_security, :identity_alias_resolver)
      assert IdentityAlias.same_principal?("human_a", "human_a")
    end

    test "two ids linked to one primary are the same principal" do
      with_resolver(OkResolver)
      assert IdentityAlias.same_principal?("human_alias", "human_other")
      assert IdentityAlias.same_principal?("human_alias", "human_primary")
    end

    test "unlinked ids are NOT the same principal" do
      with_resolver(OkResolver)
      refute IdentityAlias.same_principal?("human_alias", "human_unrelated")
    end

    test "security regression: fails CLOSED when the store is unavailable" do
      # Distinct ids that WOULD resolve equal must not be admitted while the
      # store cannot be consulted. Failing open here would let an outage widen
      # who counts as a turn's owner.
      with_resolver(DownResolver)
      refute IdentityAlias.same_principal?("human_alias", "human_other")
    end

    test "security regression: fails closed with no resolver configured" do
      Application.delete_env(:arbor_security, :identity_alias_resolver)
      refute IdentityAlias.same_principal?("human_alias", "human_other")
    end

    test "non-binary input is never a match" do
      with_resolver(OkResolver)
      refute IdentityAlias.same_principal?(nil, "human_primary")
      refute IdentityAlias.same_principal?("human_primary", nil)
    end
  end
end
