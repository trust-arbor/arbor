defmodule Arbor.Security.Store.RevocationLedger do
  @moduledoc false

  require Logger

  alias Arbor.Common.SafePath
  alias Arbor.Security.Store.RecordAuthenticator

  @version 1
  @filename "capability_revocations.v1.json"
  @marker_suffix ".initialized"
  @marker_kind "capability-revocation-ledger-initialized"
  @max_entries 100_000
  @max_generation 9_007_199_254_740_991
  @lock_retries 5
  @digest_re ~r/\A[0-9a-f]{64}\z/
  @known_unsupported_dir_sync [:eisdir, :enotsup, :einval, :enotty, :eopnotsupp]

  defmodule Snapshot do
    @moduledoc false

    @enforce_keys [:path, :revocations]
    defstruct [:path, :revocations]

    @type t :: %__MODULE__{
            path: String.t(),
            revocations: :missing | %{optional(String.t()) => pos_integer()}
          }
  end

  @opaque snapshot :: Snapshot.t()

  @doc false
  @spec with_snapshot(String.t(), keyword(), (snapshot() -> result)) ::
          result | {:error, atom() | tuple()}
        when result: term()
  def with_snapshot(authority_root, opts, fun)
      when is_binary(authority_root) and is_list(opts) and is_function(fun, 1) do
    with {:ok, path} <- ledger_path(authority_root, opts) do
      with_ledger_lock(path, fn ->
        with {:ok, snapshot} <- read_snapshot(path, opts) do
          fun.(snapshot)
        end
      end)
    end
  end

  def with_snapshot(_authority_root, _opts, _fun),
    do: {:error, :revocation_ledger_unavailable}

  @doc false
  @spec snapshot(String.t(), keyword()) ::
          {:ok, snapshot()} | {:error, atom() | tuple()}
  def snapshot(authority_root, opts)
      when is_binary(authority_root) and is_list(opts) do
    with_snapshot(authority_root, opts, &{:ok, &1})
  end

  def snapshot(_authority_root, _opts),
    do: {:error, :revocation_ledger_unavailable}

  @doc false
  @spec generation(snapshot(), String.t()) :: non_neg_integer()
  def generation(%Snapshot{revocations: :missing}, capability_id)
      when is_binary(capability_id),
      do: 0

  def generation(%Snapshot{revocations: revocations}, capability_id)
      when is_map(revocations) and is_binary(capability_id),
      do: Map.get(revocations, digest(capability_id), 0)

  @doc false
  @spec missing?(snapshot()) :: boolean()
  def missing?(%Snapshot{revocations: :missing}), do: true
  def missing?(%Snapshot{}), do: false

  @spec max_generation(String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, atom() | tuple()}
  def max_generation(authority_root, capability_id, opts)
      when is_binary(authority_root) and is_binary(capability_id) and is_list(opts) do
    with {:ok, snapshot} <- snapshot(authority_root, opts) do
      case snapshot do
        %Snapshot{revocations: :missing} -> {:error, :revocation_ledger_missing}
        %Snapshot{} -> {:ok, generation(snapshot, capability_id)}
      end
    end
  end

  def max_generation(_authority_root, _capability_id, _opts),
    do: {:error, :revocation_ledger_unavailable}

  @spec record(String.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, atom() | tuple()}
  def record(authority_root, capability_id, generation, opts)
      when is_binary(authority_root) and is_binary(capability_id) and is_integer(generation) and
             generation > 0 and generation <= @max_generation and is_list(opts) do
    with_snapshot(authority_root, opts, fn snapshot ->
      record_locked(snapshot, capability_id, generation, opts)
    end)
  end

  def record(_authority_root, _capability_id, _generation, _opts),
    do: {:error, :revocation_ledger_unavailable}

  @doc false
  @spec record_locked(snapshot(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, atom() | tuple()}
  def record_locked(%Snapshot{} = snapshot, capability_id, generation, opts)
      when is_binary(capability_id) and is_integer(generation) and generation > 0 and
             generation <= @max_generation and is_list(opts) do
    revocations = if snapshot.revocations == :missing, do: %{}, else: snapshot.revocations

    with :ok <- ensure_private_parent(snapshot.path),
         :ok <- ensure_capacity(revocations, capability_id),
         next <- Map.update(revocations, digest(capability_id), generation, &max(&1, generation)),
         :ok <- publish(snapshot.path, next, opts),
         :ok <- ensure_marker(snapshot.path, opts) do
      :ok
    end
  end

  def record_locked(_snapshot, _capability_id, _generation, _opts),
    do: {:error, :revocation_ledger_unavailable}

  @spec ensure_initialized(String.t(), keyword()) :: :ok | {:error, atom() | tuple()}
  def ensure_initialized(authority_root, opts)
      when is_binary(authority_root) and is_list(opts) do
    with_snapshot(authority_root, opts, fn snapshot ->
      ensure_initialized_locked(snapshot, opts)
    end)
  end

  def ensure_initialized(_authority_root, _opts),
    do: {:error, :revocation_ledger_unavailable}

  @doc false
  @spec ensure_initialized_locked(snapshot(), keyword()) ::
          :ok | {:error, atom() | tuple()}
  def ensure_initialized_locked(%Snapshot{revocations: :missing, path: path}, opts)
      when is_list(opts) do
    with :ok <- ensure_private_parent(path),
         :ok <- publish(path, %{}, opts),
         :ok <- ensure_marker(path, opts) do
      :ok
    end
  end

  def ensure_initialized_locked(%Snapshot{}, opts) when is_list(opts), do: :ok

  def ensure_initialized_locked(_snapshot, _opts),
    do: {:error, :revocation_ledger_unavailable}

  defp read_snapshot(path, opts) do
    case read_existing_ledger(path, opts) do
      {:ok, revocations} ->
        with :ok <- ensure_marker(path, opts) do
          {:ok, %Snapshot{path: path, revocations: revocations}}
        end

      {:error, :revocation_ledger_missing} ->
        case read_marker(path, opts) do
          :missing -> {:ok, %Snapshot{path: path, revocations: :missing}}
          :ok -> {:error, :revocation_ledger_missing}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp read_existing_ledger(path, opts) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:error, :enoent} ->
        {:error, :revocation_ledger_missing}

      {:ok, _stat} ->
        with :ok <- admit_private_parent(parent) do
          case File.lstat(path) do
            {:error, :enoent} -> {:error, :revocation_ledger_missing}
            _ -> read_ledger(path, opts)
          end
        end

      {:error, _reason} ->
        {:error, :revocation_ledger_parent_unavailable}
    end
  end

  defp read_ledger(path, opts) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %File.Stat{type: :regular, mode: mode, links: 1}} ->
        if Bitwise.band(mode, 0o777) == 0o600 do
          decode_file(path, opts)
        else
          {:error, :revocation_ledger_insecure_mode}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :revocation_ledger_symlink_rejected}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :revocation_ledger_hardlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :revocation_ledger_not_regular}

      {:error, reason} ->
        {:error, {:revocation_ledger_read_failed, reason}}
    end
  end

  defp decode_file(path, opts) do
    with {:ok, real_path} <- SafePath.resolve_real(path),
         true <- real_path == Path.expand(path),
         {:ok, bytes} <- File.read(real_path),
         {:ok, decoded} <- Jason.decode(bytes),
         {:ok, revocations, projection, auth} <- admit_document(decoded),
         :ok <-
           RecordAuthenticator.verify(
             projection,
             auth,
             :capability_revocation_ledger,
             opts
           ) do
      {:ok, revocations}
    else
      false -> {:error, :revocation_ledger_identity_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :revocation_ledger_malformed}
    end
  end

  defp ensure_marker(path, opts) do
    case read_marker(path, opts) do
      :ok -> :ok
      :missing -> publish_marker(path, opts)
      {:error, _reason} = error -> error
    end
  end

  defp read_marker(path, opts) do
    marker = marker_path(path)

    case File.lstat(marker) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular, mode: mode, links: 1}} ->
        if Bitwise.band(mode, 0o777) == 0o600 do
          decode_marker(marker, path, opts)
        else
          {:error, :revocation_ledger_marker_insecure_mode}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :revocation_ledger_marker_symlink_rejected}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :revocation_ledger_marker_hardlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :revocation_ledger_marker_not_regular}

      {:error, reason} ->
        {:error, {:revocation_ledger_marker_read_failed, reason}}
    end
  end

  defp decode_marker(marker, ledger, opts) do
    expected_projection = marker_projection(ledger)

    with {:ok, real_path} <- SafePath.resolve_real(marker),
         true <- real_path == Path.expand(marker),
         {:ok, bytes} <- File.read(real_path),
         {:ok, decoded} <- Jason.decode(bytes),
         %{"authentication" => auth} = document <- decoded,
         true <-
           MapSet.new(Map.keys(document)) ==
             MapSet.new(Map.keys(expected_projection) ++ ["authentication"]),
         true <- Map.drop(document, ["authentication"]) == expected_projection,
         :ok <-
           RecordAuthenticator.verify(
             expected_projection,
             auth,
             :capability_revocation_ledger,
             opts
           ) do
      :ok
    else
      false -> {:error, :revocation_ledger_marker_malformed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :revocation_ledger_marker_malformed}
    end
  end

  defp publish_marker(path, opts) do
    projection = marker_projection(path)

    with {:ok, auth} <-
           RecordAuthenticator.seal(projection, :capability_revocation_ledger, opts),
         {:ok, bytes} <- Jason.encode(Map.put(projection, "authentication", auth)),
         :ok <- publish_bytes(marker_path(path), bytes),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    end
  end

  defp marker_projection(path) do
    %{
      "version" => @version,
      "kind" => @marker_kind,
      "ledger_path_digest" => digest(Path.expand(path))
    }
  end

  defp marker_path(path), do: path <> @marker_suffix

  defp admit_document(
         %{
           "version" => @version,
           "revocations" => revocations,
           "authentication" => auth
         } = document
       )
       when is_map(revocations) and is_map(auth) do
    with true <-
           MapSet.new(Map.keys(document)) ==
             MapSet.new(["version", "revocations", "authentication"]),
         true <- map_size(revocations) <= @max_entries,
         true <- Enum.all?(revocations, &valid_entry?/1) do
      projection = %{"version" => @version, "revocations" => revocations}
      {:ok, revocations, projection, auth}
    else
      _ -> {:error, :revocation_ledger_malformed}
    end
  end

  defp admit_document(_document), do: {:error, :revocation_ledger_malformed}

  defp valid_entry?({key, generation}) when is_binary(key) and is_integer(generation),
    do: Regex.match?(@digest_re, key) and generation > 0 and generation <= @max_generation

  defp valid_entry?(_entry), do: false

  defp ensure_capacity(revocations, capability_id) do
    key = digest(capability_id)

    if Map.has_key?(revocations, key) or map_size(revocations) < @max_entries,
      do: :ok,
      else: {:error, :revocation_ledger_capacity_exceeded}
  end

  defp publish(path, revocations, opts) do
    projection = %{"version" => @version, "revocations" => revocations}

    with {:ok, auth} <-
           RecordAuthenticator.seal(projection, :capability_revocation_ledger, opts),
         {:ok, bytes} <- Jason.encode(Map.put(projection, "authentication", auth)),
         :ok <- publish_bytes(path, bytes),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    end
  end

  defp publish_bytes(path, bytes) do
    with {:ok, tmp} <- temporary_path(path),
         :ok <- write_private(tmp, bytes) do
      case File.rename(tmp, path) do
        :ok ->
          require_private_regular(path)

        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, {:revocation_ledger_publish_failed, reason}}
      end
    end
  end

  defp temporary_path(path) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, path <> ".#{System.unique_integer([:positive])}.#{suffix}.tmp"}
  end

  defp write_private(path, bytes) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        result =
          with :ok <- :file.change_mode(String.to_charlist(path), 0o600),
               :ok <- :file.write(io, bytes),
               :ok <- :file.sync(io) do
            :ok
          end

        _ = :file.close(io)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(path)
            {:error, {:revocation_ledger_publish_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:revocation_ledger_publish_failed, reason}}
    end
  rescue
    _ ->
      _ = File.rm(path)
      {:error, :revocation_ledger_publish_failed}
  catch
    _, _ ->
      _ = File.rm(path)
      {:error, :revocation_ledger_publish_failed}
  end

  defp require_private_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o600,
          do: :ok,
          else: {:error, :revocation_ledger_insecure_mode}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :revocation_ledger_symlink_rejected}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :revocation_ledger_hardlink_rejected}

      _ ->
        {:error, :revocation_ledger_not_regular}
    end
  end

  defp ensure_private_parent(path) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(parent),
             :ok <- File.chmod(parent, 0o700),
             :ok <- admit_private_parent(parent) do
          :ok
        else
          _ -> {:error, :revocation_ledger_parent_unavailable}
        end

      {:ok, _stat} ->
        admit_private_parent(parent)

      {:error, _reason} ->
        {:error, :revocation_ledger_parent_unavailable}
    end
  end

  defp admit_private_parent(parent) do
    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(parent),
         true <- Bitwise.band(mode, 0o777) == 0o700,
         {:ok, real} <- SafePath.resolve_real(parent),
         true <- real == Path.expand(parent) do
      :ok
    else
      _ -> {:error, :revocation_ledger_parent_unavailable}
    end
  end

  defp ledger_path(authority_root, opts) do
    case configured_path(authority_root, opts) do
      path when is_binary(path) ->
        expanded_root = Path.expand(authority_root)
        expanded_path = Path.expand(path)

        if Path.type(path) != :absolute do
          {:error, :revocation_ledger_path_invalid}
        else
          with :ok <- admit_independent_path(expanded_root, expanded_path) do
            {:ok, expanded_path}
          end
        end

      _invalid ->
        {:error, :revocation_ledger_path_invalid}
    end
  end

  if Mix.env() == :test do
    defp admit_independent_path(_expanded_root, _expanded_path), do: :ok

    defp configured_path(authority_root, opts) do
      Keyword.get(
        opts,
        :revocation_ledger_path,
        Path.join([authority_root, ".test-secure", @filename])
      )
    end
  else
    defp admit_independent_path(expanded_root, expanded_path) do
      if within?(expanded_root, expanded_path),
        do: {:error, :revocation_ledger_not_independent},
        else: :ok
    end

    defp configured_path(_authority_root, opts) do
      Keyword.get_lazy(opts, :revocation_ledger_path, fn ->
        master_path =
          Application.get_env(
            :arbor_security,
            :master_key_path,
            Path.join(System.user_home!(), ".arbor/security/master.key")
          )

        Path.join(Path.dirname(master_path), @filename)
      end)
    end
  end

  if Mix.env() != :test do
    defp within?(root, path), do: path == root or String.starts_with?(path, root <> "/")
  end

  defp with_ledger_lock(path, operation) do
    resource = {__MODULE__, :ledger_lock, path}
    id = {resource, self()}
    nodes = [node() | Node.list(:connected)] |> Enum.uniq() |> Enum.sort()

    case :global.trans(id, operation, nodes, @lock_retries) do
      :aborted -> {:error, :revocation_ledger_lock_aborted}
      other -> other
    end
  end

  defp sync_directory(dir) do
    case :file.open(String.to_charlist(dir), [:raw, :read, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        _ = :file.close(io)

        case result do
          :ok -> :ok
          {:error, reason} when reason in @known_unsupported_dir_sync -> :ok
          {:error, reason} -> {:error, {:revocation_ledger_dir_sync_failed, reason}}
        end

      {:error, reason} when reason in @known_unsupported_dir_sync ->
        :ok

      {:error, reason} ->
        {:error, {:revocation_ledger_dir_sync_failed, reason}}
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp warn_physical_tombstone_failure(reason) do
    Logger.warning("Capability revocation ledger committed but tombstone convergence failed",
      reason: reason
    )
  end

  @doc false
  def physical_tombstone_failed(reason), do: warn_physical_tombstone_failure(reason)
end
