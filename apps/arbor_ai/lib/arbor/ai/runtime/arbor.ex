defmodule Arbor.AI.Runtime.Arbor do
  @moduledoc """
  In-BEAM runtime — drives turns through `Arbor.LLM.Client` (req_llm).

  The default and "always available" runtime. Carries Arbor's full
  middleware stack (rate limiting, taint, telemetry, plug pipeline).
  Owns the model loop: retries, tool continuation, and final-answer
  decisions all happen here, in the calling process.

  Use this runtime when you want:

  - Full Jido action integration
  - Memory + compaction running on the turn's context
  - Capability + taint enforcement on every tool call
  - Arbor-native tool handlers (`Arbor.Actions`)

  ## Phase 2c shape

  `prepare/2` is a no-op pass-through — req_llm doesn't need session
  setup; the Request struct IS the prepared turn. `execute/3` calls
  `Arbor.LLM.Client.complete/3`. The optional `:client` opt lets callers
  inject a pre-built `%Client{}` (e.g., one with custom middleware);
  the default builds a fresh one via `Client.new()`.

  Streaming callbacks aren't yet wired in Phase 2c — `execute/3` returns
  the full `%Response{}` after `Client.complete/3` returns. Adding
  streaming is a localized change inside `execute/3` (call
  `Client.stream/3` instead and wrap with `:on_text_delta` callbacks)
  but not in this commit's scope.
  """

  @behaviour Arbor.AI.Runtime

  alias Arbor.AI.Runtime
  alias Arbor.Contracts.AI.RuntimeProfile
  alias Arbor.LLM.Client
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  @impl Runtime
  @spec prepare(Request.t(), keyword()) :: {:ok, Request.t()}
  def prepare(%Request{} = request, _opts), do: {:ok, request}

  @impl Runtime
  @spec execute(Request.t(), Runtime.callbacks(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def execute(%Request{} = prepared, _callbacks, opts) do
    client = Keyword.get_lazy(opts, :client, fn -> Client.new() end)
    forwarded = Keyword.drop(opts, [:client])
    Client.complete(client, prepared, forwarded)
  end

  @impl Runtime
  @spec profile() :: RuntimeProfile.t()
  def profile do
    {:ok, p} =
      RuntimeProfile.new(%{
        runtime_id: :arbor,
        display_name: "Arbor (BEAM-native HTTP via req_llm)",
        # The loop, history, and tool continuation all live in the calling
        # process — no external owner steals control.
        owns_model_loop: true,
        owns_thread_history: true,
        # Full Jido + native tools + memory stack composes here. This is
        # the runtime that exercises Arbor's full security and observability
        # stack continuously.
        supports_jido_actions: true,
        supports_action_hooks: true,
        supports_native_tools: true,
        runs_context_engine: true,
        exposes_compaction_data: true,
        unsupported_features: []
      })

    p
  end
end
