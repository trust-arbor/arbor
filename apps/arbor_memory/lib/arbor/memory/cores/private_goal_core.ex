defmodule Arbor.Memory.Cores.PrivateGoalCore do
  @moduledoc false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.TaintEnvelope

  @namespace "private_goals"
  @scope_keys ~w(agent_id human_id engagement_id session_id turn_id)
  @goal_keys ~w(id description priority progress status)
  @body_keys ~w(version snapshot_revision scope goals owner_stamp)
  @max_bytes 262_144
  @max_goals 50

  def namespace, do: @namespace

  def key(scope), do: digest([scope.agent_id, scope.human_id])

  def put(goals, scope, goal_id, attrs, revision) when is_map(attrs) do
    goal = Map.put(attrs, "id", goal_id)

    with true <- Enum.sort(Map.keys(attrs)) == ~w(description priority progress status),
         true <- valid_goal?(goal),
         true <- valid_goals?(goals),
         updated <- [goal | Enum.reject(goals, &(&1["id"] == goal_id))],
         true <- length(updated) <= @max_goals,
         body <- %{
           "version" => 1,
           "snapshot_revision" => revision,
           "scope" => Map.new(@scope_keys, &{&1, Map.fetch!(scope, scope_atom(&1))}),
           "goals" => Enum.sort_by(updated, & &1["id"])
         },
         :ok <- bounded(body) do
      {:ok, body}
    else
      _ -> {:error, :invalid_private_goal}
    end
  end

  def put(_, _, _, _, _), do: {:error, :invalid_private_goal}

  def admit_body(body) when is_map(body) do
    with true <- Enum.sort(Map.keys(body)) == Enum.sort(@body_keys),
         true <- body["version"] === 1,
         true <- valid_revision?(body["snapshot_revision"]),
         true <- valid_scope?(body["scope"]),
         true <- valid_goals?(body["goals"]),
         true <- is_map(body["owner_stamp"]),
         :ok <- bounded(body) do
      :ok
    else
      _ -> {:error, :invalid_private_goal_snapshot}
    end
  end

  def admit_body(_), do: {:error, :invalid_private_goal_snapshot}

  def descriptor(body, key) do
    with :ok <- bounded(body),
         {:ok, digest} <- digest(Map.delete(body, "owner_stamp")) do
      {:ok,
       Map.merge(body["scope"], %{
         "namespace" => @namespace,
         "key" => key,
         "id" => "memory:" <> @namespace <> ":" <> key,
         "body_digest" => digest,
         "snapshot_revision" => body["snapshot_revision"]
       })}
    end
  end

  def record_descriptor(%Record{data: body, key: physical, id: id} = record) do
    with :ok <- admit_body(body),
         scope <- body["scope"],
         {:ok, key} <- digest([scope["agent_id"], scope["human_id"]]),
         true <- physical == @namespace <> ":" <> key,
         true <- id == "memory:" <> physical,
         true <- is_integer(record.generation) and record.generation > 0,
         true <- is_integer(record.revision) and record.revision > 0 do
      descriptor(body, key)
    else
      _ -> {:error, :invalid_private_goal_snapshot}
    end
  end

  def record_descriptor(_), do: {:error, :invalid_private_goal_snapshot}

  def same_pair?(body, scope) do
    body["scope"]["agent_id"] == scope.agent_id and
      body["scope"]["human_id"] == scope.human_id
  end

  def next_revision(:not_found), do: 1
  def next_revision(%Record{} = record), do: record.data["snapshot_revision"] + 1

  def active(goals) do
    goals
    |> Enum.filter(&(&1["status"] == "active"))
    |> Enum.sort_by(&{-&1["priority"], &1["id"]})
  end

  def bounded(body) do
    case TaintEnvelope.canonical_json(body) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> :ok
      _ -> {:error, :private_goal_snapshot_too_large}
    end
  end

  defp valid_scope?(scope) when is_map(scope) do
    Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys) and
      Enum.all?(scope, fn {_key, value} -> label?(value) end)
  end

  defp valid_scope?(_), do: false

  defp valid_goals?(goals) when is_list(goals) and length(goals) <= @max_goals do
    Enum.all?(goals, &valid_goal?/1) and
      length(Enum.uniq_by(goals, & &1["id"])) == length(goals)
  end

  defp valid_goals?(_), do: false

  defp valid_goal?(goal) when is_map(goal) do
    Enum.sort(Map.keys(goal)) == Enum.sort(@goal_keys) and id?(goal["id"]) and
      description?(goal["description"]) and is_integer(goal["priority"]) and
      goal["priority"] in 0..100 and is_number(goal["progress"]) and
      goal["progress"] >= 0 and goal["progress"] <= 1 and
      goal["status"] in ["active", "achieved", "abandoned"]
  end

  defp valid_goal?(_), do: false
  defp id?(id) when is_binary(id), do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, id)
  defp id?(_), do: false

  defp description?(value) when is_binary(value),
    do: byte_size(value) in 1..4096 and String.valid?(value) and String.trim(value) != ""

  defp description?(_), do: false

  defp label?(value) when is_binary(value),
    do: byte_size(value) in 1..256 and String.valid?(value) and String.trim(value) == value

  defp label?(_), do: false

  defp valid_revision?(value),
    do: is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807

  defp digest(value) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(value),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp scope_atom("agent_id"), do: :agent_id
  defp scope_atom("human_id"), do: :human_id
  defp scope_atom("engagement_id"), do: :engagement_id
  defp scope_atom("session_id"), do: :session_id
  defp scope_atom("turn_id"), do: :turn_id
end
