defmodule Arbor.LLM.OAuth.Storage.File do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Storage

  alias Arbor.LLM.OAuth.Storage

  @impl true
  def fetch(key) when key in [:openai, :xai] do
    path = Storage.plaintext_path(key)

    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, {:token_file_unreadable, :enoent}}
      {:error, reason} -> {:error, {:token_file_unreadable, reason}}
    end
  end

  @impl true
  def store(key, json) when key in [:openai, :xai] and is_binary(json) do
    atomic_write(key, Storage.plaintext_path(key), json)
  end

  @doc false
  def atomic_write(key, path, json)
      when key in [:openai, :xai] and is_binary(path) and is_binary(json) do
    dir = Path.dirname(path)

    with :ok <- ensure_store_dir(dir),
         {:ok, tmp} <- create_temp_path(dir, key),
         :ok <- write_temp_token_file(tmp, json) do
      case perform_rename(tmp, path) do
        :ok ->
          case post_rename_finalize(dir, path) do
            :ok -> :ok
            {:error, inner} -> {:error, {:token_store_post_commit_failed, inner}}
          end

        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, {:token_store_write_failed, reason}}
      end
    end
  end

  @doc false
  def delete_plaintext(key) when key in [:openai, :xai] do
    path = Storage.plaintext_path(key)

    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        _ = scrub_regular_file(path)

        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, {:plaintext_token_file_not_removed, reason}}
        end

      {:error, :enoent} ->
        :ok

      {:ok, %{type: other}} ->
        {:error, {:plaintext_token_file_not_removed, {:not_regular, other}}}

      {:error, reason} ->
        {:error, {:plaintext_token_file_not_removed, reason}}
    end
  end

  # Test seam: Application env `:oauth_rename_fun` (arity 2) replaces the rename
  # call so tests can force a deterministic pre-commit failure. Production never
  # sets this; real behavior is File.rename/2.
  defp perform_rename(tmp, path) do
    case Application.get_env(:arbor_llm, :oauth_rename_fun) do
      fun when is_function(fun, 2) -> fun.(tmp, path)
      _ -> File.rename(tmp, path)
    end
  end

  defp post_rename_finalize(dir, path) do
    with :ok <- fsync_directory(dir), :ok <- ensure_final_mode(path), do: :ok
  end

  # Test seam: Application env `:oauth_fsync_dir_fun` (arity 1) replaces the raw
  # directory-sync step so tests can force a deterministic post-commit failure.
  # Production never sets this; real behavior is do_fsync_directory/1.
  defp fsync_directory(dir) do
    result =
      case Application.get_env(:arbor_llm, :oauth_fsync_dir_fun) do
        fun when is_function(fun, 1) -> fun.(dir)
        _ -> do_fsync_directory(dir)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:token_store_write_failed, reason}}
    end
  end

  defp do_fsync_directory(dir) when is_binary(dir) do
    case :file.open(dir, [:raw, :read, :directory]) do
      {:ok, io} ->
        try do
          case :file.sync(io) do
            :ok -> :ok
            {:error, reason} -> {:error, {:dir_fsync_failed, reason}}
          end
        after
          _ = close_io_silent(io)
        end

      {:error, reason} ->
        {:error, {:dir_open_failed, reason}}
    end
  end

  defp ensure_store_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        _ = File.chmod(dir, 0o700)
        :ok

      {:error, reason} ->
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp create_temp_path(dir, key) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp = Path.join(dir, ".#{key}.#{System.unique_integer([:positive])}.#{suffix}.tmp")
    {:ok, tmp}
  end

  defp write_temp_token_file(tmp, json) do
    case :file.open(tmp, [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- :file.change_mode(tmp, 0o600),
               :ok <- :file.write(io, json),
               :ok <- :file.sync(io),
               :ok <- :file.close(io) do
            :ok
          else
            {:error, reason} ->
              _ = close_io_silent(io)
              _ = File.rm(tmp)
              {:error, {:token_store_write_failed, reason}}
          end
        rescue
          e ->
            _ = close_io_silent(io)
            _ = File.rm(tmp)
            {:error, {:token_store_write_failed, Exception.message(e)}}
        catch
          kind, reason ->
            _ = close_io_silent(io)
            _ = File.rm(tmp)
            {:error, {:token_store_write_failed, {kind, reason}}}
        end

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp ensure_final_mode(path) do
    case File.chmod(path, 0o600) do
      :ok ->
        case File.stat(path) do
          {:ok, %{mode: mode}} when Bitwise.band(mode, 0o777) == 0o600 ->
            :ok

          {:ok, _} ->
            {:error, {:token_store_write_failed, :insecure_mode}}

          {:error, reason} ->
            {:error, {:token_store_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp close_io_silent(io) do
    try do
      :file.close(io)
    catch
      _, _ -> :ok
    end
  end

  defp scrub_regular_file(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 and size <= 1_048_576 ->
        zeros = :binary.copy(<<0>>, size)

        case :file.open(path, [:raw, :binary, :write]) do
          {:ok, io} ->
            _ = :file.write(io, zeros)
            _ = :file.sync(io)
            _ = :file.close(io)
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
