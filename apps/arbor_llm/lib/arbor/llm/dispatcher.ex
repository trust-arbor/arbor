defmodule Arbor.LLM.Dispatcher do
  @moduledoc """
  Behaviour for the high-level LLM dispatch surface.

  Implementations route an `Arbor.LLM.Request` through model selection,
  runtime resolution, telemetry emission, and (optionally) fallback
  chains. The canonical implementation is `Arbor.AI.Runtime.Dispatch`,
  registered as the default via:

      config :arbor_orchestrator, :llm_dispatcher, Arbor.AI.Runtime.Dispatch

  ## Why a behaviour

  `arbor_orchestrator` and `arbor_ai` are both at the same hierarchy
  level (no horizontal deps allowed per CLAUDE.md). LlmHandler in
  `arbor_orchestrator` needs to drive dispatch through `arbor_ai`'s
  Selector + Registry to honor runtime axis, fallback chains, and
  per-call telemetry. Behaviour injection (CONTRACT_RULES.md §9) is
  the established pattern — the behaviour lives in `arbor_llm` (which
  both depend on), implementations live in `arbor_ai`, callers resolve
  via Application env at runtime.

  ## Opts shape

  The behaviour accepts the union of options the canonical
  implementation cares about. Callers pass these straight through; an
  implementation that doesn't recognize a key ignores it.

    * `:policy` — selection + fallback policy
      (`Arbor.AI.Runtime.Selector.policy()`). Includes runtime override,
      provider override, model/provider pins, default runtime, and
      fallback chain.
    * `:callbacks` — streaming callbacks
      (`Arbor.AI.Runtime.callbacks()`): `:on_text_delta`,
      `:on_thinking_delta`, `:on_tool_call`, `:on_usage`. When set,
      implementations stream incremental events through these as the
      response is produced.
    * `:client` — pre-built `Arbor.LLM.Client` to use for the BEAM-
      native runtime path; lets callers thread their own middleware
      pipeline through dispatch without reconstructing it.
    * `:telemetry_metadata` — extra fields merged into emitted
      telemetry event metadata (request_id, agent_id, trace_id, etc.).

  Additional keys are forwarded as runtime opts to the chosen runtime
  adapter's `prepare/2` and `execute/3`.
  """

  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  @doc """
  Dispatch a request through the implementation's selection + runtime
  resolution + (optional) fallback chain. Returns the response or an
  error.
  """
  @callback dispatch(Request.t(), keyword()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Resolve the configured dispatcher module from Application env.

  Defaults to `Arbor.AI.Runtime.Dispatch` for production. Tests and
  alternate runtimes override via:

      Application.put_env(:arbor_orchestrator, :llm_dispatcher, MyDispatcher)
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:arbor_orchestrator, :llm_dispatcher, Arbor.AI.Runtime.Dispatch)
  end

  @doc """
  Convenience wrapper that resolves the configured implementation and
  invokes its `dispatch/2`. Callers can use this directly instead of
  doing `impl().dispatch(request, opts)` themselves.

  Module-resolved at call time via `apply/3` rather than a compile-time
  alias — the resolution depends on Application env, and callers in
  `arbor_orchestrator` would create a dep cycle if they aliased
  `Arbor.AI.Runtime.Dispatch` directly.
  """
  @spec dispatch(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def dispatch(%Request{} = request, opts \\ []) do
    apply(impl(), :dispatch, [request, opts])
  end
end
