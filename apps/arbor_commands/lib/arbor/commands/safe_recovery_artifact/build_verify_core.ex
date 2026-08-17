defmodule Arbor.Commands.SafeRecoveryArtifact.BuildVerifyCore do
  @moduledoc false

  # Pure two-build evidence equality for E0B2C3c1 --build-verify. The
  # committed and freshly composed manifests must project to identical
  # canonical bytes once only the Git provenance pointers (source.commit and
  # source.tree) are excluded: build outputs, findings, reproducibility,
  # toolchain, platform-inventory bindings, and build inputs must all agree.

  alias Arbor.Commands.SafeRecoveryArtifact.Encode

  @provenance_keys ["commit", "tree"]

  @doc """
  Require identical evidence between the committed and the fresh manifest,
  excluding only `source.commit` and `source.tree`.
  """
  @spec equal_evidence(map(), map()) :: :ok | {:error, {:build_verify_mismatch, map()}}
  def equal_evidence(committed, fresh) when is_map(committed) and is_map(fresh) do
    with {:ok, committed_digest} <- Encode.manifest_digest(committed),
         {:ok, fresh_digest} <- Encode.manifest_digest(fresh),
         {:ok, committed_stripped} <- strip_provenance(committed),
         {:ok, fresh_stripped} <- strip_provenance(fresh),
         {:ok, committed_bytes} <- Encode.canonical_json(committed_stripped),
         {:ok, fresh_bytes} <- Encode.canonical_json(fresh_stripped) do
      if committed_bytes == fresh_bytes do
        :ok
      else
        {:error,
         {:build_verify_mismatch,
          %{committed_manifest_digest: committed_digest, fresh_manifest_digest: fresh_digest}}}
      end
    end
  end

  def equal_evidence(_committed, _fresh), do: {:error, :invalid_manifest}

  defp strip_provenance(%{"source" => source} = manifest) when is_map(source) do
    {:ok, %{manifest | "source" => Map.drop(source, @provenance_keys)}}
  end

  defp strip_provenance(_manifest), do: {:error, :invalid_manifest}
end
