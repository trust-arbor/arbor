defmodule Arbor.Monitor.Config.Testing do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ExUnit.Callbacks],
    exports: :all

  @namespace :monitor

  @spec snapshot_namespace() :: :error | {:ok, term()}
  def snapshot_namespace do
    Application.fetch_env(:arbor_kernel, @namespace)
  end

  @spec restore_namespace(:error | {:ok, term()}) :: :ok
  def restore_namespace({:ok, value}) do
    Application.put_env(:arbor_kernel, @namespace, value)
  end

  def restore_namespace(:error) do
    Application.delete_env(:arbor_kernel, @namespace)
  end

  @spec isolate_namespace() :: :ok
  def isolate_namespace do
    snapshot = snapshot_namespace()
    ExUnit.Callbacks.on_exit(fn -> restore_namespace(snapshot) end)
    :ok
  end

  @spec put(atom(), term()) :: :ok
  def put(key, value) when is_atom(key) do
    Application.put_env(:arbor_kernel, @namespace, put_key(fetch_namespace(), key, value))
  end

  @spec delete(atom()) :: :ok
  def delete(key) when is_atom(key) do
    case fetch_namespace() do
      :error ->
        :ok

      {:ok, config} ->
        Application.put_env(:arbor_kernel, @namespace, delete_key(config, key))
    end
  end

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    case fetch_namespace() do
      :error -> default
      {:ok, config} -> fetch_key(config, key, default)
    end
  end

  defp fetch_namespace, do: Application.fetch_env(:arbor_kernel, @namespace)

  defp put_key(:error, key, value), do: [{key, value}]

  defp put_key({:ok, config}, key, value) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.put(config, key, value)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp put_key({:ok, %{} = config}, key, value) do
    if Map.has_key?(config, :__struct__) do
      raise ArgumentError, malformed_namespace_message()
    else
      Map.put(config, key, value)
    end
  end

  defp put_key({:ok, _config}, _key, _value) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp delete_key(config, key) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.delete(config, key)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp delete_key(%{} = config, key) do
    if Map.has_key?(config, :__struct__) do
      raise ArgumentError, malformed_namespace_message()
    else
      Map.delete(config, key)
    end
  end

  defp delete_key(_config, _key) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp fetch_key(config, key, default) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.get(config, key, default)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp fetch_key(%{} = config, key, default) do
    if Map.has_key?(config, :__struct__) do
      raise ArgumentError, malformed_namespace_message()
    else
      Map.get(config, key, default)
    end
  end

  defp fetch_key(_config, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp malformed_namespace_message do
    "Config.Testing malformed :arbor_kernel :monitor namespace"
  end
end
