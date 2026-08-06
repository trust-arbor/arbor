defmodule Arbor.Memory.EmbeddingEvidence do
  @moduledoc false

  # Pure helpers for source-owned embedding model evidence. Provider maps in
  # caller metadata are never authority.

  alias Arbor.Contracts.Persistence.VectorRecord

  @local_hash_model_id "memory:local_hash_v1"
  @legacy_model_id "legacy:unspecified"

  @doc "Stable model id for deterministic local hash fallback vectors."
  @spec local_hash_model_id() :: String.t()
  def local_hash_model_id, do: @local_hash_model_id

  @doc "Durable model id for precomputed / absent evidence."
  @spec legacy_model_id() :: String.t()
  def legacy_model_id, do: @legacy_model_id

  @doc """
  Validate an Arbor.AI (or provider) embedding result into vector + model_evidence.

  Requires non-empty provider/model, matching dimensions, and normalized length.
  """
  @spec from_provider_result(term()) ::
          {:ok, %{vector: [float()], model_evidence: term(), model_id: String.t()}}
          | {:error, atom()}
  def from_provider_result(%{embedding: embedding, model: model, provider: provider} = result)
      when is_list(embedding) do
    dimensions = Map.get(result, :dimensions) || Map.get(result, "dimensions")

    with {:ok, model_bin} <- normalize_utf8_label(model),
         {:ok, provider_bin} <- provider_to_string(provider),
         {:ok, vector} <- VectorRecord.normalize_vector(embedding),
         true <- dimensions == VectorRecord.dimensions(),
         true <- length(vector) == VectorRecord.dimensions() do
      model_id = provider_bin <> "/" <> model_bin

      {:ok,
       %{
         vector: vector,
         model_evidence: {:provider_model, provider_bin, model_bin},
         model_id: model_id
       }}
    else
      false -> {:error, :invalid_provider_embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_provider_result(_), do: {:error, :invalid_provider_embedding}

  @doc "Caller-precomputed vector: no model authority."
  @spec from_precomputed(term()) ::
          {:ok, %{vector: [float()], model_evidence: :absent, model_id: String.t()}}
          | {:error, atom()}
  def from_precomputed(embedding) do
    case VectorRecord.normalize_vector(embedding) do
      {:ok, vector} ->
        {:ok,
         %{
           vector: vector,
           model_evidence: :absent,
           model_id: @legacy_model_id
         }}

      {:error, :invalid_vector} ->
        {:error, :invalid_embedding}
    end
  end

  @doc "Deterministic local hash fallback with stable explicit model id."
  @spec local_hash_fallback(String.t()) ::
          %{vector: [float()], model_evidence: term(), model_id: String.t()}
  def local_hash_fallback(text) when is_binary(text) do
    dimension = VectorRecord.dimensions()
    hash = :erlang.phash2(text, 1_000_000)

    raw =
      for i <- 0..(dimension - 1) do
        :math.sin((hash + i) / 1000) * 0.5 + 0.5
      end

    # This vector is generated locally from finite values at the contract's
    # exact dimension. Never silently fall back to an unvalidated representation.
    {:ok, vector} = VectorRecord.normalize_vector(raw)

    %{
      vector: vector,
      model_evidence: {:model_id, @local_hash_model_id},
      model_id: @local_hash_model_id
    }
  end

  defp provider_to_string(provider) when is_atom(provider) and not is_nil(provider) do
    normalize_utf8_label(Atom.to_string(provider))
  end

  defp provider_to_string(provider) when is_binary(provider), do: normalize_utf8_label(provider)
  defp provider_to_string(_), do: {:error, :invalid_provider_embedding}

  defp normalize_utf8_label(label) when is_atom(label) and not is_nil(label) do
    normalize_utf8_label(Atom.to_string(label))
  end

  defp normalize_utf8_label(label) when is_binary(label) do
    if String.valid?(label) do
      trimmed = String.trim(label)

      if byte_size(trimmed) > 0 do
        {:ok, trimmed}
      else
        {:error, :invalid_provider_embedding}
      end
    else
      {:error, :invalid_provider_embedding}
    end
  end

  defp normalize_utf8_label(_), do: {:error, :invalid_provider_embedding}
end
