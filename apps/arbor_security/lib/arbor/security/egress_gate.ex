defmodule Arbor.Security.EgressGate do
  @moduledoc """
  The egress decision (2026-06-14 URI-addressing-vs-classification decision),
  shared by the two paths that reach it:

  - `Arbor.Security.AuthDecision` — the capability-authorized action path
    (`authorize_and_execute/4`), passing the matched capability as a candidate.
  - `Arbor.Security.authorize_egress/3` — the standalone path for callers that
    have no operation capability (the compute-node LLM path, `LlmHandler`), which
    supplies the agent's egress-constrained capabilities as candidates.

  Keys off the *resolved classification* (egress_tier + taint), NOT off parsing a
  URI. Inert unless `config :arbor_security, :egress_gate_enforcing` is true (the
  gate lands dark). Composition, in order:

  1. **Taint conjunct** — hostile data to an external destination is an absolute
     hard block. Untrusted data is also blocked except for one exact, already-
     validated interactive-disclosure capability to an external provider route.
  2. **Tier semantics** — `:external_peer` is advisory (1.0 ACP deferral);
     `:on_host`/`:none` allow; `:on_premises` allows unless the on-premises flag.
  3. **Policy standing** — caller-supplied `opts[:egress_mode]` for gated tiers
     (`:allow`/`:ask`/`:block`). The security kernel does not consult trust
     policy directly; callers that want trust-profile modulation supply the
     resolved mode.
  4. **Capability refinement** — a candidate cap whose `constraints.egress`
     (`max_tier`/`destinations`) covers the request downgrades `:ask` -> `:allow`.
  """

  alias Arbor.Contracts.Security.{Capability, CapabilityUri}
  alias Arbor.Contracts.Security.Classification

  @type decision :: :allow | :ask | {:block, atom()}

  # VP-05D2A0 — interactive-disclosure capability namespace. Segment-aware
  # membership only (CapabilityUri.prefix_match?/2), never String.starts_with?/2.
  @disclosure_uri_prefix "arbor://egress/disclose"

  # Escalation order for egress tiers (used for cap max_tier coverage).
  @tier_rank %{
    none: 0,
    on_host: 0,
    on_premises: 1,
    external_provider: 2,
    external_peer: 3
  }

  @doc "Whether egress enforcement is switched on (default false — the gate lands dark)."
  @spec enforcing?() :: boolean()
  def enforcing? do
    Application.get_env(:arbor_security, :egress_gate_enforcing, false) == true
  end

  @doc """
  The egress decision for an agent + resolved tier, given candidate caps for
  refinement. Returns `:allow`, `:ask`, or `{:block, reason}`.

  `opts`: `:egress_taint` (level atom or Taint struct), `:egress_destination`
  (host/provider string for destination-scoped caps), plus the disclosure
  route opts `:egress_provider`/`:egress_runtime`/`:egress_model` consulted
  only when `disclosure_cap` is present.

  `disclosure_cap` (VP-05D2A0) is an already-validated, exact interactive
  disclosure `Capability.t()` (never a raw candidate list, never resolved
  here) — see `Arbor.Security.DisclosureCapability.fetch_and_validate/2`. It
  may admit `:untrusted` data to `:external_provider` on its exact bound
  route ONLY; `:hostile` is always hard-blocked before `disclosure_cap` is
  ever inspected, and no other tier consults it. Ordinary caps in `caps` can
  never perform this override — they only ever reach `cap_covers?/3`, which
  is unreachable while taint is untrusted/hostile.

  An explicit caller-supplied `opts[:egress_mode] == :block` is absolute: it
  is checked before the disclosure override, so a valid exact disclosure
  capability cannot admit `:untrusted` data when the caller has explicitly
  blocked this egress. Only a genuinely un-gated tier (`:on_host`, `:none`) or
  the taint level itself changes that outcome.
  """
  @spec decide(String.t(), atom(), keyword(), [map()], Capability.t() | nil) :: decision()
  def decide(agent_id, tier, opts \\ [], caps \\ [], disclosure_cap \\ nil) do
    cond do
      not enforcing?() ->
        :allow

      Classification.external_egress?(tier) and taint_level(opts) == :hostile ->
        {:block, :hostile}

      Classification.external_egress?(tier) and taint_level(opts) == :untrusted ->
        if not explicit_block?(opts) and disclosure_admits?(disclosure_cap, tier, opts) do
          :allow
        else
          {:block, untrusted_block_reason(opts)}
        end

      true ->
        case policy_mode(agent_id, tier, opts) do
          :block -> {:block, :policy}
          :allow -> :allow
          :ask -> if Enum.any?(caps, &cap_covers?(&1, tier, opts)), do: :allow, else: :ask
        end
    end
  end

  # An explicit :block from the caller-supplied egress standing is absolute —
  # no capability (ordinary or disclosure) may override it. Ordinary caps
  # already can't reach this (cap_covers?/3 is only consulted from the :ask
  # branch of policy_mode/3, never from :block); this guard closes the
  # equivalent gap for the disclosure override specifically.
  defp explicit_block?(opts), do: Keyword.get(opts, :egress_mode) == :block

  defp untrusted_block_reason(opts) do
    if explicit_block?(opts), do: :policy, else: :untrusted
  end

  defp disclosure_admits?(nil, _tier, _opts), do: false

  defp disclosure_admits?(%{resource_uri: uri} = cap, :external_provider, opts) do
    CapabilityUri.prefix_match?(@disclosure_uri_prefix, uri) and
      disclosure_route_matches?(cap, opts)
  end

  defp disclosure_admits?(_cap, _other_tier, _opts), do: false

  defp disclosure_route_matches?(cap, opts) do
    disclosure = disclosure_constraint(cap)

    field(disclosure, :destination) == Keyword.get(opts, :egress_destination) and
      field(disclosure, :provider) == Keyword.get(opts, :egress_provider) and
      field(disclosure, :runtime) == Keyword.get(opts, :egress_runtime) and
      model_matches?(disclosure, opts)
  end

  defp model_matches?(disclosure, opts) do
    if has_field?(disclosure, :model) do
      field(disclosure, :model) == Keyword.get(opts, :egress_model)
    else
      true
    end
  end

  defp disclosure_constraint(%{constraints: constraints}) when is_map(constraints) do
    field(constraints, :disclosure) || %{}
  end

  defp disclosure_constraint(_cap), do: %{}

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp has_field?(map, key) when is_map(map) and is_atom(key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_field?(_map, _key), do: false

  # The intent for a tier from tier semantics + caller-supplied policy standing,
  # EXCLUDING caps.
  @spec policy_mode(String.t(), atom(), keyword()) :: :allow | :ask | :block
  defp policy_mode(_agent_id, tier, opts) do
    case tier do
      :external_peer -> :allow
      :on_host -> :allow
      :none -> :allow
      :on_premises -> if gate_on_premises?(), do: egress_mode(opts), else: :allow
      :external_provider -> egress_mode(opts)
      _ -> :allow
    end
  end

  defp gate_on_premises? do
    Application.get_env(:arbor_security, :gate_on_premises_egress, false) == true
  end

  # The policy layer may pass trust-profile standing in `opts[:egress_mode]`.
  # Missing or malformed standing fails closed to :ask for gated tiers. :auto is
  # equivalent to :allow in this 3-state egress decision.
  defp egress_mode(opts) do
    case Keyword.get(opts, :egress_mode) do
      mode when mode in [:allow, :auto] -> :allow
      :block -> :block
      :ask -> :ask
      _ -> :ask
    end
  end

  # A candidate cap may carry constraints.egress = %{max_tier:, destinations:}.
  # Covers the request iff the resolved tier is at or below max_tier AND (the
  # destinations list is empty OR the resolved destination is in it).
  defp cap_covers?(cap, tier, opts) do
    case egress_constraint(cap) do
      nil ->
        false

      egress ->
        max_tier = normalize_tier(Map.get(egress, :max_tier) || Map.get(egress, "max_tier"))
        destinations = Map.get(egress, :destinations) || Map.get(egress, "destinations") || []

        tier_within?(tier, max_tier) and destination_allowed?(destinations, opts)
    end
  end

  defp egress_constraint(%{constraints: constraints}) when is_map(constraints) do
    Map.get(constraints, :egress) || Map.get(constraints, "egress")
  end

  defp egress_constraint(_), do: nil

  defp tier_within?(_tier, nil), do: false

  defp tier_within?(tier, max_tier) do
    Map.get(@tier_rank, tier, 99) <= Map.get(@tier_rank, max_tier, -1)
  end

  defp destination_allowed?([], _opts), do: true

  defp destination_allowed?(destinations, opts) when is_list(destinations) do
    case Keyword.get(opts, :egress_destination) do
      dest when is_binary(dest) -> dest in destinations
      _ -> false
    end
  end

  defp destination_allowed?(_destinations, _opts), do: false

  defp normalize_tier(tier) when is_atom(tier) and not is_nil(tier), do: tier

  defp normalize_tier(tier) when is_binary(tier) do
    case tier do
      "on_host" -> :on_host
      "on_premises" -> :on_premises
      "external_provider" -> :external_provider
      "external_peer" -> :external_peer
      _ -> nil
    end
  end

  defp normalize_tier(_), do: nil

  # The flowing data's taint level — accepts a bare level atom or a Taint struct.
  defp taint_level(opts) do
    case Keyword.get(opts, :egress_taint) do
      %{level: level} -> level
      level when is_atom(level) -> level
      _ -> nil
    end
  end
end
