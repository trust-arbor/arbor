defmodule Arbor.Security.IdentityAlias do
  @moduledoc """
  Resolve an identity to the primary it is linked to.

  `mix arbor.user.link` associates several proof subjects with one primary
  private-conversation owner. Resolution is an ownership input, never proof of
  authentication or permission: grants, revocation and audit retain the exact
  authenticated subject. Callers choose explicitly whether a comparison concerns
  the proof subject or canonical private owner.

  ## Why the storage is injected

  Alias records live in `Arbor.Persistence.BufferedStore` (`arbor_persistence`,
  L3). This library is L2, so it cannot depend on that store — a direct call
  would invert the hierarchy the dependency guard enforces. Resolution is the
  part that belongs low, next to the other identity primitives; the store is an
  injectable detail supplied by a library that may depend on both.

      config :arbor_security, identity_alias_resolver: MyResolver

  ## Fail closed

  `resolve/1` returns `{:error, _}` when no resolver is configured or the store
  is unavailable. It deliberately does NOT fall back to returning the input id.

  An unresolvable identity must not look like an independent primary during an
  outage. Conversation admission and continuations require successful resolution
  and deny when it is unavailable.
  """

  @callback resolve(String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Resolve `id` to its primary, or `{:error, reason}`.

  An id with no alias record resolves to itself — that is a successful
  resolution, not a failure. A missing resolver or an unreachable store is a
  failure.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(id) when is_binary(id) and id != "" do
    case resolver() do
      nil ->
        {:error, :identity_alias_resolver_unconfigured}

      module when is_atom(module) ->
        safe_resolve(module, id)
    end
  end

  def resolve(_id), do: {:error, :invalid_identity}

  @doc """
  True when both ids resolve to the same primary.

  Fails CLOSED: any resolution error returns false. Two identical ids compare
  equal without consulting the store, so an outage cannot break the common case.
  """
  @spec same_principal?(String.t(), String.t()) :: boolean()
  def same_principal?(a, b) when is_binary(a) and is_binary(b) do
    if a == b do
      true
    else
      case {resolve(a), resolve(b)} do
        {{:ok, primary}, {:ok, primary}} -> true
        _ -> false
      end
    end
  end

  def same_principal?(_a, _b), do: false

  @doc "The configured resolver module, or nil."
  @spec resolver() :: module() | nil
  def resolver, do: Application.get_env(:arbor_security, :identity_alias_resolver)

  defp safe_resolve(module, id) do
    case module.resolve(id) do
      {:ok, primary} when is_binary(primary) and primary != "" -> {:ok, primary}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :identity_alias_malformed}
    end
  rescue
    exception -> {:error, {:identity_alias_raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:identity_alias_threw, {kind, reason}}}
  end
end
