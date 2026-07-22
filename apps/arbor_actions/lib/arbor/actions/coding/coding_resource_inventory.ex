defmodule Arbor.Actions.Coding.CodingResourceInventory do
  @moduledoc """
  Bounded, read-only coding resource inventory.

  The registry performs the projection while it owns the live state. This module
  only validates the small public option surface and selects the registry. No
  journal read or lifecycle operation is performed here.
  """

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: RetentionJournal

  @default_max_items 64
  @max_items RetentionJournal.max_records()
  @max_filter_bytes 256
  @allowed_keys [:server, :task_id, :principal_id, :max_items]

  @spec snapshot(keyword()) ::
          {:ok, map()} | {:error, :invalid_coding_resource_inventory_options | term()}
  def snapshot(opts \\ [])

  def snapshot(opts) when is_list(opts) do
    case normalize_options(opts) do
      {:ok, normalized} ->
        WorkspaceLeaseRegistry.reconciliation_inventory(
          normalized.task_id,
          normalized.principal_id,
          normalized.max_items,
          server: normalized.server
        )

      {:error, _reason} = error ->
        error
    end
  end

  def snapshot(_opts), do: {:error, :invalid_coding_resource_inventory_options}

  defp normalize_options(opts) do
    keys = Enum.map(opts, &option_key/1)

    cond do
      :invalid in keys ->
        {:error, :invalid_coding_resource_inventory_options}

      Enum.any?(keys, &(&1 not in @allowed_keys)) ->
        {:error, :invalid_coding_resource_inventory_options}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_coding_resource_inventory_options}

      true ->
        with {:ok, task_id} <- validate_filter(Keyword.get(opts, :task_id)),
             {:ok, principal_id} <- validate_filter(Keyword.get(opts, :principal_id)),
             {:ok, max_items} <- validate_max_items(Keyword.get(opts, :max_items)),
             :ok <- validate_server(Keyword.get(opts, :server, WorkspaceLeaseRegistry)) do
          {:ok,
           %{
             server: Keyword.get(opts, :server, WorkspaceLeaseRegistry),
             task_id: task_id,
             principal_id: principal_id,
             max_items: max_items
           }}
        else
          _ -> {:error, :invalid_coding_resource_inventory_options}
        end
    end
  end

  defp option_key({key, _value}) when is_atom(key), do: key
  defp option_key(_option), do: :invalid

  defp validate_filter(nil), do: {:ok, nil}

  defp validate_filter(value)
       when is_binary(value) and byte_size(value) <= @max_filter_bytes do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      {:error, :invalid_filter}
    end
  end

  defp validate_filter(_value), do: {:error, :invalid_filter}

  defp validate_max_items(nil), do: {:ok, @default_max_items}

  defp validate_max_items(value) when is_integer(value) and value > 0 and value <= @max_items,
    do: {:ok, value}

  defp validate_max_items(_value), do: {:error, :invalid_max_items}

  defp validate_server(server) when is_atom(server), do: :ok
  defp validate_server({:global, _name}), do: :ok
  defp validate_server({:via, registry, _name}) when is_atom(registry), do: :ok
  defp validate_server(_server), do: {:error, :invalid_server}
end
