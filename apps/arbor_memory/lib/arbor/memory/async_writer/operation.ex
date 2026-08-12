defmodule Arbor.Memory.AsyncWriter.Operation do
  @moduledoc false

  alias Arbor.Memory.Config

  @type persist ::
          {:persist,
           %{
             agent_id: String.t(),
             namespace: String.t(),
             key: String.t(),
             data: term(),
             metadata: map()
           }}

  @type embed ::
          {:embed,
           %{
             agent_id: String.t(),
             namespace: String.t(),
             key: String.t(),
             content: String.t(),
             type: String.t() | nil,
             taint: term()
           }}

  @type t :: persist() | embed()

  @spec validate(term()) :: :ok | {:error, {:memory_store, :async_writer, :invalid_operation}}
  @persist_keys MapSet.new([:agent_id, :namespace, :key, :data, :metadata])
  @embed_keys MapSet.new([:agent_id, :namespace, :key, :content, :type, :taint])

  def validate({:persist, fields}) when is_map(fields) do
    with :ok <- require_exact_keys(fields, @persist_keys),
         :ok <- validate_agent_id(fields.agent_id),
         :ok <- require_binary(fields.namespace),
         :ok <- require_binary(fields.key),
         :ok <- require_plain_map(fields.metadata) do
      :ok
    else
      _ -> invalid()
    end
  end

  def validate({:embed, fields}) when is_map(fields) do
    with :ok <- require_exact_keys(fields, @embed_keys),
         :ok <- validate_agent_id(fields.agent_id),
         :ok <- require_binary(fields.namespace),
         :ok <- require_binary(fields.key),
         :ok <- require_nonempty_binary(fields.content),
         :ok <- require_normalized_type(fields.type) do
      :ok
    else
      _ -> invalid()
    end
  end

  def validate(_), do: invalid()

  @spec validate_agent_id(term()) :: :ok | :error
  def validate_agent_id(id) when is_binary(id) do
    max = Config.mutation_admission_max_agent_id_bytes()

    if byte_size(id) > 0 and byte_size(id) <= max and String.valid?(id) and
         String.trim(id) == id and String.trim(id) != "" do
      :ok
    else
      :error
    end
  end

  def validate_agent_id(_), do: :error

  @spec agent_id(t()) :: String.t()
  def agent_id({:persist, %{agent_id: agent_id}}), do: agent_id
  def agent_id({:embed, %{agent_id: agent_id}}), do: agent_id

  defp require_exact_keys(fields, allowed) do
    if MapSet.equal?(MapSet.new(Map.keys(fields)), allowed), do: :ok, else: :error
  end

  defp require_binary(value) when is_binary(value) and value != "", do: :ok
  defp require_binary(_), do: :error

  defp require_nonempty_binary(value) when is_binary(value) and value != "", do: :ok
  defp require_nonempty_binary(_), do: :error

  defp require_plain_map(value) when is_map(value) and not is_struct(value), do: :ok
  defp require_plain_map(_), do: :error

  defp require_normalized_type(nil), do: :ok
  defp require_normalized_type(type) when is_binary(type), do: :ok
  defp require_normalized_type(_), do: :error

  defp invalid, do: {:error, {:memory_store, :async_writer, :invalid_operation}}
end
