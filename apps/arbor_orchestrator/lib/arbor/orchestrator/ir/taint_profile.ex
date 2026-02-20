defmodule Arbor.Orchestrator.IR.TaintProfile do
  @moduledoc """
  Compile-time taint profile for compiled graph nodes.

  Unlike `Arbor.Contracts.Security.Taint` which tracks runtime *state*
  (what sanitizations HAVE been applied), a TaintProfile declares
  *requirements* (what sanitizations are NEEDED on input and what a
  node PROVIDES on output).

  Populated by the IR Compiler and consumed by the IR Validator for
  compile-time sanitization flow analysis.
  """

  import Bitwise

  @taint_contract Arbor.Contracts.Security.Taint

  @type sensitivity :: :public | :internal | :confidential | :restricted
  @type confidence :: :unverified | :plausible | :corroborated | :verified

  @type t :: %__MODULE__{
          sensitivity: sensitivity(),
          required_sanitizations: non_neg_integer(),
          output_sanitizations: non_neg_integer(),
          wipes_sanitizations: boolean(),
          min_confidence: confidence(),
          provider_constraint: atom() | nil
        }

  defstruct sensitivity: :public,
            required_sanitizations: 0,
            output_sanitizations: 0,
            wipes_sanitizations: false,
            min_confidence: :unverified,
            provider_constraint: nil

  @confidence_rank %{unverified: 0, plausible: 1, corroborated: 2, verified: 3}

  @doc """
  Returns a pessimistic (maximally restrictive) taint profile.

  Used for adapt nodes which can self-modify pipeline topology at runtime.
  """
  @spec pessimistic() :: t()
  def pessimistic do
    %__MODULE__{
      sensitivity: :restricted,
      required_sanitizations: 0,
      output_sanitizations: 0,
      wipes_sanitizations: true,
      min_confidence: :unverified,
      provider_constraint: :can_see_restricted
    }
  end

  @doc """
  Check if a provided sanitization bitmask satisfies a required bitmask.

  Returns true if every bit set in `required` is also set in `provided`.
  """
  @spec satisfies?(non_neg_integer(), non_neg_integer()) :: boolean()
  def satisfies?(provided, required) do
    band(provided, required) == required
  end

  @doc """
  Returns a list of sanitization names that are required but not provided.

  Uses the Taint contract's `sanitization_bits/0` to decode the bitmask.
  """
  @spec missing_sanitizations(non_neg_integer(), non_neg_integer()) :: [atom()]
  def missing_sanitizations(provided, required) do
    missing_mask = band(required, bnot(provided))

    if missing_mask == 0 do
      []
    else
      sanitization_bits()
      |> Enum.filter(fn {_name, bit} -> band(missing_mask, bit) != 0 end)
      |> Enum.map(fn {name, _bit} -> name end)
      |> Enum.sort()
    end
  end

  @doc """
  Returns the numeric rank for a confidence level.
  """
  @spec confidence_rank(confidence()) :: non_neg_integer()
  def confidence_rank(level), do: Map.get(@confidence_rank, level, 0)

  @doc """
  Parse a comma-separated sanitization names string into a bitmask.

  Example: `"command_injection,path_traversal"` → `0b00001100`
  """
  @spec parse_sanitization_names(String.t()) :: non_neg_integer()
  def parse_sanitization_names(names_str) when is_binary(names_str) do
    names_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(0, fn name, mask ->
      case safe_sanitization_bit(name) do
        {:ok, bit} -> bor(mask, bit)
        :error -> mask
      end
    end)
  end

  def parse_sanitization_names(_), do: 0

  # -- Private --

  defp sanitization_bits do
    if Code.ensure_loaded?(@taint_contract) and
         function_exported?(@taint_contract, :sanitization_bits, 0) do
      @taint_contract.sanitization_bits()
    else
      %{}
    end
  end

  defp safe_sanitization_bit(name) when is_binary(name) do
    atom = String.to_existing_atom(name)

    if Code.ensure_loaded?(@taint_contract) and
         function_exported?(@taint_contract, :sanitization_bit, 1) do
      @taint_contract.sanitization_bit(atom)
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end
end
