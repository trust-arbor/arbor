defmodule Arbor.Contracts.Memory.Percept do
  @moduledoc """
  Body's observation back to Mind after execution.

  A Percept is the feedback from the Body (Host) to the Mind (Seed) after
  an Intent has been processed. It carries the outcome, any result data,
  and timing information.

  ## Percept Types

  - `:action_result` - Result of an executed action
  - `:environment` - Observation about the environment
  - `:interrupt` - External interruption occurred
  - `:error` - Error during execution
  - `:timeout` - Execution timed out

  ## Outcomes

  - `:success` - Intent completed successfully
  - `:failure` - Intent failed
  - `:partial` - Intent partially completed
  - `:blocked` - Intent was blocked (reflex or capability)
  - `:interrupted` - Intent was interrupted

  ## Example

      %Percept{
        id: "prc_def456",
        type: :action_result,
        intent_id: "int_xyz789",
        outcome: :success,
        data: %{exit_code: 0, output: "All 42 tests passed"},
        duration_ms: 3500,
        created_at: ~U[2026-02-04 00:00:03Z]
      }
  """

  use TypedStruct

  @typedoc "Type of percept"
  @type percept_type :: :action_result | :environment | :interrupt | :error | :timeout

  @typedoc "Outcome of the related intent"
  @type outcome :: :success | :failure | :partial | :blocked | :interrupted

  typedstruct do
    @typedoc "A percept from Body to Mind"

    field :id, String.t(), enforce: true
    field :type, percept_type(), enforce: true
    field :intent_id, String.t() | nil, default: nil
    field :outcome, outcome(), enforce: true
    field :data, map(), default: %{}
    field :error, term() | nil, default: nil
    field :duration_ms, integer() | nil, default: nil
    field :created_at, DateTime.t()
    field :metadata, map(), default: %{}
  end

  @doc """
  Creates a new Percept with a generated ID and timestamp.
  """
  @spec new(percept_type(), outcome(), keyword()) :: t()
  def new(type, outcome, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || generate_id(),
      type: type,
      intent_id: opts[:intent_id],
      outcome: outcome,
      data: opts[:data] || %{},
      error: opts[:error],
      duration_ms: opts[:duration_ms],
      created_at: opts[:created_at] || DateTime.utc_now(),
      metadata: opts[:metadata] || %{}
    }
  end

  @doc """
  Creates a success percept for an action result.
  """
  @spec success(String.t() | nil, map(), keyword()) :: t()
  def success(intent_id \\ nil, data \\ %{}, opts \\ []) do
    new(:action_result, :success, [{:intent_id, intent_id}, {:data, data} | opts])
  end

  @doc """
  Creates a failure percept for an action result.
  """
  @spec failure(String.t() | nil, term(), keyword()) :: t()
  def failure(intent_id \\ nil, error \\ nil, opts \\ []) do
    new(:action_result, :failure, [{:intent_id, intent_id}, {:error, error} | opts])
  end

  @doc """
  Creates a blocked percept (reflex or capability denial).
  """
  @spec blocked(String.t() | nil, String.t(), keyword()) :: t()
  def blocked(intent_id \\ nil, reason, opts \\ []) do
    new(:action_result, :blocked, [
      {:intent_id, intent_id},
      {:data, %{reason: reason}} | opts
    ])
  end

  @doc """
  Creates a timeout percept.
  """
  @spec timeout(String.t() | nil, integer(), keyword()) :: t()
  def timeout(intent_id \\ nil, duration_ms, opts \\ []) do
    new(:timeout, :failure, [
      {:intent_id, intent_id},
      {:duration_ms, duration_ms},
      {:error, :timeout} | opts
    ])
  end

  @doc """
  Returns true if the percept indicates success.
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{outcome: :success}), do: true
  def success?(%__MODULE__{}), do: false

  @doc """
  Returns true if the percept indicates failure.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{outcome: outcome}) when outcome in [:failure, :blocked, :interrupted],
    do: true

  def failed?(%__MODULE__{}), do: false

  @doc """
  Reconstruct a Percept from a plain map (e.g. deserialized signal data).

  Handles both atom and string keys. Safely atomizes `:type`, `:outcome`.
  Parses ISO8601 datetime strings for `:created_at`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map_get(map, :id) || generate_id(),
      type: atomize(map_get(map, :type)) || :action_result,
      intent_id: map_get(map, :intent_id),
      outcome: atomize(map_get(map, :outcome)) || :success,
      data: map_get(map, :data) || %{},
      error: map_get(map, :error),
      duration_ms: map_get(map, :duration_ms),
      created_at: parse_datetime(map_get(map, :created_at)) || DateTime.utc_now(),
      metadata: map_get(map, :metadata) || %{}
    }
  end

  defp generate_id do
    "prc_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  @known_types [:action_result, :environment, :interrupt, :error, :timeout]
  @known_outcomes [:success, :failure, :partial, :blocked, :interrupted]
  @known_atoms @known_types ++ @known_outcomes

  defp atomize(nil), do: nil
  defp atomize(a) when is_atom(a), do: a
  defp atomize(s) when is_binary(s) do
    atom_match = Enum.find(@known_atoms, fn a -> Atom.to_string(a) == s end)
    atom_match || String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil
end

defimpl Jason.Encoder, for: Arbor.Contracts.Memory.Percept do
  def encode(percept, opts) do
    percept
    |> Map.from_struct()
    |> Map.update(:created_at, nil, &datetime_to_string/1)
    |> Map.update(:error, nil, &error_to_string/1)
    |> Jason.Encode.map(opts)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp error_to_string(nil), do: nil
  defp error_to_string(error) when is_atom(error), do: Atom.to_string(error)
  defp error_to_string(error) when is_binary(error), do: error
  defp error_to_string(error), do: inspect(error)
end
