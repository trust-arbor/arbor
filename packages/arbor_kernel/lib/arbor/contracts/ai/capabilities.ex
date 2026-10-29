defmodule Arbor.Contracts.AI.Capabilities do
  @moduledoc """
  Declarative capability flags for an LLM provider.

  Each provider adapter declares what features it supports via a
  `%Capabilities{}` struct. The routing layer uses these flags to match
  task requirements to provider abilities — e.g., "need thinking? route
  to a provider where `thinking: true`."

  ## Usage

      caps = Capabilities.new(streaming: true, thinking: true, tool_calls: true)
      Capabilities.supports?(caps, :thinking)  # => true
      Capabilities.supports?(caps, :vision)    # => false

      # Check multiple requirements at once
      Capabilities.satisfies?(caps, [:streaming, :tool_calls])  # => true
  """

  @type t :: %__MODULE__{
          streaming: boolean(),
          tool_calls: boolean(),
          thinking: boolean(),
          extended_thinking: boolean(),
          vision: boolean(),
          resume: boolean(),
          multi_turn: boolean(),
          structured_output: boolean(),
          embeddings: boolean(),
          max_context: pos_integer() | nil,
          max_output: pos_integer() | nil
        }

  defstruct streaming: false,
            tool_calls: false,
            thinking: false,
            extended_thinking: false,
            vision: false,
            resume: false,
            multi_turn: false,
            structured_output: false,
            embeddings: false,
            max_context: nil,
            max_output: nil

  @capability_flags [
    :streaming,
    :tool_calls,
    :thinking,
    :extended_thinking,
    :vision,
    :resume,
    :multi_turn,
    :structured_output,
    :embeddings
  ]

  @doc """
  Create a new Capabilities struct from a keyword list or map.

  Boolean fields default to `false`. Integer fields default to `nil`.

  ## Examples

      iex> caps = Arbor.Contracts.AI.Capabilities.new(streaming: true, thinking: true)
      iex> caps.streaming
      true
      iex> caps.vision
      false
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ [])

  def new(attrs) when is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  def new(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
    |> then(&struct(__MODULE__, &1))
  end

  @doc """
  Returns true if the given capability flag is supported.

  ## Examples

      iex> caps = Arbor.Contracts.AI.Capabilities.new(thinking: true)
      iex> Arbor.Contracts.AI.Capabilities.supports?(caps, :thinking)
      true
      iex> Arbor.Contracts.AI.Capabilities.supports?(caps, :vision)
      false
  """
  @spec supports?(t(), atom()) :: boolean()
  def supports?(%__MODULE__{} = caps, flag) when flag in @capability_flags do
    Map.get(caps, flag, false) == true
  end

  def supports?(%__MODULE__{} = caps, :max_context) do
    caps.max_context != nil
  end

  def supports?(%__MODULE__{} = caps, :max_output) do
    caps.max_output != nil
  end

  @doc """
  Returns true if all given capability requirements are satisfied.

  ## Examples

      iex> caps = Arbor.Contracts.AI.Capabilities.new(streaming: true, tool_calls: true)
      iex> Arbor.Contracts.AI.Capabilities.satisfies?(caps, [:streaming, :tool_calls])
      true
      iex> Arbor.Contracts.AI.Capabilities.satisfies?(caps, [:streaming, :vision])
      false
  """
  @spec satisfies?(t(), [atom()]) :: boolean()
  def satisfies?(%__MODULE__{} = caps, requirements) when is_list(requirements) do
    Enum.all?(requirements, &supports?(caps, &1))
  end

  @doc """
  Returns the list of all boolean capability flag names.
  """
  @spec flags() :: [atom()]
  def flags, do: @capability_flags

  @doc """
  Returns the list of capability flags that are enabled.

  ## Examples

      iex> caps = Arbor.Contracts.AI.Capabilities.new(streaming: true, vision: true)
      iex> Arbor.Contracts.AI.Capabilities.enabled(caps)
      [:streaming, :vision]
  """
  @spec enabled(t()) :: [atom()]
  def enabled(%__MODULE__{} = caps) do
    Enum.filter(@capability_flags, &supports?(caps, &1))
  end
end
