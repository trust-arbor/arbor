defmodule Arbor.Contracts.Coding.Plan do
  @moduledoc """
  Versioned, JSON-clean input contract for the reviewed coding workflow.

  A plan describes requested work and bounded execution policy. It is data, not
  authority: graph definitions, actions, capabilities, identities, signers, and
  execution principals are intentionally absent and are rejected as unknown
  fields. The executor derives authority independently from the authenticated
  caller.

  `new/1` accepts atom-keyed maps, string-keyed maps, and keyword-style object
  lists. Every object is closed: unknown fields and duplicate atom/string aliases
  are rejected before construction. `to_map/1` emits the canonical string-keyed
  representation used at JSON and Engine checkpoint boundaries.

  ## Defaults and bounds

  * base ref: `HEAD`
  * isolated workspace, with generated branch/worktree locations
  * default task and validation profiles; binding review
  * at most two rework cycles
  * 15-minute wall-clock budget and 5-minute inactivity budget
  * no explicit model-cost cap and parallelism of one
  * commit and retain the workspace; do not open a draft PR

  Wall-clock values are bounded to 10 seconds through 24 hours. Inactivity is
  bounded to 10 seconds through 1 hour, model cost to 100 USD, and parallelism
  to eight workers.
  """

  use TypedStruct

  @schema_version 1

  @profile_ids ~w(
    default
    security_regression
    contract_change
    frontend_visual
    docs_only
    cross_app
    database_migration
  )
  @overlay_ids @profile_ids -- ["default"]
  @review_profiles ~w(binding human_required none)
  @workspace_modes ~w(isolated)
  @permission_modes ~w(default deny)

  # These names match canonical terminal workflow outcomes. The compiler, not
  # planner-supplied free-form text, decides how each condition is wired.
  @rework_stop_conditions ~w(declined no_changes review_rejected validation_failed)

  @top_fields [
    :version,
    :task,
    :repo_root,
    :base_ref,
    :task_class,
    :workspace_policy,
    :worker,
    :validation_profile,
    :review_profile,
    :overlays,
    :rework,
    :budgets,
    :output,
    :requested_paths
  ]
  @workspace_fields [:mode, :branch_name, :worktree_base_dir]
  @worker_fields [:provider, :model, :permission_mode]
  @rework_fields [:max_cycles, :stop_conditions]
  @budget_fields [:wall_clock_ms, :inactivity_timeout_ms, :model_cost_usd, :parallelism]
  @output_fields [:commit, :draft_pr, :retain_workspace]

  @default_base_ref "HEAD"
  @default_workspace_policy %{
    "mode" => "isolated",
    "branch_name" => nil,
    "worktree_base_dir" => nil
  }
  @default_rework %{"max_cycles" => 2, "stop_conditions" => []}

  @min_timeout_ms 10_000
  @max_wall_clock_ms 86_400_000
  @max_inactivity_timeout_ms 3_600_000
  @default_wall_clock_ms 900_000
  @default_inactivity_timeout_ms 300_000
  @max_model_cost_usd 100.0
  @max_parallelism 8

  @default_budgets %{
    "wall_clock_ms" => @default_wall_clock_ms,
    "inactivity_timeout_ms" => @default_inactivity_timeout_ms,
    "model_cost_usd" => nil,
    "parallelism" => 1
  }
  @default_output %{"commit" => true, "draft_pr" => false, "retain_workspace" => true}

  @type workspace_policy :: %{required(String.t()) => String.t() | nil}
  @type worker :: %{required(String.t()) => String.t() | nil}
  @type rework :: %{required(String.t()) => non_neg_integer() | [String.t()]}
  @type budgets :: %{required(String.t()) => number() | nil}
  @type output :: %{required(String.t()) => boolean()}

  typedstruct enforce: true do
    @typedoc "A normalized coding plan with no embedded execution authority."

    field(:version, pos_integer(), default: @schema_version)
    field(:task, String.t())
    field(:repo_root, String.t())
    field(:base_ref, String.t(), default: @default_base_ref)
    field(:task_class, String.t(), default: "default")
    field(:workspace_policy, workspace_policy(), default: @default_workspace_policy)
    field(:worker, worker())
    field(:validation_profile, String.t(), default: "default")
    field(:review_profile, String.t(), default: "binding")
    field(:overlays, [String.t()], default: [])
    field(:rework, rework(), default: @default_rework)
    field(:budgets, budgets(), default: @default_budgets)
    field(:output, output(), default: @default_output)
    field(:requested_paths, [String.t()], default: [])
  end

  @doc "Return the integer schema version accepted by this contract."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Construct and validate a coding plan.

  Required input is limited to `task`, `repo_root`, and a `worker` object with
  a provider. All omitted policy fields are filled with canonical defaults.
  Known enum atoms are accepted for ergonomic keyword construction and are
  normalized to strings.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @top_fields, []),
         {:ok, version} <- normalize_version(Map.get(attrs, :version, @schema_version)),
         {:ok, task} <- fetch_nonblank_string(attrs, :task, []),
         {:ok, repo_root} <- fetch_nonblank_string(attrs, :repo_root, []),
         {:ok, base_ref} <-
           normalize_nonblank_string(Map.get(attrs, :base_ref, @default_base_ref), "base_ref"),
         {:ok, task_class} <-
           normalize_enum(Map.get(attrs, :task_class, "default"), @profile_ids, "task_class"),
         {:ok, workspace_policy} <-
           normalize_workspace_policy(Map.get(attrs, :workspace_policy, %{})),
         {:ok, worker} <- fetch_worker(attrs),
         {:ok, validation_profile} <-
           normalize_enum(
             Map.get(attrs, :validation_profile, "default"),
             @profile_ids,
             "validation_profile"
           ),
         {:ok, review_profile} <-
           normalize_enum(
             Map.get(attrs, :review_profile, "binding"),
             @review_profiles,
             "review_profile"
           ),
         {:ok, overlays} <- normalize_overlays(Map.get(attrs, :overlays, [])),
         {:ok, rework} <- normalize_rework(Map.get(attrs, :rework, %{})),
         {:ok, budgets} <- normalize_budgets(Map.get(attrs, :budgets, %{})),
         {:ok, output} <- normalize_output(Map.get(attrs, :output, %{})),
         {:ok, requested_paths} <-
           normalize_requested_paths(Map.get(attrs, :requested_paths, [])) do
      {:ok,
       %__MODULE__{
         version: version,
         task: task,
         repo_root: repo_root,
         base_ref: base_ref,
         task_class: task_class,
         workspace_policy: workspace_policy,
         worker: worker,
         validation_profile: validation_profile,
         review_profile: review_profile,
         overlays: overlays,
         rework: rework,
         budgets: budgets,
         output: output,
         requested_paths: requested_paths
       }}
    end
  end

  @doc "Return the complete canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = plan) do
    %{
      "version" => plan.version,
      "task" => plan.task,
      "repo_root" => plan.repo_root,
      "base_ref" => plan.base_ref,
      "task_class" => plan.task_class,
      "workspace_policy" => plan.workspace_policy,
      "worker" => plan.worker,
      "validation_profile" => plan.validation_profile,
      "review_profile" => plan.review_profile,
      "overlays" => plan.overlays,
      "rework" => plan.rework,
      "budgets" => plan.budgets,
      "output" => plan.output,
      "requested_paths" => plan.requested_paths
    }
  end

  defp normalize_version(@schema_version), do: {:ok, @schema_version}

  defp normalize_version(value) do
    {:error, {:invalid_field, "version", {:expected, @schema_version, value}}}
  end

  defp normalize_workspace_policy(value) do
    with {:ok, attrs} <- normalize_object(value, @workspace_fields, ["workspace_policy"]),
         {:ok, mode} <-
           normalize_enum(
             Map.get(attrs, :mode, "isolated"),
             @workspace_modes,
             "workspace_policy.mode"
           ),
         {:ok, branch_name} <-
           normalize_optional_string(
             Map.get(attrs, :branch_name),
             "workspace_policy.branch_name"
           ),
         {:ok, worktree_base_dir} <-
           normalize_optional_string(
             Map.get(attrs, :worktree_base_dir),
             "workspace_policy.worktree_base_dir"
           ) do
      {:ok,
       %{
         "mode" => mode,
         "branch_name" => branch_name,
         "worktree_base_dir" => worktree_base_dir
       }}
    end
  end

  defp fetch_worker(attrs) do
    case Map.fetch(attrs, :worker) do
      {:ok, value} -> normalize_worker(value)
      :error -> {:error, {:missing_field, "worker"}}
    end
  end

  defp normalize_worker(value) do
    with {:ok, attrs} <- normalize_object(value, @worker_fields, ["worker"]),
         {:ok, provider} <- fetch_nonblank_string(attrs, :provider, ["worker"]),
         {:ok, model} <- normalize_optional_string(Map.get(attrs, :model), "worker.model"),
         {:ok, permission_mode} <-
           normalize_enum(
             Map.get(attrs, :permission_mode, "default"),
             @permission_modes,
             "worker.permission_mode"
           ) do
      {:ok,
       %{
         "provider" => provider,
         "model" => model,
         "permission_mode" => permission_mode
       }}
    end
  end

  defp normalize_overlays(value) when is_list(value) do
    value
    |> normalize_enum_list(@overlay_ids, "overlays")
    |> sort_uniq_result()
  end

  defp normalize_overlays(value),
    do: {:error, {:invalid_field, "overlays", {:expected_list, value}}}

  defp normalize_rework(value) do
    with {:ok, attrs} <- normalize_object(value, @rework_fields, ["rework"]),
         {:ok, max_cycles} <-
           normalize_integer_range(
             Map.get(attrs, :max_cycles, 2),
             0,
             2,
             "rework.max_cycles"
           ),
         {:ok, stop_conditions} <-
           normalize_stop_conditions(Map.get(attrs, :stop_conditions, [])) do
      {:ok, %{"max_cycles" => max_cycles, "stop_conditions" => stop_conditions}}
    end
  end

  defp normalize_stop_conditions(value) when is_list(value) do
    value
    |> normalize_enum_list(@rework_stop_conditions, "rework.stop_conditions")
    |> sort_uniq_result()
  end

  defp normalize_stop_conditions(value) do
    {:error, {:invalid_field, "rework.stop_conditions", {:expected_list, value}}}
  end

  defp normalize_budgets(value) do
    with {:ok, attrs} <- normalize_object(value, @budget_fields, ["budgets"]),
         {:ok, wall_clock_ms} <-
           normalize_integer_range(
             Map.get(attrs, :wall_clock_ms, @default_wall_clock_ms),
             @min_timeout_ms,
             @max_wall_clock_ms,
             "budgets.wall_clock_ms"
           ),
         {:ok, inactivity_timeout_ms} <-
           normalize_integer_range(
             Map.get(attrs, :inactivity_timeout_ms, @default_inactivity_timeout_ms),
             @min_timeout_ms,
             @max_inactivity_timeout_ms,
             "budgets.inactivity_timeout_ms"
           ),
         {:ok, model_cost_usd} <-
           normalize_optional_number_range(
             Map.get(attrs, :model_cost_usd),
             0.0,
             @max_model_cost_usd,
             "budgets.model_cost_usd"
           ),
         {:ok, parallelism} <-
           normalize_integer_range(
             Map.get(attrs, :parallelism, 1),
             1,
             @max_parallelism,
             "budgets.parallelism"
           ) do
      {:ok,
       %{
         "wall_clock_ms" => wall_clock_ms,
         "inactivity_timeout_ms" => inactivity_timeout_ms,
         "model_cost_usd" => model_cost_usd,
         "parallelism" => parallelism
       }}
    end
  end

  defp normalize_output(value) do
    with {:ok, attrs} <- normalize_object(value, @output_fields, ["output"]),
         {:ok, commit} <- normalize_required_true(Map.get(attrs, :commit, true), "output.commit"),
         {:ok, draft_pr} <-
           normalize_boolean(Map.get(attrs, :draft_pr, false), "output.draft_pr"),
         {:ok, retain_workspace} <-
           normalize_required_true(
             Map.get(attrs, :retain_workspace, true),
             "output.retain_workspace"
           ) do
      {:ok,
       %{
         "commit" => commit,
         "draft_pr" => draft_pr,
         "retain_workspace" => retain_workspace
       }}
    end
  end

  defp normalize_requested_paths(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {path, index}, {:ok, paths} ->
      case normalize_requested_path(path, index) do
        {:ok, path} -> {:cont, {:ok, [path | paths]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, paths |> Enum.uniq() |> Enum.sort()}
      {:error, _} = error -> error
    end
  end

  defp normalize_requested_paths(value) do
    {:error, {:invalid_field, "requested_paths", {:expected_list, value}}}
  end

  defp normalize_requested_path(path, index) when is_binary(path) do
    field = "requested_paths[#{index}]"

    cond do
      not String.valid?(path) ->
        {:error, {:invalid_field, field, :invalid_utf8}}

      String.trim(path) == "" ->
        {:error, {:invalid_field, field, :blank}}

      String.contains?(path, <<0>>) ->
        {:error, {:invalid_field, field, :nul_byte}}

      absolute_path?(path) ->
        {:error, {:invalid_field, field, :absolute_path}}

      traversal_path?(path) ->
        {:error, {:invalid_field, field, :traversal_segment}}

      true ->
        {:ok, path}
    end
  end

  defp normalize_requested_path(path, index) do
    {:error, {:invalid_field, "requested_paths[#{index}]", {:expected_string, path}}}
  end

  defp absolute_path?(path) do
    Path.type(path) == :absolute or
      String.starts_with?(path, ["/", "\\"]) or
      Regex.match?(~r/^[A-Za-z]:/, path)
  end

  defp traversal_path?(path) do
    path
    |> String.split(~r{[\\/]}, trim: false)
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp normalize_enum_list(values, allowed, path) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, normalized} ->
      case normalize_enum(value, allowed, "#{path}[#{index}]") do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp sort_uniq_result({:ok, values}), do: {:ok, values |> Enum.uniq() |> Enum.sort()}
  defp sort_uniq_result({:error, _} = error), do: error

  defp normalize_enum(value, allowed, path) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if is_binary(normalized) and normalized in allowed do
      {:ok, normalized}
    else
      {:error, {:invalid_field, path, {:expected_one_of, allowed, value}}}
    end
  end

  defp fetch_nonblank_string(attrs, key, parent_path) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> normalize_nonblank_string(value, field_path(parent_path, key))
      :error -> {:error, {:missing_field, field_path(parent_path, key)}}
    end
  end

  defp normalize_nonblank_string(value, path) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, {:invalid_field, path, :invalid_utf8}}
      String.trim(value) == "" -> {:error, {:invalid_field, path, :blank}}
      true -> {:ok, value}
    end
  end

  defp normalize_nonblank_string(value, path) do
    {:error, {:invalid_field, path, {:expected_nonblank_string, value}}}
  end

  defp normalize_optional_string(nil, _path), do: {:ok, nil}
  defp normalize_optional_string(value, path), do: normalize_nonblank_string(value, path)

  defp normalize_integer_range(value, min, max, _path)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp normalize_integer_range(value, min, max, path) do
    {:error, {:invalid_field, path, {:expected_integer_between, min, max, value}}}
  end

  defp normalize_optional_number_range(nil, _exclusive_min, _max, _path), do: {:ok, nil}

  defp normalize_optional_number_range(value, exclusive_min, max, _path)
       when is_number(value) and value > exclusive_min and value <= max,
       do: {:ok, value * 1.0}

  defp normalize_optional_number_range(value, exclusive_min, max, path) do
    {:error, {:invalid_field, path, {:expected_number_above_through, exclusive_min, max, value}}}
  end

  defp normalize_required_true(true, _path), do: {:ok, true}

  defp normalize_required_true(value, path) do
    {:error, {:invalid_field, path, {:must_be_true, value}}}
  end

  defp normalize_boolean(value, _path) when is_boolean(value), do: {:ok, value}

  defp normalize_boolean(value, path) do
    {:error, {:invalid_field, path, {:expected_boolean, value}}}
  end

  defp normalize_object(value, allowed_fields, path) do
    with {:ok, entries} <- object_entries(value, path),
         {:ok, named_entries} <- name_entries(entries, path),
         :ok <- reject_duplicate_fields(named_entries, path),
         :ok <- reject_unknown_fields(named_entries, allowed_fields, path) do
      fields_by_name = Map.new(allowed_fields, &{Atom.to_string(&1), &1})

      {:ok,
       Map.new(named_entries, fn {name, value} ->
         {Map.fetch!(fields_by_name, name), value}
       end)}
    end
  end

  defp object_entries(value, path) when is_map(value) do
    if is_struct(value) do
      {:error, {:invalid_object, object_path(path)}}
    else
      {:ok, Map.to_list(value)}
    end
  end

  defp object_entries(value, path) when is_list(value) do
    if Enum.all?(value, &match?({_, _}, &1)) do
      {:ok, value}
    else
      {:error, {:invalid_object, object_path(path)}}
    end
  end

  defp object_entries(_value, path), do: {:error, {:invalid_object, object_path(path)}}

  defp name_entries(entries, path) do
    Enum.reduce_while(entries, {:ok, []}, fn {key, value}, {:ok, named} ->
      case key_name(key) do
        {:ok, name} -> {:cont, {:ok, [{name, value} | named]}}
        :error -> {:halt, {:error, {:invalid_object_key, object_path(path), key}}}
      end
    end)
  end

  defp key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp key_name(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp key_name(_key), do: :error

  defp reject_duplicate_fields(named_entries, path) do
    duplicates =
      named_entries
      |> Enum.map(&elem(&1, 0))
      |> Enum.frequencies()
      |> Enum.filter(fn {_field, count} -> count > 1 end)
      |> Enum.map(fn {field, _count} -> qualify_path(path, field) end)
      |> Enum.sort()

    case duplicates do
      [] -> :ok
      fields -> {:error, {:duplicate_fields, fields}}
    end
  end

  defp reject_unknown_fields(named_entries, allowed_fields, path) do
    allowed_names = MapSet.new(allowed_fields, &Atom.to_string/1)

    unknown =
      named_entries
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&MapSet.member?(allowed_names, &1))
      |> Enum.uniq()
      |> Enum.map(&qualify_path(path, &1))
      |> Enum.sort()

    case unknown do
      [] -> :ok
      fields -> {:error, {:unknown_fields, fields}}
    end
  end

  defp field_path(parent, key), do: qualify_path(parent, Atom.to_string(key))
  defp qualify_path([], field), do: field
  defp qualify_path(parent, field), do: Enum.join(parent ++ [field], ".")
  defp object_path([]), do: "plan"
  defp object_path(path), do: Enum.join(path, ".")
end
