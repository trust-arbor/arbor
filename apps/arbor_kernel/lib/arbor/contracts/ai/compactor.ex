defmodule Arbor.Contracts.AI.Compactor do
  @moduledoc """
  Behaviour for pluggable context compaction strategies.

  Compactors maintain a shadow context: the `full_transcript` is append-only
  and immutable, while `llm_messages` is a projected view that the LLM
  actually sees. Compaction modifies only the projected view.

  ## Implementing a Compactor

      defmodule MyCompactor do
        @behaviour Arbor.Contracts.AI.Compactor

        defstruct [:window, messages: [], transcript: []]

        @impl true
        def new(opts), do: %__MODULE__{window: Keyword.get(opts, :effective_window, 75_000)}

        @impl true
        def append(%__MODULE__{} = c, message) do
          %{c | messages: c.messages ++ [message], transcript: c.transcript ++ [message]}
        end

        @impl true
        def maybe_compact(%__MODULE__{} = c), do: c

        @impl true
        def llm_messages(%__MODULE__{messages: msgs}), do: msgs

        @impl true
        def full_transcript(%__MODULE__{transcript: t}), do: t

        @impl true
        def stats(%__MODULE__{} = c) do
          %{
            total_messages: length(c.transcript),
            visible_messages: length(c.messages),
            compression_ratio: 1.0,
            compactions_performed: 0
          }
        end
      end
  """

  @type t :: struct()
  @type message :: map()
  @type stats :: %{
          total_messages: non_neg_integer(),
          visible_messages: non_neg_integer(),
          compression_ratio: float(),
          compactions_performed: non_neg_integer()
        }

  @doc "Create a new compactor with the given options."
  @callback new(keyword()) :: t()

  @doc "Append a message to both the full transcript and the projected view."
  @callback append(t(), message()) :: t()

  @doc "Run compaction if the projected view exceeds the effective window."
  @callback maybe_compact(t()) :: t()

  @doc "Return the projected message view for LLM calls."
  @callback llm_messages(t()) :: [message()]

  @doc "Return the full, unmodified transcript."
  @callback full_transcript(t()) :: [message()]

  @doc "Return compaction statistics."
  @callback stats(t()) :: stats()
end
