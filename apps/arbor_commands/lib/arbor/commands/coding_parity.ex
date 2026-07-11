defmodule Arbor.Commands.CodingParity do
  @moduledoc """
  Projects stable `coding_change` task-result artifacts for deterministic path
  parity. Artifact quality is reported separately; branch, commit, opaque ID,
  timing, and provider-usage fields are excluded.
  """

  @schema "arbor.coding_parity.projection.v1"
  @statuses ~w(
    approval_denied cancelled change_committed declined human_review_required
    no_changes pr_created pr_failed review_failed review_rejected
    review_requires_rework rework_exhausted validation_failed
  )
  @no_validation_statuses ~w(cancelled declined no_changes)
  @comparison_paths [
    {"approval", ["approval"]},
    {"cancellation", ["cancellation"]},
    {"changed_files", ["changed_files"]},
    {"cleanup", ["cleanup"]},
    {"review.blast_radius", ["review", "blast_radius"]},
    {"review.human_required", ["review", "human_required"]},
    {"review.recommendation", ["review", "recommendation"]},
    {"review.security_veto", ["review", "security_veto"]},
    {"review.tier_decision", ["review", "tier_decision"]},
    {"terminal_status", ["terminal_status"]},
    {"tree_oid", ["tree_oid"]},
    {"validation_outcome", ["validation_outcome"]}
  ]
  @oid_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @missing :__coding_parity_missing__

  @doc "Project one coding artifact and its runtime observations."
  @spec project(map(), map()) :: {:ok, map()} | {:error, map()}
  def project(result, observations) do
    with :ok <- validate_observations(observations),
         {:ok, context} <- unwrap(result),
         {:ok, status} <- terminal_status(context.sources),
         {:ok, tree} <- tree_oid(context.sources, observations),
         {:ok, files} <- changed_files(context.sources),
         {:ok, validation} <- validation_outcome(context.sources, status),
         {:ok, review} <- review_outcome(context.review_sources),
         {:ok, cleanup} <- lifecycle(:cleanup, context.metrics, observations),
         {:ok, cancellation} <- lifecycle(:cancellation, context.metrics, observations),
         {:ok, approval} <- lifecycle(:approval, context.metrics, observations) do
      semantic = %{
        "approval" => approval,
        "cancellation" => cancellation,
        "changed_files" => files,
        "cleanup" => cleanup,
        "terminal_status" => status,
        "tree_oid" => tree,
        "validation_outcome" => validation
      }

      semantic = if review == %{}, do: semantic, else: Map.put(semantic, "review", review)

      {:ok,
       %{
         "artifact_quality" => artifact_quality(context.artifacts),
         "schema" => @schema,
         "semantic" => semantic
       }}
    end
  end

  @doc "Compare two projections and return sorted field-level differences."
  @spec compare(map(), map()) :: {:ok, map()} | {:error, map()}
  def compare(left, right) do
    left_result = validate_projection(left)
    right_result = validate_projection(right)

    case {left_result, right_result} do
      {{:ok, left}, {:ok, right}} ->
        differences = differences(left["semantic"], right["semantic"])

        {:ok,
         %{
           "artifact_quality" => %{
             "left" => left["artifact_quality"],
             "right" => right["artifact_quality"]
           },
           "differences" => differences,
           "equivalent?" => differences == [],
           "semantic" => %{"left" => left["semantic"], "right" => right["semantic"]}
         }}

      _other ->
        errors = comparison_errors(left_result, right_result)
        {:error, %{"error" => "coding_parity_comparison_failed", "sides" => errors}}
    end
  end

  defp validate_observations(observations)
       when is_map(observations) and not is_struct(observations) do
    allowed = ~w(tree_oid cleanup cancellation approval)
    atoms = [:tree_oid, :cleanup, :cancellation, :approval]

    if Enum.all?(Map.keys(observations), &(&1 in allowed or &1 in atoms)),
      do: :ok,
      else: invalid("unknown_observation", "observations")
  end

  defp validate_observations(_observations),
    do: invalid("invalid_observations", "observations")

  defp unwrap(result) when is_map(result) and not is_struct(result) do
    case fetch(result, "result_type", :result_type) do
      {:ok, type} -> unwrap_public(result, type)
      :error -> invalid("non_coding_result", "result")
    end
  end

  defp unwrap(_result), do: invalid("invalid_result", "result")

  defp unwrap_public(result, type) do
    with {:ok, "coding_change"} <- token(type, "result.result_type"),
         {:ok, payload} <- required_map(result, "payload", :payload) do
      {:ok, context(result, payload)}
    else
      {:ok, _other} -> invalid("unsupported_result_type", "result.result_type")
      {:error, _reason} = error -> error
    end
  end

  defp context(root, payload) do
    raw = map_value(root, "raw", :raw) || %{}
    report = map_value(payload, "report", :report) || payload
    review = map_value(report, "review", :review) || %{}
    verdict = map_value(payload, "verdict", :verdict) || %{}
    sources = [report, payload, raw, root]

    %{
      artifacts: first_map(sources, "artifacts", :artifacts) || %{},
      metrics: first_map([root, payload, raw], "metrics", :metrics) || %{},
      review_sources: [report, review, verdict, payload, raw, root],
      sources: sources
    }
  end

  defp terminal_status(sources) do
    value =
      case first(sources, [{"canonical_status", :canonical_status}]) do
        @missing -> first(sources, [{"status", :status}])
        canonical -> canonical
      end

    with {:ok, status} <- token(value, "terminal_status"), true <- status in @statuses do
      {:ok, status}
    else
      false -> invalid("unknown_terminal_status", "terminal_status")
      {:error, _reason} = error -> error
    end
  end

  defp tree_oid(sources, observations) do
    value =
      case first([observations], [{"tree_oid", :tree_oid}]) do
        @missing -> first(sources, [{"tree_oid", :tree_oid}])
        observed -> observed
      end

    if is_binary(value) and Regex.match?(@oid_pattern, String.trim(value)) do
      {:ok, value |> String.trim() |> String.downcase()}
    else
      reason = if value == @missing, do: "missing_tree_oid", else: "invalid_tree_oid"
      invalid(reason, "tree_oid")
    end
  end

  defp changed_files(sources) do
    case first(sources, [{"changed_files", :changed_files}, {"files", :files}]) do
      files when is_list(files) -> normalize_files(files)
      @missing -> invalid("missing_changed_files", "changed_files")
      _other -> invalid("invalid_changed_files", "changed_files")
    end
  end

  defp normalize_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      value = if is_atom(file), do: Atom.to_string(file), else: file

      if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
           not String.contains?(value, <<0>>) do
        {:cont, {:ok, [value | acc]}}
      else
        {:halt, invalid("invalid_changed_file", "changed_files")}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp validation_outcome(sources, status) do
    case first(sources, [{"validation_outcome", :validation_outcome}, {"validation", :validation}]) do
      @missing when status == "validation_failed" -> {:ok, "failed"}
      @missing when status in @no_validation_statuses -> {:ok, "not_run"}
      @missing -> invalid("missing_validation_outcome", "validation_outcome")
      value -> aggregate_validation(value)
    end
  end

  defp aggregate_validation([]), do: {:ok, "not_run"}

  defp aggregate_validation(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case aggregate_validation(value) do
        {:ok, outcome} -> {:cont, {:ok, [outcome | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, outcomes} -> {:ok, Enum.find(["failed", "passed"], "not_run", &(&1 in outcomes))}
      error -> error
    end
  end

  defp aggregate_validation(value) when is_map(value) and not is_struct(value) do
    case first([value], [{"passed", :passed}, {"status", :status}, {"outcome", :outcome}]) do
      true -> {:ok, "passed"}
      false -> {:ok, "failed"}
      outcome -> aggregate_validation(outcome)
    end
  end

  defp aggregate_validation(value) do
    with {:ok, value} <- token(value, "validation_outcome") do
      cond do
        value in ~w(ok passed success) ->
          {:ok, "passed"}

        value in ~w(error failed validation_failed) ->
          {:ok, "failed"}

        value in ~w(not_run skipped) ->
          {:ok, "not_run"}

        true ->
          invalid("unknown_validation_outcome", "validation_outcome")
      end
    end
  end

  defp review_outcome(sources) do
    fields = [
      {"recommendation",
       [
         {"review_recommendation", :review_recommendation},
         {"recommendation", :recommendation}
       ]},
      {"tier_decision", [{"tier_decision", :tier_decision}]},
      {"human_required", [{"human_required", :human_required}]},
      {"security_veto", [{"security_veto", :security_veto}]},
      {"blast_radius", [{"blast_radius", :blast_radius}]}
    ]

    Enum.reduce_while(fields, {:ok, %{}}, fn {name, keys}, {:ok, acc} ->
      case first(sources, keys) do
        @missing ->
          {:cont, {:ok, acc}}

        value when name in ["human_required", "security_veto"] and is_boolean(value) ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        value ->
          put_review_field(acc, name, value)
      end
    end)
  end

  defp put_review_field(map, name, value) do
    with {:ok, value} <- token(value, "review.#{name}") do
      {:cont, {:ok, Map.put(map, name, value)}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp lifecycle(kind, metrics, observations) do
    source =
      case observation(kind, observations) do
        @missing -> metrics
        value -> value
      end

    source = if is_binary(source) or is_atom(source), do: %{"status" => source}, else: source
    project_lifecycle(kind, source)
  end

  defp observation(:cleanup, map), do: first([map], [{"cleanup", :cleanup}])
  defp observation(:cancellation, map), do: first([map], [{"cancellation", :cancellation}])
  defp observation(:approval, map), do: first([map], [{"approval", :approval}])

  defp project_lifecycle(kind, map) when is_map(map) and not is_struct(map) do
    fields = [{"status", lifecycle_status_keys(kind), :token} | lifecycle_extra_fields(kind)]

    Enum.reduce_while(fields, {:ok, %{}}, fn {name, keys, type}, {:ok, acc} ->
      case first([map], keys) do
        @missing -> {:cont, {:ok, acc}}
        value -> put_lifecycle_field(acc, kind, name, type, value)
      end
    end)
    |> case do
      {:ok, projected} when map_size(projected) > 0 -> {:ok, projected}
      {:ok, _empty} -> invalid("missing_runtime_observation", "runtime.#{kind}")
      error -> error
    end
  end

  defp project_lifecycle(kind, _value),
    do: invalid("invalid_runtime_observation", "runtime.#{kind}")

  defp put_lifecycle_field(map, kind, name, :token, value) do
    case token(value, "runtime.#{kind}.#{name}") do
      {:ok, value} -> {:cont, {:ok, Map.put(map, name, value)}}
      error -> {:halt, error}
    end
  end

  defp put_lifecycle_field(map, _kind, name, :boolean, value) when is_boolean(value),
    do: {:cont, {:ok, Map.put(map, name, value)}}

  defp put_lifecycle_field(map, _kind, name, :count, value)
       when is_integer(value) and value >= 0,
       do: {:cont, {:ok, Map.put(map, name, value)}}

  defp put_lifecycle_field(_map, kind, name, _type, _value),
    do: {:halt, invalid("invalid_runtime_observation", "runtime.#{kind}.#{name}")}

  defp lifecycle_status_keys(:cleanup),
    do: [{"status", :status}, {"workspace_release_status", :workspace_release_status}]

  defp lifecycle_status_keys(:cancellation),
    do: [{"status", :status}, {"cancellation_status", :cancellation_status}]

  defp lifecycle_status_keys(:approval),
    do: [{"status", :status}, {"approval_status", :approval_status}]

  defp lifecycle_extra_fields(:cleanup) do
    [
      {"completed", [{"completed", :completed}], :boolean},
      {"resources_cleaned", [{"resources_cleaned", :resources_cleaned}], :boolean},
      {"workspace_removed", [{"workspace_removed", :workspace_removed}], :boolean},
      {"workspace_retained", [{"workspace_retained", :workspace_retained}], :boolean}
    ]
  end

  defp lifecycle_extra_fields(:cancellation) do
    [
      {"requested", [{"requested", :requested}], :boolean},
      {"cancelled", [{"cancelled", :cancelled}], :boolean},
      {"worker_terminated", [{"worker_terminated", :worker_terminated}], :boolean},
      {"cleanup_completed", [{"cleanup_completed", :cleanup_completed}], :boolean}
    ]
  end

  defp lifecycle_extra_fields(:approval) do
    [
      {"requested", [{"requested", :requested}], :boolean},
      {"required", [{"required", :required}, {"approval_required", :approval_required}],
       :boolean},
      {"resumed", [{"resumed", :resumed}], :boolean},
      {"count", [{"count", :count}], :count}
    ]
  end

  defp artifact_quality(artifacts) do
    %{
      "digest" => artifact?(artifacts, "graph_hash", :graph_hash),
      "dot" => artifact?(artifacts, "coding_pipeline_path", :coding_pipeline_path),
      "manifest" => artifact?(artifacts, "compile_manifest_path", :compile_manifest_path),
      "plan" => artifact?(artifacts, "coding_plan_path", :coding_plan_path)
    }
  end

  defp artifact?(artifacts, string, atom) do
    case fetch(artifacts, string, atom) do
      {:ok, value} when is_binary(value) -> String.trim(value) != ""
      {:ok, true} -> true
      _other -> false
    end
  end

  defp validate_projection(projection) when is_map(projection) and not is_struct(projection) do
    semantic = Map.get(projection, "semantic")
    quality = Map.get(projection, "artifact_quality")

    if Map.get(projection, "schema") == @schema and is_map(semantic) and is_map(quality),
      do: {:ok, projection},
      else: invalid("invalid_projection", "projection")
  end

  defp validate_projection(_projection), do: invalid("invalid_projection", "projection")

  defp differences(left, right) do
    Enum.flat_map(@comparison_paths, fn {field, path} ->
      left_value = path_value(left, path)
      right_value = path_value(right, path)

      if left_value == right_value,
        do: [],
        else: [
          %{"field" => field, "left" => display(left_value), "right" => display(right_value)}
        ]
    end)
  end

  defp path_value(map, path) do
    Enum.reduce_while(path, map, fn key, value ->
      if is_map(value) and Map.has_key?(value, key),
        do: {:cont, Map.get(value, key)},
        else: {:halt, @missing}
    end)
  end

  defp display(@missing), do: nil
  defp display(value), do: value

  defp comparison_errors(left, right) do
    [{"left", left}, {"right", right}]
    |> Enum.flat_map(fn
      {_side, {:ok, _projection}} -> []
      {side, {:error, cause}} -> [%{"cause" => cause, "side" => side}]
    end)
  end

  defp required_map(map, string, atom) do
    case fetch(map, string, atom) do
      {:ok, value} when is_map(value) and not is_struct(value) -> {:ok, value}
      {:ok, _value} -> invalid("invalid_map", "result.#{string}")
      :error -> invalid("missing_field", "result.#{string}")
    end
  end

  defp map_value(map, string, atom) do
    case fetch(map, string, atom) do
      {:ok, value} when is_map(value) and not is_struct(value) -> value
      _other -> nil
    end
  end

  defp first_map(sources, string, atom) do
    Enum.find_value(sources, fn source -> map_value(source, string, atom) end)
  end

  defp first(sources, keys) do
    Enum.reduce_while(sources, @missing, fn source, @missing ->
      found =
        Enum.find_value(keys, fn {string, atom} ->
          case fetch(source, string, atom) do
            {:ok, nil} -> nil
            {:ok, value} -> {:found, value}
            :error -> nil
          end
        end)

      if found, do: {:halt, elem(found, 1)}, else: {:cont, @missing}
    end)
  end

  defp fetch(map, string, atom) when is_map(map) do
    case Map.fetch(map, string) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, atom)
    end
  end

  defp fetch(_map, _string, _atom), do: :error

  defp token(@missing, field), do: invalid("missing_field", field)
  defp token(value, field) when is_atom(value), do: token(Atom.to_string(value), field)

  defp token(value, field) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" do
      {:ok, value |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/u, "_")}
    else
      invalid("invalid_field", field)
    end
  end

  defp token(_value, field), do: invalid("invalid_field", field)

  defp invalid(reason, field) do
    {:error,
     %{
       "error" => "invalid_coding_parity_input",
       "field" => field,
       "reason" => reason
     }}
  end
end
