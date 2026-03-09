defmodule Arbor.AI.SensitivityRouter.RoutingDecision do
  @moduledoc """
  Structured result from sensitivity routing decisions.

  Returned by `SensitivityRouter.decide/4` to give callers full context
  about what happened and why, enabling UX-appropriate responses.
  """

  @type action :: :proceed | :rerouted | :blocked

  @type t :: %__MODULE__{
          action: action(),
          original: {atom(), String.t()} | nil,
          alternative: {atom(), String.t()} | nil,
          sensitivity: atom() | nil,
          mode: atom() | nil,
          reason: String.t() | nil
        }

  defstruct [:action, :original, :alternative, :sensitivity, :mode, :reason]
end

defmodule Arbor.AI.SensitivityRouter do
  @moduledoc """
  Sensitivity-aware LLM provider/model auto-selection router.

  Pure-function module (no state) that selects the best `{provider, model}`
  pair based on data sensitivity classification. Bridges the gap between
  the taint system (which classifies data) and LLM routing (which picks providers).

  ## How It Works

  1. `BackendTrust.can_see?/3` checks if a `{provider, model}` can handle a sensitivity level
  2. Candidates are filtered by clearance, then sorted by priority (lower = preferred)
  3. The current provider is preferred if it already qualifies (stability)

  ## Routing Modes

  The router supports four modes that control UX behavior when rerouting:

  - `:auto` — reroute silently (current behavior, for trusted agents)
  - `:warn` — reroute + emit signal (UI notification)
  - `:gated` — reroute + emit signal + write decision to context
  - `:block` — fail request with error, refuse to send

  Modes are determined by the agent's trust profile via `Arbor.Trust.effective_mode/3`
  for the `arbor://ai/sensitivity` URI prefix, with per-agent overrides.

  Trust profile modes map to routing modes:
  - `:block` → `:block` (refuse to route)
  - `:ask` → `:gated` (route + require confirmation)
  - `:allow` → `:warn` (route + notify)
  - `:auto` → `:auto` (route silently)

  ## Configuration

      config :arbor_ai, :routing_candidates, [
        %{provider: :ollama, model: "llama3.2", priority: 1},
        %{provider: :anthropic, model: "claude-sonnet-4-5-20250514", priority: 2},
        %{provider: :openrouter, model: "anthropic/claude-sonnet-4-5-20250514", priority: 3}
      ]

      config :arbor_ai, :sensitivity_routing_overrides, %{
        "agent_secrets_handler" => :block
      }
  """

  alias Arbor.AI.BackendTrust
  alias Arbor.AI.SensitivityRouter.RoutingDecision

  require Logger

  @type sensitivity :: :public | :internal | :confidential | :restricted

  @type candidate :: %{
          provider: atom(),
          model: String.t(),
          priority: non_neg_integer()
        }

  @type routing_mode :: :auto | :warn | :gated | :block

  @doc """
  Make a routing decision with mode-based behavior.

  Returns a `%RoutingDecision{}` struct describing what should happen.
  The caller is responsible for acting on the decision (e.g., emitting
  signals for `:warn`/`:gated`, blocking for `:block`).

  ## Options

  - `:agent_id` — agent ID for trust-tier lookup and per-agent overrides
  - `:candidates` — override the configured candidate pool
  - `:mode` — explicit mode override (bypasses trust-tier resolution)

  ## Returns

  - `%RoutingDecision{action: :proceed}` — current provider is fine
  - `%RoutingDecision{action: :rerouted, mode: mode, ...}` — rerouted with mode context
  - `%RoutingDecision{action: :blocked, reason: "..."}` — request blocked
  """
  @spec decide(atom(), String.t(), sensitivity() | nil, keyword()) :: RoutingDecision.t()
  def decide(provider, model, nil, _opts) do
    %RoutingDecision{action: :proceed, original: {provider, model}}
  end

  def decide(provider, model, :public, _opts) do
    %RoutingDecision{action: :proceed, original: {provider, model}, sensitivity: :public}
  end

  def decide(provider, model, sensitivity, opts) do
    if BackendTrust.can_see?(provider, model, sensitivity) do
      %RoutingDecision{action: :proceed, original: {provider, model}, sensitivity: sensitivity}
    else
      agent_id = Keyword.get(opts, :agent_id)
      mode = Keyword.get(opts, :mode) || resolve_mode(agent_id)
      decide_with_mode(provider, model, sensitivity, mode, agent_id, opts)
    end
  end

  defp decide_with_mode(provider, model, sensitivity, :block, agent_id, _opts) do
    decision = %RoutingDecision{
      action: :blocked,
      original: {provider, model},
      sensitivity: sensitivity,
      mode: :block,
      reason:
        "#{provider}/#{model} cannot handle #{sensitivity} data; " <>
          "routing blocked by policy"
    }

    safe_emit_signal(:sensitivity_blocked, %{
      original: {provider, model},
      sensitivity: sensitivity,
      agent_id: agent_id
    })

    decision
  end

  defp decide_with_mode(provider, model, sensitivity, mode, agent_id, opts) do
    select_opts =
      opts
      |> Keyword.put(:current_provider, provider)
      |> Keyword.put(:current_model, model)

    case select(sensitivity, select_opts) do
      {:ok, {new_provider, new_model}} ->
        build_rerouted_decision(
          {provider, model},
          {new_provider, new_model},
          sensitivity,
          mode,
          agent_id
        )

      {:error, :no_candidates} ->
        Logger.warning(
          "[SensitivityRouter] No candidates for #{sensitivity} data, " <>
            "keeping #{provider}/#{model}"
        )

        %RoutingDecision{
          action: :proceed,
          original: {provider, model},
          sensitivity: sensitivity,
          mode: mode,
          reason: "No alternative candidates available"
        }
    end
  end

  defp build_rerouted_decision(
         {provider, model} = original,
         {new_provider, new_model} = alternative,
         sensitivity,
         mode,
         agent_id
       ) do
    decision = %RoutingDecision{
      action: :rerouted,
      original: original,
      alternative: alternative,
      sensitivity: sensitivity,
      mode: mode,
      reason:
        "#{provider}/#{model} cannot handle #{sensitivity} data; " <>
          "rerouted to #{new_provider}/#{new_model}"
    }

    maybe_emit_reroute_signal(mode, original, alternative, sensitivity, agent_id)
    Logger.info("[SensitivityRouter] #{decision.reason} (mode=#{mode})")
    decision
  end

  defp maybe_emit_reroute_signal(:auto, _original, _alternative, _sensitivity, _agent_id),
    do: :ok

  defp maybe_emit_reroute_signal(mode, original, alternative, sensitivity, agent_id) do
    signal_type = if mode == :gated, do: :sensitivity_gated, else: :sensitivity_rerouted

    safe_emit_signal(signal_type, %{
      original: original,
      alternative: alternative,
      sensitivity: sensitivity,
      mode: mode,
      agent_id: agent_id
    })
  end

  @doc """
  Resolve the routing mode for an agent based on trust profile.

  Uses `Arbor.Trust.effective_mode/3` to look up the agent's profile-based
  trust mode for the `arbor://ai/sensitivity` URI prefix, then maps to
  a routing mode:

  - `:block` → `:block` (refuse to route)
  - `:ask` → `:gated` (route + require confirmation)
  - `:allow` → `:warn` (route + notify)
  - `:auto` → `:auto` (route silently)

  Per-agent overrides in `:sensitivity_routing_overrides` take precedence.
  Falls back to `:warn` if the trust system is unavailable.

  ## Examples

      resolve_mode("agent_001")  #=> :gated  (new agent, :ask profile)
      resolve_mode("agent_vet")  #=> :auto   (veteran agent, :auto profile)
      resolve_mode(nil)          #=> :warn   (no agent context)
  """
  @spec resolve_mode(String.t() | nil) :: routing_mode()
  def resolve_mode(nil), do: :warn

  def resolve_mode(agent_id) when is_binary(agent_id) do
    # Check per-agent overrides first
    overrides = Application.get_env(:arbor_ai, :sensitivity_routing_overrides, %{})

    case Map.get(overrides, agent_id) do
      mode when mode in [:auto, :warn, :gated, :block] ->
        mode

      _ ->
        resolve_mode_from_trust(agent_id)
    end
  end

  def resolve_mode(_), do: :warn

  @doc """
  Select the best `{provider, model}` pair for the given sensitivity level.

  Filters configured candidates by `BackendTrust.can_see?/3`, then sorts by:
  1. Priority (lower = preferred)
  2. Trust level breadth as tiebreaker (more capable = preferred)

  ## Options

  - `:current_provider` — prefer this provider if it qualifies (stability)
  - `:current_model` — prefer this model if it qualifies (stability)
  - `:candidates` — override the configured candidate pool

  ## Returns

  - `{:ok, {provider, model}}` — best candidate found
  - `{:error, :no_candidates}` — no configured candidates can handle this sensitivity
  """
  @spec select(sensitivity(), keyword()) :: {:ok, {atom(), String.t()}} | {:error, :no_candidates}
  def select(sensitivity, opts \\ []) do
    candidates = Keyword.get(opts, :candidates) || configured_candidates()
    current_provider = Keyword.get(opts, :current_provider)
    current_model = Keyword.get(opts, :current_model)

    qualified =
      candidates
      |> Enum.filter(fn %{provider: p, model: m} ->
        BackendTrust.can_see?(p, m, sensitivity)
      end)
      |> Enum.sort_by(fn %{priority: priority} -> priority end)

    case qualified do
      [] ->
        {:error, :no_candidates}

      candidates_list ->
        # Prefer current provider+model if it's in the qualified list (stability)
        preferred =
          if current_provider do
            Enum.find(candidates_list, fn %{provider: p, model: m} ->
              p == current_provider and (current_model == nil or m == current_model)
            end)
          end

        case preferred do
          %{provider: p, model: m} ->
            {:ok, {p, m}}

          nil ->
            %{provider: p, model: m} = hd(candidates_list)
            {:ok, {p, m}}
        end
    end
  end

  @doc """
  Validate that a `{provider, model}` pair can handle the given sensitivity.

  ## Returns

  - `:ok` — the pair has sufficient clearance
  - `{:error, :insufficient_clearance}` — the pair cannot handle this sensitivity
  """
  @spec validate(atom(), String.t(), sensitivity()) :: :ok | {:error, :insufficient_clearance}
  def validate(provider, model, sensitivity)
      when is_atom(provider) and is_binary(model) and is_atom(sensitivity) do
    if BackendTrust.can_see?(provider, model, sensitivity) do
      :ok
    else
      {:error, :insufficient_clearance}
    end
  end

  @doc """
  Main integration point: returns original pair if sufficient, selects alternative if not.

  No-op for `:public` data (all providers can handle public data).

  This is the backward-compatible API. New callers should prefer `decide/4`
  for structured routing decisions with mode awareness.

  ## Options

  Same as `select/2`, plus:
  - `:agent_id` — agent ID for trust-tier lookup (passed through to `decide/4`)

  ## Returns

  - `{provider, model}` — original or rerouted pair
  """
  @spec maybe_reroute(atom(), String.t(), sensitivity() | nil, keyword()) ::
          {atom(), String.t()}
  def maybe_reroute(provider, model, nil, _opts), do: {provider, model}
  def maybe_reroute(provider, model, :public, _opts), do: {provider, model}

  def maybe_reroute(provider, model, sensitivity, opts) do
    case decide(provider, model, sensitivity, opts) do
      %RoutingDecision{action: :proceed} ->
        {provider, model}

      %RoutingDecision{action: :rerouted, alternative: {p, m}} ->
        {p, m}

      %RoutingDecision{action: :blocked} ->
        # Backward compat: blocked falls back to original (callers can't handle errors)
        Logger.warning(
          "[SensitivityRouter] Routing blocked for #{provider}/#{model} " <>
            "with #{sensitivity} data, keeping original (legacy API)"
        )

        {provider, model}
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # URI prefix used for sensitivity routing trust resolution.
  @sensitivity_uri "arbor://ai/sensitivity"

  # Resolve mode from agent trust profile via runtime bridge.
  # Uses effective_mode/3 which resolves via ProfileResolver (URI-prefix rules).
  @spec resolve_mode_from_trust(String.t()) :: routing_mode()
  defp resolve_mode_from_trust(agent_id) do
    if trust_effective_mode_available?() do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      trust_mode = apply(Arbor.Trust, :effective_mode, [agent_id, @sensitivity_uri])
      trust_mode_to_routing(trust_mode)
    else
      :warn
    end
  rescue
    _ -> :warn
  catch
    :exit, _ -> :warn
  end

  defp trust_effective_mode_available? do
    Code.ensure_loaded?(Arbor.Trust) and
      function_exported?(Arbor.Trust, :effective_mode, 2)
  end

  # Map trust profile modes to sensitivity routing modes
  defp trust_mode_to_routing(:block), do: :block
  defp trust_mode_to_routing(:ask), do: :gated
  defp trust_mode_to_routing(:allow), do: :warn
  defp trust_mode_to_routing(:auto), do: :auto
  defp trust_mode_to_routing(_), do: :warn

  # Emit a signal via runtime bridge (arbor_ai is Standalone, no compile dep on signals).
  defp safe_emit_signal(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Arbor.Signals, :emit, [:ai, type, data])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Read routing candidates from application config.
  @spec configured_candidates() :: [candidate()]
  defp configured_candidates do
    Application.get_env(:arbor_ai, :routing_candidates, [])
  end
end
