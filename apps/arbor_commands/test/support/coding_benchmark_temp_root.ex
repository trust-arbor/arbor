defmodule Arbor.Commands.CodingBenchmarkTempRoot do
  @moduledoc false

  # Exclusive test roots for coding-benchmark suites.
  #
  # Roots live under a fixed child of `System.tmp_dir!/0` so Apple Container
  # guests (with TMPDIR on the real /tmp tmpfs) and host runs both stay out of
  # worktree-local `.tmp/` residue that can survive a killed validation and be
  # reopened by a later BEAM after `System.unique_integer/1` restarts.

  alias Arbor.Common.SafePath

  @parent_component "arbor-coding-benchmark-tests"
  @max_prefix_bytes 64
  @token_bytes 16
  @max_attempts 16
  @prefix_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/

  @doc """
  Parent directory for all benchmark test roots under `System.tmp_dir!/0`.
  """
  @spec parent_path() :: String.t()
  def parent_path do
    Path.join(System.tmp_dir!(), @parent_component)
  end

  @doc """
  Create an exclusive empty directory under `parent_path/0`.

  `prefix` must be a bounded, path-safe single path segment (no separators,
  no `.`/`..`, alphanumeric with optional `_`/`-`). The final leaf name is
  `prefix` plus a cryptographically random token of at least 128 bits.

  On success returns the SafePath-canonical absolute path of the new directory.
  Raises on invalid input or filesystem failure.
  """
  @spec create!(String.t()) :: String.t()
  def create!(prefix) when is_binary(prefix) do
    case create(prefix) do
      {:ok, path} ->
        path

      {:error, reason} ->
        raise ArgumentError,
              "coding benchmark temp root create failed for #{inspect(prefix)}: #{inspect(reason)}"
    end
  end

  def create!(prefix) do
    raise ArgumentError,
          "coding benchmark temp root prefix must be a binary, got: #{inspect(prefix)}"
  end

  @doc """
  Same as `create!/1` but returns `{:ok, canonical_path}` or `{:error, reason}`.

  A successful path is always the SafePath-resolved real path of the exclusive
  leaf. Optional `:token_fun` is reserved for focused exclusive-collision tests
  only; ordinary callers leave it unset so `:crypto.strong_rand_bytes/1` remains
  the randomness source.
  """
  @spec create(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(prefix, opts \\ [])

  def create(prefix, opts) when is_binary(prefix) and is_list(opts) do
    token_fun = Keyword.get(opts, :token_fun, &default_token/0)

    with :ok <- validate_prefix(prefix),
         :ok <- validate_token_fun(token_fun),
         parent = parent_path(),
         :ok <- ensure_parent(parent) do
      exclusive_create(parent, prefix, token_fun, @max_attempts)
    end
  end

  def create(_prefix, _opts), do: {:error, :invalid_prefix}

  defp validate_prefix(prefix) when is_binary(prefix) do
    cond do
      prefix == "" ->
        {:error, :invalid_prefix}

      byte_size(prefix) > @max_prefix_bytes ->
        {:error, :invalid_prefix}

      not String.valid?(prefix) ->
        {:error, :invalid_prefix}

      path_like_segment?(prefix) ->
        {:error, :invalid_prefix}

      not Regex.match?(@prefix_pattern, prefix) ->
        {:error, :invalid_prefix}

      true ->
        :ok
    end
  end

  defp validate_prefix(_prefix), do: {:error, :invalid_prefix}

  defp path_like_segment?(segment) do
    segment in [".", ".."] or
      String.contains?(segment, "/") or
      String.contains?(segment, "\\") or
      String.contains?(segment, "\0") or
      Path.basename(segment) != segment or
      String.starts_with?(segment, "~")
  end

  defp validate_token_fun(fun) when is_function(fun, 0), do: :ok
  defp validate_token_fun(_other), do: {:error, :invalid_token_fun}

  defp ensure_parent(parent) do
    case File.mkdir_p(parent) do
      :ok ->
        case File.lstat(parent) do
          {:ok, %{type: :directory}} -> :ok
          {:ok, _stat} -> {:error, {:parent_not_directory, parent}}
          {:error, reason} -> {:error, {:parent_stat_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:parent_create_failed, reason}}
    end
  end

  defp exclusive_create(_parent, _prefix, _token_fun, 0) do
    {:error, :exclusive_create_exhausted}
  end

  defp exclusive_create(parent, prefix, token_fun, remaining) when remaining > 0 do
    with {:ok, token} <- fetch_token(token_fun),
         :ok <- validate_token(token) do
      path = Path.join(parent, prefix <> "-" <> token)

      case File.mkdir(path) do
        :ok ->
          finalize_created_leaf(path)

        {:error, :eexist} ->
          exclusive_create(parent, prefix, token_fun, remaining - 1)

        {:error, reason} ->
          {:error, {:mkdir_failed, reason}}
      end
    end
  end

  defp finalize_created_leaf(path) do
    case canonicalize(path) do
      {:ok, real} ->
        {:ok, real}

      {:error, reason} ->
        # Best-effort cleanup of the empty leaf we just created; never hide the
        # original canonicalize/stat failure behind a successful Path.expand.
        _ = File.rmdir(path)
        {:error, reason}
    end
  end

  defp fetch_token(token_fun) do
    case token_fun.() do
      token when is_binary(token) -> {:ok, token}
      other -> {:error, {:invalid_token, other}}
    end
  end

  defp validate_token(token) when is_binary(token) do
    cond do
      token == "" ->
        {:error, :invalid_token}

      not String.valid?(token) ->
        {:error, :invalid_token}

      path_like_segment?(token) ->
        {:error, :invalid_token}

      not Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, token) ->
        {:error, :invalid_token}

      # url_encode64(16 bytes) without padding is 22 chars (>= 128 bits).
      byte_size(token) < 22 ->
        {:error, :token_too_short}

      true ->
        :ok
    end
  end

  defp validate_token(_token), do: {:error, :invalid_token}

  defp default_token do
    Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
  end

  # Fail closed: only SafePath.resolve_real/1 may produce the success path.
  # No Path.expand/1 or other non-real fallback.
  defp canonicalize(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case SafePath.resolve_real(path) do
          {:ok, real} -> {:ok, real}
          {:error, reason} -> {:error, {:canonicalize_failed, reason}}
        end

      {:ok, _stat} ->
        {:error, :not_directory}

      {:error, reason} ->
        {:error, {:stat_failed, reason}}
    end
  end
end
