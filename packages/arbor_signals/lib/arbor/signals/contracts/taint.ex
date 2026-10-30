defmodule Arbor.Signals.Contracts.Taint do
  @moduledoc """
  Compatibility function namespace for Kernel's canonical taint contract.

  As of Signals 0.2, `Arbor.Contracts.Security.Taint` owns the struct, validation
  and lattice operations. These functions delegate to that owner and return its
  values. No separate Signals taint struct or JSON encoder is defined here.

  Callers that construct or match structs must use the canonical Kernel type.
  Existing process-local Signals struct values are not silently coerced; migrate
  them explicitly at a trusted boundary. The closed durable v1 envelope format
  is unchanged. Legacy `Signals.Taint.data_hash/1` continues to hash the exact
  caller term, so changing a process-local term's type changes that legacy hash.
  """

  alias Arbor.Contracts.Security.Taint, as: CanonicalTaint

  @type t :: CanonicalTaint.t()
  @type level :: CanonicalTaint.level()
  @type sensitivity :: CanonicalTaint.sensitivity()
  @type confidence :: CanonicalTaint.confidence()

  @spec fields() :: [atom()]
  defdelegate fields(), to: CanonicalTaint

  @spec max_source_bytes() :: pos_integer()
  defdelegate max_source_bytes(), to: CanonicalTaint

  @spec max_chain_entries() :: pos_integer()
  defdelegate max_chain_entries(), to: CanonicalTaint

  @spec max_chain_entry_bytes() :: pos_integer()
  defdelegate max_chain_entry_bytes(), to: CanonicalTaint

  @spec max_join_inputs() :: pos_integer()
  defdelegate max_join_inputs(), to: CanonicalTaint

  @spec invalid_durable_provenance() :: t()
  defdelegate invalid_durable_provenance(), to: CanonicalTaint

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, atom()}
  defdelegate new(attrs), to: CanonicalTaint

  @spec canonicalize(term()) :: {:ok, t()} | {:error, atom()}
  defdelegate canonicalize(value), to: CanonicalTaint

  @spec validate(term()) :: :ok | {:error, atom()}
  defdelegate validate(value), to: CanonicalTaint

  @spec join(term(), term()) :: {:ok, t()} | {:error, atom()}
  defdelegate join(left, right), to: CanonicalTaint

  @spec join_many([term()]) :: {:ok, t()} | {:error, atom()}
  defdelegate join_many(values), to: CanonicalTaint

  @spec to_persisted(term()) :: {:ok, map()} | {:error, atom()}
  defdelegate to_persisted(value), to: CanonicalTaint

  @spec sanitization_bits() :: %{atom() => non_neg_integer()}
  defdelegate sanitization_bits(), to: CanonicalTaint

  @spec sanitization_bit(atom()) :: {:ok, non_neg_integer()} | :error
  defdelegate sanitization_bit(name), to: CanonicalTaint

  @spec levels() :: [level()]
  defdelegate levels(), to: CanonicalTaint

  @spec sensitivities() :: [sensitivity()]
  defdelegate sensitivities(), to: CanonicalTaint

  @spec confidences() :: [confidence()]
  defdelegate confidences(), to: CanonicalTaint
end
