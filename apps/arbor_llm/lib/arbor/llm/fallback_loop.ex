defmodule Arbor.LLM.FallbackLoop do
  @moduledoc """
  Generic fallback-chain executor for LLM-style call paths.

  Both `Arbor.AI.Runtime.Dispatch` and the LlmHandler tool-loop wrapper
  in `Arbor.Orchestrator.Handlers.LlmHandler` ran nearly identical
  fallback loops before this module landed. The shapes that differ
  (what an "attempt" is, how an override mutates it, when to skip vs
  fail, what to emit on each fallback) are parameterized as opts; the
  loop control flow lives here.

  ## The shape

  An "attempt" is anything you want to thread between calls — typically
  the LLM `Request`, but for Dispatch it's a `{request, policy, opts}`
  bundle since both the request AND the Selector policy mutate per
  fallback entry. The loop is generic over this type.

  ## Semantics

    1. Run `do_call.(initial_attempt)`. If `{:ok, _}`, return it.
    2. On `{:error, reason}`, check `eligible?.(reason)`:
       - If false: return the error immediately (fail-closed).
       - If true: walk the chain.
    3. For each entry in the chain:
       a. Call `apply_override.(initial_attempt, entry)`.
          - `{:ok, attempt'}` — try this attempt.
          - `:no_change` — skip this entry, move to the next.
       b. Emit `on_fallback.(initial_attempt, entry, last_error)`.
       c. Run `do_call.(attempt')`.
          - On success: return.
          - On error: check eligibility. If eligible AND more entries
            remain, continue; otherwise return the error.
    4. If the chain is exhausted with no success, return the most
       recent error.

  Overrides apply to the **original** attempt, not the previous
  attempt, so each entry is independent of what came before.

  ## Opts

    * `:do_call` (required) — `(attempt -> {:ok, any()} | {:error, any()})`
    * `:apply_override` (required) — `(attempt, override -> {:ok, attempt'} | :no_change)`
    * `:eligible?` — `(reason -> boolean())`, defaults to
      `Arbor.LLM.Retry.fallback_eligible?/1`. Pass a custom predicate
      to widen the set (e.g., Dispatch composes Retry's classifier
      with its own path-failure list).
    * `:on_fallback` — `(attempt, override, last_error -> any())`, called
      once per fallback attempt (NOT on the primary). Defaults to a
      no-op. Use for telemetry or logging.

  ## Example — minimal (LlmHandler tool-loop shape)

      FallbackLoop.run(request, chain,
        do_call: fn req -> ToolLoop.run(client, req, tool_opts) end,
        apply_override: fn req, override ->
          if Map.has_key?(override, :model) do
            {:ok, %{req | model: override.model}}
          else
            :no_change
          end
        end
      )

  ## Example — multi-field attempt state (Dispatch shape)

      FallbackLoop.run(%{request: request, policy: base_policy, opts: opts}, chain,
        do_call: fn %{request: r, policy: p, opts: o} -> do_dispatch_once(r, p, o) end,
        apply_override: fn state, override ->
          {:ok, %{state |
            request: apply_request_override(state.request, override),
            policy: apply_policy_override(state.policy, override)
          }}
        end,
        eligible?: &Dispatch.fallback_eligible?/1,
        on_fallback: fn state, override, err ->
          emit_fallback_telemetry(state.request, override, err)
        end
      )
  """

  @type attempt :: any()
  @type override :: map()
  @type result :: {:ok, any()} | {:error, any()}
  @type apply_override_result :: {:ok, attempt()} | :no_change

  @type opts :: [
          do_call: (attempt() -> result()),
          apply_override: (attempt(), override() -> apply_override_result()),
          eligible?: (any() -> boolean()),
          on_fallback: (attempt(), override(), any() -> any())
        ]

  @doc """
  Drive an attempt through the fallback chain. See module docs for
  semantics. Returns `{:ok, _}` on first success, `{:error, _}` if the
  primary attempt has a non-eligible error OR the chain is exhausted.
  """
  @spec run(attempt(), [override()], opts()) :: result()
  def run(initial_attempt, chain, opts) do
    do_call = Keyword.fetch!(opts, :do_call)
    apply_override = Keyword.fetch!(opts, :apply_override)
    eligible? = Keyword.get(opts, :eligible?, &Arbor.LLM.Retry.fallback_eligible?/1)
    on_fallback = Keyword.get(opts, :on_fallback, fn _, _, _ -> :ok end)

    case do_call.(initial_attempt) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        if chain != [] and eligible?.(reason) do
          walk(initial_attempt, chain, do_call, apply_override, eligible?, on_fallback, error)
        else
          error
        end
    end
  end

  defp walk(_initial, [], _do_call, _apply_override, _eligible?, _on_fallback, last_error),
    do: last_error

  defp walk(initial, [entry | rest], do_call, apply_override, eligible?, on_fallback, last_error) do
    case apply_override.(initial, entry) do
      :no_change ->
        walk(initial, rest, do_call, apply_override, eligible?, on_fallback, last_error)

      {:ok, attempt} ->
        on_fallback.(initial, entry, last_error)

        case do_call.(attempt) do
          {:ok, _} = ok ->
            ok

          {:error, reason} = error ->
            if rest != [] and eligible?.(reason) do
              walk(initial, rest, do_call, apply_override, eligible?, on_fallback, error)
            else
              error
            end
        end
    end
  end
end
