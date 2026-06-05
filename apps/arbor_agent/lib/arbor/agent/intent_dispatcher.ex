defmodule Arbor.Agent.IntentDispatcher do
  @moduledoc """
  Resolves an `Arbor.Contracts.Memory.Intent` to an `Arbor.Actions`
  module and dispatches it through `Arbor.Actions.authorize_and_execute/4`,
  returning a `%Percept{}` describing the outcome.

  This is the previously-stubbed `dispatch_physical_intent` path from
  `Arbor.Agent.ActionCycleServer` — the original code referenced a
  function that was never defined on `Arbor.Agent.ToolBridge`, so the
  path silently failed since it was first written. After the Phase 4+
  AgentSDK cleanup, it returned `{:error, :physical_dispatch_not_implemented}`
  with a roadmap inbox item. This module implements the real path.

  ## Design (Option 3: action-driven + capability audit)

  Dispatch resolution is `:action`-driven — the intent's `:action` atom
  is the LLM-natural identifier, same shape every LLM tool-calling API
  uses (OpenAI, Anthropic, etc.). Resolution goes through
  `Arbor.Actions.name_to_module/1` which already handles both
  `"file_read"` and `"file.read"` formats.

  When `:capability` is also set on the intent, it's used as a security
  **audit cross-check** — the resolved module's `canonical_uri_for/2`
  must match the intent's capability hint (prefix match, since a hint
  like `"arbor://fs"` covers any action under that namespace). A
  mismatch returns `{:error, {:capability_mismatch, ...}}` rather than
  executing — fail-closed on potential LLM tampering or namespace
  drift.

  ## Static module, pure helpers

  Behaviour injection was considered and rejected for v1 — the
  plausible second-implementation cases (test-mode, sandbox, council
  read-only, dry-run) are all better solved as hooks/decoration or
  at the intent-emission layer, not as alternative dispatchers. The
  internals are structured as small pure functions
  (`resolve_action_module/1`, `audit_capability_match/3`,
  `build_action_context/3`) so behaviour extraction is a small
  refactor if needed later.

  ## Return shape

  `dispatch/3` returns:

    * `{:ok, %Percept{outcome: :success | :failure | :blocked, ...}}`
      — the action was dispatched successfully. The percept's
      `:outcome` reflects what happened during execution
      (`:success` for normal returns; `:blocked` for capability
      denials, taint enforcement, or pending-approval; `:failure`
      for runtime errors).
    * `{:error, reason}` — the dispatcher couldn't dispatch the
      intent at all (missing `:action`, unknown action name,
      capability mismatch, non-`:act` intent type, etc.). The
      caller should treat this as a system-level failure, not a
      negative outcome to feed back to the LLM.
  """

  alias Arbor.Contracts.Memory.{Intent, Percept}

  @type opts :: keyword()
  @type result :: {:ok, Percept.t()} | {:error, term()}

  @doc """
  Dispatch an actionable intent.

  ## Options

    * `:workspace` — the agent's workspace path; threaded into the
      action's context for path-traversal protection in File.* actions.
    * `:context` — extra fields to merge into the action's context
      (e.g. `:signed_request` for cryptographic auth flows).
  """
  @spec dispatch(String.t(), Intent.t(), opts()) :: result()
  def dispatch(agent_id, %Intent{} = intent, opts \\ []) when is_binary(agent_id) do
    with :ok <- ensure_actionable(intent),
         {:ok, module} <- resolve_action_module(intent),
         :ok <- audit_capability_match(module, intent.params, intent.capability) do
      context = build_action_context(agent_id, intent, opts)
      execute(agent_id, module, intent, context)
    end
  end

  # ── Resolution ─────────────────────────────────────────────────────

  @doc """
  Return `:ok` if the intent is `:act`-typed (suitable for body
  execution); `{:error, ...}` otherwise. Pure helper exposed so
  alternative cycle harnesses can pre-filter before calling
  `dispatch/3`.
  """
  @spec ensure_actionable(Intent.t()) :: :ok | {:error, {:non_actionable_intent, atom()}}
  def ensure_actionable(%Intent{type: :act}), do: :ok
  def ensure_actionable(%Intent{type: type}), do: {:error, {:non_actionable_intent, type}}

  @doc """
  Resolve the intent's `:action` atom to an `Arbor.Actions` module via
  `Arbor.Actions.name_to_module/1`.

  Returns `{:error, :intent_missing_action}` if `:action` is nil,
  `{:error, {:unknown_action, name}}` if the name doesn't match any
  registered action.
  """
  @spec resolve_action_module(Intent.t()) ::
          {:ok, module()} | {:error, :intent_missing_action | {:unknown_action, atom()}}
  def resolve_action_module(%Intent{action: nil}), do: {:error, :intent_missing_action}

  def resolve_action_module(%Intent{action: action_name}) when is_atom(action_name) do
    case Arbor.Actions.name_to_module(Atom.to_string(action_name)) do
      {:ok, module} -> {:ok, module}
      {:error, :unknown_action} -> {:error, {:unknown_action, action_name}}
    end
  end

  # ── Capability audit ──────────────────────────────────────────────

  @doc """
  Cross-check the resolved module's canonical URI against the intent's
  `:capability` hint. Returns `:ok` when the hint is absent OR is a
  prefix of the module's canonical URI; `{:error, {:capability_mismatch, _}}`
  otherwise.

  The prefix-match semantic lets the LLM emit a namespace-level hint
  (`"arbor://fs"`) that covers any action under that namespace
  (`"arbor://fs/read"`, `"arbor://fs/write"`). A more specific hint
  (`"arbor://fs/read"`) is also valid — it just permits exactly that
  action.

  Hint divergence is fail-closed: if the LLM emits `:action =
  :file_write` but `:capability = "arbor://fs/read"`, the resolved
  module's URI is `"arbor://fs/write"` which does NOT start with
  `"arbor://fs/read"`, so the dispatch is rejected.
  """
  @spec audit_capability_match(module(), map(), String.t() | nil) ::
          :ok | {:error, {:capability_mismatch, map()}}
  def audit_capability_match(_module, _params, nil), do: :ok
  def audit_capability_match(_module, _params, ""), do: :ok

  def audit_capability_match(module, params, expected_uri) when is_binary(expected_uri) do
    actual_uri = Arbor.Actions.canonical_uri_for(module, params)

    if capability_uri_matches?(actual_uri, expected_uri) do
      :ok
    else
      {:error,
       {:capability_mismatch,
        %{expected: expected_uri, actual: actual_uri, module: inspect(module)}}}
    end
  end

  # Prefix match. expected_uri = "arbor://fs" covers actual = "arbor://fs/read";
  # expected_uri = "arbor://fs/read" covers actual = "arbor://fs/read" only.
  defp capability_uri_matches?(actual, expected) do
    String.starts_with?(actual, expected)
  end

  # ── Context building ──────────────────────────────────────────────

  @doc """
  Assemble the context map handed to `Arbor.Actions.authorize_and_execute/4`.

  Threads through:
    * `:agent_id` — added automatically by authorize_and_execute, but
      including it here lets file actions use `:workspace` together
      with the agent identity.
    * `:workspace` — from `opts[:workspace]` if set; absent otherwise.
    * `:intent_id`, `:intent_goal_id` — propagated for audit/percept
      correlation downstream.
    * Any keys from `opts[:context]` (merged last, wins over defaults).
  """
  @spec build_action_context(String.t(), Intent.t(), opts()) :: map()
  def build_action_context(agent_id, %Intent{} = intent, opts) do
    base = %{
      agent_id: agent_id,
      intent_id: intent.id,
      intent_goal_id: intent.goal_id
    }

    base
    |> maybe_put(:workspace, Keyword.get(opts, :workspace))
    |> Map.merge(Keyword.get(opts, :context, %{}))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Execution + Percept formatting ────────────────────────────────

  defp execute(agent_id, module, %Intent{params: params} = intent, context) do
    started_at = System.monotonic_time(:millisecond)
    result = Arbor.Actions.authorize_and_execute(agent_id, module, params, context)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    {:ok, format_percept(intent, module, result, duration_ms)}
  end

  defp format_percept(intent, module, {:ok, action_result}, duration_ms) do
    Percept.new(:action_result, :success,
      intent_id: intent.id,
      data: %{result: action_result, module: inspect(module), action: intent.action},
      duration_ms: duration_ms,
      summary: "#{inspect(intent.action)} → ok"
    )
  end

  defp format_percept(intent, module, {:ok, :pending_approval, proposal_id}, duration_ms) do
    Percept.new(:action_result, :blocked,
      intent_id: intent.id,
      data: %{
        reason: :pending_approval,
        proposal_id: proposal_id,
        module: inspect(module),
        action: intent.action
      },
      duration_ms: duration_ms,
      summary: "#{inspect(intent.action)} → pending_approval (#{proposal_id})"
    )
  end

  defp format_percept(intent, module, {:error, :unauthorized}, duration_ms) do
    Percept.new(:action_result, :blocked,
      intent_id: intent.id,
      data: %{reason: :unauthorized, module: inspect(module), action: intent.action},
      error: :unauthorized,
      duration_ms: duration_ms,
      summary: "#{inspect(intent.action)} → unauthorized"
    )
  end

  defp format_percept(intent, module, {:error, {:taint_blocked, param, level, role}}, duration_ms) do
    Percept.new(:action_result, :blocked,
      intent_id: intent.id,
      data: %{
        reason: :taint_blocked,
        param: param,
        level: level,
        role: role,
        module: inspect(module),
        action: intent.action
      },
      error: :taint_blocked,
      duration_ms: duration_ms,
      summary: "#{inspect(intent.action)} → taint_blocked (#{param})"
    )
  end

  defp format_percept(intent, module, {:error, reason}, duration_ms) do
    Percept.new(:action_result, :failure,
      intent_id: intent.id,
      data: %{module: inspect(module), action: intent.action},
      error: reason,
      duration_ms: duration_ms,
      summary: "#{inspect(intent.action)} → error: #{inspect(reason)}"
    )
  end
end
