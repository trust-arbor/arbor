defmodule Arbor.Commands.KernelMaterialization.Evidence do
  @moduledoc """
  Pure admit/compare for K4B transform/generated destination evidence.
  """

  alias Arbor.Commands.KernelMaterialization.{Core, Encode}

  @schema "arbor.packaging.kernel_materialization.transform_evidence.v1"
  @kinds MapSet.new(["transform", "generated"])
  @accepted_modes MapSet.new(["100644", "100755"])
  @owner_apps MapSet.new(["arbor_kernel", "arbor_kernel_runtime"])
  @allowed_keys MapSet.new(["schema", "version", "plan_digest", "entries"])
  @allowed_entry_keys MapSet.new(["destination_path", "kind", "mode", "oid"])

  @spec empty(String.t()) :: map()
  def empty(plan_digest) when is_binary(plan_digest) do
    %{
      "schema" => @schema,
      "version" => 1,
      "plan_digest" => plan_digest,
      "entries" => []
    }
  end

  def empty(_), do: empty(String.duplicate("0", 64))

  @doc """
  Decide whether empty evidence may be written for `plan_digest`.

  Missing files are represented as `nil`. Non-empty evidence is never
  rewritten. Malformed JSON or schema fails closed.
  """
  @spec bind_empty(nil | binary(), String.t()) :: {:ok, map()} | {:error, term()}
  def bind_empty(nil, plan_digest) when is_binary(plan_digest) do
    {:ok, empty(plan_digest)}
  end

  def bind_empty(bytes, plan_digest) when is_binary(bytes) and is_binary(plan_digest) do
    case Jason.decode(bytes) do
      {:ok, raw} when is_map(raw) ->
        cond do
          is_list(raw["entries"]) and raw["entries"] != [] ->
            {:error, :evidence_not_empty}

          exact_keys?(raw, @allowed_keys) and raw["schema"] == @schema and
            raw["version"] == 1 and raw["entries"] == [] and
            Encode.blob_oid_valid?(raw["plan_digest"]) and
              Encode.oid_matches_format?(raw["plan_digest"], "sha256") ->
            {:ok, empty(plan_digest)}

          true ->
            {:error, :evidence_malformed}
        end

      {:ok, _} ->
        {:error, :evidence_malformed}

      _ ->
        {:error, :evidence_malformed}
    end
  end

  def bind_empty(_, _), do: {:error, :evidence_malformed}

  @spec admit(map(), map()) :: {:ok, map()} | {:error, term()}
  def admit(raw, plan) when is_map(raw) and is_map(plan) do
    digest = plan["entries_digest"]

    cond do
      raw["schema"] != @schema or raw["version"] != 1 ->
        {:error, :transform_evidence_unbound}

      not is_binary(raw["plan_digest"]) or byte_size(raw["plan_digest"]) != 64 ->
        {:error, :missing_evidence_identity}

      not Encode.blob_oid_valid?(raw["plan_digest"]) or
          not Encode.oid_matches_format?(raw["plan_digest"], "sha256") ->
        {:error, :missing_evidence_identity}

      raw["plan_digest"] != digest ->
        {:error, :evidence_digest_mismatch}

      not is_list(raw["entries"]) ->
        {:error, :transform_evidence_unbound}

      not exact_keys?(raw, @allowed_keys) ->
        {:error, :transform_evidence_unbound}

      true ->
        with {:ok, entries} <- admit_entries(raw["entries"], plan, plan["object_format"]) do
          {:ok,
           %{
             "schema" => @schema,
             "version" => 1,
             "plan_digest" => digest,
             "entries" => entries
           }}
        end
    end
  end

  def admit(_, _), do: {:error, :transform_evidence_unbound}

  defp admit_entries(list, plan, format) do
    cond do
      not Enum.all?(list, &is_map/1) ->
        {:error, :transform_evidence_unbound}

      true ->
        dests = Enum.map(list, & &1["destination_path"])
        reserved = reserved_paths(plan)

        if length(dests) != length(Enum.uniq(dests)) do
          {:error, :duplicate_destination}
        else
          Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
            case admit_entry(entry, plan, reserved, format) do
              {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
              {:error, _} = err -> {:halt, err}
            end
          end)
          |> case do
            {:ok, acc} -> {:ok, Enum.reverse(acc)}
            err -> err
          end
        end
    end
  end

  defp admit_entry(entry, plan, reserved, format) when is_map(entry) do
    dest = entry["destination_path"]
    kind = entry["kind"]
    mode = entry["mode"]
    oid = entry["oid"]
    transform_destinations = Core.transform_destinations(plan)

    cond do
      not is_binary(dest) or dest == "" ->
        {:error, {:invalid_path, dest || ""}}

      not valid_generated_or_transform_path?(dest) ->
        {:error, {:invalid_path, dest}}

      kind not in @kinds ->
        {:error, :transform_evidence_unbound}

      not is_binary(mode) or not is_binary(oid) ->
        {:error, :missing_evidence_identity}

      mode not in @accepted_modes or not Encode.blob_oid_valid?(oid) or
          not Encode.oid_matches_format?(oid, format || infer_format(oid)) ->
        {:error, :missing_evidence_identity}

      not exact_keys?(entry, @allowed_entry_keys) ->
        {:error, :transform_evidence_unbound}

      kind == "transform" and not MapSet.member?(transform_destinations, dest) ->
        {:error, :transform_evidence_unbound}

      kind == "generated" and not generated_root?(dest) ->
        {:error, :transform_evidence_unbound}

      kind == "generated" and MapSet.member?(reserved, dest) ->
        {:error, :evidence_path_overlap}

      kind == "generated" and MapSet.member?(transform_destinations, dest) ->
        {:error, :evidence_path_overlap}

      true ->
        {:ok, Encode.order_evidence_entry(entry)}
    end
  end

  defp admit_entry(_, _, _, _), do: {:error, :transform_evidence_unbound}

  defp reserved_paths(plan) do
    exact =
      (plan["entries"] || [])
      |> Enum.filter(&(&1["disposition"] == "exact_move"))
      |> Enum.map(& &1["destination_path"])

    retain =
      (plan["retained_targets"] || [])
      |> Enum.filter(&(&1["disposition"] == "retain"))
      |> Enum.map(& &1["path"])

    transform = MapSet.to_list(Core.transform_destinations(plan))
    MapSet.new(exact ++ retain ++ transform)
  end

  defp generated_root?(path) do
    case Path.split(path) do
      ["apps", app | rest] when rest != [] -> app in @owner_apps
      _ -> false
    end
  end

  defp valid_generated_or_transform_path?(path) do
    cond do
      path == "" ->
        false

      not String.valid?(path) ->
        false

      String.contains?(path, <<0>>) ->
        false

      String.starts_with?(path, "/") ->
        false

      String.contains?(path, "\\") ->
        false

      String.starts_with?(path, ":") ->
        false

      String.contains?(path, "*") or String.contains?(path, "?") or
        String.contains?(path, "[") or String.contains?(path, "]") or
          String.contains?(path, "~") ->
        false

      path
      |> String.split("/")
      |> Enum.any?(&(&1 in ["..", "", "."])) ->
        false

      true ->
        true
    end
  end

  defp infer_format(oid) when byte_size(oid) == 64, do: "sha256"
  defp infer_format(_), do: "sha1"

  defp exact_keys?(map, expected) when is_map(map) do
    MapSet.equal?(MapSet.new(Map.keys(map)), expected)
  end

  defp exact_keys?(_, _), do: false
end
