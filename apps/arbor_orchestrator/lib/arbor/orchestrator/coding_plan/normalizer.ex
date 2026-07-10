defmodule Arbor.Orchestrator.CodingPlan.Normalizer do
  @moduledoc """
  Normalizes external coding tasks into the versioned coding-plan contract.

  This module is the strict JSON boundary for coding task payloads. It accepts
  either the legacy flat task shape or a direct versioned plan, but never a
  mixture of the two. It translates compatibility data only; repository scope,
  caller identity, capabilities, graph selection, and execution authority stay
  with the executor.
  """

  alias Arbor.Contracts.Coding.Plan

  @kind "coding_change"

  @legacy_required_keys ~w(task repo_path acp_agent)
  @legacy_optional_keys ~w(base_ref branch_name worktree_base_dir open_pr submit_review)
  @legacy_keys MapSet.new(["kind" | @legacy_required_keys ++ @legacy_optional_keys])
  @direct_keys MapSet.new(~w(kind plan))

  @forbidden_task_keys MapSet.new(~w(
    action_executor
    actions
    actions_executor
    agent_id
    authorization
    authorizer
    capabilities
    coding_pipeline_path
    edges
    engine
    engine_module
    graph
    graph_path
    identity
    identity_private_key
    key_file
    module
    nodes
    path
    pipeline
    pipeline_path
    principal_id
    private_key
    private_keys
    signer
    signing_key
    signing_key_file
    signing_keys
    task_id
  ))

  @doc """
  Normalize a strict string-keyed JSON coding task into `Plan` version 1.

  Legacy optional `nil` values are treated as omitted for compatibility. Direct
  plans are passed to `Plan.new/1` without key or value coercion.
  """
  @spec normalize_task(term()) :: {:ok, Plan.t()} | {:error, term()}
  def normalize_task(task) when is_map(task) and not is_struct(task) do
    with :ok <- ensure_json_object(task, :top),
         :ok <- reject_forbidden_task_keys(task),
         :ok <- require_kind(task) do
      normalize_shape(task)
    end
  end

  def normalize_task(_task), do: {:error, :invalid_task}

  defp normalize_shape(%{"plan" => plan} = task) do
    extra_keys =
      task |> Map.keys() |> Enum.reject(&MapSet.member?(@direct_keys, &1)) |> Enum.sort()

    cond do
      Enum.any?(extra_keys, &MapSet.member?(@legacy_keys, &1)) ->
        {:error, :mixed_task_shape}

      extra_keys != [] ->
        {:error, {:unknown_task_key, hd(extra_keys)}}

      true ->
        Plan.new(plan)
    end
  end

  defp normalize_shape(task) do
    with :ok <- reject_unknown_task_keys(task, @legacy_keys),
         {:ok, task_text} <- require_task_text(task),
         {:ok, repo_root} <- require_trimmed_string(task, "repo_path"),
         {:ok, provider} <- require_trimmed_string(task, "acp_agent"),
         {:ok, base_ref} <- optional_trimmed_string(task, "base_ref"),
         {:ok, branch_name} <- optional_trimmed_string(task, "branch_name"),
         {:ok, worktree_base_dir} <- optional_trimmed_string(task, "worktree_base_dir"),
         {:ok, draft_pr} <- optional_boolean(task, "open_pr", false),
         {:ok, submit_review} <- optional_boolean(task, "submit_review", true) do
      workspace_policy =
        %{"mode" => "isolated"}
        |> put_optional("branch_name", branch_name)
        |> put_optional("worktree_base_dir", worktree_base_dir)

      plan_attrs =
        %{
          "version" => Plan.schema_version(),
          "task" => task_text,
          "repo_root" => repo_root,
          "worker" => %{"provider" => provider},
          "workspace_policy" => workspace_policy,
          "review_profile" => if(submit_review, do: "binding", else: "none"),
          "output" => %{"draft_pr" => draft_pr}
        }
        |> put_optional("base_ref", base_ref)

      Plan.new(plan_attrs)
    end
  end

  defp require_kind(%{"kind" => @kind}), do: :ok

  defp require_kind(%{"kind" => kind}) when is_binary(kind),
    do: {:error, {:unsupported_task_kind, kind}}

  defp require_kind(%{"kind" => _kind}), do: {:error, {:invalid_field_type, "kind"}}
  defp require_kind(_task), do: {:error, :missing_task_kind}

  defp require_task_text(task) do
    case Map.fetch(task, "task") do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, {:blank_field, "task"}},
          else: {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field_type, "task"}}

      :error ->
        {:error, {:missing_field, "task"}}
    end
  end

  defp require_trimmed_string(task, field) do
    case Map.fetch(task, field) do
      {:ok, value} -> normalize_trimmed_string(value, field)
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp optional_trimmed_string(task, field) do
    case Map.fetch(task, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> normalize_trimmed_string(value, field)
    end
  end

  defp normalize_trimmed_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:blank_field, field}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_trimmed_string(_value, field), do: {:error, {:invalid_field_type, field}}

  defp optional_boolean(task, field, default) do
    case Map.fetch(task, field) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} -> normalize_boolean(value, field)
    end
  end

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean("1", _field), do: {:ok, true}
  defp normalize_boolean("0", _field), do: {:ok, false}

  defp normalize_boolean(value, field) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, {:invalid_field_type, field}}
    end
  end

  defp normalize_boolean(_value, field), do: {:error, {:invalid_field_type, field}}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp reject_forbidden_task_keys(task) do
    task
    |> Map.keys()
    |> Enum.filter(&MapSet.member?(@forbidden_task_keys, &1))
    |> Enum.sort()
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:forbidden_task_key, key}}
    end
  end

  defp reject_unknown_task_keys(task, allowed) do
    task
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.sort()
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_task_key, key}}
    end
  end

  defp ensure_json_object(map, location) when is_map(map) and not is_struct(map) do
    map
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, {:non_json_task, key_error(location)}}}

        not String.valid?(key) ->
          {:halt, {:error, {:non_json_task, :invalid_utf8_key}}}

        true ->
          case ensure_json_value(value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:non_json_task, reason}}}
          end
      end
    end)
  end

  defp ensure_json_value(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8_string}
  end

  defp ensure_json_value(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp ensure_json_value([]), do: :ok

  defp ensure_json_value([head | tail]) do
    with :ok <- ensure_json_value(head),
         :ok <- ensure_json_list_tail(tail) do
      :ok
    end
  end

  defp ensure_json_value(%_struct{}), do: {:error, :struct_not_json}
  defp ensure_json_value(map) when is_map(map), do: ensure_json_object_value(map)
  defp ensure_json_value(value) when is_atom(value), do: {:error, :atom_not_json}
  defp ensure_json_value(value) when is_pid(value), do: {:error, :pid_not_json}
  defp ensure_json_value(value) when is_function(value), do: {:error, :function_not_json}
  defp ensure_json_value(value) when is_reference(value), do: {:error, :reference_not_json}
  defp ensure_json_value(value) when is_port(value), do: {:error, :port_not_json}
  defp ensure_json_value(value) when is_tuple(value), do: {:error, :tuple_not_json}
  defp ensure_json_value(_value), do: {:error, :non_json_value}

  defp ensure_json_list_tail([]), do: :ok

  defp ensure_json_list_tail([head | tail]) do
    with :ok <- ensure_json_value(head),
         :ok <- ensure_json_list_tail(tail) do
      :ok
    end
  end

  defp ensure_json_list_tail(_improper_tail), do: {:error, :improper_list_not_json}

  defp ensure_json_object_value(map) do
    case ensure_json_object(map, :nested) do
      :ok -> :ok
      {:error, {:non_json_task, reason}} -> {:error, reason}
    end
  end

  defp key_error(:top), do: :non_string_key
  defp key_error(:nested), do: :nested_non_string_key
end
