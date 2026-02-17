defmodule Arbor.Orchestrator.Engine.Backoff do
  @moduledoc """
  Retry backoff configuration with named presets.

  Presets:
  - `:standard` — exponential, 5 attempts, 200ms initial, jitter
  - `:aggressive` — exponential, 5 attempts, 500ms initial, jitter
  - `:linear` — constant delay, 3 attempts, 500ms, jitter
  - `:patient` — exponential with 3x factor, 3 attempts, 2s initial, jitter
  - `:none` — single attempt, no retry
  """

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          initial_delay_ms: non_neg_integer(),
          backoff_factor: float(),
          max_delay_ms: non_neg_integer(),
          jitter: boolean()
        }

  defstruct max_attempts: 1,
            initial_delay_ms: 200,
            backoff_factor: 2.0,
            max_delay_ms: 60_000,
            jitter: false

  @doc "Get a preset backoff configuration by name."
  @spec preset(atom()) :: t()
  def preset(:standard) do
    %__MODULE__{
      max_attempts: 5,
      initial_delay_ms: 200,
      backoff_factor: 2.0,
      max_delay_ms: 60_000,
      jitter: true
    }
  end

  def preset(:aggressive) do
    %__MODULE__{
      max_attempts: 5,
      initial_delay_ms: 500,
      backoff_factor: 2.0,
      max_delay_ms: 60_000,
      jitter: true
    }
  end

  def preset(:linear) do
    %__MODULE__{
      max_attempts: 3,
      initial_delay_ms: 500,
      backoff_factor: 1.0,
      max_delay_ms: 60_000,
      jitter: true
    }
  end

  def preset(:patient) do
    %__MODULE__{
      max_attempts: 3,
      initial_delay_ms: 2_000,
      backoff_factor: 3.0,
      max_delay_ms: 60_000,
      jitter: true
    }
  end

  def preset(:none) do
    %__MODULE__{
      max_attempts: 1,
      initial_delay_ms: 200,
      backoff_factor: 2.0,
      max_delay_ms: 60_000,
      jitter: false
    }
  end

  def preset(_), do: preset(:none)

  @doc "Get a preset by string name (case-insensitive)."
  @spec from_string(String.t()) :: t()
  def from_string(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.to_existing_atom()
    |> preset()
  rescue
    ArgumentError -> preset(:none)
  end

  @doc "Compute the delay in ms for the given attempt number (1-based)."
  @spec delay_ms(t(), pos_integer()) :: non_neg_integer()
  def delay_ms(%__MODULE__{} = b, attempt) when is_integer(attempt) and attempt >= 1 do
    delay = trunc(b.initial_delay_ms * :math.pow(b.backoff_factor, attempt - 1))
    min(delay, b.max_delay_ms)
  end

  @doc "List all available preset names."
  @spec preset_names() :: [atom()]
  def preset_names, do: [:standard, :aggressive, :linear, :patient, :none]
end
