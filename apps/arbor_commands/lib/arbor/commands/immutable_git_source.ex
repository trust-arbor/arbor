defmodule Arbor.Commands.ImmutableGitSource do
  @moduledoc """
  Generic immutable Git source boundary.

  Reconstructs one exact commit and expected tree into an absent child of an
  owner-private parent from bounded OID-verified objects. The public facade
  does not accept an arbitrary absolute destination.
  """

  alias Arbor.Commands.ImmutableGitSource.Reconstruct

  @production_opt_keys MapSet.new([:timeout_ms, :materialize_paths])
  @test_limit_keys [
    :max_entries,
    :max_listing_bytes,
    :max_object_bytes,
    :max_total_bytes,
    :max_symlink_bytes
  ]
  @default_timeout_ms 300_000
  @max_timeout_ms 3_600_000

  @production_limits %{
    max_entries: 50_000,
    max_listing_bytes: 16_777_216,
    max_object_bytes: 16_777_216,
    max_total_bytes: 268_435_456,
    max_symlink_bytes: 4_096
  }

  @type identity :: Reconstruct.identity()

  @doc "Production reconstruct limits."
  @spec production_limits() :: Reconstruct.limits()
  def production_limits, do: @production_limits

  @doc """
  Reconstruct `commit_oid`/`expected_tree` into `relative_dest` under an
  owner-private parent identity.

  Production options: `:timeout_ms` and `:materialize_paths`.

  `:materialize_paths` is an optional closed list of regular blob paths.
  When omitted, every supported tree entry is materialized, including
  safe relative symlinks. When set, only those regular files are written;
  unselected blobs, including Git mode `120000`, stay absent from the
  worktree. The imported commit and tree identity is unchanged.
  """
  @spec reconstruct(String.t(), String.t(), String.t(), String.t(), identity(), keyword()) ::
          :ok | {:error, term()}
  def reconstruct(source, relative_dest, commit_oid, expected_tree, identity, opts \\ [])

  def reconstruct(source, relative_dest, commit_oid, expected_tree, identity, opts)
      when is_binary(source) and is_binary(relative_dest) and is_binary(commit_oid) and
             is_binary(expected_tree) and is_map(identity) and is_list(opts) do
    with :ok <- reject_limit_overrides(opts),
         :ok <- admit_production_opts(opts),
         {:ok, timeout_ms} <- admit_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms)) do
      identity
      |> require_owned_identity()
      |> case do
        :ok ->
          finish_reconstruct(
            source,
            relative_dest,
            commit_oid,
            expected_tree,
            identity,
            @production_limits,
            timeout_ms,
            require_private: true,
            materialize_paths: Keyword.get(opts, :materialize_paths, :all)
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def reconstruct(_source, _relative_dest, _commit, _tree, _identity, _opts),
    do: {:error, :invalid_reconstruct_request}

  @doc false
  @spec reconstruct_for_test(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          identity(),
          keyword()
        ) :: :ok | {:error, term()}
  def reconstruct_for_test(source, relative_dest, commit_oid, expected_tree, identity, opts \\ [])

  def reconstruct_for_test(source, relative_dest, commit_oid, expected_tree, identity, opts)
      when is_binary(source) and is_binary(relative_dest) and is_binary(commit_oid) and
             is_binary(expected_tree) and is_map(identity) and is_list(opts) do
    limits = merge_limits(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    require_private? = Keyword.get(opts, :require_private, true)

    with {:ok, timeout_ms} <- admit_timeout(timeout_ms) do
      finish_reconstruct(
        source,
        relative_dest,
        commit_oid,
        expected_tree,
        identity,
        limits,
        timeout_ms,
        require_private: require_private?,
        materialize_paths: Keyword.get(opts, :materialize_paths, :all)
      )
    end
  end

  def reconstruct_for_test(_source, _relative_dest, _commit, _tree, _identity, _opts),
    do: {:error, :invalid_reconstruct_request}

  defp finish_reconstruct(
         source,
         relative_dest,
         commit_oid,
         expected_tree,
         identity,
         limits,
         timeout_ms,
         run_opts
       ) do
    case Reconstruct.run(
           source,
           relative_dest,
           commit_oid,
           expected_tree,
           identity,
           limits,
           [timeout_ms: timeout_ms, branch: "source"] ++ run_opts
         ) do
      :ok -> :ok
      {:error, "parent_identity_mismatch"} -> {:error, :parent_identity_mismatch}
      {:error, "parent_not_private"} -> {:error, :parent_not_private}
      {:error, "invalid_reconstruct_request"} -> {:error, :invalid_reconstruct_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_owned_identity(%{
         path: path,
         type: :directory,
         device: device,
         minor_device: minor_device,
         inode: inode
       })
       when is_binary(path) and is_integer(device) and is_integer(minor_device) and
              is_integer(inode) do
    :ok
  end

  defp require_owned_identity(_identity), do: {:error, :invalid_reconstruct_request}

  defp reject_limit_overrides(opts) do
    if Enum.any?(@test_limit_keys, &Keyword.has_key?(opts, &1)) or
         Keyword.has_key?(opts, :require_private) or Keyword.has_key?(opts, :branch) do
      {:error, :invalid_reconstruct_request}
    else
      :ok
    end
  end

  defp admit_production_opts(opts) do
    keys = opts |> Keyword.keys() |> MapSet.new()

    if MapSet.subset?(keys, @production_opt_keys) do
      :ok
    else
      {:error, :invalid_reconstruct_request}
    end
  end

  defp admit_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms,
       do: {:ok, timeout_ms}

  defp admit_timeout(_timeout), do: {:error, :invalid_reconstruct_request}

  defp merge_limits(opts) do
    Enum.reduce(@test_limit_keys, @production_limits, fn key, acc ->
      case Keyword.get(opts, key) do
        value when is_integer(value) and value > 0 -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end
end
