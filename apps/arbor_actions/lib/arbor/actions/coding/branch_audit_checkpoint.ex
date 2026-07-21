defmodule Arbor.Actions.Coding.BranchAuditCheckpoint do
  @moduledoc "Secure atomic file boundary for branch-audit checkpoints."

  alias Arbor.Actions.Coding.BranchAuditCheckpointCore, as: Core

  @mode 0o600

  @spec load(String.t(), map()) ::
          {:ok, map(), :hit | :missing | :stale} | {:error, term()}
  def load(path, expected_scope) when is_binary(path) and is_map(expected_scope) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, empty_from_scope(expected_scope), :missing}

      {:ok, %File.Stat{type: :regular, mode: mode, size: size}} ->
        with :ok <- secure_mode(mode),
             true <- size <= Core.max_bytes(),
             {:ok, bytes} <- File.read(path),
             {:ok, cache} <- Core.decode_json(bytes),
             :ok <- validate_scope_shape(cache, expected_scope) do
          if Core.scope_matches?(cache, expected_scope),
            do: {:ok, cache, :hit},
            else: {:ok, empty_from_scope(expected_scope), :stale}
        else
          false -> {:error, :checkpoint_size_exceeded}
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_branch_audit_checkpoint}
        end

      {:ok, _stat} ->
        {:error, :insecure_checkpoint_file}

      {:error, _reason} ->
        {:error, :checkpoint_unavailable}
    end
  end

  def load(_path, _expected_scope), do: {:error, :invalid_checkpoint_path}

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, cache) when is_binary(path) and is_map(cache) do
    with {:ok, bytes} <- Core.encode(cache),
         :ok <- check_destination(path),
         {:ok, temp_path} <- write_temp(path, bytes),
         :ok <- replace_destination(path, temp_path) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def write(_path, _cache), do: {:error, :invalid_checkpoint_path}

  defp empty_from_scope(scope) do
    Core.empty(scope["repository"], scope["destination"], %{})
  end

  defp validate_scope_shape(cache, expected_scope) do
    with :ok <- Core.validate(cache),
         true <-
           Core.scope_matches?(cache, expected_scope) or valid_stale_scope?(cache, expected_scope) do
      :ok
    else
      false -> {:error, :checkpoint_scope_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp valid_stale_scope?(cache, expected_scope) do
    cache["policy_version"] == expected_scope["policy_version"] and
      is_map(cache["repository"]) and is_map(cache["destination"])
  end

  defp check_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular, mode: mode}} -> secure_mode(mode)
      {:ok, _stat} -> {:error, :insecure_checkpoint_file}
      {:error, _reason} -> {:error, :checkpoint_unavailable}
    end
  end

  defp write_temp(path, bytes) do
    temp_path = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    case File.lstat(temp_path) do
      {:error, :enoent} ->
        case :file.open(String.to_charlist(temp_path), [:write, :exclusive, :binary]) do
          {:ok, io} ->
            result =
              with :ok <- File.chmod(temp_path, @mode),
                   :ok <- :file.write(io, bytes),
                   :ok <- :file.sync(io),
                   {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(temp_path),
                   :ok <- secure_mode(mode) do
                {:ok, temp_path}
              else
                {:error, _reason} = error -> error
                _other -> {:error, :checkpoint_write_failed}
              end

            _ = :file.close(io)

            case result do
              {:ok, _path} = ok ->
                ok

              {:error, _reason} = error ->
                _ = File.rm(temp_path)
                error
            end

          {:error, _reason} ->
            {:error, :checkpoint_write_failed}
        end

      {:ok, _stat} ->
        {:error, :checkpoint_temp_exists}

      {:error, _reason} ->
        {:error, :checkpoint_unavailable}
    end
  end

  defp replace_destination(path, temp_path) do
    with :ok <- check_destination(path),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(temp_path)
        error
    end
  end

  defp secure_mode(mode) when is_integer(mode) do
    if Bitwise.band(mode, 0o7777) == @mode,
      do: :ok,
      else: {:error, :insecure_checkpoint_permissions}
  end

  defp secure_mode(_mode), do: {:error, :insecure_checkpoint_permissions}
end
