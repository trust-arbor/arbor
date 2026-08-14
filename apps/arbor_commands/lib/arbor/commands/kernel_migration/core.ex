defmodule Arbor.Commands.KernelMigration.Core do
  @moduledoc """
  Pure PK-K0 projector: K-upward inventory, ordinal identities, dispositions.
  """

  alias Arbor.Commands.KernelMigration.Encode

  @policy_version "k0.v1"
  @k_apps ["arbor_common", "arbor_contracts", "arbor_monitor", "arbor_signals"]
  @dispositions MapSet.new([
                  "remove_dead_code",
                  "invert_consumer_behaviour",
                  "lower_band_facade_or_data",
                  "relocate_plumbing_preserve_module"
                ])
  @owners MapSet.new([
            "K1A-contracts-data-and-load-boundary",
            "K1B-common-telemetry-persistence",
            "K1C-common-action-security-plumbing",
            "K1D-monitor-operational-bridges",
            "K1E-signals-durable-sink",
            "K1F-signals-security-services"
          ])
  @max_rationale_bytes 500
  @max_failures 50
  @report_schema "arbor.packaging.kernel_migration.report.v1"

  @spec policy_version() :: String.t()
  def policy_version, do: @policy_version

  @spec k_apps() :: [String.t()]
  def k_apps, do: @k_apps

  @spec mix_task_path?(String.t()) :: boolean()
  def mix_task_path?(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", _app, "lib", "mix", "tasks" | _] -> true
      _ -> false
    end
  end

  def mix_task_path?(_), do: false

  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(census) when is_map(census) do
    edges = Map.get(census, "classified_edges") || []

    k_set = MapSet.new(@k_apps)

    findings =
      edges
      |> Enum.filter(fn edge ->
        Map.get(edge, "from_app") in k_set and Map.get(edge, "fate") == "upward"
      end)
      |> assign_ordinals()
      |> Enum.map(&finalize_finding/1)
      |> Enum.sort_by(&finding_sort/1)

    {runtime, mix_task} = Enum.split_with(findings, &(&1["collection"] == "runtime"))

    {:ok,
     %{
       "policy_version" => @policy_version,
       "k_apps" => @k_apps,
       "runtime" => runtime,
       "mix_task" => mix_task,
       "provenance" => Map.get(census, "provenance") || %{}
     }}
  end

  def project(_), do: {:error, :invalid_census}

  @spec admit_dispositions(map()) :: {:ok, map()} | {:error, term()}
  def admit_dispositions(raw) when is_map(raw) do
    with :ok <- exact_schema(raw, "arbor.packaging.kernel_migration.disposition.v1"),
         :ok <- exact_version(raw),
         {:ok, entries} <- admit_disposition_entries(Map.get(raw, "entries")) do
      ids = Enum.map(entries, & &1["finding_id"])

      cond do
        length(ids) != length(Enum.uniq(ids)) ->
          {:error, :duplicate_disposition}

        true ->
          ordered = Enum.sort_by(entries, &disposition_sort/1)

          {:ok,
           %{
             "schema" => "arbor.packaging.kernel_migration.disposition.v1",
             "version" => 1,
             "policy_version" => raw["policy_version"] || @policy_version,
             "k_apps" => raw["k_apps"] || @k_apps,
             "entries" => Enum.map(ordered, &Encode.order_disposition/1),
             "entries_digest" => Encode.disposition_digest(ordered)
           }}
      end
    end
  end

  def admit_dispositions(_), do: {:error, :malformed_disposition}

  @spec compare_dispositions([map()], map()) :: {:ok, map()}
  def compare_dispositions(runtime, admitted) when is_list(runtime) and is_map(admitted) do
    derived = Map.new(runtime, &{&1["finding_id"], &1})
    reviewed = Map.new(admitted["entries"] || [], &{&1["finding_id"], &1})

    failures =
      []
      |> missing_failures(derived, reviewed)
      |> extra_failures(derived, reviewed)

    status = if failures == [], do: "ok", else: "failed"
    bounded = Enum.take(Enum.sort_by(failures, &{&1["reason"], &1["detail"]}), @max_failures)

    {:ok,
     %{
       "status" => status,
       "failures" => bounded,
       "failure_count" => length(failures),
       "truncated" => length(failures) > @max_failures
     }}
  end

  def compare_dispositions(_, _), do: {:error, :invalid_compare}

  @spec show(map(), map(), map()) :: map()
  def show(projected, compare, extras) when is_map(projected) and is_map(compare) do
    extras = extras || %{}
    mode = extras["mode"] || "report"
    status = if compare["status"] == "failed", do: "failed", else: "ok"

    runtime = projected["runtime"] || []
    mix_task = projected["mix_task"] || []
    boundary = extras["boundary"] || []
    formatter = extras["formatter"] || []
    dispositions = extras["dispositions"] || []

    policy = %{
      "version" => @policy_version,
      "k_apps" => @k_apps
    }

    provenance =
      (projected["provenance"] || %{})
      |> Map.take(["scan_manifest_digest", "object_format", "provenance_source"])
      |> Map.put("k_apps", @k_apps)
      |> Map.put("policy_version", @policy_version)

    identity =
      Encode.identity(%{
        "scan_manifest_digest" => provenance["scan_manifest_digest"] || "",
        "disposition_manifest_digest" => extras["disposition_manifest_digest"] || "",
        "boundary_manifest_digest" => extras["boundary_manifest_digest"] || "",
        "formatter_manifest_digest" => extras["formatter_manifest_digest"] || "",
        "policy_version" => @policy_version,
        "k_apps" => @k_apps,
        "runtime_digest" => Encode.runtime_digest(runtime),
        "mix_task_digest" => Encode.mix_task_digest(mix_task)
      })

    %{
      "schema" => @report_schema,
      "mode" => mode,
      "status" => status,
      "output" => extras["output"] || "human",
      "identity" => identity,
      "policy" => policy,
      "provenance" => provenance,
      "counts" => %{
        "total" => length(runtime) + length(mix_task),
        "runtime" => length(runtime),
        "mix_task" => length(mix_task),
        "boundary" => length(boundary),
        "formatter" => length(formatter),
        "dispositions" => length(dispositions)
      },
      "runtime" => runtime,
      "mix_task" => mix_task,
      "boundary" => boundary,
      "formatter" => formatter,
      "dispositions" => dispositions,
      "comparison" => compare,
      "errors" => extras["errors"] || []
    }
  end

  defp assign_ordinals(edges) do
    edges
    |> Enum.with_index()
    |> Enum.group_by(fn {edge, _} -> identity_key(edge) end)
    |> Enum.flat_map(fn {_key, group} ->
      group
      |> Enum.sort_by(fn {edge, idx} ->
        {Map.get(edge, "line", 0), Map.get(edge, "extract_seq", idx)}
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{edge, _idx}, ordinal} ->
        Map.put(edge, "occurrence_ordinal", ordinal)
      end)
    end)
  end

  defp finalize_finding(edge) do
    collection = if mix_task_path?(edge["file"]), do: "mix_task", else: "runtime"

    edge
    |> Map.put("collection", collection)
    |> then(fn finding -> Map.put(finding, "finding_id", Encode.finding_id(finding)) end)
    |> Encode.order_finding()
  end

  defp identity_key(edge) do
    {
      edge["file"],
      edge["from_module"],
      edge["target"],
      edge["kind"],
      edge["class"]
    }
  end

  defp finding_sort(f) do
    {f["file"], f["line"], f["from_module"], f["target"], f["kind"], f["class"],
     f["occurrence_ordinal"]}
  end

  defp disposition_sort(e) do
    {e["file"], e["from_module"], e["target"], e["kind"], e["class"], e["occurrence_ordinal"]}
  end

  defp exact_schema(%{"schema" => schema}, schema), do: :ok
  defp exact_schema(_, _), do: {:error, :malformed_disposition}

  defp exact_version(%{"version" => 1}), do: :ok
  defp exact_version(_), do: {:error, :malformed_disposition}

  defp admit_disposition_entries(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case admit_disposition_entry(entry) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp admit_disposition_entries(_), do: {:error, :malformed_disposition}

  defp admit_disposition_entry(entry) when is_map(entry) do
    disp = entry["disposition"]
    owner = entry["owner_packet"]
    rationale = entry["rationale"]
    ordinal = entry["occurrence_ordinal"] || 1

    cond do
      not MapSet.member?(@dispositions, disp) ->
        {:error, :invalid_disposition}

      not MapSet.member?(@owners, owner) ->
        {:error, :invalid_owner_packet}

      not is_binary(rationale) or String.trim(rationale) == "" or
          byte_size(rationale) > @max_rationale_bytes ->
        {:error, :invalid_rationale}

      not is_integer(ordinal) or ordinal < 1 ->
        {:error, :invalid_ordinal}

      not Encode.blob_oid_valid?(entry["blob_oid"]) ->
        {:error, :missing_disposition_evidence}

      true ->
        normalized =
          entry
          |> Map.put("occurrence_ordinal", ordinal)
          |> then(fn e -> Map.put(e, "finding_id", Encode.finding_id(e)) end)
          |> Encode.order_disposition()

        if is_binary(entry["finding_id"]) and entry["finding_id"] != normalized["finding_id"] do
          {:error, :finding_id_mismatch}
        else
          {:ok, normalized}
        end
    end
  end

  defp admit_disposition_entry(_), do: {:error, :malformed_disposition}

  defp missing_failures(failures, derived, reviewed) do
    Enum.reduce(derived, failures, fn {id, finding}, acc ->
      if Map.has_key?(reviewed, id) do
        acc
      else
        [%{"reason" => "missing_disposition", "detail" => id_detail(finding)} | acc]
      end
    end)
  end

  defp extra_failures(failures, derived, reviewed) do
    Enum.reduce(reviewed, failures, fn {id, entry}, acc ->
      if Map.has_key?(derived, id) do
        acc
      else
        [%{"reason" => "stale_or_extra_disposition", "detail" => id_detail(entry)} | acc]
      end
    end)
  end

  defp id_detail(entry) do
    Enum.join(
      [
        entry["file"] || "",
        entry["from_module"] || "",
        entry["target"] || "",
        entry["kind"] || "",
        entry["class"] || "",
        to_string(entry["occurrence_ordinal"] || 1)
      ],
      "|"
    )
  end
end
