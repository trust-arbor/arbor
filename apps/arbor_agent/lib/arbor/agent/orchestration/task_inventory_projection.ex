defmodule Arbor.Agent.Orchestration.TaskInventoryProjection do
  @moduledoc """
  Pure, bounded projection of the volatile orchestration task registry.

  This module only returns reconciliation evidence. It never copies task
  payloads, results, contexts, errors, metadata, authority, or executable
  values into the returned map.
  """

  alias Arbor.Agent.Orchestration.TaskArtifacts

  @schema_version 1
  @max_tasks 1_000
  @max_id_bytes 256
  @max_step_bytes 256
  @max_control_count 100
  @closed_control_statuses ~w(delivered delivery_unconfirmed unsupported)
  @states ~w(running waiting_approval done failed cancelled)

  @spec from_state(map(), map(), pos_integer(), map()) :: map()
  def from_state(state, filters, max_items, owner_statuses \\ %{})

  def from_state(state, filters, max_items, owner_statuses)
      when is_map(state) and is_map(filters) and is_integer(max_items) and max_items > 0 and
             is_map(owner_statuses) do
    {records, observed_count, hard_truncated} = bounded_records(Map.get(state, :tasks))

    {tasks, malformed_count} =
      Enum.reduce(records, {[], 0}, fn {_key, record}, {projected, malformed} ->
        case project_record(record, owner_statuses) do
          {:ok, task} -> {[task | projected], malformed}
          :malformed -> {projected, malformed + 1}
        end
      end)

    matching_tasks = Enum.filter(tasks, &matches?(&1, filters))
    sorted_tasks = Enum.sort_by(matching_tasks, &{&1["task_id"], &1["agent_id"]})
    returned_tasks = Enum.take(sorted_tasks, max_items)
    matching_count = length(matching_tasks)
    returned_count = length(returned_tasks)
    truncated_count = max(matching_count - returned_count, 0)

    %{
      "schema_version" => @schema_version,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{
        "task_id" => Map.get(filters, :task_id),
        "agent_id" => Map.get(filters, :agent_id),
        "state" => state_filter(Map.get(filters, :state))
      },
      "max_items" => max_items,
      "truncated" => hard_truncated or truncated_count > 0,
      "counts" => %{
        "observed" => observed_count,
        "matching" => matching_count,
        "returned" => returned_count,
        "filtered_out" => max(observed_count - malformed_count - matching_count, 0),
        "truncated" => truncated_count,
        "malformed" => malformed_count
      },
      "tasks" => returned_tasks
    }
  end

  def from_state(_state, _filters, _max_items, _owner_statuses),
    do: invalid_inventory()

  defp bounded_records(tasks) when is_map(tasks) do
    ordered =
      tasks
      |> :maps.iterator()
      |> take_iterator(@max_tasks)
      |> Enum.sort_by(fn {key, _record} -> lexical_key(key) end)

    {ordered, min(map_size(tasks), @max_tasks), map_size(tasks) > @max_tasks}
  end

  defp bounded_records(_tasks), do: {[{nil, nil}], 1, false}

  defp lexical_key(key) when is_binary(key), do: {0, key}
  defp lexical_key(_key), do: {1, ""}

  defp take_iterator(iterator, limit), do: take_iterator(iterator, limit, [])

  defp take_iterator(_iterator, 0, acc), do: acc

  defp take_iterator(iterator, limit, acc) do
    case :maps.next(iterator) do
      :none -> acc
      {key, value, next_iterator} -> take_iterator(next_iterator, limit - 1, [{key, value} | acc])
    end
  end

  defp project_record(record, owner_statuses) when is_map(record) and not is_struct(record) do
    with {:ok, task_id} <- required_string(record, :task_id, @max_id_bytes),
         {:ok, agent_id} <- required_string(record, :agent_id, @max_id_bytes),
         {:ok, state} <- closed_state(value(record, :state)),
         {:ok, current_step} <- optional_string(value(record, :current_step), @max_step_bytes),
         {:ok, waiting_on} <- optional_string(value(record, :waiting_on), @max_step_bytes),
         {:ok, started_at} <- required_timestamp(value(record, :started_at)),
         {:ok, updated_at} <- required_timestamp(value(record, :updated_at)),
         {:ok, completed_at} <- optional_timestamp(value(record, :completed_at)),
         true <- is_list(value(record, :controls, [])) do
      owner = Map.get(owner_statuses, task_id, %{})
      terminal = terminal_data(record, state)

      {:ok,
       %{
         "task_id" => task_id,
         "agent_id" => agent_id,
         "state" => state,
         "current_step" => current_step,
         "waiting_on" => waiting_on,
         "started_at" => started_at,
         "updated_at" => updated_at,
         "completed_at" => completed_at,
         "owner_process" => %{
           "present" => Map.get(owner, :present) == true,
           "alive" => Map.get(owner, :alive) == true
         },
         "control_counts" => control_counts(value(record, :controls, [])),
         "evidence_present" => evidence_present?(terminal),
         "artifacts_present" => artifacts_present?(terminal)
       }
       |> maybe_put_outcome(state, terminal)}
    else
      _ -> :malformed
    end
  rescue
    _ -> :malformed
  catch
    _, _ -> :malformed
  end

  defp project_record(_record, _owner_statuses), do: :malformed

  defp terminal_data(record, "done"), do: value(record, :result)

  defp terminal_data(record, state) when state in ["failed", "cancelled"],
    do: value(record, :error)

  defp terminal_data(_record, _state), do: nil

  defp maybe_put_outcome(task, state, terminal) when state in ["done", "failed", "cancelled"] do
    case TaskArtifacts.extract_outcome(terminal) do
      {:ok, outcome} -> Map.put(task, "outcome", outcome)
      :error -> task
    end
  end

  defp maybe_put_outcome(task, _state, _terminal), do: task

  defp matches?(task, filters) do
    matches_value?(Map.get(filters, :task_id), task["task_id"]) and
      matches_value?(Map.get(filters, :agent_id), task["agent_id"]) and
      matches_value?(state_filter(Map.get(filters, :state)), task["state"])
  end

  defp matches_value?(nil, _actual), do: true
  defp matches_value?(expected, actual), do: expected == actual

  defp control_counts(controls) do
    {closed, open} =
      controls
      |> Enum.take(@max_control_count)
      |> Enum.reduce({0, 0}, fn control, {closed, open} ->
        status = value(control, :status)

        if status in @closed_control_statuses do
          {closed + 1, open}
        else
          {closed, open + 1}
        end
      end)

    %{"closed" => closed, "open" => open}
  end

  defp evidence_present?(term),
    do:
      present_key?(term, [
        :evidence_ref,
        "evidence_ref",
        :evidence,
        "evidence",
        :task_evidence,
        "task_evidence",
        :adoption_evidence,
        "adoption_evidence"
      ])

  defp artifacts_present?(term), do: present_key?(term, [:artifacts, "artifacts"])

  defp present_key?(term, keys), do: present_key?(term, keys, 0)

  defp present_key?(_term, _keys, depth) when depth > 3, do: false

  defp present_key?(term, keys, depth) when is_map(term) and not is_struct(term) do
    direct? =
      Enum.any?(keys, fn key ->
        case Map.fetch(term, key) do
          {:ok, value} -> present_value?(value)
          :error -> false
        end
      end)

    direct? or
      Enum.any?(
        [
          :payload,
          "payload",
          :report,
          "report",
          :result,
          "result",
          :error,
          "error",
          :detail,
          "detail"
        ],
        fn key ->
          case Map.fetch(term, key) do
            {:ok, value} -> present_key?(value, keys, depth + 1)
            :error -> false
          end
        end
      )
  end

  defp present_key?(_term, _keys, _depth), do: false

  defp present_value?(nil), do: false
  defp present_value?(false), do: false
  defp present_value?(value) when is_binary(value), do: value != ""
  defp present_value?(value) when is_list(value), do: value != []
  defp present_value?(value) when is_map(value), do: map_size(value) > 0
  defp present_value?(_value), do: true

  defp required_string(record, key, max_bytes), do: required_string(value(record, key), max_bytes)

  defp required_string(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      :error
    end
  end

  defp required_string(_value, _max_bytes), do: :error

  defp optional_string(nil, _max_bytes), do: {:ok, nil}

  defp optional_string(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      :error
    end
  end

  defp optional_string(_value, _max_bytes), do: :error

  defp required_timestamp(value) do
    case optional_timestamp(value) do
      {:ok, timestamp} when is_binary(timestamp) -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp optional_timestamp(nil), do: {:ok, nil}

  defp optional_timestamp(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp optional_timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    if String.valid?(value) and value != "" and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      :error
    end
  end

  defp optional_timestamp(_value), do: :error

  defp closed_state(value) when is_atom(value) do
    state = Atom.to_string(value)
    if state in @states, do: {:ok, state}, else: :error
  end

  defp closed_state(value) when is_binary(value),
    do: if(value in @states, do: {:ok, value}, else: :error)

  defp closed_state(_value), do: :error

  defp state_filter(nil), do: nil
  defp state_filter(value) when is_atom(value), do: Atom.to_string(value)
  defp state_filter(value), do: value

  defp value(term, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_term, _key, default), do: default

  defp invalid_inventory do
    %{
      "schema_version" => @schema_version,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "agent_id" => nil, "state" => nil},
      "max_items" => 0,
      "truncated" => true,
      "counts" => %{
        "observed" => 0,
        "matching" => 0,
        "returned" => 0,
        "filtered_out" => 0,
        "truncated" => 0,
        "malformed" => 1
      },
      "tasks" => []
    }
  end
end
