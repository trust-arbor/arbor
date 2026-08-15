defmodule Arbor.Commands.KernelMaterialization do
  @moduledoc """
  Imperative shell for the K4A kernel materialization plan and checker.

  Production `run/1` only accepts CLI options. Synthetic inventory and Git
  runners are test-only via `run_for_test/1`. Check never writes. Write-plan
  refuses synthetic input.
  """

  alias Arbor.Commands.KernelMaterialization.{Core, Encode, Evidence}
  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SourceCoupling.GitInventory
  alias Arbor.Common.SafePath

  @default_plan_rel "apps/arbor_commands/priv/packaging/kernel_materialization_plan.v1.json"
  @default_evidence_rel "apps/arbor_commands/priv/packaging/kernel_materialization_transform_evidence.v1.json"

  @production_opt_keys [
    :mode,
    :phase,
    :json,
    :root,
    :plan,
    :transform_evidence,
    :allow_write
  ]

  @synthetic_opt_keys [
    :inventory,
    :run_git,
    :plan_map,
    :evidence_map,
    :extra_target_files,
    :source_presence,
    :present_paths,
    :dest_files,
    :target_files,
    :enforce_production_policy
  ]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] -> do_run(opts, allow_synthetic: false)
      unexpected -> {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, "report")

    cond do
      mode == "write_plan" and Keyword.get(opts, :allow_write, false) != true ->
        {:error, :write_not_allowed}

      mode == "write_plan" and synthetic_present?(opts) ->
        {:error, :write_plan_requires_git_inventory}

      true ->
        do_run(opts, allow_synthetic: true)
    end
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  defp synthetic_present?(opts) do
    Enum.any?(@synthetic_opt_keys -- [:enforce_production_policy], &Keyword.has_key?(opts, &1))
  end

  defp do_run(opts, allow_synthetic: allow_synthetic) do
    mode = Keyword.get(opts, :mode, "report")
    json? = Keyword.get(opts, :json, false) == true
    output = if json?, do: "json", else: "human"
    phase = Keyword.get(opts, :phase)

    with {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, paths} <- resolve_paths(root, opts) do
      case mode do
        "write_plan" ->
          write_plan(root, paths, opts, allow_synthetic, output)

        mode when mode in ["check", "report"] ->
          check_or_report(root, paths, opts, allow_synthetic, mode, phase, output)

        _ ->
          {:error, :invalid_opts}
      end
    end
  end

  defp write_plan(root, paths, opts, allow_synthetic, output) do
    cond do
      Keyword.get(opts, :allow_write, false) != true ->
        {:error, :write_not_allowed}

      allow_synthetic and synthetic_present?(opts) ->
        {:error, :write_plan_requires_git_inventory}

      true ->
        generate_and_write(root, paths, opts, output)
    end
  end

  defp generate_and_write(root, paths, opts, output) do
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    with {:ok, inventory} <-
           GitInventory.load_selected_blobs(root, Core.planned_selected_apps(), git_opts),
         {:ok, files} <- Core.admit_blobs(inventory.files, inventory.object_format),
         {:ok, plan} <-
           Core.project(files, object_format: inventory.object_format),
         :ok <- Core.enforce_production_policy(plan),
         {:ok, plan_bytes} <- Encode.encode_plan(plan),
         {:ok, evidence} <- prepare_empty_evidence(paths.evidence, plan["entries_digest"]),
         :ok <- File.mkdir_p(Path.dirname(paths.plan)),
         :ok <- File.write(paths.plan, plan_bytes),
         :ok <- write_evidence_map(paths.evidence, evidence) do
      compare = %{
        "status" => "ok",
        "failures" => [],
        "failure_count" => 0,
        "truncated" => false
      }

      {:ok,
       Core.show(plan, compare, %{"mode" => "write_plan", "phase" => "", "output" => output})}
    end
  end

  defp prepare_empty_evidence(path, digest) do
    existing =
      cond do
        File.regular?(path) ->
          case File.read(path) do
            {:ok, bytes} -> bytes
            {:error, reason} -> {:error, {:evidence_read, reason}}
          end

        true ->
          nil
      end

    case existing do
      {:error, _} = err ->
        err

      bytes_or_nil ->
        Evidence.bind_empty(bytes_or_nil, digest)
    end
  end

  defp write_evidence_map(path, evidence) do
    with {:ok, bytes} <- Encode.encode_evidence(evidence),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      :ok
    else
      {:error, reason} -> {:error, {:evidence_write, reason}}
    end
  end

  defp check_or_report(root, paths, opts, allow_synthetic, mode, phase, output) do
    with {:ok, phase} <- require_phase(phase),
         {:ok, plan} <- load_plan(root, paths.plan, opts, allow_synthetic),
         {:ok, evidence} <- load_evidence(root, paths.evidence, plan, opts, allow_synthetic),
         :ok <- maybe_enforce(plan, opts, allow_synthetic),
         {:ok, compare} <- compare_phase(root, plan, evidence, phase, opts, allow_synthetic) do
      {:ok, Core.show(plan, compare, %{"mode" => mode, "phase" => phase, "output" => output})}
    end
  end

  defp require_phase(phase) when phase in ["planned", "materialized"], do: {:ok, phase}
  defp require_phase(_), do: {:error, {:phase, :required}}

  defp maybe_enforce(plan, _opts, false), do: Core.enforce_production_policy(plan)

  defp maybe_enforce(plan, opts, true) do
    if Keyword.get(opts, :enforce_production_policy, false) do
      Core.enforce_production_policy(plan)
    else
      :ok
    end
  end

  defp compare_phase(root, plan, _evidence, "planned", opts, allow_synthetic) do
    with {:ok, files, object_format, extra_targets, present_paths, presence} <-
           planned_inventory(root, opts, allow_synthetic),
         {:ok, files} <- Core.admit_blobs(files, object_format),
         {:ok, current} <- Core.project(files, object_format: object_format) do
      context = %{
        source_presence: presence,
        extra_target_paths: extra_targets,
        present_paths: present_paths
      }

      with {:ok, compare} <- Core.compare_planned(current, plan, context) do
        byte_compare_plans(compare, current, plan)
      end
    end
  end

  defp compare_phase(root, plan, evidence, "materialized", opts, allow_synthetic) do
    with {:ok, presence} <- source_presence(root, opts, allow_synthetic),
         {:ok, dest_files} <- materialized_dest_files(root, plan, evidence, opts, allow_synthetic),
         {:ok, target_files} <-
           materialized_targets(root, plan["object_format"], opts, allow_synthetic) do
      Core.compare_materialized(plan, evidence, %{
        dest_files: dest_files,
        target_files: target_files,
        source_presence: presence
      })
    end
  end

  defp byte_compare_plans(%{"status" => "ok"} = compare, current, admitted) do
    with {:ok, current_bytes} <- Encode.encode_plan(current),
         {:ok, admitted_bytes} <- Encode.encode_plan(admitted) do
      if current_bytes == admitted_bytes do
        {:ok, compare}
      else
        {:ok,
         %{
           compare
           | "status" => "failed",
             "failures" => [
               %{"reason" => "plan_byte_drift", "detail" => "encoded plan mismatch"}
             ],
             "failure_count" => 1
         }}
      end
    end
  end

  defp byte_compare_plans(compare, _, _), do: {:ok, compare}

  defp planned_inventory(_root, opts, true) do
    case Keyword.get(opts, :inventory) do
      files when is_list(files) ->
        format = infer_format(files)
        extra = Keyword.get(opts, :extra_target_files, [])
        present = Keyword.get(opts, :present_paths, Enum.map(files, &file_path/1))
        presence = Keyword.get(opts, :source_presence) || presence_from_files(files)
        {:ok, files, format, extra, present, presence}

      nil ->
        {:error, :invalid_files}

      _ ->
        {:error, :invalid_files}
    end
  end

  defp planned_inventory(root, opts, false) do
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    with {:ok, inventory} <-
           GitInventory.load_selected_blobs(root, Core.planned_selected_apps(), git_opts),
         {:ok, runtime} <-
           GitInventory.load_selected_blobs(root, ["arbor_kernel_runtime"], git_opts) do
      extra = Enum.map(runtime.files, & &1.path)
      present = Enum.map(inventory.files ++ runtime.files, & &1.path)
      presence = presence_from_files(inventory.files)
      {:ok, inventory.files, inventory.object_format, extra, present, presence}
    end
  end

  defp source_presence(_root, opts, true) do
    {:ok, Keyword.get(opts, :source_presence, %{})}
  end

  defp source_presence(root, opts, false) do
    git_opts = Keyword.take(opts, [:run_git])

    case GitInventory.list_stage_prefixes(root, Core.source_prefixes(), git_opts) do
      {:ok, entries} ->
        {:ok, presence_from_paths(Enum.map(entries, & &1.path))}

      {:error, _} = err ->
        err
    end
  end

  defp materialized_dest_files(_root, _plan, _evidence, opts, true) do
    case Keyword.get(opts, :dest_files) do
      map when is_map(map) -> {:ok, map}
      nil -> {:ok, %{}}
      _ -> {:error, :invalid_files}
    end
  end

  defp materialized_dest_files(root, plan, evidence, opts, false) do
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])
    paths = dest_query_paths(plan, evidence)

    with {:ok, %{present: files, absent: _}} <-
           GitInventory.query_indexed_blobs_batched(root, paths, git_opts),
         {:ok, admitted} <- Core.admit_blobs(files, plan["object_format"]) do
      {:ok, Map.new(admitted, &{&1.path, &1})}
    end
  end

  defp materialized_targets(_root, format, opts, true) do
    files = Keyword.get(opts, :target_files, [])
    Core.admit_blobs(files, format || "sha1")
  end

  defp materialized_targets(root, format, opts, false) do
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    with {:ok, inventory} <-
           GitInventory.load_selected_blobs(root, Core.materialized_target_apps(), git_opts) do
      Core.admit_blobs(inventory.files, format || inventory.object_format)
    end
  end

  defp dest_query_paths(plan, evidence) do
    exact =
      (plan["entries"] || [])
      |> Enum.filter(&(&1["disposition"] == "exact_move"))
      |> Enum.map(& &1["destination_path"])

    retain =
      (plan["retained_targets"] || [])
      |> Enum.filter(&(&1["disposition"] == "retain"))
      |> Enum.map(& &1["path"])

    evidence_dests = Enum.map(evidence["entries"] || [], & &1["destination_path"])

    (exact ++ retain ++ evidence_dests)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp load_plan(root, abs_path, opts, true) do
    case Keyword.get(opts, :plan_map) do
      map when is_map(map) -> Core.admit_plan(map)
      nil -> load_plan_from_index(root, abs_path, opts)
      _ -> {:error, :plan_not_immutable}
    end
  end

  defp load_plan(root, abs_path, opts, false) do
    load_plan_from_index(root, abs_path, opts)
  end

  defp load_plan_from_index(root, abs_path, opts) do
    rel = relative_from_root(root, abs_path)
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    case GitInventory.query_indexed_blobs_batched(root, [rel], git_opts) do
      {:ok, %{present: [file], absent: []}} ->
        admit_and_decode_plan(file)

      {:ok, %{absent: [_]}} ->
        {:error, :manifest_not_indexed}

      {:error, _} = err ->
        err

      _ ->
        {:error, :manifest_not_indexed}
    end
  end

  defp load_evidence(root, abs_path, plan, opts, true) do
    case Keyword.get(opts, :evidence_map) do
      map when is_map(map) -> Evidence.admit(map, plan)
      nil -> load_evidence_from_index(root, abs_path, plan, opts)
      _ -> {:error, :transform_evidence_unbound}
    end
  end

  defp load_evidence(root, abs_path, plan, opts, false) do
    load_evidence_from_index(root, abs_path, plan, opts)
  end

  defp load_evidence_from_index(root, abs_path, plan, opts) do
    rel = relative_from_root(root, abs_path)
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    case GitInventory.query_indexed_blobs_batched(root, [rel], git_opts) do
      {:ok, %{present: [file], absent: []}} ->
        admit_and_decode_evidence(file, plan)

      {:ok, %{absent: [_]}} ->
        {:error, :manifest_not_indexed}

      {:error, _} = err ->
        err

      _ ->
        {:error, :manifest_not_indexed}
    end
  end

  defp admit_and_decode_plan(file) do
    format = blob_format(file)

    with {:ok, [admitted]} <- Core.admit_blobs([file], format) do
      decode_plan(admitted.bytes)
    end
  end

  defp admit_and_decode_evidence(file, plan) do
    format = blob_format(file)

    with {:ok, [admitted]} <- Core.admit_blobs([file], format) do
      decode_evidence(admitted.bytes, plan)
    end
  end

  defp blob_format(file) do
    oid = file[:blob_oid] || file["blob_oid"] || ""
    if byte_size(oid) == 64, do: "sha256", else: "sha1"
  end

  defp decode_plan(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> Core.admit_plan(map)
      _ -> {:error, :plan_not_immutable}
    end
  end

  defp decode_evidence(bytes, plan) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> Evidence.admit(map, plan)
      _ -> {:error, :transform_evidence_unbound}
    end
  end

  defp resolve_root(path), do: PackagingRoot.resolve(path)

  @spec discover_root(String.t()) :: {:ok, String.t()} | {:error, term()}
  def discover_root(start), do: PackagingRoot.discover(start)

  defp resolve_paths(root, opts) do
    with {:ok, plan} <- resolve_within(root, Keyword.get(opts, :plan), @default_plan_rel),
         {:ok, evidence} <-
           resolve_within(root, Keyword.get(opts, :transform_evidence), @default_evidence_rel) do
      {:ok, %{plan: plan, evidence: evidence}}
    end
  end

  defp resolve_within(root, nil, default_rel), do: SafePath.safe_join(root, default_rel)

  defp resolve_within(root, path, _default) when is_binary(path) do
    if String.starts_with?(path, "/") do
      if SafePath.within?(path, root), do: {:ok, Path.expand(path)}, else: {:error, :path_escape}
    else
      SafePath.safe_join(root, path)
    end
  end

  defp relative_from_root(root, abs) do
    root = Path.expand(root)
    abs = Path.expand(abs)

    case Path.relative_to(abs, root) do
      ^abs -> abs
      rel -> rel
    end
  end

  defp presence_from_files(files) do
    presence_from_paths(Enum.map(files, &file_path/1))
  end

  defp presence_from_paths(paths) do
    Map.new(Core.source_apps(), fn app ->
      {app,
       Enum.any?(paths, fn path ->
         match?(["apps", ^app | _], Path.split(path))
       end)}
    end)
  end

  defp file_path(file) when is_map(file) do
    file[:path] || file["path"] || ""
  end

  defp infer_format(files) do
    case Enum.find_value(files, fn file -> file[:blob_oid] || file["blob_oid"] || file["oid"] end) do
      oid when is_binary(oid) and byte_size(oid) == 64 -> "sha256"
      _ -> "sha1"
    end
  end
end
