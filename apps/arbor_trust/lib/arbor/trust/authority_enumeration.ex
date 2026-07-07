defmodule Arbor.Trust.AuthorityEnumeration do
  @moduledoc """
  Read-only authority snapshots for a principal.

  A6 closes the enumeration gap introduced by trust-policy JIT minting: listing
  held capability tokens alone undercounts what an agent can request, while
  calling `Arbor.Trust.authorize/4` to test candidates mutates the system by
  minting those tokens. This module keeps enumeration side-effect free by
  combining:

  - held capabilities already in the security store
  - caller-supplied candidate URIs the trust profile would JIT-mint

  The candidate URI universe is supplied by higher-level callers because
  `arbor_trust` cannot depend on tool/action registries.
  """

  alias Arbor.Trust.{Policy, PolicyEnforcer}

  @type mode :: :block | :ask | :allow | :auto

  @type candidate_entry :: %{
          required(:uri) => String.t(),
          required(:mode) => mode(),
          required(:held) => boolean(),
          required(:held_capability_ids) => [String.t()],
          required(:policy_mintable) => boolean(),
          required(:sources) => [:held_capability | :policy_mintable],
          optional(:policy_error) => term()
        }

  @type snapshot :: %{
          required(:principal_id) => String.t(),
          required(:held_capabilities) => [Arbor.Contracts.Security.Capability.t()],
          required(:held_uris) => [String.t()],
          required(:policy_mintable_uris) => [String.t()],
          required(:effective_uris) => [String.t()],
          required(:candidate_entries) => [candidate_entry()]
        }

  @doc """
  Enumerate held and profile-mintable authority for `candidate_uris`.

  This is a read-only operation. It does not grant capabilities, submit
  approval proposals, increment usage counters, or emit authorization signals.

  `candidate_uris` should be the finite surface the caller cares about (for
  example known action/tool URIs). Held capabilities are always listed in
  `:held_capabilities`/`:held_uris`, even when they do not correspond to a
  candidate URI.
  """
  @spec enumerate(String.t(), [String.t()], keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def enumerate(principal_id, candidate_uris, opts \\ [])

  def enumerate(principal_id, candidate_uris, opts)
      when is_binary(principal_id) do
    with {:ok, held_capabilities} <- list_held_capabilities(principal_id, opts) do
      candidates = normalize_candidate_uris(candidate_uris)

      entries =
        Enum.map(candidates, fn uri ->
          entry_for_candidate(principal_id, uri, held_capabilities, opts)
        end)

      {:ok,
       %{
         principal_id: principal_id,
         held_capabilities: held_capabilities,
         held_uris:
           held_capabilities |> Enum.map(& &1.resource_uri) |> Enum.uniq() |> Enum.sort(),
         policy_mintable_uris: entries |> mintable_uris() |> Enum.sort(),
         effective_uris: entries |> effective_uris() |> Enum.sort(),
         candidate_entries: entries
       }}
    end
  end

  def enumerate(_principal_id, _candidate_uris, _opts), do: {:error, :invalid_principal}

  @doc """
  True when a candidate entry represents authority usable through trust-layer
  authorization.
  """
  @spec effective_entry?(candidate_entry()) :: boolean()
  def effective_entry?(%{sources: [], mode: _mode}), do: false
  def effective_entry?(%{mode: :block}), do: false
  def effective_entry?(%{sources: sources}), do: sources != []

  defp list_held_capabilities(principal_id, opts) do
    list_opts =
      opts
      |> Keyword.take([:include_expired])

    case Arbor.Security.list_capabilities(principal_id, list_opts) do
      {:ok, caps} -> {:ok, caps}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :capability_store_unavailable}
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
  end

  defp normalize_candidate_uris(candidate_uris) do
    candidate_uris
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp entry_for_candidate(principal_id, uri, held_capabilities, opts) do
    matching_caps =
      Enum.filter(held_capabilities, &Arbor.Security.capability_authorizes?(&1, uri, opts))

    held? = matching_caps != []
    {mode, policy_error} = policy_mode(principal_id, uri, opts)

    policy_mintable? =
      not held? and is_nil(policy_error) and
        PolicyEnforcer.mintable?(principal_id, uri, opts)

    sources =
      []
      |> maybe_add_source(held?, :held_capability)
      |> maybe_add_source(policy_mintable?, :policy_mintable)

    entry = %{
      uri: uri,
      mode: mode,
      held: held?,
      held_capability_ids: Enum.map(matching_caps, & &1.id),
      policy_mintable: policy_mintable?,
      sources: sources
    }

    if policy_error do
      Map.put(entry, :policy_error, policy_error)
    else
      entry
    end
  end

  defp policy_mode(principal_id, uri, opts) do
    explanation = Policy.explain(principal_id, uri, opts)

    case Map.fetch(explanation, :error) do
      {:ok, reason} -> {Map.get(explanation, :effective_mode, :ask), reason}
      :error -> {Map.fetch!(explanation, :effective_mode), nil}
    end
  end

  defp maybe_add_source(sources, true, source), do: [source | sources]
  defp maybe_add_source(sources, false, _source), do: sources

  defp mintable_uris(entries) do
    entries
    |> Enum.filter(& &1.policy_mintable)
    |> Enum.map(& &1.uri)
  end

  defp effective_uris(entries) do
    entries
    |> Enum.filter(&effective_entry?/1)
    |> Enum.map(& &1.uri)
  end
end
