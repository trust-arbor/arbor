defmodule Arbor.Security.Store.JSONFile do
  @moduledoc """
  JSON file-backed storage backend with connected-cluster durable CAS.

  Implements `Arbor.Contracts.Persistence.Store` for structured
  `%Arbor.Contracts.Persistence.Record{}` values only.

  ## Durability class

  Returns `:node_restart`: authenticated live records and generation tombstones survive a full
  local BEAM node restart when the configured directory remains on durable local
  disk. All get/list paths that can migrate and all mutating paths share one
  backend-owned lock per `(canonical_real_base, namespace)` across every
  currently connected visible or hidden Erlang node.

  Publication writes an exclusive same-directory temporary file (mode `0600`
  before content), file-syncs, then atomically renames onto the target.
  Incomplete temporary files are never inventory entries.

  Directory entry sync is attempted after rename. **Known-unsupported** directory
  sync outcomes preserve `:node_restart` content+rename durability but **do not**
  claim host power-loss durability. **Unexpected** post-rename failures return
  `{:error, {:publish_commit_uncertain, reason}}`.

  ## Non-claims

  - No partition-safe or hostile multi-user filesystem linearizability. Nodes
    that cannot see each other must not write the same local filesystem root.
  - No host power-loss durability when directory sync is unavailable.
  - Version-1 and unauthenticated version-2 records require an explicit offline
    migration. They are never admitted or rewritten during normal startup.
  - The independent revocation ledger plus its initialization marker detects
    stale authority records and ledger-only loss. It cannot detect an attacker
    rolling back or deleting both independent files together; same-UID storage
    compromise remains outside this durability boundary.
  - Inventory bounds apply to logical records before hydration or migration;
    `File.ls/1` still materializes directory names and does not bound same-UID
    filesystem resource consumption.

  ## Configuration

  Application-owned AuthorityStore identity is `config :arbor_security,
  :authority_state_root` (absolute). This module's Application env `base_dir`
  is a legacy alias of that key: Config canonicalizes both without `File.cwd!/0`
  and fails closed on conflict. A default durable AuthorityStore with no
  `base_dir` injects the frozen root; only an explicit absolute test root
  bypasses it.

      config :arbor_security, authority_state_root: "/var/lib/arbor/security"
      config :arbor_security, Arbor.Security.Store.JSONFile,
        base_dir: ".arbor/security"

  Pass `name: "capabilities"` (or another collection) and optional `base_dir:`
  in opts. Isolated tests may pass an explicit absolute `base_dir`. New objects
  use digest-only paths under `ns_<ns_digest>/`.
  """

  @behaviour Arbor.Contracts.Persistence.Store
  @behaviour Arbor.Security.Store.BoundedInventory

  require Logger

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Persistence.Revision
  alias Arbor.Security.Store.RecordAuthenticator
  alias Arbor.Security.Store.RevocationLedger

  @default_base_dir ".arbor/security"
  @max_key_bytes 512
  @max_namespace_bytes 128
  @lock_retries 5
  @legacy_safe_re ~r/^[A-Za-z0-9][A-Za-z0-9._@:-]{0,511}$/
  @digest_hex_re ~r/^[0-9a-f]{64}$/
  # Exact staging name from create_temp_path/1 only.
  @temp_name_re ~r/^\.[0-9a-f]{64}\.[0-9]+\.[0-9a-f]{8}\.tmp$/
  @known_unsupported_dir_sync ~w(eisdir enotsup einval enotty eopnotsupp)a
  @authenticated_version 3
  @unauthenticated_version 2

  # ---------------------------------------------------------------------------
  # Store callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def put(key, value, opts \\ [])

  def put(key, %Record{} = record, opts) do
    with :ok <- validate_input_record(record) do
      with_context(key, opts, &put_locked(&1, key, record))
    end
  end

  def put(_key, _value, _opts), do: {:error, :unsupported_value}

  @impl true
  def get(key, opts \\ []) do
    with_context(key, opts, fn ctx ->
      case load_entry(ctx, migrate?: true) do
        {:ok, entry} ->
          case Revision.live_value(entry) do
            {:ok, value} -> {:ok, value}
            :not_found -> {:error, :not_found}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc false
  def authoritative_entry(key, opts \\ []) do
    with_context(key, opts, &load_entry(&1, migrate?: true))
  end

  @doc false
  def compare_and_create(key, expected, %Record{} = replacement, opts) do
    with_context(key, opts, fn ctx ->
      with false <- Revision.key_mismatch?(key, replacement),
           true <- expected == :absent or valid_creation_tombstone?(expected),
           {:ok, entry} <- load_entry(ctx, migrate?: true),
           true <- entry == expected do
        do_cas(ctx, entry, :not_found, replacement)
      else
        false -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end)
  end

  def compare_and_create(_key, _expected, _replacement, _opts),
    do: {:error, :unsupported_value}

  defp valid_creation_tombstone?({:tombstone, generation})
       when is_integer(generation) and generation > 0 and generation < 9_007_199_254_740_991,
       do: true

  defp valid_creation_tombstone?(_), do: false

  @impl true
  def delete(key, opts \\ []) do
    with_context(key, opts, fn ctx ->
      with {:ok, entry} <- load_entry(ctx, migrate?: true) do
        delete_locked(ctx, entry)
      end
    end)
  end

  @impl true
  def list(opts \\ []) do
    # Validate limit before any base creation / namespace resolution.
    with {:ok, limit} <- Revision.authoritative_list_limit(opts),
         {:ok, ctx} <- namespace_context(opts) do
      with_ns_lock(ctx, fn operation_ctx -> inventory_list(operation_ctx, limit) end)
    end
  end

  @impl Arbor.Security.Store.BoundedInventory
  def bounded_list(limit, opts \\ [])

  def bounded_list(limit, opts) when is_integer(limit) and limit > 0 and is_list(opts) do
    with {:ok, ctx} <- namespace_context(opts) do
      with_ns_lock(ctx, fn operation_ctx -> inventory_list(operation_ctx, limit) end)
    end
  end

  def bounded_list(_limit, _opts), do: {:error, :invalid_inventory_limit}

  @impl true
  def exists?(key, opts \\ []) do
    case get(key, opts) do
      {:ok, _} ->
        true

      {:error, reason} ->
        if reason != :not_found do
          Logger.warning("JSONFile exists? failed", reason: reason)
        end

        false
    end
  rescue
    e ->
      Logger.warning("JSONFile exists? raised", reason: Exception.message(e))
      false
  catch
    kind, reason ->
      Logger.warning("JSONFile exists? aborted", reason: {kind, reason})
      false
  end

  @impl true
  def compare_and_swap(key, expected, replacement, opts \\ [])

  def compare_and_swap(key, expected, %Record{} = replacement, opts) do
    with :ok <- validate_input_record(replacement) do
      with_context(key, opts, &cas_locked(&1, key, expected, replacement))
    end
  end

  def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :unsupported_value}

  @impl true
  def compare_and_delete(key, expected, opts \\ [])

  def compare_and_delete(key, %Record{} = expected, opts) do
    with_context(key, opts, &compare_delete_locked(&1, key, expected))
  end

  def compare_and_delete(_key, _expected, _opts), do: {:error, :conflict}

  @impl true
  def durability_class(_opts), do: :node_restart

  # ---------------------------------------------------------------------------
  # CAS body
  # ---------------------------------------------------------------------------

  defp put_locked(ctx, key, record) do
    if Revision.key_mismatch?(key, record) do
      {:error, :key_mismatch}
    else
      with {:ok, entry} <- load_entry(ctx, migrate?: true),
           {:ok, stored} <- Revision.apply_put(entry, record) do
        publish_live(ctx, stored)
      end
    end
  end

  defp delete_locked(ctx, {:tombstone, _generation}) do
    _ = retire_legacy(ctx)
    :ok
  end

  defp delete_locked(ctx, entry) do
    case Revision.to_tombstone(entry) do
      :absent -> :ok
      {:tombstone, _gen} = tombstone -> publish_tombstone(ctx, tombstone)
    end
  end

  defp cas_locked(ctx, key, expected, replacement) do
    if Revision.cas_operands_key_mismatch?(key, expected, replacement) do
      {:error, :key_mismatch}
    else
      with {:ok, entry} <- load_entry(ctx, migrate?: true) do
        do_cas(ctx, entry, expected, replacement)
      end
    end
  end

  defp compare_delete_locked(ctx, key, expected) do
    if Revision.key_mismatch?(key, expected) do
      {:error, :key_mismatch}
    else
      with {:ok, entry} <- load_entry(ctx, migrate?: true),
           true <- Revision.cas_matches?(entry, expected),
           {:tombstone, _gen} = tombstone <- Revision.to_tombstone(entry) do
        publish_tombstone(ctx, tombstone)
      else
        false -> {:error, :conflict}
        :absent -> {:error, :conflict}
        {:error, _reason} = error -> error
      end
    end
  end

  defp publish_tombstone(ctx, tombstone) do
    with :ok <- record_revocation(ctx, tombstone) do
      case publish_entry(ctx, tombstone) do
        :ok ->
          _ = retire_legacy(ctx)
          :ok

        {:error, reason} = error ->
          if capability_namespace?(ctx) do
            RevocationLedger.physical_tombstone_failed(reason)
            :ok
          else
            error
          end
      end
    end
  end

  defp do_cas(ctx, entry, :not_found, replacement) do
    cond do
      entry == :absent ->
        stored = Revision.advance_cas_insert(replacement)
        publish_live_ok(ctx, stored)

      match?({:tombstone, _}, entry) ->
        {:tombstone, prev_gen} = entry
        stored = Revision.advance_cas_insert_from_tombstone(prev_gen, replacement)
        publish_live_ok(ctx, stored)

      true ->
        {:error, :conflict}
    end
  end

  defp do_cas(ctx, entry, {:value, expected_value}, replacement) do
    if Revision.cas_matches?(entry, expected_value) do
      case entry do
        %Record{} = current ->
          case Revision.advance_cas_update(current, replacement) do
            {:ok, stored} -> publish_live_ok(ctx, stored)
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, :conflict}
      end
    else
      {:error, :conflict}
    end
  end

  defp do_cas(_ctx, _entry, _expected, _replacement), do: {:error, :conflict}

  defp publish_live_ok(ctx, stored) do
    case publish_live(ctx, stored) do
      :ok -> {:ok, stored}
      {:error, _} = err -> err
    end
  end

  defp publish_live(ctx, %Record{} = stored) do
    with :ok <- ensure_revocation_ledger(ctx) do
      case publish_entry(ctx, stored) do
        :ok ->
          _ = retire_legacy(ctx)
          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  defp ensure_revocation_ledger(ctx) do
    case Map.get(ctx, :revocation_snapshot, :not_applicable) do
      :not_applicable -> :ok
      snapshot -> RevocationLedger.ensure_initialized_locked(snapshot, ctx.security_opts)
    end
  end

  defp record_revocation(ctx, {:tombstone, generation}) do
    if capability_namespace?(ctx) do
      RevocationLedger.record_locked(
        ctx.revocation_snapshot,
        ctx.key,
        generation,
        ctx.security_opts
      )
    else
      :ok
    end
  end

  defp capability_namespace?(%{namespace: "capabilities"}), do: true
  defp capability_namespace?(_ctx), do: false

  # ---------------------------------------------------------------------------
  # Context, lock, identity
  # ---------------------------------------------------------------------------

  defp with_context(key, opts, fun) do
    with {:ok, ctx} <- key_context(key, opts) do
      with_ns_lock(ctx, fun)
    end
  end

  defp with_ns_lock(ctx, fun) do
    resource = {__MODULE__, :namespace_lock, ctx.real_base, ctx.ns_digest}
    id = {resource, self()}
    nodes = [node() | Node.list(:connected)] |> Enum.uniq() |> Enum.sort()

    # Keep this lock order stable: namespace first, shared ledger second. The
    # ledger lease spans snapshot admission, the authority operation, and any
    # ledger publication so separate authority roots cannot lose updates when
    # they intentionally share one ledger.
    operation = fn -> with_revocation_snapshot(ctx, fun) end

    case :global.trans(id, operation, nodes, @lock_retries) do
      :aborted -> {:error, :lock_aborted}
      other -> other
    end
  end

  defp with_revocation_snapshot(ctx, fun) do
    if capability_namespace?(ctx) do
      RevocationLedger.with_snapshot(ctx.real_base, ctx.security_opts, fn snapshot ->
        fun.(Map.put(ctx, :revocation_snapshot, snapshot))
      end)
    else
      fun.(ctx)
    end
  end

  defp key_context(key, opts) do
    with {:ok, key} <- validate_key(key),
         {:ok, namespace} <- namespace_from_opts(opts),
         {:ok, real_base} <- resolve_real_base(opts) do
      ns_digest = digest_hex(ns_tag(namespace))
      key_digest = digest_hex(key_tag(key))
      ns_dir = Path.join(real_base, "ns_" <> ns_digest)
      v2_path = Path.join(ns_dir, key_digest <> ".json")

      with :ok <- ensure_under_root(real_base, ns_dir),
           :ok <- ensure_under_root(real_base, v2_path) do
        {:ok,
         %{
           key: key,
           namespace: namespace,
           real_base: real_base,
           ns_digest: ns_digest,
           key_digest: key_digest,
           ns_dir: ns_dir,
           v2_path: v2_path,
           security_opts: security_opts(opts),
           legacy_path: legacy_path(real_base, namespace, key),
           legacy_dir: legacy_dir(real_base, namespace)
         }}
      end
    end
  end

  defp namespace_context(opts) do
    with {:ok, namespace} <- namespace_from_opts(opts),
         {:ok, real_base} <- resolve_real_base(opts) do
      ns_digest = digest_hex(ns_tag(namespace))
      ns_dir = Path.join(real_base, "ns_" <> ns_digest)

      with :ok <- ensure_under_root(real_base, ns_dir) do
        {:ok,
         %{
           key: nil,
           namespace: namespace,
           real_base: real_base,
           ns_digest: ns_digest,
           key_digest: nil,
           ns_dir: ns_dir,
           v2_path: nil,
           security_opts: security_opts(opts),
           legacy_path: nil,
           legacy_dir: legacy_dir(real_base, namespace)
         }}
      end
    end
  end

  defp namespace_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> {:ok, nil}
      name when is_atom(name) -> validate_namespace(Atom.to_string(name))
      name -> validate_namespace(name)
    end
  end

  defp security_opts(opts) do
    Keyword.take(opts, [
      :record_auth_key,
      :record_authentication_token,
      :security_supervisor_pid,
      :revocation_ledger_path
    ])
  end

  defp validate_key(key) when is_binary(key) do
    cond do
      key == "" -> {:error, :invalid_key}
      byte_size(key) > @max_key_bytes -> {:error, :invalid_key}
      not String.valid?(key) -> {:error, :invalid_key}
      String.contains?(key, <<0>>) -> {:error, :invalid_key}
      true -> {:ok, key}
    end
  end

  defp validate_key(_), do: {:error, :invalid_key}

  defp validate_namespace(nil), do: {:ok, nil}

  defp validate_namespace(ns) when is_binary(ns) do
    cond do
      ns == "" -> {:error, :invalid_namespace}
      byte_size(ns) > @max_namespace_bytes -> {:error, :invalid_namespace}
      not String.valid?(ns) -> {:error, :invalid_namespace}
      String.contains?(ns, <<0>>) -> {:error, :invalid_namespace}
      true -> {:ok, ns}
    end
  end

  defp validate_namespace(_), do: {:error, :invalid_namespace}

  defp ns_tag(nil), do: <<0>>
  defp ns_tag(ns) when is_binary(ns), do: <<1, ns::binary>>

  defp key_tag(key) when is_binary(key), do: <<2, key::binary>>

  defp digest_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp legacy_safe_identity?(nil, key), do: legacy_safe_component?(key)

  defp legacy_safe_identity?(ns, key) when is_binary(ns),
    do: legacy_safe_component?(ns) and legacy_safe_component?(key)

  defp legacy_safe_component?(value) when is_binary(value) do
    Regex.match?(@legacy_safe_re, value) and not String.contains?(value, "..")
  end

  defp legacy_dir(real_base, nil), do: real_base

  defp legacy_dir(real_base, ns) when is_binary(ns) do
    if legacy_safe_component?(ns), do: Path.join(real_base, ns), else: nil
  end

  defp legacy_path(real_base, namespace, key) do
    if legacy_safe_identity?(namespace, key) do
      Path.join(legacy_dir(real_base, namespace), key <> ".json")
    else
      nil
    end
  end

  defp resolve_real_base(opts) do
    configured =
      Keyword.get(opts, :base_dir) ||
        Application.get_env(:arbor_security, __MODULE__, [])
        |> Keyword.get(:base_dir, @default_base_dir)

    expanded =
      if Path.type(configured) == :absolute do
        Path.expand(configured)
      else
        Path.expand(configured, File.cwd!())
      end

    with :ok <- File.mkdir_p(expanded),
         {:ok, real} <- SafePath.resolve_real(expanded),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(real) do
      _ = File.chmod(real, 0o700)
      {:ok, real}
    else
      {:error, :not_found} -> {:error, :invalid_managed_target}
      {:ok, %File.Stat{type: type}} when type != :directory -> {:error, :invalid_managed_target}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_base_dir, other}}
    end
  end

  defp ensure_under_root(real_base, path) do
    normalized_base = Path.expand(real_base)
    normalized = Path.expand(path)

    if normalized_base == "/" or
         normalized == normalized_base or
         String.starts_with?(normalized, normalized_base <> "/") do
      :ok
    else
      {:error, :path_escape}
    end
  end

  # ---------------------------------------------------------------------------
  # Managed path typing (no intermediate symlink escape)
  # ---------------------------------------------------------------------------

  # lstat the managed namespace directory before ls/read/write of children.
  # enoent is allowed for reads (empty namespace); writers create via ensure_ns_dir.
  defp lstat_managed_dir(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, :directory}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{}} -> {:error, :invalid_managed_target}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lstat_managed_file(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, :regular}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{}} -> {:error, :invalid_managed_target}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  # After confirming parent dir is a real directory (not symlink), lstat the file
  # and re-resolve its real path so intermediate symlink races cannot escape.
  defp open_managed_regular_file(real_base, parent_dir, path) do
    with {:ok, :directory} <- lstat_managed_dir(parent_dir),
         :ok <- ensure_under_root(real_base, parent_dir),
         :ok <- ensure_under_root(real_base, path),
         {:ok, :regular} <- lstat_managed_file(path),
         {:ok, real_file} <- SafePath.resolve_real(path),
         :ok <- ensure_under_root(real_base, real_file) do
      {:ok, real_file}
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Load / migrate
  # ---------------------------------------------------------------------------

  defp load_entry(ctx, _opts) do
    case open_managed_regular_file(ctx.real_base, ctx.ns_dir, ctx.v2_path) do
      {:ok, real_file} ->
        read_authenticated_file(real_file, ctx)

      {:error, :enoent} ->
        # Distinguish missing parent/file from parent being a forbidden type.
        case lstat_managed_dir(ctx.ns_dir) do
          {:ok, :directory} ->
            load_legacy_or_absent(ctx)

          {:error, :enoent} ->
            load_legacy_or_absent(ctx)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_legacy_or_absent(ctx) do
    case read_legacy_raw(ctx) do
      {:ok, _recovered} ->
        {:error, :offline_migration_required}

      {:error, :not_found} ->
        revocation_fence_for_absent(ctx)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revocation_fence_for_absent(ctx) do
    case Map.get(ctx, :revocation_snapshot, :not_applicable) do
      :not_applicable ->
        {:ok, :absent}

      snapshot ->
        if RevocationLedger.missing?(snapshot) do
          {:ok, :absent}
        else
          case RevocationLedger.generation(snapshot, ctx.key) do
            0 -> {:ok, :absent}
            generation -> {:ok, {:tombstone, generation}}
          end
        end
    end
  end

  defp revocation_generation(ctx) do
    case Map.get(ctx, :revocation_snapshot, :not_applicable) do
      :not_applicable ->
        {:ok, 0}

      snapshot ->
        if RevocationLedger.missing?(snapshot),
          do: {:error, :revocation_ledger_missing},
          else: {:ok, RevocationLedger.generation(snapshot, ctx.key)}
    end
  end

  defp apply_revocation_fence(ctx, entry) do
    if capability_namespace?(ctx) do
      with {:ok, revoked_generation} <- revocation_generation(ctx) do
        case entry do
          %Record{generation: generation} when generation <= revoked_generation ->
            {:ok, {:tombstone, revoked_generation}}

          {:tombstone, generation} ->
            {:ok, {:tombstone, max(generation, revoked_generation)}}

          %Record{} = record ->
            {:ok, record}
        end
      end
    else
      {:ok, entry}
    end
  end

  defp read_legacy_raw(ctx) do
    path = ctx.legacy_path

    if is_nil(path) do
      {:error, :not_found}
    else
      parent = ctx.legacy_dir

      case open_managed_regular_file(ctx.real_base, parent, path) do
        {:ok, real_file} ->
          case File.read(real_file) do
            {:ok, json} -> decode_legacy(json, ctx.key)
            {:error, :enoent} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_legacy(json, key) do
    case Jason.decode(json) do
      {:ok, %{"data" => data} = envelope} when is_map(data) ->
        metadata =
          case Map.fetch(envelope, "metadata") do
            {:ok, meta} when is_map(meta) -> meta
            :error -> %{}
            {:ok, _} -> :invalid
          end

        if metadata == :invalid do
          {:error, :malformed_legacy}
        else
          recovered = %Record{
            id: key,
            key: key,
            data: data,
            metadata: metadata,
            generation: 0,
            revision: 0,
            inserted_at: nil,
            updated_at: nil
          }

          {:ok, recovered}
        end

      {:ok, _} ->
        {:error, :malformed_legacy}

      {:error, _} ->
        {:error, :malformed_legacy}
    end
  end

  defp retire_legacy(ctx) do
    path = ctx.legacy_path

    if is_binary(path) do
      case open_managed_regular_file(ctx.real_base, ctx.legacy_dir, path) do
        {:ok, real_file} ->
          case File.rm(real_file) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> log_legacy_retirement_skip(reason)
          end

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          log_legacy_retirement_skip(reason)
      end
    else
      :ok
    end
  end

  defp log_legacy_retirement_skip(reason) do
    Logger.warning("JSONFile legacy retirement skipped", reason: reason)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Input / envelope validation
  # ---------------------------------------------------------------------------

  defp validate_input_record(%Record{} = record) do
    cond do
      not is_binary(record.id) or record.id == "" ->
        {:error, :malformed_record}

      not is_binary(record.key) or record.key == "" ->
        {:error, :malformed_record}

      not is_map(record.data) ->
        {:error, :malformed_record}

      not is_map(record.metadata) ->
        {:error, :malformed_record}

      not (is_integer(record.generation) and record.generation >= 0) ->
        {:error, :malformed_record}

      not (is_integer(record.revision) and record.revision >= 0) ->
        {:error, :malformed_record}

      not valid_optional_datetime?(record.inserted_at) ->
        {:error, :malformed_record}

      not valid_optional_datetime?(record.updated_at) ->
        {:error, :malformed_record}

      true ->
        :ok
    end
  end

  defp validate_input_record(_), do: {:error, :unsupported_value}

  defp valid_optional_datetime?(nil), do: true
  defp valid_optional_datetime?(%DateTime{} = dt), do: encodable_datetime?(dt)
  defp valid_optional_datetime?(_), do: false

  defp encodable_datetime?(%DateTime{} = dt), do: match?({:ok, _}, encode_timestamp(dt))
  defp encodable_datetime?(_), do: false

  defp validate_publish_live(%Record{} = record) do
    cond do
      not is_binary(record.id) or record.id == "" ->
        {:error, :malformed_record}

      not is_binary(record.key) or record.key == "" ->
        {:error, :malformed_record}

      not is_map(record.data) ->
        {:error, :malformed_record}

      not is_map(record.metadata) ->
        {:error, :malformed_record}

      not (is_integer(record.generation) and record.generation >= 1) ->
        {:error, :malformed_record}

      not (is_integer(record.revision) and record.revision >= 1) ->
        {:error, :malformed_record}

      not encodable_datetime?(record.updated_at) ->
        {:error, :malformed_record}

      not valid_optional_datetime?(record.inserted_at) ->
        {:error, :malformed_record}

      true ->
        :ok
    end
  end

  defp validate_publish_tombstone({:tombstone, gen})
       when is_integer(gen) and gen >= 1,
       do: :ok

  defp validate_publish_tombstone(_), do: {:error, :malformed_record}

  # ---------------------------------------------------------------------------
  # Envelope encode / decode
  # ---------------------------------------------------------------------------

  defp read_authenticated_file(path, ctx) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, entry} <- decode_envelope(decoded, ctx.namespace, ctx.key, ctx.security_opts),
         :ok <- verify_digest_filename(ctx.key, ctx.key_digest),
         {:ok, fenced_entry} <- apply_revocation_fence(ctx, entry) do
      {:ok, fenced_entry}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_envelope}
    end
  end

  defp verify_digest_filename(key, expected_digest)
       when is_binary(key) and is_binary(expected_digest) do
    if digest_hex(key_tag(key)) == expected_digest do
      :ok
    else
      {:error, :identity_mismatch}
    end
  end

  defp decode_envelope(
         %{"version" => @authenticated_version, "authentication" => auth} = map,
         expected_ns,
         expected_key,
         security_opts
       ) do
    projection = Map.delete(map, "authentication")

    with :ok <-
           require_exact_keys(map, ["version", "namespace", "key", "entry", "authentication"]),
         :ok <- match_namespace(map["namespace"], expected_ns),
         :ok <- match_key(map["key"], expected_key),
         :ok <- RecordAuthenticator.verify(projection, auth, :authority_record, security_opts) do
      decode_entry(map["entry"], expected_key)
    end
  end

  defp decode_envelope(
         %{"version" => @unauthenticated_version} = map,
         expected_ns,
         expected_key,
         _security_opts
       ) do
    with :ok <- require_exact_keys(map, ["version", "namespace", "key", "entry"]),
         :ok <- match_namespace(map["namespace"], expected_ns),
         :ok <- match_key(map["key"], expected_key),
         {:ok, _entry} <- decode_entry(map["entry"], expected_key) do
      {:error, :offline_migration_required}
    end
  end

  defp decode_envelope(_map, _expected_ns, _expected_key, _security_opts),
    do: {:error, :malformed_envelope}

  defp require_exact_keys(map, keys) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys) do
      :ok
    else
      {:error, :malformed_envelope}
    end
  end

  defp require_exact_keys(_value, _keys), do: {:error, :malformed_envelope}

  defp match_namespace(ns, expected) when ns == expected, do: :ok
  defp match_namespace(_, _), do: {:error, :identity_mismatch}

  defp match_key(key, expected) when is_binary(key) and key == expected, do: :ok
  defp match_key(_, _), do: {:error, :identity_mismatch}

  defp decode_entry(entry, expected_key) when is_map(entry) do
    case entry do
      %{
        "kind" => "tombstone",
        "generation" => gen
      } = t
      when is_integer(gen) and gen >= 1 ->
        if Map.keys(t) -- ["kind", "generation"] == [] do
          {:ok, {:tombstone, gen}}
        else
          {:error, :malformed_envelope}
        end

      %{
        "kind" => "record",
        "id" => id,
        "key" => key,
        "generation" => gen,
        "revision" => rev,
        "inserted_at" => inserted_at,
        "updated_at" => updated_at,
        "data" => data,
        "metadata" => metadata
      }
      when is_binary(id) and id != "" and is_binary(key) and key == expected_key and
             is_integer(gen) and
             gen >= 1 and is_integer(rev) and rev >= 1 and is_map(data) and is_map(metadata) ->
        with {:ok, inserted} <- decode_nullable_timestamp(inserted_at),
             {:ok, updated} <- decode_required_timestamp(updated_at) do
          {:ok,
           %Record{
             id: id,
             key: key,
             generation: gen,
             revision: rev,
             inserted_at: inserted,
             updated_at: updated,
             data: data,
             metadata: metadata
           }}
        end

      _ ->
        {:error, :malformed_envelope}
    end
  end

  defp decode_entry(_, _), do: {:error, :malformed_envelope}

  # Only inserted_at may be null on live records.
  defp decode_nullable_timestamp(nil), do: {:ok, nil}

  defp decode_nullable_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :malformed_envelope}
    end
  end

  defp decode_nullable_timestamp(_), do: {:error, :malformed_envelope}

  defp decode_required_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :malformed_envelope}
    end
  end

  defp decode_required_timestamp(_), do: {:error, :malformed_envelope}

  defp encode_envelope(ctx, %Record{} = record) do
    with {:ok, inserted_at} <- encode_timestamp(record.inserted_at),
         {:ok, updated_at} <- encode_timestamp(record.updated_at),
         projection <- %{
           "version" => @authenticated_version,
           "namespace" => ctx.namespace,
           "key" => ctx.key,
           "entry" => %{
             "kind" => "record",
             "id" => record.id,
             "key" => record.key,
             "generation" => record.generation,
             "revision" => record.revision,
             "inserted_at" => inserted_at,
             "updated_at" => updated_at,
             "data" => record.data,
             "metadata" => record.metadata
           }
         },
         {:ok, authentication} <-
           RecordAuthenticator.seal(projection, :authority_record, ctx.security_opts) do
      {:ok, Map.put(projection, "authentication", authentication)}
    end
  end

  defp encode_envelope(ctx, {:tombstone, gen}) when is_integer(gen) and gen >= 1 do
    projection = %{
      "version" => @authenticated_version,
      "namespace" => ctx.namespace,
      "key" => ctx.key,
      "entry" => %{
        "kind" => "tombstone",
        "generation" => gen
      }
    }

    with {:ok, authentication} <-
           RecordAuthenticator.seal(projection, :authority_record, ctx.security_opts) do
      {:ok, Map.put(projection, "authentication", authentication)}
    end
  end

  defp encode_timestamp(nil), do: {:ok, nil}

  defp encode_timestamp(%DateTime{} = dt) do
    {:ok, DateTime.to_iso8601(dt)}
  rescue
    _ -> {:error, :malformed_record}
  catch
    _, _ -> {:error, :malformed_record}
  end

  defp encode_timestamp(_), do: {:error, :malformed_record}

  # ---------------------------------------------------------------------------
  # Atomic publication
  # ---------------------------------------------------------------------------

  defp publish_entry(ctx, %Record{} = record) do
    with :ok <- validate_publish_live(record),
         {:ok, envelope} <- encode_envelope(ctx, record) do
      do_publish(ctx, envelope)
    end
  end

  defp publish_entry(ctx, {:tombstone, gen} = tombstone) when is_integer(gen) and gen >= 1 do
    with :ok <- validate_publish_tombstone(tombstone),
         {:ok, envelope} <- encode_envelope(ctx, tombstone) do
      do_publish(ctx, envelope)
    end
  end

  defp publish_entry(_ctx, {:tombstone, _gen}), do: {:error, :malformed_record}

  defp do_publish(ctx, envelope) do
    with {:ok, json} <- encode_json(envelope),
         :ok <- ensure_ns_dir(ctx),
         {:ok, tmp} <- create_temp_path(ctx),
         :ok <- write_temp_file(tmp, json) do
      case File.rename(tmp, ctx.v2_path) do
        :ok ->
          case post_rename_finalize(ctx) do
            :ok -> :ok
            {:error, reason} -> {:error, {:publish_commit_uncertain, reason}}
          end

        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, {:publish_failed, reason}}
      end
    else
      {:error, {:publish_failed, _}} = err ->
        err

      {:error, reason} ->
        {:error, {:publish_failed, reason}}
    end
  end

  defp encode_json(envelope) do
    case Jason.encode(envelope) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  rescue
    e -> {:error, {:encode_failed, Exception.message(e)}}
  end

  defp ensure_ns_dir(ctx) do
    with :ok <- ensure_under_root(ctx.real_base, ctx.ns_dir) do
      case lstat_managed_dir(ctx.ns_dir) do
        {:ok, :directory} ->
          _ = File.chmod(ctx.ns_dir, 0o700)
          :ok

        {:error, :enoent} ->
          case File.mkdir_p(ctx.ns_dir) do
            :ok ->
              _ = File.chmod(ctx.ns_dir, 0o700)

              case lstat_managed_dir(ctx.ns_dir) do
                {:ok, :directory} -> :ok
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_temp_path(ctx) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    tmp =
      Path.join(
        ctx.ns_dir,
        ".#{ctx.key_digest}.#{System.unique_integer([:positive])}.#{suffix}.tmp"
      )

    with :ok <- ensure_under_root(ctx.real_base, tmp) do
      {:ok, tmp}
    end
  end

  defp write_temp_file(tmp, json) do
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
              {:error, {:publish_failed, reason}}
          end
        rescue
          e ->
            _ = close_io_silent(io)
            _ = File.rm(tmp)
            {:error, {:publish_failed, Exception.message(e)}}
        catch
          kind, reason ->
            _ = close_io_silent(io)
            _ = File.rm(tmp)
            {:error, {:publish_failed, {kind, reason}}}
        end

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:publish_failed, reason}}
    end
  end

  defp post_rename_finalize(ctx) do
    with :ok <- fsync_directory(ctx.ns_dir) do
      ensure_final_mode(ctx.v2_path)
    end
  end

  defp fsync_directory(dir) when is_binary(dir) do
    case Application.get_env(:arbor_security, :json_file_fsync_dir_fun) do
      fun when is_function(fun, 1) ->
        normalize_dir_sync_result(fun.(dir))

      _ ->
        do_fsync_directory(dir)
    end
  end

  defp do_fsync_directory(dir) do
    case :file.open(dir, [:raw, :read, :directory]) do
      {:ok, io} ->
        try do
          case :file.sync(io) do
            :ok -> :ok
            {:error, reason} -> normalize_dir_sync_result({:error, reason})
          end
        after
          _ = close_io_silent(io)
        end

      {:error, reason} ->
        normalize_dir_sync_result({:error, reason})
    end
  end

  # Known-unsupported directory sync: keep node-restart content+rename success
  # without claiming power-loss durability.
  defp normalize_dir_sync_result(:ok), do: :ok

  defp normalize_dir_sync_result({:error, reason}) when reason in @known_unsupported_dir_sync,
    do: :ok

  defp normalize_dir_sync_result({:error, {:dir_fsync_failed, reason}})
       when reason in @known_unsupported_dir_sync,
       do: :ok

  defp normalize_dir_sync_result({:error, {:dir_open_failed, reason}})
       when reason in @known_unsupported_dir_sync,
       do: :ok

  defp normalize_dir_sync_result({:error, reason}), do: {:error, reason}

  defp ensure_final_mode(path) do
    case File.chmod(path, 0o600) do
      :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular, mode: mode}} ->
            if Bitwise.band(mode, 0o777) == 0o600, do: :ok, else: {:error, :insecure_mode}

          {:ok, _} ->
            {:error, :invalid_managed_target}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_io_silent(io) do
    :file.close(io)
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Inventory
  # ---------------------------------------------------------------------------

  defp inventory_list(ctx, limit) do
    with {:ok, v2_entries} <- collect_v2_entries(ctx, limit),
         {:ok, legacy_entries} <- collect_legacy_entries(ctx, v2_entries, limit) do
      merged = Map.merge(legacy_entries, v2_entries)
      count = map_size(merged)

      if is_integer(limit) and count > limit do
        # Fail before inspecting whether legacy records need offline migration.
        {:error, :inventory_limit_exceeded}
      else
        with :ok <- reject_legacy_entries(merged) do
          live_keys =
            merged
            |> Enum.filter(fn {_k, class} -> class == :live end)
            |> Enum.map(fn {k, _} -> k end)

          {:ok, live_keys}
        end
      end
    end
  end

  defp collect_v2_entries(ctx, limit) do
    case lstat_managed_dir(ctx.ns_dir) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}

      {:ok, :directory} ->
        collect_v2_names(ctx, limit)
    end
  end

  defp collect_v2_names(ctx, limit) do
    with {:ok, names} <- File.ls(ctx.ns_dir) do
      if bounded_v2_name_count(names, limit) > limit do
        {:error, :inventory_limit_exceeded}
      else
        Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
          reduce_v2_name(ctx, name, acc)
        end)
      end
    end
  end

  defp bounded_v2_name_count(names, limit) do
    Enum.reduce_while(names, 0, fn name, count ->
      next = if v2_record_name?(name), do: count + 1, else: count
      if next > limit, do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp v2_record_name?(name) do
    String.ends_with?(name, ".json") and
      name
      |> String.trim_trailing(".json")
      |> then(&Regex.match?(@digest_hex_re, &1))
  end

  defp reduce_v2_name(ctx, name, acc) do
    cond do
      temp_name?(name) ->
        {:cont, {:ok, acc}}

      String.ends_with?(name, ".json") ->
        stem = String.trim_trailing(name, ".json")

        if Regex.match?(@digest_hex_re, stem) do
          case ingest_v2_name(ctx, name) do
            {:ok, key, class} -> {:cont, {:ok, Map.put(acc, key, class)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          case quarantine_foreign_json(ctx, name) do
            :ok -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end

      true ->
        {:cont, {:ok, acc}}
    end
  end

  defp ingest_v2_name(ctx, name) do
    path = Path.join(ctx.ns_dir, name)
    stem = String.trim_trailing(name, ".json")

    with {:ok, real_file} <- open_managed_regular_file(ctx.real_base, ctx.ns_dir, path),
         {:ok, json} <- File.read(real_file),
         {:ok, decoded} <- Jason.decode(json),
         true <- is_map(decoded) || {:error, :malformed_envelope},
         key when is_binary(key) <- Map.get(decoded, "key") || {:error, :malformed_envelope},
         {:ok, key} <- validate_key(key),
         :ok <- verify_digest_filename(key, stem),
         {:ok, entry} <- decode_envelope(decoded, ctx.namespace, key, ctx.security_opts),
         {:ok, fenced_entry} <- apply_revocation_fence(%{ctx | key: key}, entry) do
      class =
        case fenced_entry do
          %Record{} -> :live
          {:tombstone, _} -> :tombstone
        end

      {:ok, key, class}
    else
      {:error, :enoent} -> {:error, :malformed_envelope}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_envelope}
    end
  end

  defp quarantine_foreign_json(ctx, name) do
    source = Path.join(ctx.ns_dir, name)
    fingerprint = digest_hex(name)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    quarantine_dir = Path.join(ctx.ns_dir, ".quarantine")
    target = Path.join(quarantine_dir, "foreign-#{fingerprint}-#{suffix}")

    outcome =
      with :ok <- ensure_under_root(ctx.real_base, source),
           :ok <- ensure_under_root(ctx.real_base, quarantine_dir),
           :ok <- ensure_under_root(ctx.real_base, target),
           :ok <- ensure_quarantine_dir(quarantine_dir),
           :ok <- File.rename(source, target),
           :ok <- fsync_directory(quarantine_dir),
           :ok <- fsync_directory(ctx.ns_dir) do
        :quarantined
      else
        _ -> :quarantine_failed
      end

    Logger.warning("JSONFile handled foreign authority-state entry",
      fingerprint: fingerprint,
      outcome: outcome
    )

    case outcome do
      :quarantined -> :ok
      :quarantine_failed -> {:error, :foreign_entry_quarantine_failed}
    end
  end

  defp ensure_quarantine_dir(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with :ok <- File.mkdir(path),
             :ok <- File.chmod(path, 0o700),
             {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(path),
             true <- Bitwise.band(mode, 0o777) == 0o700 do
          :ok
        else
          _ -> {:error, :quarantine_unavailable}
        end

      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o700,
          do: :ok,
          else: {:error, :quarantine_unavailable}

      _ ->
        {:error, :quarantine_unavailable}
    end
  end

  defp collect_legacy_entries(%{legacy_dir: nil}, _v2_entries, _limit), do: {:ok, %{}}

  defp collect_legacy_entries(ctx, v2_entries, limit) do
    legacy_dir = ctx.legacy_dir

    # For named namespaces, missing legacy dir is empty. For nil namespace the
    # legacy dir is the real base (already a verified directory).
    case lstat_managed_dir(legacy_dir) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}

      {:ok, :directory} ->
        collect_legacy_names(ctx, v2_entries, limit)
    end
  end

  defp collect_legacy_names(ctx, v2_entries, limit) do
    with {:ok, names} <- File.ls(ctx.legacy_dir),
         :ok <- ensure_legacy_inventory_within_limit(ctx, names, v2_entries, limit) do
      Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
        reduce_legacy_name(ctx, v2_entries, name, acc)
      end)
    end
  end

  defp ensure_legacy_inventory_within_limit(_ctx, _names, _v2_entries, nil), do: :ok

  defp ensure_legacy_inventory_within_limit(ctx, names, v2_entries, limit)
       when is_integer(limit) do
    count =
      Enum.reduce_while(names, map_size(v2_entries), fn name, count ->
        next =
          case legacy_inventory_key(ctx, v2_entries, name) do
            {:ok, _key} -> count + 1
            :skip -> count
          end

        if next > limit, do: {:halt, next}, else: {:cont, next}
      end)

    if count > limit, do: {:error, :inventory_limit_exceeded}, else: :ok
  end

  defp reduce_legacy_name(ctx, v2_entries, name, acc) do
    case legacy_inventory_key(ctx, v2_entries, name) do
      {:ok, key} -> reduce_legacy_json(ctx, name, key, acc)
      :skip -> {:cont, {:ok, acc}}
    end
  end

  defp legacy_inventory_key(ctx, v2_entries, name) do
    if String.ends_with?(name, ".json") do
      key = String.trim_trailing(name, ".json")

      if not Map.has_key?(v2_entries, key) and legacy_safe_identity?(ctx.namespace, key),
        do: {:ok, key},
        else: :skip
    else
      :skip
    end
  end

  defp reduce_legacy_json(ctx, name, key, acc) do
    cond do
      not legacy_safe_identity?(ctx.namespace, key) ->
        {:cont, {:ok, acc}}

      true ->
        path = Path.join(ctx.legacy_dir, name)

        case ingest_legacy_name(ctx, path, key) do
          {:ok, :live} -> {:cont, {:ok, Map.put(acc, key, :legacy_live)}}
          {:error, :not_found} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp ingest_legacy_name(ctx, path, key) do
    with {:ok, real_file} <- open_managed_regular_file(ctx.real_base, ctx.legacy_dir, path),
         {:ok, json} <- File.read(real_file),
         {:ok, _recovered} <- decode_legacy(json, key) do
      {:ok, :live}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_legacy}
    end
  end

  defp reject_legacy_entries(merged) do
    if Enum.any?(merged, fn {_key, class} -> class == :legacy_live end),
      do: {:error, :offline_migration_required},
      else: :ok
  end

  defp temp_name?(name) when is_binary(name), do: Regex.match?(@temp_name_re, name)
end
