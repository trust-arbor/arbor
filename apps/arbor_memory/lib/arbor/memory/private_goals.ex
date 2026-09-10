defmodule Arbor.Memory.PrivateGoals do
  @moduledoc false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{Config, MemoryStore, MutationAdmission, TokenBudget}
  alias Arbor.Memory.Cores.PrivateGoalCore, as: Core

  def put(admission, goal_id, attrs) do
    with {:ok, scope} <- authorize(admission, :write),
         :ok <- MemoryStore.require_node_restart_authority(),
         {:ok, lease} <- MutationAdmission.acquire(scope.agent_id) do
      try do
        put_admitted(admission, scope, goal_id, attrs)
      after
        MutationAdmission.release(lease)
      end
    end
  end

  def active(admission) do
    with {:ok, scope} <- authorize(admission, :read),
         :ok <- MemoryStore.require_node_restart_authority(),
         {:ok, key} <- Core.key(scope),
         {:ok, goals, _expected} <- load(key, scope),
         {:ok, ^scope} <- authorize(admission, :read) do
      {:ok, Core.active(goals)}
    else
      {:ok, _changed_scope} -> {:error, :invalid_memory_admission}
      error -> error
    end
  end

  def context(admission, model) when is_binary(model) do
    with {:ok, goals} <- active(admission) do
      text =
        Enum.map_join(goals, "\n", fn goal ->
          "- #{goal["description"]} (priority #{goal["priority"]}, progress #{goal["progress"]})"
        end)

      section = if text == "", do: "", else: "## Private goals\n" <> text
      size = TokenBudget.model_context_size(model)
      {:ok, TokenBudget.truncate(section, {:min_max, 200, 4000, 0.05}, size)}
    end
  end

  def context(_, _), do: {:error, :invalid_private_goal_request}

  defp put_admitted(admission, scope, goal_id, attrs) do
    with {:ok, key} <- Core.key(scope),
         {:ok, goals, expected} <- load(key, scope),
         {:ok, body} <- Core.put(goals, scope, goal_id, attrs, Core.next_revision(expected)),
         {:ok, descriptor} <- Core.descriptor(body, key),
         {:ok, stamp} <- security(:attest_private_goal_snapshot, [admission, descriptor]),
         body <- Map.put(body, "owner_stamp", stamp),
         :ok <- Core.admit_body(body),
         {:ok, ^scope} <- authorize(admission, :write) do
      commit(key, expected, body, descriptor, goal_id)
    else
      {:ok, _changed_scope} -> {:error, :invalid_memory_admission}
      error -> error
    end
  end

  defp commit(key, expected, body, descriptor, goal_id) do
    case MemoryStore.compare_and_swap_tainted(Core.namespace(), key, expected, body,
           taint: TaintEnvelope.missing_fallback()
         ) do
      {:ok, %Record{data: ^body} = record} ->
        with {:ok, ^descriptor} <- Core.record_descriptor(record),
             :ok <- security(:verify_private_goal_snapshot, [descriptor, body["owner_stamp"]]) do
          {:ok, goal_id}
        else
          _ -> {:error, :outcome_unknown}
        end

      {:error, {:memory_store, :critical, :outcome_unknown}} ->
        {:error, :outcome_unknown}

      {:error, _} = error ->
        error

      _ ->
        {:error, :outcome_unknown}
    end
  end

  defp load(key, scope) do
    case MemoryStore.load_tainted_authoritative_with_status(Core.namespace(), key) do
      {:ok, %TaintedValue{value: body, taint: taint}, :verified, %Record{data: body} = record,
       :namespaced} ->
        with true <- taint == TaintEnvelope.missing_fallback(),
             :ok <- verify_record(record),
             true <- Core.same_pair?(body, scope) do
          {:ok, body["goals"], record}
        else
          _ -> {:error, :invalid_private_goal_snapshot}
        end

      {:error, :not_found} ->
        {:ok, [], :not_found}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_private_goal_snapshot}
    end
  end

  @doc false
  def verify_record(record) do
    with {:ok, descriptor} <- Core.record_descriptor(record),
         do: security(:verify_private_goal_snapshot, [descriptor, record.data["owner_stamp"]])
  end

  defp authorize(admission, operation),
    do: security(:authorize_private_memory_turn, [admission, operation])

  # Called only by the existing GoalStore destruction/absence owner. Every row
  # is verified before selecting an agent; metadata labels never select data
  # for deletion. CAS deletion retains the exact verified Record fence.
  @doc false
  def inventory(agent_id) do
    with {:ok, rows} <- MemoryStore.load_all_tainted_authoritative(Core.namespace()),
         {:ok, verified} <- verify_inventory(rows) do
      {:ok,
       Enum.filter(verified, fn {_key, record} -> record.data["scope"]["agent_id"] == agent_id end)}
    end
  end

  @doc false
  def delete_inventory(records) do
    Enum.reduce_while(records, :ok, fn {key, record}, :ok ->
      case MemoryStore.compare_and_delete_tainted(Core.namespace(), key, record) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_inventory(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      {key, %TaintedValue{}, :verified}, {:ok, acc} ->
        case MemoryStore.load_tainted_authoritative_with_status(Core.namespace(), key) do
          {:ok, %TaintedValue{taint: taint}, :verified, %Record{} = record, :namespaced} ->
            result =
              if taint == TaintEnvelope.missing_fallback(),
                do: verify_record(record),
                else: {:error, :invalid_private_goal_snapshot}

            case result do
              :ok -> {:cont, {:ok, [{key, record} | acc]}}
              error -> {:halt, error}
            end

          _ ->
            {:halt, {:error, :invalid_private_goal_snapshot}}
        end

      _, _ ->
        {:halt, {:error, :invalid_private_goal_snapshot}}
    end)
  end

  defp security(function, args) do
    apply(Config.private_memory_security(), function, args)
  rescue
    _ -> {:error, :private_goal_authority_unavailable}
  catch
    _, _ -> {:error, :private_goal_authority_unavailable}
  end
end
