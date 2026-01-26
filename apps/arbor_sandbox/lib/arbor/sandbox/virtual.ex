defmodule Arbor.Sandbox.Virtual do
  @moduledoc """
  Virtual filesystem sandbox using jido_sandbox.

  Provides an in-memory filesystem for preview/dry-run operations
  with snapshot and restore capabilities.
  """

  @doc """
  Create a new virtual filesystem.
  """
  @spec create(keyword()) :: {:ok, map()}
  def create(_opts \\ []) do
    sandbox = JidoSandbox.new()
    {:ok, %{vfs: sandbox, snapshots: %{}}}
  end

  @doc """
  Write content to a path in the virtual filesystem.
  """
  @spec write(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def write(%{vfs: vfs} = state, path, content) do
    case JidoSandbox.write(vfs, path, content) do
      {:ok, new_vfs} -> {:ok, %{state | vfs: new_vfs}}
      error -> error
    end
  end

  @doc """
  Read content from a path in the virtual filesystem.
  """
  @spec read(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(%{vfs: vfs}, path) do
    JidoSandbox.read(vfs, path)
  end

  @doc """
  Delete a file from the virtual filesystem.
  """
  @spec delete(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(%{vfs: vfs} = state, path) do
    case JidoSandbox.delete(vfs, path) do
      {:ok, new_vfs} -> {:ok, %{state | vfs: new_vfs}}
      error -> error
    end
  end

  @doc """
  List files in a directory.
  """
  @spec list(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(%{vfs: vfs}, path) do
    JidoSandbox.list(vfs, path)
  end

  @doc """
  Check if a path exists.
  """
  @spec exists?(map(), String.t()) :: boolean()
  def exists?(%{vfs: vfs}, path) do
    case JidoSandbox.read(vfs, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Create a snapshot of the current state.
  """
  @spec snapshot(map()) :: {:ok, String.t(), map()}
  def snapshot(%{vfs: vfs} = state) do
    case JidoSandbox.snapshot(vfs) do
      {:ok, snapshot_id, new_vfs} ->
        {:ok, snapshot_id, %{state | vfs: new_vfs}}

      error ->
        error
    end
  end

  @doc """
  Restore from a snapshot.
  """
  @spec restore(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore(%{vfs: vfs} = state, snapshot_id) do
    case JidoSandbox.restore(vfs, snapshot_id) do
      {:ok, new_vfs} -> {:ok, %{state | vfs: new_vfs}}
      error -> error
    end
  end

  @doc """
  Execute Lua code with VFS access.
  """
  @spec eval_lua(map(), String.t()) :: {:ok, term(), map()} | {:error, term(), map()}
  def eval_lua(%{vfs: vfs} = state, code) do
    case JidoSandbox.eval_lua(vfs, code) do
      {:ok, result, new_vfs} -> {:ok, result, %{state | vfs: new_vfs}}
      {:error, reason, new_vfs} -> {:error, reason, %{state | vfs: new_vfs}}
    end
  end
end
