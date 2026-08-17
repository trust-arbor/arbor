defmodule Arbor.Common.Extension.RegistryCore do
  @moduledoc false

  # Pure protected-registry machine. No ETS, Process, or Application
  # access. Published entries are closed handle maps — never module
  # atoms or PIDs. Staged names are invisible until commit.

  @type state :: %{
          core_locked?: boolean(),
          core_names: MapSet.t(),
          published: map(),
          staged: map() | nil,
          consumed_nonces: MapSet.t()
        }

  @spec new() :: state()
  def new do
    %{
      core_locked?: false,
      core_names: MapSet.new(),
      published: %{},
      staged: nil,
      consumed_nonces: MapSet.new()
    }
  end

  @spec lock_core(state()) :: state()
  def lock_core(state), do: %{state | core_locked?: true}

  @spec mark_core(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  def mark_core(%{core_locked?: true}, _name), do: {:error, "commit_conflict"}

  def mark_core(state, name) when is_binary(name) do
    {:ok, %{state | core_names: MapSet.put(state.core_names, name)}}
  end

  def mark_core(_state, _name), do: {:error, "malformed"}

  @spec stage(state(), map(), map(), String.t(), String.t()) ::
          {:ok, state()} | {:error, String.t()}
  def stage(%{staged: staged}, _transaction, _handle, _owner_id, _now) when is_map(staged) do
    {:error, "commit_conflict"}
  end

  def stage(state, transaction, handle, owner_id, now)
      when is_map(transaction) and is_map(handle) and is_binary(owner_id) and is_binary(now) do
    name = handle["protocol_id"]

    cond do
      not is_binary(name) ->
        {:error, "malformed"}

      forbidden_identity?(handle) ->
        {:error, "malformed"}

      core_blocked?(state, name) ->
        {:error, "commit_conflict"}

      true ->
        {:ok,
         %{
           state
           | staged: %{
               "transaction_id" => transaction["transaction_id"],
               "name" => name,
               "handle" => handle,
               "owner_id" => owner_id,
               "generation" => handle["generation"],
               "lease_id" => handle["lease_id"],
               "lease_expires_at" => handle["lease_expires_at"]
             }
         }}
    end
  end

  def stage(_state, _transaction, _handle, _owner_id, _now), do: {:error, "malformed"}

  @spec publish(state(), map(), String.t()) :: {:ok, state()} | {:error, String.t()}
  def publish(%{staged: staged} = state, receipt, now)
      when is_map(staged) and is_map(receipt) and is_binary(now) do
    cond do
      receipt["transaction_id"] != staged["transaction_id"] ->
        {:error, "transaction_mismatch"}

      receipt["state"] != "committed" ->
        {:error, "not_ready"}

      staged["lease_expires_at"] < now ->
        {:error, "expired_lease"}

      core_blocked?(state, staged["name"]) ->
        {:error, "commit_conflict"}

      true ->
        entry = %{
          "name" => staged["name"],
          "handle" => staged["handle"],
          "generation" => staged["generation"],
          "lease_id" => staged["lease_id"],
          "lease_expires_at" => staged["lease_expires_at"],
          "owner_id" => staged["owner_id"],
          "core" => MapSet.member?(state.core_names, staged["name"]),
          "receipt_state" => receipt["state"]
        }

        {:ok, %{state | staged: nil, published: Map.put(state.published, staged["name"], entry)}}
    end
  end

  def publish(_state, _receipt, _now), do: {:error, "not_ready"}

  @spec rollback(state()) :: {:ok, state()} | {:error, String.t()}
  def rollback(%{staged: staged} = state) when is_map(staged) do
    {:ok, %{state | staged: nil}}
  end

  def rollback(_state), do: {:error, "not_ready"}

  @spec consume_nonce(state(), String.t()) :: state()
  def consume_nonce(state, nonce) when is_binary(nonce) do
    %{state | consumed_nonces: MapSet.put(state.consumed_nonces, nonce)}
  end

  @spec resolve(state(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def resolve(state, name, now) when is_binary(name) and is_binary(now) do
    case Map.get(state.published, name) do
      nil ->
        {:error, "no_compatible_provider"}

      %{"lease_expires_at" => expiry} = entry ->
        if expiry < now do
          {:error, "expired_lease"}
        else
          {:ok, entry}
        end
    end
  end

  def resolve(_state, _name, _now), do: {:error, "malformed"}

  @spec list_published(state(), String.t()) :: [map()]
  def list_published(state, now) when is_binary(now) do
    state.published
    |> Map.values()
    |> Enum.filter(fn entry -> entry["lease_expires_at"] >= now end)
    |> Enum.sort_by(& &1["name"])
  end

  @spec cleanup(state(), String.t(), keyword()) :: state()
  def cleanup(state, now, opts \\ []) when is_binary(now) and is_list(opts) do
    dead = Keyword.get(opts, :dead_owner_id)

    published =
      state.published
      |> Enum.reject(fn {_name, entry} ->
        entry["lease_expires_at"] < now or (is_binary(dead) and entry["owner_id"] == dead)
      end)
      |> Map.new()

    staged =
      case state.staged do
        %{"owner_id" => ^dead} when is_binary(dead) -> nil
        other -> other
      end

    %{state | published: published, staged: staged}
  end

  defp core_blocked?(%{core_locked?: true, core_names: names, published: published}, name) do
    MapSet.member?(names, name) and Map.has_key?(published, name)
  end

  defp core_blocked?(_state, _name), do: false

  defp forbidden_identity?(handle) do
    Enum.any?(["module", "pid", "node", "mfa"], &Map.has_key?(handle, &1))
  end
end
