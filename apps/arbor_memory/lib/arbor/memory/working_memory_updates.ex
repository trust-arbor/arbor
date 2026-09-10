defmodule Arbor.Memory.WorkingMemoryUpdates do
  @moduledoc false

  alias Arbor.Contracts.Security.TaintedValue
  alias Arbor.Memory.{WorkingMemory, WorkingMemoryStore}

  @fields [:memory_notes, :concerns, :curiosity]

  @type report :: %{
          updated: boolean(),
          applied_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          error_count: non_neg_integer(),
          errors: [map()]
        }

  @spec index_notes(String.t(), term()) :: {:ok, report()} | {:error, report()}
  def index_notes(agent_id, notes) when is_list(notes),
    do: apply_updates(agent_id, %{memory_notes: notes})

  def index_notes(agent_id, data) when is_map(data),
    do: apply_updates(agent_id, %{memory_notes: field_items(data, :memory_notes)})

  def index_notes(agent_id, nil), do: apply_updates(agent_id, %{})
  def index_notes(_agent_id, _data), do: failure(report(), 1, "input", :invalid_notes)

  @spec apply_updates(String.t(), map()) :: {:ok, report()} | {:error, report()}
  def apply_updates(agent_id, data) when is_map(data) do
    {items, skipped} = validated_items(data)
    result = %{report() | skipped_count: skipped}

    if items == [] do
      {:ok, result}
    else
      save_updates(agent_id, items, result)
    end
  end

  def apply_updates(_agent_id, _data), do: failure(report(), 1, "input", :invalid_updates)

  defp save_updates(agent_id, items, result) do
    case WorkingMemoryStore.load_working_memory_tainted(agent_id) do
      {:ok, %{value: %TaintedValue{value: %WorkingMemory{} = current}}} ->
        updated = Enum.reduce(items, current, &apply_item/2)
        save_changed(agent_id, current, updated, length(items), result)

      {:error, reason} ->
        failure(result, length(items), "load", reason)
    end
  end

  defp save_changed(_agent_id, current, current, count, result),
    do: {:ok, %{result | skipped_count: result.skipped_count + count}}

  defp save_changed(agent_id, _current, updated, count, result) do
    case WorkingMemoryStore.save_working_memory(agent_id, updated) do
      :ok -> {:ok, %{result | updated: true, applied_count: count}}
      {:error, reason} -> failure(result, count, "save", reason)
    end
  end

  defp validated_items(data) do
    {items, skipped} =
      Enum.reduce(@fields, {[], 0}, fn field, {items, skipped} ->
        Enum.reduce(field_items(data, field), {items, skipped}, &admit_item(field, &1, &2))
      end)

    {Enum.reverse(items), skipped}
  end

  defp admit_item(field, item, {items, skipped}) do
    case item_text(field, item) do
      text when is_binary(text) ->
        if String.trim(text) == "",
          do: {items, skipped + 1},
          else: {[{field, text} | items], skipped}

      _ ->
        {items, skipped + 1}
    end
  end

  defp field_items(data, field) do
    key = Atom.to_string(field)

    selected =
      Enum.find_value(["session." <> key, key, field], fn alias_key ->
        case Map.fetch(data, alias_key) do
          {:ok, nil} -> nil
          {:ok, value} -> {:present, value}
          :error -> nil
        end
      end)

    case selected do
      {:present, value} -> List.wrap(value)
      nil -> []
    end
  end

  defp item_text(_field, text) when is_binary(text), do: text
  defp item_text(:memory_notes, %{"text" => text}) when is_binary(text), do: text
  defp item_text(:memory_notes, %{text: text}) when is_binary(text), do: text
  defp item_text(_field, _item), do: nil

  defp apply_item({:memory_notes, text}, wm), do: WorkingMemory.add_thought(wm, text)
  defp apply_item({:concerns, text}, wm), do: WorkingMemory.add_concern(wm, text)
  defp apply_item({:curiosity, text}, wm), do: WorkingMemory.add_curiosity(wm, text)

  defp report,
    do: %{updated: false, applied_count: 0, skipped_count: 0, error_count: 0, errors: []}

  defp failure(result, count, stage, reason) do
    {:error,
     %{
       result
       | error_count: count,
         errors: [%{stage: stage, reason: inspect(reason, limit: 10, printable_limit: 256)}]
     }}
  end
end
