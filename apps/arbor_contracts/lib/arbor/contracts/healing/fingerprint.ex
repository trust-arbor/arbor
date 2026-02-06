defmodule Arbor.Contracts.Healing.Fingerprint do
  @moduledoc """
  Anomaly fingerprint for deduplication.

  A fingerprint uniquely identifies an anomaly class based on:
  - `skill` - which monitor skill detected it (:beam, :memory, :ets, etc.)
  - `metric` - which specific metric triggered (:process_count, :total_memory, etc.)
  - `direction` - whether the value was above or below the expected baseline

  Two anomalies with the same fingerprint represent the same underlying issue
  and should be deduplicated within a time window.

  ## Examples

      # Create from an anomaly
      {:ok, fp} = Fingerprint.from_anomaly(anomaly)

      # Check equality
      Fingerprint.equal?(fp1, fp2)

      # Get hash for ETS key
      Fingerprint.hash(fp)  # => integer
  """

  use TypedStruct

  @type direction :: :above | :below

  typedstruct enforce: true do
    @typedoc "Anomaly fingerprint for deduplication"

    field(:skill, atom())
    field(:metric, atom())
    field(:direction, direction())
    field(:hash, integer())
  end

  @doc """
  Create a fingerprint from an anomaly.

  Expects anomaly to have:
  - `skill` - atom identifying the skill
  - `details.metric` - atom identifying the metric
  - `details.value` and `details.ewma` - for determining direction
  """
  @spec from_anomaly(map()) :: {:ok, t()} | {:error, term()}
  def from_anomaly(%{skill: skill, details: details}) when is_atom(skill) and is_map(details) do
    metric = Map.get(details, :metric)
    value = Map.get(details, :value)
    ewma = Map.get(details, :ewma)

    cond do
      is_nil(metric) ->
        {:error, :missing_metric}

      is_nil(value) or is_nil(ewma) ->
        {:error, :missing_value_or_ewma}

      true ->
        direction = if value > ewma, do: :above, else: :below
        hash = compute_hash(skill, metric, direction)

        {:ok,
         %__MODULE__{
           skill: skill,
           metric: metric,
           direction: direction,
           hash: hash
         }}
    end
  end

  def from_anomaly(_), do: {:error, :invalid_anomaly_format}

  @doc """
  Create a fingerprint directly from components.
  """
  @spec new(atom(), atom(), direction()) :: t()
  def new(skill, metric, direction) when is_atom(skill) and is_atom(metric) do
    %__MODULE__{
      skill: skill,
      metric: metric,
      direction: direction,
      hash: compute_hash(skill, metric, direction)
    }
  end

  @doc """
  Check if two fingerprints are equal.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{hash: h1}, %__MODULE__{hash: h2}), do: h1 == h2

  @doc """
  Get the fingerprint hash (for use as ETS key).
  """
  @spec hash(t()) :: integer()
  def hash(%__MODULE__{hash: h}), do: h

  @doc """
  Get a fingerprint family hash (skill + metric only, ignoring direction).
  Used for rejection tracking across both directions.
  """
  @spec family_hash(t()) :: integer()
  def family_hash(%__MODULE__{skill: skill, metric: metric}) do
    :erlang.phash2({skill, metric})
  end

  @doc """
  Convert fingerprint to a loggable string.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{skill: skill, metric: metric, direction: direction}) do
    "#{skill}:#{metric}:#{direction}"
  end

  # Compute a stable hash for the fingerprint
  defp compute_hash(skill, metric, direction) do
    :erlang.phash2({skill, metric, direction})
  end
end
