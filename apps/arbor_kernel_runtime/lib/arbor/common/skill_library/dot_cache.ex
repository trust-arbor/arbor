defmodule Arbor.Common.SkillLibrary.DotCache do
  @moduledoc """
  Content-hash-based cache for JIT-compiled DOT graphs.

  Stores compiled DOT files alongside their source SKILL.md files.
  Uses a header comment with source and compiled-content hashes to detect
  staleness or cache-file tampering. Cache names are restricted to valid skill
  identifiers and always resolve below `.arbor/skills`.

  ## Cache Layout

  For a skill at `.arbor/skills/efficiency/SKILL.md`, the compiled DOT
  is stored at `.arbor/skills/efficiency/COMPILED.dot` with a header:

      // arbor:source_hash=<sha256> dot_hash=<sha256> compiled_at=2026-02-17T00:00:00Z
      digraph efficiency {
        ...
      }

  ## Usage

      # Check if cache is stale
      DotCache.stale?("efficiency", "abc123...")

      # Get cached DOT path
      {:ok, path} = DotCache.get("efficiency", "abc123...")

      # Store compiled DOT
      {:ok, path} = DotCache.put("efficiency", "abc123...", dot_content)
  """

  alias Arbor.Common.SafePath

  @compiled_filename "COMPILED.dot"
  @skill_name_pattern ~r/\A[a-z0-9][a-z0-9\-]{0,63}\z/
  @hash_pattern ~r/\A[0-9a-f]{64}\z/

  @doc """
  Get the path to the cached DOT file for a skill.

  Returns `{:ok, path}` if the cache exists and hash matches,
  `{:error, :not_found}` otherwise.
  """
  @spec get(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :stale | :unsafe_cache_path}
  def get(skill_name, content_hash) do
    with :ok <- validate_cache_key(skill_name, content_hash),
         {:ok, root} <- cache_root(false),
         {:ok, dir} <- find_skill_dir(root, skill_name),
         dot_path = Path.join(dir, @compiled_filename),
         {:ok, content} <- read_cache_file(dot_path, root) do
      if valid_cache_content?(content, content_hash) do
        {:ok, dot_path}
      else
        {:error, :stale}
      end
    else
      {:error, :invalid_cache_key} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Store a compiled DOT graph in the cache.

  Writes the DOT content with a header comment containing the content hash
  and compilation timestamp.
  """
  @spec put(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def put(skill_name, content_hash, dot_content) do
    with :ok <- validate_cache_key(skill_name, content_hash),
         true <- is_binary(dot_content),
         {:ok, root} <- cache_root(true),
         {:ok, dir} <- find_or_create_skill_dir(root, skill_name) do
      dot_path = Path.join(dir, @compiled_filename)
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      dot_hash = sha256(dot_content)

      header =
        "// arbor:source_hash=#{content_hash} dot_hash=#{dot_hash} compiled_at=#{timestamp}\n"

      content = header <> dot_content

      with :ok <- require_safe_destination(dot_path),
           :ok <- atomic_write_cache(dot_path, dir, root, content) do
        {:ok, dot_path}
      end
    else
      false -> {:error, :invalid_dot_content}
      {:error, _} = error -> error
    end
  end

  @doc """
  Check if the cached DOT for a skill is stale (hash mismatch or missing).
  """
  @spec stale?(String.t(), String.t()) :: boolean()
  def stale?(skill_name, content_hash) do
    case get(skill_name, content_hash) do
      {:ok, _} -> false
      _ -> true
    end
  end

  # -- Private ----------------------------------------------------------------

  # This legacy cache is intentionally confined to its own fixed root. Every
  # existing path component must be a real directory rather than a symlink.
  defp cache_root(create?) do
    with {:ok, cwd} <- SafePath.resolve_real(File.cwd!()),
         :ok <- require_directory(cwd),
         arbor_dir = Path.join(cwd, ".arbor"),
         :ok <- ensure_directory(arbor_dir, create?),
         root = Path.join(arbor_dir, "skills"),
         :ok <- ensure_directory(root, create?) do
      {:ok, root}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unsafe_cache_path}
    end
  end

  defp find_skill_dir(root, skill_name) do
    dir = cache_dir(root, skill_name)

    case require_directory(dir) do
      :ok -> {:ok, dir}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unsafe_cache_path}
    end
  end

  defp find_or_create_skill_dir(root, skill_name) do
    dir = cache_dir(root, skill_name)

    case ensure_directory(dir, true) do
      :ok -> {:ok, dir}
      {:error, _reason} -> {:error, :unsafe_cache_path}
    end
  end

  defp cache_dir(root, skill_name), do: Path.join(root, skill_name)

  defp ensure_directory(path, false), do: require_directory(path)

  defp ensure_directory(path, true) do
    case :file.read_link_info(path) do
      {:ok, info} ->
        require_directory_info(info)

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> require_directory(path)
          {:error, :eexist} -> require_directory(path)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_directory(path) do
    case :file.read_link_info(path) do
      {:ok, info} -> require_directory_info(info)
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_directory_info(
         {:file_info, _size, :directory, _access, _atime, _mtime, _ctime, _mode, _links, _major,
          _minor, _inode, _uid, _gid}
       ),
       do: :ok

  defp require_directory_info(_info), do: {:error, :not_directory}

  defp validate_cache_key(skill_name, content_hash)
       when is_binary(skill_name) and is_binary(content_hash) do
    if Regex.match?(@skill_name_pattern, skill_name) and
         Regex.match?(@hash_pattern, content_hash) do
      :ok
    else
      {:error, :invalid_cache_key}
    end
  end

  defp validate_cache_key(_, _), do: {:error, :invalid_cache_key}

  defp read_cache_file(dot_path, root) do
    with {:ok, info} <- :file.read_link_info(dot_path),
         :ok <- require_regular_info(info),
         {:ok, content, ^dot_path} <- SafePath.read_within(dot_path, root) do
      {:ok, content}
    else
      {:error, :enoent} ->
        {:error, :not_found}

      {:ok, _content, _different_path} ->
        {:error, :unsafe_cache_path}

      {:error, reason} when reason in [:path_traversal, :path_changed, :not_regular] ->
        {:error, :unsafe_cache_path}

      {:error, _reason} ->
        {:error, :stale}
    end
  end

  defp valid_cache_content?(content, expected_source_hash) do
    case String.split(content, "\n", parts: 2) do
      [header, dot_content] ->
        case Regex.run(
               ~r/\A\/\/ arbor:source_hash=([0-9a-f]{64}) dot_hash=([0-9a-f]{64}) compiled_at=\S+\z/,
               header
             ) do
          [_, ^expected_source_hash, expected_dot_hash] ->
            secure_equal?(sha256(dot_content), expected_dot_hash)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp require_safe_destination(dot_path) do
    case :file.read_link_info(dot_path) do
      {:ok, info} -> require_regular_info(info)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
    |> case do
      :ok -> :ok
      {:error, _reason} -> {:error, :unsafe_cache_path}
    end
  end

  defp require_regular_info(
         {:file_info, _size, :regular, _access, _atime, _mtime, _ctime, _mode, _links, _major,
          _minor, _inode, _uid, _gid}
       ),
       do: :ok

  defp require_regular_info(_info), do: {:error, :not_regular}

  defp atomic_write_cache(dot_path, dir, root, content) do
    temp_path =
      Path.join(
        dir,
        ".#{@compiled_filename}.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.tmp"
      )

    result =
      with :ok <- require_directory(dir),
           {:ok, io_device} <- File.open(temp_path, [:write, :binary, :raw, :exclusive]) do
        write_verified_temp(io_device, temp_path, dot_path, dir, root, content)
      end

    if result != :ok, do: remove_verified_temp(temp_path, root)
    result
  end

  defp write_verified_temp(io_device, temp_path, dot_path, dir, root, content) do
    result =
      with {:ok, opened_info} <- :file.read_file_info(io_device),
           {:ok, current_info} <- :file.read_link_info(temp_path),
           true <- same_file_identity?(opened_info, current_info),
           :ok <- require_directory(dir),
           {:ok, ^temp_path} <- SafePath.resolve_within(temp_path, root),
           :ok <- :file.write(io_device, content),
           :ok <- :file.sync(io_device) do
        :ok
      else
        _unsafe_or_failed -> {:error, :unsafe_cache_path}
      end

    :ok = File.close(io_device)

    with :ok <- result,
         :ok <- require_directory(dir),
         :ok <- require_safe_destination(dot_path),
         {:ok, written, ^temp_path} <- SafePath.read_within(temp_path, root),
         true <- secure_equal?(written, content),
         :ok <- File.rename(temp_path, dot_path),
         {:ok, ^content} <- verify_written_cache(dot_path, root) do
      :ok
    else
      _unsafe_or_failed -> {:error, :unsafe_cache_path}
    end
  end

  defp verify_written_cache(dot_path, root) do
    with {:ok, info} <- :file.read_link_info(dot_path),
         :ok <- require_regular_info(info),
         {:ok, content, ^dot_path} <- SafePath.read_within(dot_path, root) do
      {:ok, content}
    else
      _unsafe_or_failed -> {:error, :unsafe_cache_path}
    end
  end

  defp remove_verified_temp(temp_path, root) do
    with {:ok, _content, ^temp_path} <- SafePath.read_within(temp_path, root) do
      File.rm(temp_path)
    else
      _ -> :ok
    end

    :ok
  end

  defp same_file_identity?(
         {:file_info, _size_a, type, _access_a, _atime_a, _mtime_a, _ctime_a, _mode_a, _links_a,
          major, minor, inode, _uid_a, _gid_a},
         {:file_info, _size_b, type, _access_b, _atime_b, _mtime_b, _ctime_b, _mode_b, _links_b,
          major, minor, inode, _uid_b, _gid_b}
       ),
       do: true

  defp same_file_identity?(_left, _right), do: false

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false
end
