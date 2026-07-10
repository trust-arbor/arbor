defmodule Arbor.Actions.Coding.SecurityRegression.Attestation do
  @moduledoc false

  @scalar_keys [
    :workspace_id,
    :base_commit,
    :candidate_commit,
    :candidate_tree_oid,
    :diff_sha256,
    :validation_profile
  ]

  @doc "Build canonical, digest-bearing reviewed-tree material."
  @spec new(map(), String.t() | nil) :: {:ok, map()} | {:error, :invalid_review_material}
  def new(material, council_decision_digest \\ nil)

  def new(material, council_decision_digest) when is_map(material) do
    with {:ok, normalized} <- normalize(material, council_decision_digest) do
      {:ok, Map.put(normalized, :canonical_digest, digest(normalized))}
    end
  end

  def new(_, _), do: {:error, :invalid_review_material}

  @doc "Return a deterministic SHA-256 over all binding attestation fields."
  @spec digest(map()) :: String.t()
  def digest(material) when is_map(material) do
    material
    |> canonical_bytes()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Deterministic binary representation used exclusively for the canonical digest."
  @spec canonical_bytes(map()) :: binary()
  def canonical_bytes(material) when is_map(material) do
    values =
      [
        "arbor-reviewed-regression-v1",
        value(material, :workspace_id),
        value(material, :base_commit),
        value(material, :candidate_commit),
        value(material, :candidate_tree_oid),
        value(material, :diff_sha256),
        value(material, :validation_profile),
        value(material, :council_decision_digest) || ""
      ] ++
        Enum.flat_map(selected_tests(material), fn %{path: path, blob_sha256: blob_sha256} ->
          [path, blob_sha256]
        end)

    values |> Enum.map(&field/1) |> IO.iodata_to_binary()
  end

  defp normalize(material, council_decision_digest) do
    with true <- Enum.all?(@scalar_keys, &valid_text?(value(material, &1))),
         true <- valid_oid?(value(material, :base_commit)),
         true <- valid_oid?(value(material, :candidate_commit)),
         true <- valid_oid?(value(material, :candidate_tree_oid)),
         true <- valid_sha256?(value(material, :diff_sha256)),
         true <- value(material, :validation_profile) == "security_regression",
         true <- is_nil(council_decision_digest) or valid_sha256?(council_decision_digest),
         {:ok, tests} <- normalize_tests(value(material, :selected_tests)) do
      material = %{
        workspace_id: value(material, :workspace_id),
        base_commit: value(material, :base_commit),
        candidate_commit: value(material, :candidate_commit),
        candidate_tree_oid: value(material, :candidate_tree_oid),
        diff_sha256: value(material, :diff_sha256),
        selected_tests: tests,
        validation_profile: value(material, :validation_profile)
      }

      {:ok, maybe_put_council_decision_digest(material, council_decision_digest)}
    else
      _ -> {:error, :invalid_review_material}
    end
  end

  defp normalize_tests(tests) when is_list(tests) and tests != [] do
    normalized =
      Enum.map(tests, fn test ->
        %{path: value(test, :path), blob_sha256: value(test, :blob_sha256)}
      end)

    if Enum.all?(normalized, &(valid_selected_path?(&1.path) and valid_sha256?(&1.blob_sha256))) and
         normalized == Enum.sort_by(normalized, & &1.path) and
         Enum.uniq_by(normalized, & &1.path) == normalized do
      {:ok, normalized}
    else
      {:error, :invalid_review_material}
    end
  end

  defp normalize_tests(_), do: {:error, :invalid_review_material}

  defp selected_tests(material) do
    material
    |> value(:selected_tests)
    |> List.wrap()
    |> Enum.map(fn test ->
      %{path: value(test, :path), blob_sha256: value(test, :blob_sha256)}
    end)
  end

  defp field(value) when is_binary(value),
    do: [Integer.to_string(byte_size(value)), ":", value, "\n"]

  defp field(_), do: "0:\n"

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil

  defp valid_text?(value),
    do: is_binary(value) and value != "" and String.valid?(value) and no_controls?(value)

  defp valid_selected_path?(value),
    do:
      valid_text?(value) and Path.type(value) == :relative and not String.contains?(value, "\\") and
        not Enum.member?(Path.split(value), "..")

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_oid?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, value)

  defp no_controls?(value), do: not Regex.match?(~r/[[:cntrl:]]/, value)
  defp maybe_put_council_decision_digest(material, nil), do: material

  defp maybe_put_council_decision_digest(material, digest),
    do: Map.put(material, :council_decision_digest, digest)
end
