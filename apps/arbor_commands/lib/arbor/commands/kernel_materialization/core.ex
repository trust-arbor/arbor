defmodule Arbor.Commands.KernelMaterialization.Core do
  @moduledoc """
  Pure K4A projector and comparer.

  Generic `project/2` does not assert the production 640/607/33/4 inventory.
  `enforce_production_policy/1` is the separate production gate.
  """

  alias Arbor.Commands.KernelMaterialization.Encode

  @plan_schema "arbor.packaging.kernel_materialization.plan.v1"
  @report_schema "arbor.packaging.kernel_materialization.report.v1"
  @policy_version "k4a.v1"
  @base_commit "207d47486485e554d4e725d9cc898b56a9f327eb"
  @max_failures 50
  @accepted_modes MapSet.new(["100644", "100755"])
  @accepted_formats MapSet.new(["sha1", "sha256"])
  @source_apps [
    "arbor_common",
    "arbor_contracts",
    "arbor_monitor",
    "arbor_signals"
  ]
  @active_source_apps ["arbor_common", "arbor_monitor", "arbor_signals"]
  @default_source_owners %{
    "arbor_contracts" => "arbor_kernel",
    "arbor_common" => "arbor_kernel_runtime",
    "arbor_signals" => "arbor_kernel_runtime",
    "arbor_monitor" => "arbor_kernel_runtime"
  }
  @default_split %{
    "passive_owner" => "arbor_kernel",
    "active_owner" => "arbor_kernel_runtime",
    "source_map" => @default_source_owners
  }
  @collision_destinations MapSet.new([
                            "apps/arbor_kernel/mix.exs",
                            "apps/arbor_kernel/test/test_helper.exs",
                            "apps/arbor_kernel_runtime/mix.exs",
                            "apps/arbor_kernel_runtime/test/test_helper.exs"
                          ])
  @semantic_transform_source_paths MapSet.new([
                                     "apps/arbor_common/README.md",
                                     "apps/arbor_common/lib/arbor/common/skill_library.ex",
                                     "apps/arbor_common/lib/arbor/eval/suites/library_construction.ex",
                                     "apps/arbor_common/lib/mix/tasks/arbor/hands/spawn.ex",
                                     "apps/arbor_common/test/arbor/common/agent_telemetry/source_guard_test.exs",
                                     "apps/arbor_common/test/arbor/common/k1c_source_guard_test.exs",
                                     "apps/arbor_common/test/arbor/common/runtime_wiring_source_shape_test.exs",
                                     "apps/arbor_common/test/mix/tasks/arbor/readiness_test.exs",
                                     "apps/arbor_common/test/mix/tasks/arbor/start_daemon_launch_test.exs",
                                     "apps/arbor_contracts/README.md",
                                     "apps/arbor_contracts/lib/arbor/contracts_census.ex",
                                     "apps/arbor_contracts/test/arbor/contracts/admission_test.exs",
                                     "apps/arbor_contracts/test/arbor/contracts/coding/plan_test.exs",
                                     "apps/arbor_contracts/test/arbor/contracts/coding/source_inventory_test.exs",
                                     "apps/arbor_contracts/test/arbor/contracts/coding/work_packet_test.exs",
                                     "apps/arbor_contracts/test/arbor/contracts/dependency_hierarchy_test.exs",
                                     "apps/arbor_contracts/test/mix_project_paths_test.exs",
                                     "apps/arbor_monitor/test/arbor/monitor/k1d_source_guard_test.exs",
                                     "apps/arbor_monitor/test/arbor/monitor/runtime_wiring_source_shape_test.exs",
                                     "apps/arbor_signals/test/arbor/signals/cluster_integration_test.exs",
                                     "apps/arbor_signals/test/arbor/signals/k1e_source_guard_test.exs",
                                     "apps/arbor_signals/test/arbor/signals/k1f_source_guard_test.exs",
                                     "apps/arbor_signals/test/arbor/signals/runtime_wiring_source_shape_test.exs",
                                     "apps/arbor_signals/test/arbor/signals/subsystem_cluster_test.exs",
                                     "apps/arbor_signals/test/support/signal_test_case.ex"
                                   ])
  @kernel_identity [
    {"apps/arbor_kernel/mix.exs", "transform_input"},
    {"apps/arbor_kernel/test/test_helper.exs", "transform_input"},
    {"apps/arbor_kernel/lib/arbor/kernel.ex", "retain"}
  ]
  @forbidden_plan_keys MapSet.new([
                         "phase",
                         "status",
                         "mode",
                         "tree_oid",
                         "planned_tree_oid",
                         "comparison",
                         "errors",
                         "output",
                         "identity"
                       ])
  @allowed_plan_keys MapSet.new([
                       "schema",
                       "version",
                       "policy_version",
                       "base_commit",
                       "object_format",
                       "split",
                       "counts",
                       "entries",
                       "retained_targets",
                       "collision_groups",
                       "entries_digest"
                     ])
  @allowed_split_keys MapSet.new(["passive_owner", "active_owner", "source_map"])
  @allowed_count_keys MapSet.new([
                        "source_entries",
                        "exact_moves",
                        "transform_inputs",
                        "collision_destinations",
                        "retained_targets"
                      ])
  @allowed_entry_keys MapSet.new([
                        "source_path",
                        "source_mode",
                        "source_oid",
                        "destination_path",
                        "disposition",
                        "target_precondition",
                        "collision_group"
                      ])
  @allowed_retained_keys MapSet.new(["path", "mode", "oid", "disposition"])
  @allowed_group_keys MapSet.new(["destination_path", "source_paths", "preexisting_paths"])

  @spec production_policy() :: map()
  def production_policy do
    %{
      "source_entries" => 640,
      "exact_moves" => 607,
      "transform_inputs" => 33,
      "collision_destinations" => 4,
      "collision_destination_paths" => MapSet.to_list(@collision_destinations) |> Enum.sort(),
      "semantic_transform_source_paths" =>
        MapSet.to_list(@semantic_transform_source_paths) |> Enum.sort(),
      "kernel_identity" =>
        Enum.map(@kernel_identity, fn {path, disposition} ->
          %{"path" => path, "disposition" => disposition}
        end),
      "split" => @default_split,
      "base_commit" => @base_commit,
      "policy_version" => @policy_version
    }
  end

  @spec default_source_owners() :: map()
  def default_source_owners, do: @default_source_owners

  @spec collision_destinations() :: MapSet.t(String.t())
  def collision_destinations, do: @collision_destinations

  @spec semantic_transform_source_paths() :: MapSet.t(String.t())
  def semantic_transform_source_paths, do: @semantic_transform_source_paths

  @spec transform_destinations(map()) :: MapSet.t(String.t())
  def transform_destinations(plan) when is_map(plan) do
    entry_destinations =
      (plan["entries"] || [])
      |> Enum.filter(&(&1["disposition"] == "transform_input"))
      |> Enum.map(& &1["destination_path"])

    retained_destinations =
      (plan["retained_targets"] || [])
      |> Enum.filter(&(&1["disposition"] == "transform_input"))
      |> Enum.map(& &1["path"])

    collision_destinations =
      (plan["collision_groups"] || [])
      |> Enum.map(& &1["destination_path"])

    MapSet.new(entry_destinations ++ retained_destinations ++ collision_destinations)
  end

  def transform_destinations(_plan), do: MapSet.new()

  @spec source_apps() :: [String.t()]
  def source_apps, do: @source_apps

  @spec planned_selected_apps() :: [String.t()]
  def planned_selected_apps, do: source_apps() ++ ["arbor_kernel"]

  @spec materialized_target_apps() :: [String.t()]
  def materialized_target_apps, do: ["arbor_kernel", "arbor_kernel_runtime"]

  @spec source_prefixes() :: [String.t()]
  def source_prefixes do
    Enum.map(source_apps(), &"apps/#{&1}")
  end

  @spec admit_blobs([map()], String.t()) :: {:ok, [map()]} | {:error, term()}
  def admit_blobs(files, object_format)
      when is_list(files) and is_binary(object_format) do
    cond do
      object_format not in @accepted_formats ->
        {:error, :mixed_object_format}

      true ->
        Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
          case admit_blob(file, object_format) do
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

  def admit_blobs(_, _), do: {:error, :invalid_files}

  @spec project([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def project(files, opts \\ [])

  def project(files, opts) when is_list(files) and is_list(opts) do
    owners = Keyword.get(opts, :source_owners, @default_source_owners)
    collisions = Keyword.get(opts, :collision_destinations, @collision_destinations)

    semantic_transforms =
      Keyword.get(opts, :semantic_transform_source_paths, @semantic_transform_source_paths)

    object_format = Keyword.get(opts, :object_format) || infer_format(files)
    base_commit = Keyword.get(opts, :base_commit, @base_commit)

    with :ok <- validate_owners(owners),
         {:ok, split} <- split_from_owners(owners),
         {:ok, sources, preexisting} <- partition_files(files),
         {:ok, mapped} <- map_destinations(sources, owners),
         {:ok, entries, groups} <-
           classify_entries(mapped, preexisting, collisions, semantic_transforms) do
      retained = classify_retained(preexisting, collisions)
      entries = Enum.sort_by(entries, & &1["source_path"])
      retained = Enum.sort_by(retained, & &1["path"])
      groups = Enum.sort_by(groups, & &1["destination_path"])

      plan = %{
        "schema" => @plan_schema,
        "version" => 1,
        "policy_version" => @policy_version,
        "base_commit" => base_commit,
        "object_format" => object_format,
        "split" => split,
        "counts" => %{
          "source_entries" => length(entries),
          "exact_moves" => Enum.count(entries, &(&1["disposition"] == "exact_move")),
          "transform_inputs" => Enum.count(entries, &(&1["disposition"] == "transform_input")),
          "collision_destinations" => length(groups),
          "retained_targets" => length(retained)
        },
        "entries" => Enum.map(entries, &Encode.order_entry/1),
        "retained_targets" => Enum.map(retained, &Encode.order_retained/1),
        "collision_groups" => Enum.map(groups, &Encode.order_group/1)
      }

      {:ok, Map.put(plan, "entries_digest", Encode.plan_digest(plan))}
    end
  end

  def project(_, _), do: {:error, :invalid_files}

  @spec enforce_production_policy(map()) :: :ok | {:error, term()}
  def enforce_production_policy(plan) when is_map(plan) do
    policy = production_policy()
    entries = plan["entries"] || []
    groups = plan["collision_groups"] || []
    retained = plan["retained_targets"] || []
    derived = derived_counts(entries, retained, groups)
    dests = groups |> Enum.map(& &1["destination_path"]) |> Enum.sort()
    by_path = Map.new(retained, &{&1["path"], &1["disposition"]})

    semantic_transform_sources =
      entries
      |> Enum.filter(&(&1["disposition"] == "transform_input" and &1["collision_group"] == ""))
      |> Enum.map(& &1["source_path"])
      |> Enum.sort()

    identity_ok? =
      Enum.all?(@kernel_identity, fn {path, disposition} ->
        Map.get(by_path, path) == disposition
      end)

    cond do
      derived["source_entries"] != policy["source_entries"] or
        derived["exact_moves"] != policy["exact_moves"] or
        derived["transform_inputs"] != policy["transform_inputs"] or
        derived["collision_destinations"] != policy["collision_destinations"] or
        dests != policy["collision_destination_paths"] or
        semantic_transform_sources != policy["semantic_transform_source_paths"] or
        plan["split"] != policy["split"] or
        plan["base_commit"] != policy["base_commit"] or
          plan["policy_version"] != policy["policy_version"] ->
        {:error, :accepted_count_mismatch}

      not identity_ok? ->
        {:error, :kernel_identity_unclassified}

      true ->
        :ok
    end
  end

  def enforce_production_policy(_), do: {:error, :accepted_count_mismatch}

  @spec admit_plan(map()) :: {:ok, map()} | {:error, term()}
  def admit_plan(raw) when is_map(raw) do
    keys = MapSet.new(Map.keys(raw))

    cond do
      not MapSet.subset?(keys, @allowed_plan_keys) ->
        {:error, :plan_not_immutable}

      Enum.any?(@forbidden_plan_keys, &Map.has_key?(raw, &1)) ->
        {:error, :plan_not_immutable}

      raw["schema"] != @plan_schema ->
        {:error, :plan_not_immutable}

      raw["version"] != 1 ->
        {:error, :plan_not_immutable}

      raw["policy_version"] != @policy_version ->
        {:error, :plan_not_immutable}

      not is_binary(raw["base_commit"]) or not is_binary(raw["object_format"]) ->
        {:error, :plan_not_immutable}

      raw["object_format"] not in @accepted_formats ->
        {:error, :mixed_object_format}

      not is_map(raw["split"]) or not is_map(raw["counts"]) ->
        {:error, :plan_not_immutable}

      not MapSet.equal?(MapSet.new(Map.keys(raw["split"])), @allowed_split_keys) ->
        {:error, :plan_not_immutable}

      not MapSet.equal?(MapSet.new(Map.keys(raw["counts"])), @allowed_count_keys) ->
        {:error, :plan_not_immutable}

      not is_list(raw["entries"]) or not is_list(raw["retained_targets"]) or
          not is_list(raw["collision_groups"]) ->
        {:error, :plan_not_immutable}

      true ->
        with {:ok, split} <- admit_split(raw["split"]),
             {:ok, entries} <- admit_plan_entries(raw["entries"], raw["object_format"]),
             {:ok, retained} <- admit_retained(raw["retained_targets"], raw["object_format"]),
             {:ok, groups} <- admit_groups(raw["collision_groups"]),
             :ok <- admit_coherence(entries, retained, groups, split) do
          counts = derived_counts(entries, retained, groups)

          if raw["counts"] != counts do
            {:error, :accepted_count_mismatch}
          else
            plan = %{
              "schema" => @plan_schema,
              "version" => 1,
              "policy_version" => raw["policy_version"],
              "base_commit" => raw["base_commit"],
              "object_format" => raw["object_format"],
              "split" => split,
              "counts" => counts,
              "entries" => entries,
              "retained_targets" => retained,
              "collision_groups" => groups
            }

            digest = Encode.plan_digest(plan)

            if raw["entries_digest"] == digest do
              {:ok, Map.put(plan, "entries_digest", digest)}
            else
              {:error, :plan_digest_mismatch}
            end
          end
        end
    end
  end

  def admit_plan(_), do: {:error, :plan_not_immutable}

  @spec compare_planned(map(), map(), map()) :: {:ok, map()}
  def compare_planned(current, admitted, context)
      when is_map(current) and is_map(admitted) and is_map(context) do
    failures =
      []
      |> compare_entry_sets(current["entries"] || [], admitted["entries"] || [])
      |> compare_retained_sets(
        current["retained_targets"] || [],
        admitted["retained_targets"] || []
      )
      |> compare_group_sets(
        current["collision_groups"] || [],
        admitted["collision_groups"] || []
      )
      |> Kernel.++(planned_phase_failures(admitted, context))

    finish_failures(failures)
  end

  def compare_planned(_, _, _), do: {:error, :invalid_compare}

  @spec compare_materialized(map(), map(), map()) :: {:ok, map()}
  def compare_materialized(plan, evidence, context)
      when is_map(plan) and is_map(evidence) and is_map(context) do
    dest_files = context[:dest_files] || context["dest_files"] || %{}
    target_files = context[:target_files] || context["target_files"] || []
    source_presence = context[:source_presence] || context["source_presence"] || %{}

    failures =
      []
      |> materialized_source_failures(source_presence)
      |> materialized_exact_failures(plan, dest_files)
      |> materialized_retain_failures(plan, dest_files)
      |> materialized_transform_failures(plan, evidence, dest_files)
      |> materialized_generated_failures(evidence, dest_files)
      |> materialized_coverage_failures(plan, evidence, target_files)

    finish_failures(failures)
  end

  def compare_materialized(_, _, _), do: {:error, :invalid_compare}

  @spec show(map(), map(), map()) :: map()
  def show(plan, compare, extras) when is_map(plan) and is_map(compare) do
    extras = extras || %{}
    status = if compare["status"] == "failed", do: "failed", else: "ok"

    %{
      "schema" => @report_schema,
      "mode" => extras["mode"] || "report",
      "phase" => extras["phase"] || "",
      "status" => status,
      "output" => extras["output"] || "human",
      "plan_digest" => plan["entries_digest"] || "",
      "object_format" => plan["object_format"] || "",
      "counts" => plan["counts"] || %{},
      "comparison" => compare,
      "errors" => extras["errors"] || []
    }
  end

  def show(_, _, _), do: %{}

  @spec source_app(String.t()) :: String.t() | nil
  def source_app(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app | _] -> app
      _ -> nil
    end
  end

  def source_app(_), do: nil

  defp admit_blob(file, object_format) when is_map(file) do
    path = field(file, :path)
    oid = field(file, :blob_oid) || field(file, :oid)
    bytes = field(file, :bytes)
    mode = field(file, :mode)
    byte_size = field(file, :byte_size)

    cond do
      not is_binary(path) or not is_binary(oid) or not is_binary(bytes) or not is_binary(mode) ->
        {:error, :invalid_files}

      not valid_repo_path?(path) ->
        {:error, {:invalid_path, path}}

      not Encode.blob_oid_valid?(oid) ->
        {:error, {:invalid_oid, oid}}

      not Encode.oid_matches_format?(oid, object_format) ->
        {:error, :mixed_object_format}

      mode not in @accepted_modes ->
        {:error, {:unsupported_selected_mode, mode, path}}

      is_integer(byte_size) and byte_size != byte_size(bytes) ->
        {:error, {:invalid_byte_size, path}}

      Encode.git_blob_oid(bytes, object_format) != oid ->
        {:error, {:oid_content_mismatch, path}}

      true ->
        {:ok,
         %{
           path: path,
           mode: mode,
           blob_oid: oid,
           byte_size: byte_size(bytes),
           bytes: bytes
         }}
    end
  end

  defp admit_blob(_, _), do: {:error, :invalid_files}

  defp infer_format(files) do
    case Enum.find_value(files, fn file -> field(file, :blob_oid) || field(file, :oid) end) do
      oid when is_binary(oid) and byte_size(oid) == 64 -> "sha256"
      _ -> "sha1"
    end
  end

  defp validate_owners(owners) when is_map(owners) do
    expected = MapSet.new(@source_apps)

    if MapSet.equal?(MapSet.new(Map.keys(owners)), expected) and
         Enum.all?(owners, fn {key, value} ->
           is_binary(key) and valid_app_name?(value)
         end) do
      :ok
    else
      {:error, :invalid_files}
    end
  end

  defp validate_owners(_), do: {:error, :invalid_files}

  defp split_from_owners(owners) do
    passive = owners["arbor_contracts"]
    active = Enum.map(@active_source_apps, &owners[&1]) |> Enum.uniq()

    case active do
      [active_owner] when active_owner != passive ->
        {:ok,
         %{
           "passive_owner" => passive,
           "active_owner" => active_owner,
           "source_map" => owners
         }}

      _ ->
        {:error, :invalid_files}
    end
  end

  defp admit_split(split) when is_map(split) do
    source_map = split["source_map"]

    with true <- MapSet.equal?(MapSet.new(Map.keys(split)), @allowed_split_keys),
         :ok <- validate_owners(source_map),
         {:ok, expected} <- split_from_owners(source_map),
         true <- split == expected do
      {:ok, expected}
    else
      _ -> {:error, :plan_not_immutable}
    end
  end

  defp admit_split(_), do: {:error, :plan_not_immutable}

  defp partition_files(files) do
    Enum.reduce_while(files, {:ok, [], []}, fn file, {:ok, sources, preexisting} ->
      path = field(file, :path)

      case Path.split(path || "") do
        ["apps", "arbor_integrations" | _] ->
          {:cont, {:ok, sources, preexisting}}

        ["apps", app | _] when app in @source_apps ->
          {:cont, {:ok, [file | sources], preexisting}}

        ["apps", "arbor_kernel" | _] ->
          {:cont, {:ok, sources, [file | preexisting]}}

        _ ->
          {:cont, {:ok, sources, preexisting}}
      end
    end)
    |> case do
      {:ok, sources, preexisting} ->
        {:ok, Enum.reverse(sources), Enum.reverse(preexisting)}

      err ->
        err
    end
  end

  defp map_destinations(sources, owners) do
    Enum.reduce_while(sources, {:ok, []}, fn file, {:ok, acc} ->
      path = field(file, :path)

      case rewrite_destination(path, owners) do
        {:ok, dest} ->
          {:cont, {:ok, [%{file: file, source_path: path, dest: dest} | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp rewrite_destination(path, owners) when is_binary(path) do
    case Path.split(path) do
      ["apps", src | rest] when rest != [] ->
        case Map.fetch(owners, src) do
          {:ok, owner} ->
            dest = Enum.join(["apps", owner | rest], "/")

            if valid_repo_path?(dest) do
              {:ok, dest}
            else
              {:error, {:invalid_path, dest}}
            end

          :error ->
            {:error, {:invalid_path, path}}
        end

      _ ->
        {:error, {:invalid_path, path}}
    end
  end

  defp rewrite_destination(path, _), do: {:error, {:invalid_path, path}}

  defp classify_entries(mapped, preexisting, collisions, semantic_transforms) do
    preexisting_paths =
      MapSet.new(preexisting, fn file -> field(file, :path) end)

    grouped = Enum.group_by(mapped, & &1.dest)

    Enum.reduce_while(grouped, {:ok, [], []}, fn {dest, group}, {:ok, entries, groups} ->
      collision? = length(group) > 1 or MapSet.member?(preexisting_paths, dest)

      cond do
        collision? and MapSet.member?(collisions, dest) ->
          classified =
            Enum.map(group, fn item ->
              to_entry(item, "transform_input", dest, precondition(dest, preexisting_paths))
            end)

          group_rec = %{
            "destination_path" => dest,
            "source_paths" => Enum.sort(Enum.map(group, & &1.source_path)),
            "preexisting_paths" =>
              if(MapSet.member?(preexisting_paths, dest), do: [dest], else: [])
          }

          {:cont, {:ok, classified ++ entries, [group_rec | groups]}}

        collision? ->
          {:halt, {:error, {:unclassified_collision, dest}}}

        Enum.any?(group, &MapSet.member?(semantic_transforms, &1.source_path)) ->
          classified =
            Enum.map(group, fn item ->
              to_entry(item, "transform_input", "", "expected_absent")
            end)

          {:cont, {:ok, classified ++ entries, groups}}

        true ->
          classified =
            Enum.map(group, fn item ->
              to_entry(item, "exact_move", "", "expected_absent")
            end)

          {:cont, {:ok, classified ++ entries, groups}}
      end
    end)
    |> case do
      {:ok, entries, groups} -> {:ok, entries, groups}
      err -> err
    end
  end

  defp precondition(dest, preexisting_paths) do
    if MapSet.member?(preexisting_paths, dest), do: "preexisting", else: "expected_absent"
  end

  defp to_entry(item, disposition, collision_group, precondition) do
    file = item.file

    Encode.order_entry(%{
      "source_path" => item.source_path,
      "source_mode" => field(file, :mode),
      "source_oid" => field(file, :blob_oid) || field(file, :oid),
      "destination_path" => item.dest,
      "disposition" => disposition,
      "target_precondition" => precondition,
      "collision_group" => collision_group
    })
  end

  defp classify_retained(preexisting, collisions) do
    Enum.map(preexisting, fn file ->
      path = field(file, :path)
      disposition = if MapSet.member?(collisions, path), do: "transform_input", else: "retain"

      Encode.order_retained(%{
        "path" => path,
        "mode" => field(file, :mode),
        "oid" => field(file, :blob_oid) || field(file, :oid),
        "disposition" => disposition
      })
    end)
  end

  defp derived_counts(entries, retained, groups) do
    %{
      "source_entries" => length(entries),
      "exact_moves" => Enum.count(entries, &(&1["disposition"] == "exact_move")),
      "transform_inputs" => Enum.count(entries, &(&1["disposition"] == "transform_input")),
      "collision_destinations" => length(groups),
      "retained_targets" => length(retained)
    }
  end

  defp admit_plan_entries(list, format) when is_list(list) do
    if Enum.all?(list, &is_map/1) do
      paths = Enum.map(list, & &1["source_path"])

      if length(paths) != length(Enum.uniq(paths)) do
        {:error, :duplicate_source}
      else
        admit_list(list, &admit_plan_entry(&1, format))
      end
    else
      {:error, :plan_not_immutable}
    end
  end

  defp admit_plan_entries(_, _), do: {:error, :plan_not_immutable}

  defp admit_plan_entry(entry, format) when is_map(entry) do
    path = entry["source_path"]
    dest = entry["destination_path"]
    oid = entry["source_oid"]
    mode = entry["source_mode"]
    disposition = entry["disposition"]
    precondition = entry["target_precondition"]
    group = entry["collision_group"]

    cond do
      not exact_keys?(entry, @allowed_entry_keys) ->
        {:error, :plan_not_immutable}

      not valid_repo_path?(path) or not valid_repo_path?(dest) ->
        {:error, {:invalid_path, path || dest}}

      not Encode.blob_oid_valid?(oid) or not Encode.oid_matches_format?(oid, format) ->
        {:error, {:invalid_oid, oid}}

      mode not in @accepted_modes ->
        {:error, {:unsupported_selected_mode, mode, path}}

      disposition not in ["exact_move", "transform_input"] ->
        {:error, :plan_not_immutable}

      precondition not in ["expected_absent", "preexisting"] ->
        {:error, :plan_not_immutable}

      not is_binary(group) ->
        {:error, :plan_not_immutable}

      true ->
        {:ok, Encode.order_entry(entry)}
    end
  end

  defp admit_plan_entry(_, _), do: {:error, :plan_not_immutable}

  defp admit_retained(list, format) when is_list(list) do
    if Enum.all?(list, &is_map/1) do
      paths = Enum.map(list, & &1["path"])

      if length(paths) != length(Enum.uniq(paths)) do
        {:error, :duplicate_retained}
      else
        do_admit_retained(list, format)
      end
    else
      {:error, :plan_not_immutable}
    end
  end

  defp admit_retained(_, _), do: {:error, :plan_not_immutable}

  defp do_admit_retained(list, format) do
    admit_list(list, fn entry ->
      path = entry["path"]
      oid = entry["oid"]
      mode = entry["mode"]

      cond do
        not exact_keys?(entry, @allowed_retained_keys) ->
          {:error, :plan_not_immutable}

        not valid_repo_path?(path) ->
          {:error, {:invalid_path, path}}

        not Encode.blob_oid_valid?(oid) or not Encode.oid_matches_format?(oid, format) ->
          {:error, {:invalid_oid, oid}}

        mode not in @accepted_modes ->
          {:error, {:unsupported_selected_mode, mode, path}}

        entry["disposition"] not in ["retain", "transform_input"] ->
          {:error, :plan_not_immutable}

        true ->
          {:ok, Encode.order_retained(entry)}
      end
    end)
  end

  defp admit_groups(list) when is_list(list) do
    if Enum.all?(list, &is_map/1) do
      dests = Enum.map(list, & &1["destination_path"])

      if length(dests) != length(Enum.uniq(dests)) do
        {:error, :duplicate_group}
      else
        do_admit_groups(list)
      end
    else
      {:error, :plan_not_immutable}
    end
  end

  defp admit_groups(_), do: {:error, :plan_not_immutable}

  defp do_admit_groups(list) do
    admit_list(list, fn entry ->
      dest = entry["destination_path"]
      sources = entry["source_paths"]
      preexisting = entry["preexisting_paths"]

      cond do
        not exact_keys?(entry, @allowed_group_keys) ->
          {:error, :plan_not_immutable}

        not valid_repo_path?(dest) ->
          {:error, {:invalid_path, dest}}

        not is_list(sources) or not Enum.all?(sources, &valid_repo_path?/1) ->
          {:error, {:invalid_path, dest}}

        not is_list(preexisting) or not Enum.all?(preexisting, &valid_repo_path?/1) ->
          {:error, {:invalid_path, dest}}

        sources == [] or length(sources) != length(Enum.uniq(sources)) ->
          {:error, :plan_not_immutable}

        preexisting not in [[], [dest]] ->
          {:error, :plan_not_immutable}

        true ->
          {:ok, Encode.order_group(entry)}
      end
    end)
  end

  defp admit_coherence(entries, retained, groups, split) do
    exact_dests =
      entries
      |> Enum.filter(&(&1["disposition"] == "exact_move"))
      |> Enum.map(& &1["destination_path"])

    transform_by_dest =
      entries
      |> Enum.filter(&(&1["disposition"] == "transform_input"))
      |> Enum.group_by(& &1["destination_path"])

    group_dests = Enum.map(groups, & &1["destination_path"])
    retained_paths = Enum.map(retained, & &1["path"])

    retain_only =
      retained
      |> Enum.filter(&(&1["disposition"] == "retain"))
      |> MapSet.new(& &1["path"])

    transform_retained =
      retained
      |> Enum.filter(&(&1["disposition"] == "transform_input"))
      |> MapSet.new(& &1["path"])

    cond do
      length(exact_dests) != length(Enum.uniq(exact_dests)) ->
        {:error, :duplicate_destination}

      MapSet.intersection(MapSet.new(exact_dests), MapSet.new(group_dests)) != MapSet.new() ->
        {:error, :duplicate_destination}

      MapSet.intersection(MapSet.new(exact_dests), retain_only) != MapSet.new() ->
        {:error, :duplicate_destination}

      length(retained_paths) != length(Enum.uniq(retained_paths)) ->
        {:error, :duplicate_retained}

      true ->
        with :ok <-
               entry_coherence(entries, MapSet.new(group_dests), split["source_map"]),
             :ok <- group_coherence(groups, transform_by_dest, transform_retained),
             :ok <-
               retained_coherence(retained, MapSet.new(group_dests), split["passive_owner"]) do
          :ok
        end
    end
  end

  defp entry_coherence(entries, group_dests, source_map) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      dest = entry["destination_path"]
      group = entry["collision_group"]
      precondition = entry["target_precondition"]

      with {:ok, ^dest} <- rewrite_destination(entry["source_path"], source_map) do
        case entry["disposition"] do
          "exact_move" ->
            if group == "" and precondition == "expected_absent" do
              {:cont, :ok}
            else
              {:halt, {:error, :plan_not_immutable}}
            end

          "transform_input" ->
            collision_transform? = group == dest and MapSet.member?(group_dests, dest)
            semantic_transform? = group == "" and precondition == "expected_absent"

            if collision_transform? or semantic_transform? do
              {:cont, :ok}
            else
              {:halt, {:error, :plan_not_immutable}}
            end

          _ ->
            {:halt, {:error, :plan_not_immutable}}
        end
      else
        _ -> {:halt, {:error, :plan_not_immutable}}
      end
    end)
  end

  defp group_coherence(groups, transform_by_dest, transform_retained) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      dest = group["destination_path"]
      sources = group["source_paths"] || []
      preexisting = group["preexisting_paths"] || []
      from_entries = Enum.map(transform_by_dest[dest] || [], & &1["source_path"]) |> Enum.sort()

      expected_precondition =
        if preexisting == [], do: "expected_absent", else: "preexisting"

      entry_ok? =
        Enum.all?(transform_by_dest[dest] || [], fn entry ->
          entry["target_precondition"] == expected_precondition
        end)

      preexisting_ok? =
        Enum.all?(preexisting, fn path ->
          path == dest and MapSet.member?(transform_retained, path)
        end)

      cond do
        sources != from_entries ->
          {:halt, {:error, :plan_not_immutable}}

        not entry_ok? or not preexisting_ok? ->
          {:halt, {:error, :plan_not_immutable}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp retained_coherence(retained, group_dests, passive_owner) do
    Enum.reduce_while(retained, :ok, fn entry, :ok ->
      path = entry["path"]

      if source_app(path) == passive_owner do
        case entry["disposition"] do
          "transform_input" ->
            if MapSet.member?(group_dests, path),
              do: {:cont, :ok},
              else: {:halt, {:error, :plan_not_immutable}}

          "retain" ->
            if MapSet.member?(group_dests, path),
              do: {:halt, {:error, :plan_not_immutable}},
              else: {:cont, :ok}

          _ ->
            {:halt, {:error, :plan_not_immutable}}
        end
      else
        {:halt, {:error, :plan_not_immutable}}
      end
    end)
  end

  defp admit_list(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp compare_entry_sets(failures, current, admitted) do
    current_map = Map.new(current, &{&1["source_path"], &1})
    admitted_map = Map.new(admitted, &{&1["source_path"], &1})

    failures =
      Enum.reduce(admitted_map, failures, fn {path, expected}, acc ->
        case Map.fetch(current_map, path) do
          :error ->
            [%{"reason" => "missing_source", "detail" => path} | acc]

          {:ok, actual} ->
            entry_field_failures(acc, path, actual, expected)
        end
      end)

    Enum.reduce(current_map, failures, fn {path, _}, acc ->
      if Map.has_key?(admitted_map, path) do
        acc
      else
        [%{"reason" => "extra_source", "detail" => path} | acc]
      end
    end)
  end

  defp entry_field_failures(failures, path, actual, expected) do
    cond do
      actual["source_mode"] != expected["source_mode"] ->
        [%{"reason" => "source_mode_drift", "detail" => path} | failures]

      actual["source_oid"] != expected["source_oid"] ->
        [%{"reason" => "source_oid_drift", "detail" => path} | failures]

      actual["destination_path"] != expected["destination_path"] or
        actual["disposition"] != expected["disposition"] or
        actual["target_precondition"] != expected["target_precondition"] or
          actual["collision_group"] != expected["collision_group"] ->
        [%{"reason" => "disposition_drift", "detail" => path} | failures]

      true ->
        failures
    end
  end

  defp compare_retained_sets(failures, current, admitted) do
    current_map = Map.new(current, &{&1["path"], &1})
    admitted_map = Map.new(admitted, &{&1["path"], &1})

    failures =
      Enum.reduce(admitted_map, failures, fn {path, expected}, acc ->
        case Map.fetch(current_map, path) do
          :error ->
            [%{"reason" => "missing_retained", "detail" => path} | acc]

          {:ok, actual} ->
            cond do
              actual["mode"] != expected["mode"] ->
                [%{"reason" => "retained_mode_drift", "detail" => path} | acc]

              actual["oid"] != expected["oid"] ->
                [%{"reason" => "retained_oid_drift", "detail" => path} | acc]

              actual["disposition"] != expected["disposition"] ->
                [%{"reason" => "disposition_drift", "detail" => path} | acc]

              true ->
                acc
            end
        end
      end)

    Enum.reduce(current_map, failures, fn {path, _}, acc ->
      if Map.has_key?(admitted_map, path) do
        acc
      else
        [%{"reason" => "extra_retained", "detail" => path} | acc]
      end
    end)
  end

  defp compare_group_sets(failures, current, admitted) do
    current_map = Map.new(current, &{&1["destination_path"], &1})
    admitted_map = Map.new(admitted, &{&1["destination_path"], &1})

    failures =
      Enum.reduce(admitted_map, failures, fn {dest, expected}, acc ->
        case Map.fetch(current_map, dest) do
          :error ->
            [%{"reason" => "unclassified_collision", "detail" => dest} | acc]

          {:ok, actual} ->
            if actual["source_paths"] == expected["source_paths"] and
                 actual["preexisting_paths"] == expected["preexisting_paths"] do
              acc
            else
              [%{"reason" => "disposition_drift", "detail" => dest} | acc]
            end
        end
      end)

    Enum.reduce(current_map, failures, fn {dest, _}, acc ->
      if Map.has_key?(admitted_map, dest) do
        acc
      else
        [%{"reason" => "unclassified_collision", "detail" => dest} | acc]
      end
    end)
  end

  defp planned_phase_failures(plan, context) do
    presence = context[:source_presence] || context["source_presence"] || %{}
    present_paths = MapSet.new(context[:present_paths] || context["present_paths"] || [])
    extra_targets = context[:extra_target_paths] || context["extra_target_paths"] || []

    apps_present =
      Enum.count(source_apps(), fn app ->
        presence[app] == true
      end)

    expected_absent =
      (plan["entries"] || [])
      |> Enum.filter(&(&1["target_precondition"] == "expected_absent"))
      |> Enum.map(& &1["destination_path"])

    failures = []

    failures =
      if apps_present == 4 do
        failures
      else
        [%{"reason" => "mixed_phase", "detail" => "source_prefixes=#{apps_present}"} | failures]
      end

    failures =
      if extra_targets == [] do
        failures
      else
        [%{"reason" => "mixed_phase", "detail" => "arbor_kernel_runtime"} | failures]
      end

    Enum.reduce(expected_absent, failures, fn dest, acc ->
      if MapSet.member?(present_paths, dest) do
        [%{"reason" => "mixed_phase", "detail" => dest} | acc]
      else
        acc
      end
    end)
  end

  defp materialized_source_failures(failures, presence) do
    present_apps = Enum.filter(source_apps(), &(presence[&1] == true))
    count = length(present_apps)

    cond do
      count == 0 ->
        failures

      count == 4 ->
        [%{"reason" => "phase_mismatch", "detail" => "all_source_prefixes_present"} | failures]

      true ->
        failures =
          Enum.reduce(present_apps, failures, fn app, acc ->
            [%{"reason" => "source_not_absent", "detail" => "apps/#{app}"} | acc]
          end)

        [%{"reason" => "mixed_phase", "detail" => "source_prefixes=#{count}"} | failures]
    end
  end

  defp materialized_exact_failures(failures, plan, dest_files) do
    exact = Enum.filter(plan["entries"] || [], &(&1["disposition"] == "exact_move"))

    Enum.reduce(exact, failures, fn entry, acc ->
      dest = entry["destination_path"]

      case fetch_file(dest_files, dest) do
        nil ->
          [%{"reason" => "missing_destination", "detail" => dest} | acc]

        file ->
          cond do
            field(file, :mode) != entry["source_mode"] ->
              [%{"reason" => "destination_mode_drift", "detail" => dest} | acc]

            file_oid(file) != entry["source_oid"] ->
              [%{"reason" => "destination_oid_drift", "detail" => dest} | acc]

            true ->
              acc
          end
      end
    end)
  end

  defp materialized_retain_failures(failures, plan, dest_files) do
    retain_only =
      Enum.filter(plan["retained_targets"] || [], &(&1["disposition"] == "retain"))

    Enum.reduce(retain_only, failures, fn entry, acc ->
      path = entry["path"]

      case fetch_file(dest_files, path) do
        nil ->
          [%{"reason" => "missing_retained", "detail" => path} | acc]

        file ->
          cond do
            field(file, :mode) != entry["mode"] ->
              [%{"reason" => "retained_mode_drift", "detail" => path} | acc]

            file_oid(file) != entry["oid"] ->
              [%{"reason" => "retained_oid_drift", "detail" => path} | acc]

            true ->
              acc
          end
      end
    end)
  end

  defp materialized_transform_failures(failures, plan, evidence, dest_files) do
    dests = plan |> transform_destinations() |> MapSet.to_list() |> Enum.sort()

    by_dest =
      (evidence["entries"] || [])
      |> Enum.filter(&(&1["kind"] == "transform"))
      |> Map.new(&{&1["destination_path"], &1})

    Enum.reduce(dests, failures, fn dest, acc ->
      case Map.fetch(by_dest, dest) do
        :error ->
          [%{"reason" => "missing_transform_evidence", "detail" => dest} | acc]

        {:ok, row} ->
          compare_evidence_row(acc, dest, row, dest_files)
      end
    end)
  end

  defp materialized_generated_failures(failures, evidence, dest_files) do
    generated = Enum.filter(evidence["entries"] || [], &(&1["kind"] == "generated"))

    Enum.reduce(generated, failures, fn row, acc ->
      dest = row["destination_path"]
      compare_evidence_row(acc, dest, row, dest_files)
    end)
  end

  defp compare_evidence_row(failures, dest, row, dest_files) do
    case fetch_file(dest_files, dest) do
      nil ->
        [%{"reason" => "missing_destination", "detail" => dest} | failures]

      file ->
        cond do
          field(file, :mode) != row["mode"] ->
            [%{"reason" => "destination_mode_drift", "detail" => dest} | failures]

          file_oid(file) != row["oid"] ->
            [%{"reason" => "destination_oid_drift", "detail" => dest} | failures]

          true ->
            failures
        end
    end
  end

  defp materialized_coverage_failures(failures, plan, evidence, target_files) do
    exact_dests =
      (plan["entries"] || [])
      |> Enum.filter(&(&1["disposition"] == "exact_move"))
      |> MapSet.new(& &1["destination_path"])

    retain_dests =
      (plan["retained_targets"] || [])
      |> Enum.filter(&(&1["disposition"] == "retain"))
      |> MapSet.new(& &1["path"])

    transform_dests = transform_destinations(plan)

    generated_dests =
      (evidence["entries"] || [])
      |> Enum.filter(&(&1["kind"] == "generated"))
      |> MapSet.new(& &1["destination_path"])

    classes = [exact_dests, retain_dests, transform_dests, generated_dests]

    Enum.reduce(target_files, failures, fn file, acc ->
      path = field(file, :path)
      hits = Enum.count(classes, &MapSet.member?(&1, path))

      cond do
        hits == 1 ->
          acc

        hits == 0 ->
          [%{"reason" => "unexplained_destination", "detail" => path} | acc]

        true ->
          [%{"reason" => "duplicate_destination", "detail" => path} | acc]
      end
    end)
  end

  defp fetch_file(map, path) when is_map(map) do
    Map.get(map, path)
  end

  defp fetch_file(_, _), do: nil

  defp file_oid(file) do
    field(file, :blob_oid) || field(file, :oid)
  end

  defp finish_failures(failures) do
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

  defp field(map, key) when is_atom(key) and is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp exact_keys?(map, expected) when is_map(map) do
    MapSet.equal?(MapSet.new(Map.keys(map)), expected)
  end

  defp exact_keys?(_, _), do: false

  defp valid_app_name?(name) when is_binary(name) do
    Regex.match?(~r/\Aarbor_[a-z0-9_]+\z/, name)
  end

  defp valid_app_name?(_), do: false

  defp valid_repo_path?(path) when is_binary(path) do
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

  defp valid_repo_path?(_), do: false
end
