defmodule Arbor.Memory.EmbeddingTaint do
  @moduledoc false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  # Only trusted producer opts supply labels. Payload metadata is never authority.
  def from_opts(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) in [[], [:taint]],
         {:ok, taint} <-
           Taint.canonicalize(Keyword.get(opts, :taint, TaintEnvelope.missing_fallback())) do
      {:ok, taint}
    else
      _ -> {:error, :invalid_taint}
    end
  end

  def from_opts(_), do: {:error, :invalid_taint}

  # A verified storage envelope proves byte integrity, not that its source was
  # labeled. Preserve missing/invalid provenance markers across that round trip.
  def fields(taint, status \\ :verified)

  def fields(nil, status) when status != :invalid_durable_provenance,
    do: fields(TaintEnvelope.missing_fallback(), :legacy_unlabeled)

  def fields(taint, status) do
    case Taint.canonicalize(taint) do
      {:ok, taint} ->
        cond do
          status == :invalid_durable_provenance or marker?(taint, "invalid_durable_provenance") ->
            invalid_fields()

          marker?(taint, "legacy_unlabeled") ->
            %{taint: taint, provenance_status: :legacy_unlabeled}

          status in [:verified, :legacy_unlabeled] ->
            %{taint: taint, provenance_status: status}

          true ->
            invalid_fields()
        end

      _ ->
        invalid_fields()
    end
  end

  defp marker?(taint, marker), do: taint.source == marker or marker in taint.chain

  defp invalid_fields,
    do: %{taint: TaintEnvelope.invalid_fallback(), provenance_status: :invalid_durable_provenance}
end
