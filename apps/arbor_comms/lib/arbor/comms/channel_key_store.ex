defmodule Arbor.Comms.ChannelKeyStore do
  @moduledoc """
  ETS-backed store for sealed channel encryption keys.

  Stores sealed (ECDH-encrypted) copies of symmetric channel keys,
  keyed by `{channel_id, member_id}`. Used during channel restore
  to recover encryption keys for returning members.

  This is a simple in-process store — no GenServer needed. Backed
  by an ETS table created lazily on first use.
  """

  @table :arbor_channel_keys

  @doc """
  Store a sealed key for a member in a channel.
  """
  @spec put(String.t(), String.t(), map()) :: :ok
  def put(channel_id, member_id, sealed_key)
      when is_binary(channel_id) and is_binary(member_id) do
    ensure_table()
    :ets.insert(@table, {{channel_id, member_id}, sealed_key})
    :ok
  end

  @doc """
  Retrieve a sealed key for a member in a channel.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(channel_id, member_id) when is_binary(channel_id) and is_binary(member_id) do
    ensure_table()

    case :ets.lookup(@table, {channel_id, member_id}) do
      [{_, sealed_key}] -> {:ok, sealed_key}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Remove a sealed key for a member.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(channel_id, member_id) when is_binary(channel_id) and is_binary(member_id) do
    ensure_table()
    :ets.delete(@table, {channel_id, member_id})
    :ok
  end

  @doc """
  Remove all sealed keys for a channel.
  """
  @spec delete_channel(String.t()) :: :ok
  def delete_channel(channel_id) when is_binary(channel_id) do
    ensure_table()
    :ets.match_delete(@table, {{channel_id, :_}, :_})
    :ok
  end

  @doc """
  List all member IDs that have sealed keys for a channel.
  """
  @spec members_with_keys(String.t()) :: [String.t()]
  def members_with_keys(channel_id) when is_binary(channel_id) do
    ensure_table()

    :ets.match(@table, {{channel_id, :"$1"}, :_})
    |> Enum.map(fn [member_id] -> member_id end)
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
