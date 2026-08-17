defmodule Arbor.Commands.SafeRecoveryArtifact.CheckCore do
  @moduledoc false

  # Pure admission decisions for the committed E0B2C3c1 artifact. Report
  # admission revalidates the closed envelope plus the full payload
  # projection (whose findings recomputation enforces the unchanged reviewed
  # blocker set). Check-level admission additionally demands a proven
  # identical two-build reproducibility result and the frozen lock
  # cross-bindings. compare_inputs/2 binds the committed inputs against an
  # observed complete input set.

  alias Arbor.Commands.SafeRecoveryArtifact.{Encode, Envelope}

  @max_build_inputs 5_000

  @doc "Report-level admission: closed envelope plus full payload validation."
  @spec admit_artifact(%{envelope_map: map(), manifest_map: map()}) ::
          {:ok, %{envelope: map(), manifest: map()}} | {:error, term()}
  def admit_artifact(%{envelope_map: envelope, manifest_map: manifest})
      when is_map(envelope) and is_map(manifest) do
    with :ok <- Envelope.validate(envelope),
         :ok <- Encode.validate_manifest(manifest) do
      {:ok, %{envelope: envelope, manifest: manifest}}
    end
  end

  def admit_artifact(_other), do: {:error, :invalid_artifact}

  @doc """
  Check-level admission: report admission plus the identical-reproducibility
  gate and the frozen lock cross-bindings.
  """
  @spec admit_for_check(%{envelope_map: map(), manifest_map: map()}) ::
          {:ok, %{envelope: map(), manifest: map()}} | {:error, term()}
  def admit_for_check(%{envelope_map: _envelope, manifest_map: manifest} = artifact) do
    with {:ok, admitted} <- admit_artifact(artifact),
         :ok <- require_identical(manifest),
         :ok <- require_lock_bindings(manifest) do
      {:ok, admitted}
    end
  end

  def admit_for_check(_other), do: {:error, :invalid_artifact}

  @doc """
  Bind the committed build inputs against the observed complete input set.

  Fails closed on any count, path-set, or per-path digest difference --
  nothing is silently downgraded to build-verify-only evidence.
  """
  @spec compare_inputs([map()], [map()]) :: :ok | {:error, term()}
  def compare_inputs(committed, observed) when is_list(committed) and is_list(observed) do
    with :ok <- require_counts(committed, observed) do
      compare_paths(committed, observed)
    end
  end

  def compare_inputs(_committed, _observed), do: {:error, :invalid_inputs}

  @doc """
  Bind the envelope descriptor to the exact payload file bytes.

  The envelope's payload digest and byte size must match the bytes actually
  read from the committed payload path.
  """
  @spec bind_payload_bytes(map(), binary()) :: :ok | {:error, term()}
  def bind_payload_bytes(
        %{"payload" => %{"sha256" => digest, "byte_size" => size}},
        payload_bytes
      )
      when is_binary(payload_bytes) do
    cond do
      byte_size(payload_bytes) != size -> {:error, :payload_size_mismatch}
      sha256_hex(payload_bytes) != digest -> {:error, :payload_digest_mismatch}
      true -> :ok
    end
  end

  def bind_payload_bytes(_envelope, _payload_bytes), do: {:error, :invalid_envelope}

  defp require_identical(%{"reproducibility" => %{"status" => "identical"}}), do: :ok

  defp require_identical(%{"reproducibility" => %{"status" => _other}}),
    do: {:error, :reproducibility_mismatch}

  defp require_identical(_manifest), do: {:error, :reproducibility_mismatch}

  defp require_lock_bindings(%{"toolchain" => toolchain, "source" => %{"build_inputs" => inputs}}) do
    by_path = Map.new(inputs, &{&1["path"], &1["sha256"]})

    with :ok <- match_lock(toolchain["mix_lock_sha256"], by_path["mix.lock"]) do
      match_lock(toolchain["tool_versions_sha256"], by_path[".tool-versions"])
    end
  end

  defp require_lock_bindings(_manifest), do: {:error, :lock_binding_mismatch}

  defp match_lock(actual, expected) when is_binary(actual) and actual == expected, do: :ok
  defp match_lock(_actual, _expected), do: {:error, :lock_binding_mismatch}

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp require_counts(committed, observed) do
    if length(committed) <= @max_build_inputs and length(observed) <= @max_build_inputs and
         length(committed) == length(observed) do
      :ok
    else
      {:error, {:input_count_mismatch, length(committed), length(observed)}}
    end
  end

  defp compare_paths(committed, observed) do
    committed_by_path = index_inputs(committed)
    observed_by_path = index_inputs(observed)

    with :ok <- require_no_missing(committed_by_path, observed_by_path),
         :ok <- require_no_extra(committed_by_path, observed_by_path) do
      require_digests(committed_by_path, observed_by_path)
    end
  end

  defp index_inputs(inputs) do
    Map.new(inputs, fn input -> {Map.fetch!(input, "path"), Map.fetch!(input, "sha256")} end)
  end

  defp require_no_missing(committed, observed) do
    case Enum.find(committed, fn {path, _digest} -> not Map.has_key?(observed, path) end) do
      nil -> :ok
      {path, _digest} -> {:error, {:missing_build_input, path}}
    end
  end

  defp require_no_extra(committed, observed) do
    case Enum.find(observed, fn {path, _digest} -> not Map.has_key?(committed, path) end) do
      nil -> :ok
      {path, _digest} -> {:error, {:extra_build_input, path}}
    end
  end

  defp require_digests(committed, observed) do
    case Enum.find(committed, fn {path, digest} -> Map.get(observed, path) != digest end) do
      nil -> :ok
      {path, _digest} -> {:error, {:input_digest_mismatch, path}}
    end
  end
end
