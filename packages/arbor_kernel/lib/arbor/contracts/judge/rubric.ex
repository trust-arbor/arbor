defmodule Arbor.Contracts.Judge.Rubric do
  @moduledoc """
  Evaluation rubric for LLM-as-judge scoring.

  A rubric defines the dimensions along which output is evaluated,
  with weights that sum to 1.0. Each dimension has a name, weight,
  and description guiding the judge.

  ## Fields

  - `domain` — what type of output this rubric evaluates (e.g., "advisory", "code")
  - `version` — rubric version for tracking evolution (default: 1)
  - `dimensions` — list of `%{name: atom, weight: float, description: String.t()}`
  """

  use TypedStruct

  typedstruct do
    @typedoc "An evaluation rubric with weighted dimensions"

    field(:domain, String.t(), enforce: true)
    field(:version, pos_integer(), default: 1)
    field(:dimensions, [map()], enforce: true)
  end

  @doc """
  Create a new rubric from attributes.

  Validates that domain is present, dimensions are non-empty,
  and weights sum to approximately 1.0.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_domain(attrs),
         :ok <- validate_dimensions(attrs),
         :ok <- validate_weights(Map.get(attrs, :dimensions, [])) do
      rubric = %__MODULE__{
        domain: Map.fetch!(attrs, :domain),
        version: Map.get(attrs, :version, 1),
        dimensions: Map.fetch!(attrs, :dimensions)
      }

      {:ok, rubric}
    end
  end

  @doc """
  Validate that dimension weights sum to approximately 1.0.

  Allows a tolerance of 0.01 for floating-point precision.
  """
  @spec validate_weights([map()]) :: :ok | {:error, term()}
  def validate_weights(dimensions) when is_list(dimensions) do
    total = Enum.reduce(dimensions, 0.0, fn dim, acc -> acc + (dim[:weight] || 0.0) end)

    if abs(total - 1.0) <= 0.01 do
      :ok
    else
      {:error, {:invalid_weights, "weights must sum to 1.0 (got #{Float.round(total, 4)})"}}
    end
  end

  @doc """
  Create a snapshot of the rubric for embedding in verdict metadata.

  Returns a JSON-serializable map.
  """
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = rubric) do
    %{
      "domain" => rubric.domain,
      "version" => rubric.version,
      "dimensions" =>
        Enum.map(rubric.dimensions, fn dim ->
          %{
            "name" => to_string(dim[:name]),
            "weight" => dim[:weight],
            "description" => dim[:description] || ""
          }
        end)
    }
  end

  # Private validation

  defp validate_domain(attrs) do
    case Map.get(attrs, :domain) do
      d when is_binary(d) and byte_size(d) > 0 -> :ok
      nil -> {:error, {:missing_required_field, :domain}}
      _ -> {:error, {:invalid_field, :domain, "must be a non-empty string"}}
    end
  end

  defp validate_dimensions(attrs) do
    case Map.get(attrs, :dimensions) do
      dims when is_list(dims) and dims != [] ->
        Enum.reduce_while(dims, :ok, fn dim, _acc ->
          cond do
            not is_map(dim) ->
              {:halt, {:error, {:invalid_dimension, "each dimension must be a map"}}}

            not is_atom(dim[:name]) ->
              {:halt, {:error, {:invalid_dimension, "dimension name must be an atom"}}}

            not is_number(dim[:weight]) or dim[:weight] < 0 ->
              {:halt,
               {:error, {:invalid_dimension, "dimension weight must be a non-negative number"}}}

            true ->
              {:cont, :ok}
          end
        end)

      nil ->
        {:error, {:missing_required_field, :dimensions}}

      [] ->
        {:error, {:invalid_field, :dimensions, "must have at least one dimension"}}

      _ ->
        {:error, {:invalid_field, :dimensions, "must be a list of dimension maps"}}
    end
  end
end
