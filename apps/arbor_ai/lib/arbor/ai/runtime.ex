defmodule Arbor.AI.Runtime do
  @moduledoc """
  Behaviour for runtime adapters — the layer that owns the model loop.

  A "runtime" is the execution model that drives a turn from a prepared
  request to a final response. Arbor today ships two real runtimes:

  - `:arbor` — in-BEAM loop via `arbor_llm`, calling req_llm for HTTP.
    Full Jido + memory + capability + taint integration. The default
    for any model without an explicit runtime pin.
  - `:acp` — subprocess + ACP protocol via `Arbor.AI.AcpSession` /
    `AcpPool`. The provider picks which CLI gets spawned (claude, codex,
    gemini, hermes, opencode, qwen_code, …). Opt-in per model.

  Future named specializations (`:claude_acp` with a `skills:` config
  knob, `:codex_acp` with thread-binding, etc.) are added only when a
  concrete CLI feature demands first-class config — until then the
  generic `:acp` handles every ACP-compatible harness.

  ## Selection

  `Arbor.AI.Runtime.Selector.choose/2` picks a `{provider, runtime}` pair
  for a given `%Arbor.Contracts.LLM.ModelEntry{}` plus optional per-turn
  policy. The chosen runtime atom is the key into the runtime registry
  (Phase 2b adds `Arbor.AI.Runtime.Registry`); for now Phase 2a defines
  only the behaviour and the selector — concrete adapter modules land in
  Phase 2b.

  ## Lifecycle of a turn

      1. Selector returns {:ok, %{provider: %ProviderEntry{}, runtime: :arbor}}
      2. Runtime.prepare(request, runtime_opts) → {:ok, prepared}
      3. Runtime.execute(prepared, callbacks, runtime_opts) → {:ok, response}

  `prepare/2` is allowed to be a no-op for simple runtimes (`:arbor`
  passes the request through largely unchanged). It exists so harnesses
  that need session setup (`:acp` spawns or attaches to a subprocess
  session) have a hook independent from `execute/3`.

  ## Streaming and callbacks

  `execute/3` accepts a `callbacks` map for streaming updates:

      %{
        on_text_delta: fn fragment -> ... end,
        on_thinking_delta: fn fragment -> ... end,
        on_tool_call: fn tool_invocation -> ... end,
        on_usage: fn usage_update -> ... end
      }

  All keys are optional; a runtime that doesn't stream tool calls just
  never invokes the `:on_tool_call` callback. Callbacks are best-effort —
  the runtime MUST still return a complete `%Response{}` from
  `execute/3` regardless of whether the caller listened.

  ## Profile declaration

  `profile/0` returns a `%Arbor.Contracts.AI.RuntimeProfile{}` describing
  what this runtime supports (loop ownership, Jido integration, native
  tools, etc.). The selector and `mix arbor.doctor` consult it. Profiles
  are static — they describe the *adapter*, not a particular running
  session.
  """

  alias Arbor.Contracts.AI.{Request, Response, RuntimeProfile}

  @typedoc """
  Runtime-specific prepared turn. Opaque to callers — only the runtime
  that produced it via `prepare/2` knows what's inside. Pass it through
  to `execute/3` verbatim.
  """
  @type prepared :: term()

  @typedoc """
  Optional streaming callbacks. All keys are optional.
  """
  @type callbacks :: %{
          optional(:on_text_delta) => (String.t() -> any()),
          optional(:on_thinking_delta) => (String.t() -> any()),
          optional(:on_tool_call) => (map() -> any()),
          optional(:on_usage) => (map() -> any())
        }

  @doc """
  Prepare a request for execution by this runtime.

  Should be cheap and idempotent — Phase 2b's executor MAY call this on
  retry. For runtimes that need session setup (subprocess attach, etc.),
  `prepare/2` returns a handle that `execute/3` uses to dispatch.
  """
  @callback prepare(Request.t(), keyword()) :: {:ok, prepared()} | {:error, term()}

  @doc """
  Execute the prepared turn. Streams updates via `callbacks` and returns
  the final `%Response{}` (or an error).

  Best-effort streaming: callers that don't pass `callbacks` still get a
  complete response. Errors are returned, never raised — the executor
  layer maps them to `Response{}` failure modes or triggers fallback.
  """
  @callback execute(prepared(), callbacks(), keyword()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Static capability profile of this runtime. Returned without arguments
  so the selector and operator tooling can inspect adapters without
  instantiating any session state.
  """
  @callback profile() :: RuntimeProfile.t()

  @doc """
  Convenience: invoke `profile/0` on a runtime module if it's loaded
  and implements the behaviour. Returns `:not_loaded` rather than
  raising for callers (selector, doctor) that probe adapter modules
  optimistically.
  """
  @spec profile_of(module()) :: RuntimeProfile.t() | :not_loaded
  def profile_of(runtime_module) when is_atom(runtime_module) do
    if Code.ensure_loaded?(runtime_module) and
         function_exported?(runtime_module, :profile, 0) do
      runtime_module.profile()
    else
      :not_loaded
    end
  end
end
