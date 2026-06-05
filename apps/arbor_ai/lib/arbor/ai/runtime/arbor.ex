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

  ## Phase 2c + Phase 4 shape

  `prepare/2` is a no-op pass-through — req_llm doesn't need session
  setup; the Request struct IS the prepared turn. `execute/3` calls
  `Arbor.LLM.Client.complete/3` when no streaming callbacks are set,
  and `Arbor.LLM.Client.stream/3` + per-event callback dispatch when
  callbacks include `:on_text_delta`, `:on_thinking_delta`, or
  `:on_tool_call`. The optional `:client` opt lets callers inject a
  pre-built `%Client{}` (e.g., one with custom middleware); the
  default builds a fresh one via `Client.new()`.

  ## Streaming → callbacks mapping

  `Client.stream` emits `%Arbor.LLM.StreamEvent{}` values. `execute/3`
  routes each event to the matching callback before collecting the
  final response via `Client.collect_stream/1`:

    | StreamEvent.type | Callback                  |
    |------------------|---------------------------|
    | `:delta` (text)  | `:on_text_delta`          |
    | `:delta` (think) | `:on_thinking_delta`      |
    | `:tool_call`     | `:on_tool_call`           |
    | `:finish`        | `:on_usage` (if usage set)|

  If the adapter doesn't support streaming
  (`{:error, {:stream_not_supported, _}}`), execute falls back to
  `Client.complete/3` and the callbacks are silently no-op'd — matches
  the "best-effort" contract in `Arbor.AI.Runtime.callbacks()`.
  """

  @behaviour Arbor.AI.Runtime

  alias Arbor.AI.Runtime
  alias Arbor.Contracts.AI.RuntimeProfile
  alias Arbor.LLM.Client
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response
  alias Arbor.LLM.StreamEvent

  @impl Runtime
  @spec prepare(Request.t(), keyword()) :: {:ok, Request.t()}
  def prepare(%Request{} = request, _opts), do: {:ok, request}

  @impl Runtime
  @spec execute(Request.t(), Runtime.callbacks(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def execute(%Request{} = prepared, callbacks, opts) do
    client = Keyword.get_lazy(opts, :client, fn -> Client.new() end)
    forwarded = Keyword.drop(opts, [:client])

    if streaming_callbacks?(callbacks) do
      execute_streaming(client, prepared, callbacks, forwarded)
    else
      Client.complete(client, prepared, forwarded)
    end
  end

  defp streaming_callbacks?(callbacks) when is_map(callbacks) do
    Map.has_key?(callbacks, :on_text_delta) or
      Map.has_key?(callbacks, :on_thinking_delta) or
      Map.has_key?(callbacks, :on_tool_call)
  end

  defp streaming_callbacks?(_), do: false

  defp execute_streaming(client, request, callbacks, opts) do
    case Client.stream(client, request, opts) do
      {:ok, events} ->
        events
        |> Stream.each(&dispatch_event(&1, callbacks))
        |> Client.collect_stream()

      {:error, {:stream_not_supported, _}} ->
        # Adapter doesn't support streaming — fall back to non-streaming.
        # Per Runtime.callbacks() docs: callbacks are best-effort.
        Client.complete(client, request, opts)

      {:error, _} = error ->
        error
    end
  end

  # Per-event dispatch. Each branch is a no-op when the callback is
  # absent — callers can subscribe to a subset of events.
  defp dispatch_event(%StreamEvent{type: :delta, data: data}, callbacks) do
    text = Map.get(data, "text") || Map.get(data, :text)
    thinking = Map.get(data, "thinking") || Map.get(data, :thinking)

    cond do
      is_binary(text) and Map.has_key?(callbacks, :on_text_delta) ->
        callbacks.on_text_delta.(text)

      is_binary(thinking) and Map.has_key?(callbacks, :on_thinking_delta) ->
        callbacks.on_thinking_delta.(thinking)

      true ->
        :ok
    end
  end

  defp dispatch_event(%StreamEvent{type: :tool_call, data: data}, callbacks) do
    if Map.has_key?(callbacks, :on_tool_call), do: callbacks.on_tool_call.(data), else: :ok
  end

  defp dispatch_event(%StreamEvent{type: :finish, data: data}, callbacks) do
    usage = Map.get(data, :usage) || Map.get(data, "usage")

    if usage && Map.has_key?(callbacks, :on_usage),
      do: callbacks.on_usage.(usage),
      else: :ok
  end

  defp dispatch_event(_event, _callbacks), do: :ok

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
