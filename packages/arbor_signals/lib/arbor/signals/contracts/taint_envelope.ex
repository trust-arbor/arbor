defmodule Arbor.Signals.Contracts.TaintEnvelope do
  @moduledoc """
  Compatibility function namespace for Kernel's durable provenance contract.

  As of Signals 0.2, `Arbor.Contracts.Security.TaintEnvelope` owns the envelope
  struct, canonical JSON encoding, validation and payload digest. All functions
  here delegate to it and return canonical Kernel values. This module defines
  no separate struct, encoder or provenance algorithm.

  Callers that construct or match envelopes must use Kernel's canonical type.
  Existing closed durable v1 maps remain valid without rewriting their fields,
  canonical payload bytes or digests. Old process-local envelope structs are not
  silently coerced into the canonical type.
  """

  alias Arbor.Contracts.Security.Taint, as: CanonicalTaint
  alias Arbor.Contracts.Security.TaintEnvelope, as: CanonicalEnvelope

  @type t :: CanonicalEnvelope.t()

  @spec version() :: pos_integer()
  defdelegate version(), to: CanonicalEnvelope

  @spec payload_encoding() :: String.t()
  defdelegate payload_encoding(), to: CanonicalEnvelope

  @spec limits() :: map()
  defdelegate limits(), to: CanonicalEnvelope

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, atom()}
  defdelegate new(attrs), to: CanonicalEnvelope

  @spec new(term(), term()) :: {:ok, t()} | {:error, atom()}
  defdelegate new(payload, taint), to: CanonicalEnvelope

  @spec to_map(term()) :: {:ok, map()} | {:error, atom()}
  defdelegate to_map(envelope), to: CanonicalEnvelope

  @spec canonical_json(term()) :: {:ok, binary()} | {:error, atom()}
  defdelegate canonical_json(payload), to: CanonicalEnvelope

  @spec payload_sha256(term()) :: {:ok, String.t()} | {:error, atom()}
  defdelegate payload_sha256(payload), to: CanonicalEnvelope

  @spec verify(term(), term()) :: {:ok, t()} | {:error, atom()}
  defdelegate verify(persisted, payload), to: CanonicalEnvelope

  @spec resolve(:missing | term(), term()) ::
          {:ok, CanonicalTaint.t(), :verified | :legacy_unlabeled | :invalid_durable_provenance}
  defdelegate resolve(persisted, payload), to: CanonicalEnvelope

  @spec missing_fallback() :: CanonicalTaint.t()
  defdelegate missing_fallback(), to: CanonicalEnvelope

  @spec invalid_fallback() :: CanonicalTaint.t()
  defdelegate invalid_fallback(), to: CanonicalEnvelope

  @spec decode_persisted(term()) :: {:ok, t()} | {:error, atom()}
  defdelegate decode_persisted(value), to: CanonicalEnvelope
end
