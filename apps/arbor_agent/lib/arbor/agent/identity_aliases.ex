defmodule Arbor.Agent.IdentityAliases do
  @moduledoc """
  Maps secondary OIDC identities to a primary Arbor identity.

  When a user has multiple OIDC logins (different providers, different accounts
  on the same provider), each login derives a different `human_<hash>`. Identity
  aliases let all of them resolve to a single primary identity.

  ## Storage

  Aliases are stored in the UserConfig store under a dedicated key per secondary
  identity: `"alias:<secondary_id>"` → `primary_id`.

  The primary identity also stores a list of its linked aliases under the
  `:linked_identities` config key.

  ## Usage

      # Link a secondary identity to a primary
      IdentityAliases.link(caller_id, "human_new_hash", "human_existing_hash")

      # Resolve an identity (returns primary if aliased, or self)
      IdentityAliases.resolve("human_new_hash")
      #=> "human_existing_hash"

      # List all aliases for a primary identity
      IdentityAliases.list_aliases("human_existing_hash")
      #=> ["human_new_hash"]

  ## Security

  Link and unlink require the caller to hold
  `arbor://identity/alias/manage`. Without this gate, any code path that
  could call `link/3` would be able to redirect a victim's future OIDC
  logins to an attacker-controlled identity — and then receive any
  capabilities granted to that identity (M5). This is an admin-class
  operation; resolve and list are read-only and remain ungated.
  """

  alias Arbor.Agent.UserConfig
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore

  require Logger

  @store_name :arbor_user_config
  @alias_prefix "alias:"
  @manage_resource "arbor://identity/alias/manage"

  @doc """
  Link a secondary identity to a primary identity.

  After linking, any OIDC login that derives `secondary_id` will be
  treated as `primary_id`. Requires `caller_id` to hold
  `arbor://identity/alias/manage` (M5).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def link(caller_id, secondary_id, primary_id)
      when is_binary(caller_id) and is_binary(secondary_id) and is_binary(primary_id) do
    with :ok <- authorize_manage(caller_id),
         :ok <- check_not_self(secondary_id, primary_id),
         :ok <- check_primary_not_aliased(primary_id) do
      Logger.info("[IdentityAliases] caller=#{caller_id} linking #{secondary_id} → #{primary_id}")

      do_link(secondary_id, primary_id)
    end
  end

  defp check_not_self(secondary_id, secondary_id), do: {:error, :cannot_alias_self}
  defp check_not_self(_secondary_id, _primary_id), do: :ok

  defp check_primary_not_aliased(primary_id) do
    case resolve(primary_id) do
      ^primary_id -> :ok
      resolved -> {:error, {:primary_is_alias, resolved}}
    end
  end

  # M5: authorize the caller against arbor://identity/alias/manage. The
  # function takes a single string caller_id (NOT a context map) because the
  # callers that exist for this surface — operator REPL, system-internal
  # bootstrap, future admin LiveView — all have a known principal at the
  # call site. We never derive it from process-dict ambient context here.
  defp authorize_manage(caller_id) do
    cond do
      not (Code.ensure_loaded?(Arbor.Security) and
               function_exported?(Arbor.Security, :authorize, 4)) ->
        {:error, :security_unavailable}

      true ->
        case Arbor.Security.authorize(caller_id, @manage_resource, :write) do
          {:ok, :authorized} ->
            :ok

          {:error, reason} ->
            {:error, {:unauthorized_alias_management, reason}}

          {:ok, :pending_approval, _} ->
            {:error, {:unauthorized_alias_management, :pending_approval}}

          other ->
            {:error, {:unauthorized_alias_management, {:unexpected, other}}}
        end
    end
  end

  @doc """
  Resolve an identity to its primary. Returns the input if no alias exists.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(agent_id) when is_binary(agent_id) do
    alias_key = @alias_prefix <> agent_id

    if available?() do
      case BufferedStore.get(alias_key, name: @store_name) do
        {:ok, raw} ->
          case unwrap_data(raw) do
            %{primary_id: primary} -> primary
            %{"primary_id" => primary} -> primary
            _ -> agent_id
          end

        _ ->
          agent_id
      end
    else
      agent_id
    end
  end

  @doc """
  Remove an alias, restoring the secondary identity as independent.

  Requires `caller_id` to hold `arbor://identity/alias/manage` (M5).
  Returns `:ok` on success, `{:error, reason}` if unauthorized.
  """
  @spec unlink(String.t(), String.t()) :: :ok | {:error, term()}
  def unlink(caller_id, secondary_id)
      when is_binary(caller_id) and is_binary(secondary_id) do
    with :ok <- authorize_manage(caller_id) do
      alias_key = @alias_prefix <> secondary_id

      # Find and update the primary's linked list
      primary_id = resolve(secondary_id)

      if primary_id != secondary_id do
        linked = UserConfig.get(primary_id, :linked_identities) || []
        updated = List.delete(linked, secondary_id)
        UserConfig.put(primary_id, :linked_identities, updated)
      end

      # Remove the alias record
      if available?() do
        BufferedStore.delete(alias_key, name: @store_name)
      end

      Logger.info("[IdentityAliases] caller=#{caller_id} unlinking #{secondary_id}")
      :ok
    end
  end

  @doc """
  List all secondary identities linked to a primary.
  """
  @spec list_aliases(String.t()) :: [String.t()]
  def list_aliases(primary_id) when is_binary(primary_id) do
    UserConfig.get(primary_id, :linked_identities) || []
  end

  @doc """
  Check if the alias store is available.
  """
  @spec available?() :: boolean()
  def available?, do: Process.whereis(@store_name) != nil

  # --- Private ---

  defp do_link(secondary_id, primary_id) do
    alias_key = @alias_prefix <> secondary_id

    if available?() do
      # Store the alias mapping
      record = %Record{
        id: alias_key,
        key: alias_key,
        data: %{primary_id: primary_id, secondary_id: secondary_id},
        metadata: %{}
      }

      BufferedStore.put(alias_key, record, name: @store_name)

      # Update the primary's linked identities list
      linked = UserConfig.get(primary_id, :linked_identities) || []

      unless secondary_id in linked do
        UserConfig.put(primary_id, :linked_identities, [secondary_id | linked])
      end

      Logger.info("[IdentityAliases] Linked #{secondary_id} → #{primary_id}")

      :ok
    else
      {:error, :store_unavailable}
    end
  end

  defp unwrap_data(%Record{data: data}), do: data
  defp unwrap_data(%{} = data), do: data
end
