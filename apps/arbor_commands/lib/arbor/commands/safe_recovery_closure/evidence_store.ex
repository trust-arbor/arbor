defmodule Arbor.Commands.SafeRecoveryClosure.EvidenceStore do
  @moduledoc false

  # The only writer for the committed E0B3 closure evidence file.
  # Destination is hardcoded; write/2 takes no path argument.

  alias Arbor.Common.SafePath

  @rel "apps/arbor_commands/priv/packaging/safe_recovery_closure.v1.json"
  @max_bytes 1_048_576

  @spec path() :: String.t()
  def path, do: @rel

  @spec write(String.t(), binary()) :: :ok | {:error, term()}
  def write(root, bytes) when is_binary(root) and is_binary(bytes) do
    cond do
      byte_size(bytes) < 1 ->
        {:error, :invalid_evidence}

      byte_size(bytes) > @max_bytes ->
        {:error, :evidence_unbounded}

      true ->
        publish(root, bytes)
    end
  end

  def write(_root, _bytes), do: {:error, :invalid_input}

  defp publish(root, bytes) do
    with {:ok, dest} <- join_within(root, @rel),
         :ok <- reject_existing_symlink(dest),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- reject_existing_symlink(dest),
         tmp <- dest <> ".tmp",
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, dest),
         {:ok, readback} <- File.read(dest),
         true <- readback == bytes do
      :ok
    else
      false -> {:error, :evidence_readback_mismatch}
      {:error, _} = error -> error
    end
  end

  defp join_within(root, rel) do
    case SafePath.safe_join(root, rel) do
      {:ok, lexical} ->
        if SafePath.within?(lexical, root), do: {:ok, lexical}, else: {:error, :path_escape}

      {:error, :path_traversal} ->
        {:error, :path_escape}

      error ->
        error
    end
  end

  defp reject_existing_symlink(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      {:ok, %{type: :symlink}} -> {:error, :evidence_symlink_redirection}
      {:ok, _} -> {:error, :evidence_not_regular}
      {:error, reason} -> {:error, {:evidence_unreadable, reason}}
    end
  end
end
