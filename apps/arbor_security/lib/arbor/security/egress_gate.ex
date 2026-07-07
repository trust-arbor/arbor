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

  1. **Taint conjunct** — untrusted/hostile data to an external destination is a
     hard block, NOT bypassable by trust standing or caps (the outbound mirror of
     the taint rebuild's inbound control-param protection).
  2. **Tier semantics** — `:external_peer` is advisory (1.0 ACP deferral);
     `:on_host`/`:none` allow; `:on_premises` allows unless the on-premises flag.
  3. **Policy standing** — caller-supplied `opts[:egress_mode]` for gated tiers
     (`:allow`/`:ask`/`:block`). The security kernel does not consult trust
     policy directly; callers that want trust-profile modulation supply the
     resolved mode.
  4. **Capability refinement** — a candidate cap whose `constraints.egress`
     (`max_tier`/`destinations`) covers the request downgrades `:ask` -> `:allow`.
  """

  alias Arbor.Contracts.Security.Classification

  @type decision :: :allow | :ask | {:block, atom()}

  @blocking_taint [:untrusted, :hostile]

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
  (host/provider string for destination-scoped caps).
  """
  @spec decide(String.t(), atom(), keyword(), [map()]) :: decision()
  def decide(agent_id, tier, opts \\ [], caps \\ []) do
    cond do
      not enforcing?() ->
        :allow

      Classification.external_egress?(tier) and taint_level(opts) in @blocking_taint ->
        {:block, taint_level(opts)}

      true ->
        case policy_mode(agent_id, tier, opts) do
          :block -> {:block, :policy}
          :allow -> :allow
          :ask -> if Enum.any?(caps, &cap_covers?(&1, tier, opts)), do: :allow, else: :ask
        end
    end
  end

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
