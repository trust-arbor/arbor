defmodule Arbor.Commands.AppEnvInventory.Encode do
  @moduledoc """
  Canonical ordered JSON and domain-separated digests for app-env inventory.
  Pure: no filesystem or process access.
  """

  @scan_manifest_domain "arbor.packaging.app_env_inventory.scan_manifest.v2\0"

  @report_key_order [
    "schema",
    "mode",
    "status",
    "output",
    "legacy_owners",
    "target_app",
    "counts",
    "findings",
    "provenance"
  ]

  @finding_key_order [
    "path",
    "line",
    "column",
    "class",
    "trust",
    "form",
    "legacy_app",
    "arity"
  ]

  @doc "Domain-separated scan manifest digest over sorted {path, mode, blob_oid}."
  @spec scan_manifest_digest([{String.t(), String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, :invalid_manifest_pairs | :duplicate_manifest_pairs}
  def scan_manifest_digest(triples) when is_list(triples) do
    cond do
      not Enum.all?(triples, &valid_manifest_triple?/1) ->
        {:error, :invalid_manifest_pairs}

      duplicate_manifest_paths?(triples) ->
        {:error, :duplicate_manifest_pairs}

      true ->
        digest =
          triples
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.reduce(
            :crypto.hash_init(:sha256) |> :crypto.hash_update(@scan_manifest_domain),
            fn {path, mode, oid}, acc ->
              :crypto.hash_update(acc, [
                <<byte_size(path)::unsigned-big-32>>,
                path,
                <<byte_size(mode)::unsigned-big-32>>,
                mode,
                <<byte_size(oid)::unsigned-big-32>>,
                oid
              ])
            end
          )
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, digest}
    end
  end

  def scan_manifest_digest(_), do: {:error, :invalid_manifest_pairs}

  defp valid_manifest_triple?({path, mode, oid})
       when is_binary(path) and is_binary(mode) and is_binary(oid) do
    path != "" and mode != "" and oid != ""
  end

  defp valid_manifest_triple?(_), do: false

  defp duplicate_manifest_paths?(triples) do
    paths = Enum.map(triples, &elem(&1, 0))
    length(paths) != length(Enum.uniq(paths))
  end

  @spec encode_report(map()) :: {:ok, binary()} | {:error, term()}
  def encode_report(report) when is_map(report) do
    ordered =
      Jason.OrderedObject.new(
        Enum.map(@report_key_order, fn key ->
          {key, canonicalize(Map.get(report, key))}
        end)
      )

    {:ok, Jason.encode!(ordered)}
  rescue
    _ -> {:error, :encode_failed}
  end

  def encode_report(_), do: {:error, :invalid_report}

  defp canonicalize(list) when is_list(list) do
    Enum.map(list, &canonicalize/1)
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    if finding?(map) do
      Jason.OrderedObject.new(
        Enum.map(@finding_key_order, fn key -> {key, canonicalize(Map.get(map, key))} end)
      )
    else
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
      |> Jason.OrderedObject.new()
    end
  end

  defp canonicalize(%Jason.OrderedObject{} = o), do: o
  defp canonicalize(other), do: other

  defp finding?(map) do
    Map.has_key?(map, "path") and Map.has_key?(map, "form") and Map.has_key?(map, "trust")
  end
end
