defmodule Arbor.LLM.Call do
  @moduledoc """
  The "connection" struct threaded through the `Arbor.LLM` plug
  pipeline.

  Carries everything a plug needs to inspect or transform an LLM
  call as it flows from the caller through the pipeline:

    * `operation` — which dispatch path (`:complete`, `:stream`,
      `:embed_cloud`, `:embed_local`). Selects which req_llm
      function `Arbor.LLM.Plugs.Dispatch` invokes.
    * `request` — the args tuple for the dispatch
      (`{model_spec, messages, opts}` for chat;
      `{model, texts, opts}` for embed). Plugs hash this for
      fixture lookup, etc.
    * `result` — set by `Plugs.Dispatch` (or short-circuited by
      `Plugs.Replay`). The pipeline finishes when the caller
      extracts this field.
    * `halted` — set by any plug that wants the rest of the
      pipeline to pass through unchanged. The `use Arbor.LLM.Plug`
      macro inserts a halted-passthrough clause at the top of every
      plug, so once a plug sets `halted: true`, subsequent plugs are
      effectively no-ops (still called, but they just return the
      call as-is).
    * `metadata` — pipeline-shared state: timestamps, fixture
      provenance, traces, etc. Use this for cross-cutting info that
      multiple plugs need to see.
    * `assigns` — ad-hoc per-plug scratch space, mirroring
      `Plug.Conn.assigns`. Use for plug-private state that other
      plugs don't need to read.

  See the `Arbor.LLM.Plug` moduledoc for the full pipeline pattern,
  and `.claude/skills/llm-plug-pipeline.md` for when and how to add
  new plugs.
  """

  @type operation :: :complete | :stream | :embed_cloud | :embed_local

  @type t :: %__MODULE__{
          operation: operation(),
          request: tuple(),
          result: term() | nil,
          halted: boolean(),
          metadata: map(),
          assigns: map()
        }

  defstruct operation: :complete,
            request: {},
            result: nil,
            halted: false,
            metadata: %{},
            assigns: %{}

  @doc """
  Construct a fresh call. Stamps `metadata.started_at` for downstream
  plugs that need wall-clock timing and a bounded, non-secret event ID for
  per-invocation observations.
  """
  @spec new(operation(), tuple()) :: t()
  def new(operation, request) when is_atom(operation) and is_tuple(request) do
    %__MODULE__{
      operation: operation,
      request: request,
      metadata: %{started_at: DateTime.utc_now(), event_id: new_event_id()}
    }
  end

  @doc """
  Halt the pipeline. Subsequent plugs see `halted: true` and pass
  through. Useful for short-circuit plugs like Replay that have
  already filled in the result.
  """
  @spec halt(t()) :: t()
  def halt(%__MODULE__{} = call), do: %{call | halted: true}

  @doc """
  Merge `additions` into `metadata`. Convenience that avoids the
  `%{call | metadata: Map.merge(call.metadata, additions)}` boilerplate.
  """
  @spec put_metadata(t(), map()) :: t()
  def put_metadata(%__MODULE__{} = call, additions) when is_map(additions) do
    %{call | metadata: Map.merge(call.metadata, additions)}
  end

  @doc """
  Assign a key in `assigns`. Mirrors `Plug.Conn.assign/3`.
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{assigns: assigns} = call, key, value) when is_atom(key) do
    %{call | assigns: Map.put(assigns, key, value)}
  end

  defp new_event_id do
    "llm-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end
end
