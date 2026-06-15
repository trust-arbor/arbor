defmodule Arbor.Contracts.Session.AssistantMessage do
  @moduledoc """
  Typed envelope for an assistant turn's outcome.

  The twin of `Arbor.Contracts.Session.UserMessage`, but with the richer
  lifecycle an assistant turn actually has. This is the **single source of
  truth** for "what the assistant produced this turn" — content, the tools it
  called, token usage, the model/provider that served it, and the lifecycle
  timestamps — populated once at the orchestrator boundary and consumed
  everywhere else through the `to_*` converters.

  ## Why this exists

  Before this struct, an assistant turn's data was scattered across magic-string
  keys in the pipeline context (`"session.response"`, `"session.usage"`,
  `"session.tool_calls"`, `"llm.model"`, `"llm.stop_reason"`, …). Producers wrote
  one set of keys; the persistence layer read another. That's exactly the
  producer/consumer drift that motivated `Pipeline.Response`, `HeartbeatResult`,
  and `TokenUsage` — and we'd already paid for it once (the `llm.usage` /
  `llm.content` dead-letter reads in persistence). Constructing through
  `from_result_ctx/3` (or `from_pipeline_response/3`) fixes the field shape in one
  place; missing data is `nil`, loud and obvious; downstream reads typed fields,
  not `Map.get/3` into a loose map.

  ## Three timestamps, deliberately

  - `started_at` — when the turn's LLM work began. Chat ordering uses this (the
    assistant logically begins responding right after the user sends).
  - `first_token_at` — time-to-first-token. Populated by the streaming work
    (`streaming-partial-preservation`); `nil` until then.
  - `completed_at` — final / interrupted / failed. Turn-duration metrics use
    `completed_at - started_at`.

  ## Status

  `:complete` is the normal terminal state. `:failed` carries an
  `interrupted_reason`. `:streaming` / `:interrupted` exist for the streaming
  work that builds on this struct — this module does not produce them yet.

  ## Construction (Construct)

      # From the orchestrator pipeline context (the live path)
      AssistantMessage.from_result_ctx(result_ctx, started_at, completed_at)

      # From a normalized Pipeline.Response (callers that have one)
      AssistantMessage.from_pipeline_response(response, started_at, completed_at)

  ## Conversion (Convert)

      am |> AssistantMessage.to_persistence()   # SessionEntry fields
      am |> AssistantMessage.to_message_map()    # %{"role"=>"assistant", ...} for the messages list
      am |> AssistantMessage.to_signal_data()    # signal payload

  These are the only sanctioned crossings between the typed world and the loose
  world (DB rows, the in-memory messages list, signal payloads).
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.TokenUsage
  alias Arbor.Contracts.Pipeline.Response

  @type status :: :streaming | :complete | :interrupted | :failed

  typedstruct do
    @typedoc "An assistant turn outcome"

    field(:content, String.t(), default: "")
    field(:status, status(), default: :complete)
    field(:started_at, DateTime.t(), enforce: true)
    field(:first_token_at, DateTime.t() | nil)
    field(:completed_at, DateTime.t() | nil)
    field(:tool_calls, [map()], default: [])
    field(:tool_history, [map()], default: [])
    field(:thinking, String.t() | nil)
    field(:usage, TokenUsage.t() | nil)
    field(:model, String.t() | nil)
    field(:provider, atom() | String.t() | nil)
    field(:finish_reason, atom() | String.t() | nil)
    field(:interrupted_reason, term() | nil)
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Build an AssistantMessage from the orchestrator pipeline context.

  This is the live path: the rich turn data lives in `result_ctx` under the
  magic-string keys the handlers write. Any key not present is left at its
  default (or `nil`). `started_at` is required; `completed_at` defaults to `nil`
  (callers pass the turn-completion time).

  ## Examples

      iex> ctx = %{"session.response" => "hi", "llm.model" => "m", "llm.stop_reason" => "stop"}
      iex> now = ~U[2026-06-15 09:00:00Z]
      iex> am = AssistantMessage.from_result_ctx(ctx, now, now)
      iex> {am.content, am.model, am.finish_reason, am.status}
      {"hi", "m", "stop", :complete}
  """
  @spec from_result_ctx(map(), DateTime.t(), DateTime.t() | nil) :: t()
  def from_result_ctx(result_ctx, %DateTime{} = started_at, completed_at \\ nil)
      when is_map(result_ctx) do
    %__MODULE__{
      content: result_ctx |> Map.get("session.response", "") |> to_string(),
      status: :complete,
      started_at: started_at,
      first_token_at: nil,
      completed_at: completed_at,
      tool_calls: List.wrap(Map.get(result_ctx, "session.tool_calls", [])),
      tool_history: List.wrap(Map.get(result_ctx, "session.tool_history", [])),
      thinking: Map.get(result_ctx, "llm.thinking"),
      usage: result_ctx |> Map.get("session.usage") |> TokenUsage.from_map(),
      model: Map.get(result_ctx, "llm.model"),
      provider: Map.get(result_ctx, "llm.provider"),
      finish_reason: Map.get(result_ctx, "llm.stop_reason")
    }
  end

  @doc """
  Build an AssistantMessage from a normalized `Pipeline.Response`.

  For callers that already hold a `%Response{}` (its usage map is normalized via
  `TokenUsage.from_map/1`). `started_at` is required; `completed_at` defaults to
  `nil`.

  ## Examples

      iex> resp = %Arbor.Contracts.Pipeline.Response{content: "ok", finish_reason: :stop}
      iex> now = ~U[2026-06-15 09:00:00Z]
      iex> am = AssistantMessage.from_pipeline_response(resp, now, now)
      iex> {am.content, am.finish_reason, am.tool_history}
      {"ok", :stop, []}
  """
  @spec from_pipeline_response(Response.t(), DateTime.t(), DateTime.t() | nil) :: t()
  def from_pipeline_response(%Response{} = resp, %DateTime{} = started_at, completed_at \\ nil) do
    %__MODULE__{
      content: resp.content || "",
      status: :complete,
      started_at: started_at,
      first_token_at: nil,
      completed_at: completed_at,
      tool_history: resp.tool_history || [],
      usage: TokenUsage.from_map(resp.usage),
      finish_reason: resp.finish_reason,
      provider:
        Map.get(resp.metadata || %{}, :provider) || Map.get(resp.metadata || %{}, "provider")
    }
  end

  @doc """
  Build a `:failed` AssistantMessage for the error path.

  ## Examples

      iex> now = ~U[2026-06-15 09:00:00Z]
      iex> am = AssistantMessage.failed(:timeout, now, now)
      iex> {am.status, am.interrupted_reason}
      {:failed, :timeout}
  """
  @spec failed(term(), DateTime.t(), DateTime.t() | nil) :: t()
  def failed(reason, %DateTime{} = started_at, completed_at \\ nil) do
    %__MODULE__{
      content: "",
      status: :failed,
      started_at: started_at,
      completed_at: completed_at,
      interrupted_reason: reason
    }
  end

  # ============================================================================
  # Conversion
  # ============================================================================

  @doc """
  Convert to the typed fields a SessionEntry assistant row needs.

  The caller (`Session.Persistence.persist_turn_entries/5`) builds the final
  content array (text + tool_use blocks) and adds `entry_type`/`role`/`metadata`;
  this returns the rest as typed fields rather than magic-string reads.
  """
  @spec to_persistence(t()) :: map()
  def to_persistence(%__MODULE__{} = am) do
    %{
      content: am.content,
      tool_calls: am.tool_calls,
      model: am.model,
      stop_reason: am.finish_reason,
      token_usage: am.usage && TokenUsage.to_persistence(am.usage),
      timestamp: am.completed_at || am.started_at
    }
  end

  @doc """
  Convert to the loose `%{"role" => "assistant", ...}` map used in the in-memory
  messages list and the compactor. Returns `nil` for empty content (mirrors the
  old `SessionCore.build_assistant_message/2` contract).
  """
  @spec to_message_map(t()) :: map() | nil
  def to_message_map(%__MODULE__{} = am) do
    case String.trim(am.content || "") do
      "" ->
        nil

      trimmed ->
        %{
          "role" => "assistant",
          "content" => trimmed,
          "timestamp" => DateTime.to_iso8601(am.completed_at || am.started_at)
        }
    end
  end

  @doc "Convert to a signal payload map."
  @spec to_signal_data(t()) :: map()
  def to_signal_data(%__MODULE__{} = am) do
    %{
      content: am.content,
      status: am.status,
      model: am.model,
      provider: am.provider,
      finish_reason: am.finish_reason,
      tool_calls_count: length(am.tool_calls),
      usage: am.usage && TokenUsage.to_signal_data(am.usage),
      started_at: am.started_at,
      first_token_at: am.first_token_at,
      completed_at: am.completed_at
    }
  end

  @doc """
  Turn duration in milliseconds (`completed_at - started_at`), or `nil` if the
  turn hasn't completed.

  ## Examples

      iex> s = ~U[2026-06-15 09:00:00.000Z]
      iex> e = ~U[2026-06-15 09:00:01.500Z]
      iex> AssistantMessage.duration_ms(%Arbor.Contracts.Session.AssistantMessage{started_at: s, completed_at: e})
      1500
  """
  @spec duration_ms(t()) :: non_neg_integer() | nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: %DateTime{} = s, completed_at: %DateTime{} = e}) do
    DateTime.diff(e, s, :millisecond)
  end
end
