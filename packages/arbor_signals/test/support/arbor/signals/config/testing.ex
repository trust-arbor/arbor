defmodule Arbor.Signals.Config.Testing do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ExUnit.Callbacks],
    exports: :all

  @app :arbor_signals

  @spec snapshot_namespace() :: keyword()
  def snapshot_namespace, do: Application.get_all_env(@app)

  @spec restore_namespace(keyword()) :: :ok
  def restore_namespace(snapshot) when is_list(snapshot) do
    if Keyword.keyword?(snapshot) do
      for {key, _value} <- Application.get_all_env(@app), do: Application.delete_env(@app, key)
      for {key, value} <- snapshot, do: Application.put_env(@app, key, value)
      :ok
    else
      raise ArgumentError, "Signals test configuration must be a keyword list"
    end
  end

  @spec isolate_namespace() :: :ok
  def isolate_namespace do
    snapshot = snapshot_namespace()
    ExUnit.Callbacks.on_exit(fn -> restore_namespace(snapshot) end)
    :ok
  end

  @spec put(atom(), term()) :: :ok
  def put(key, value) when is_atom(key), do: Application.put_env(@app, key, value)

  @spec delete(atom()) :: :ok
  def delete(key) when is_atom(key), do: Application.delete_env(@app, key)

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key), do: Application.get_env(@app, key, default)
end
