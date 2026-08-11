defmodule Arbor.Security.Store.JSONFile do
  @moduledoc """
  JSON file-backed storage backend with local-node durable CAS.

  Implements `Arbor.Contracts.Persistence.Store` for structured
  `%Arbor.Contracts.Persistence.Record{}` values only.

  ## Durability class

  Returns `:node_restart`: live records and generation tombstones survive a full
  local BEAM node restart when the configured directory remains on durable local
  disk. All get/list paths that can migrate and all mutating paths share one
  backend-owned lock per `(canonical_real_base, namespace)` on **this node only**.

  Publication writes an exclusive same-directory temporary file (mode `0600`
  before content), file-syncs, then atomically renames onto the target.
  Incomplete temporary files are never inventory entries.

  Directory entry sync is attempted after rename. **Known-unsupported** directory
  sync outcomes preserve `:node_restart` content+rename durability but **do not**
  claim host power-loss durability. **Unexpected** post-rename failures return
  `{:error, {:publish_commit_uncertain, reason}}`.

  ## Non-claims

  - No cross-node, partition-safe, or hostile multi-user filesystem linearizability.
  - No host power-loss durability when directory sync is unavailable.
  - No fencing for unmigrated legacy files until the first successful Revision
    transition and version-2 publication.

  ## Configuration

      config :arbor_security, Arbor.Security.Store.JSONFile,
        base_dir: ".arbor/security"

  Pass `name: "capabilities"` (or another collection) and optional `base_dir:`
  in opts. New objects use digest-only paths under `ns_<ns_digest>/`.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  require Logger

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Persistence.Revision

  @default_base_dir ".arbor/security"
  @max_key_bytes 512
  @max_namespace_bytes 128
  @lock_retries 5
  @legacy_safe_re ~r/^[A-Za-z0-9][A-Za-z0-9._@:-]{0,511}$/
  @digest_hex_re ~r/^[0-9a-f]{64}$/
  # Exact staging name from create_temp_path/1 only.
  @temp_name_re ~r/^\.[0-9a-f]{64}\.[0-9]+\.[0-9a-f]{8}\.tmp$/
  @known_unsupported_dir_sync ~w(eisdir enotsup einval enotty eopnotsupp)a

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
      with_ns_lock(ctx, fn -> inventory_list(ctx, limit) end)
    end
  end

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
    with :ok <- publish_entry(ctx, tombstone) do
      _ = retire_legacy(ctx)
      :ok
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
    case publish_entry(ctx, stored) do
      :ok ->
        _ = retire_legacy(ctx)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Context, lock, identity
  # ---------------------------------------------------------------------------

  defp with_context(key, opts, fun) do
    with {:ok, ctx} <- key_context(key, opts) do
      with_ns_lock(ctx, fn -> fun.(ctx) end)
    end
  end

  defp with_ns_lock(ctx, fun) do
    resource = {__MODULE__, :namespace_lock, ctx.real_base, ctx.ns_digest}
    id = {resource, self()}

    case :global.trans(id, fun, [node()], @lock_retries) do
      :aborted -> {:error, :lock_aborted}
      other -> other
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

  defp load_entry(ctx, opts) do
    migrate? = Keyword.get(opts, :migrate?, true)

    case open_managed_regular_file(ctx.real_base, ctx.ns_dir, ctx.v2_path) do
      {:ok, real_file} ->
        read_v2_file(real_file, ctx.namespace, ctx.key, ctx.key_digest)

      {:error, :enoent} ->
        # Distinguish missing parent/file from parent being a forbidden type.
        case lstat_managed_dir(ctx.ns_dir) do
          {:ok, :directory} ->
            load_legacy_or_absent(ctx, migrate?)

          {:error, :enoent} ->
            load_legacy_or_absent(ctx, migrate?)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_legacy_or_absent(ctx, migrate?) do
    case read_legacy_raw(ctx) do
      {:ok, recovered} ->
        if migrate? do
          migrate_legacy(ctx, recovered)
        else
          {:ok, {:legacy_raw, recovered}}
        end

      {:error, :not_found} ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, reason}
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

  defp migrate_legacy(ctx, recovered) do
    case Revision.apply_put(:absent, recovered) do
      {:ok, fenced} ->
        case publish_live(ctx, fenced) do
          :ok -> {:ok, fenced}
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, reason}
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

  defp read_v2_file(path, expected_ns, expected_key, expected_digest) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, entry} <- decode_v2(decoded, expected_ns, expected_key),
         :ok <- verify_digest_filename(expected_key, expected_digest) do
      {:ok, entry}
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

  defp decode_v2(map, expected_ns, expected_key) when is_map(map) do
    with :ok <- require_keys(map, ["version", "namespace", "key", "entry"]),
         :ok <- match_version(map["version"]),
         :ok <- match_namespace(map["namespace"], expected_ns),
         :ok <- match_key(map["key"], expected_key) do
      decode_entry(map["entry"], expected_key)
    end
  end

  defp decode_v2(_, _, _), do: {:error, :malformed_envelope}

  defp require_keys(map, keys) when is_map(map) do
    if Enum.all?(keys, &Map.has_key?(map, &1)) do
      :ok
    else
      {:error, :malformed_envelope}
    end
  end

  defp require_keys(_value, _keys), do: {:error, :malformed_envelope}

  defp match_version(2), do: :ok
  defp match_version(_), do: {:error, :malformed_envelope}

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

  # Only inserted_at may be null on live v2 records.
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
         {:ok, updated_at} <- encode_timestamp(record.updated_at) do
      {:ok,
       %{
         "version" => 2,
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
       }}
    end
  end

  defp encode_envelope(ctx, {:tombstone, gen}) when is_integer(gen) and gen >= 1 do
    {:ok,
     %{
       "version" => 2,
       "namespace" => ctx.namespace,
       "key" => ctx.key,
       "entry" => %{
         "kind" => "tombstone",
         "generation" => gen
       }
     }}
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
    with {:ok, v2_entries} <- collect_v2_entries(ctx),
         {:ok, legacy_entries} <- collect_legacy_entries(ctx, v2_entries) do
      merged = Map.merge(legacy_entries, v2_entries)
      count = map_size(merged)

      if is_integer(limit) and count > limit do
        # Fail before any migration side effects.
        {:error, :inventory_limit_exceeded}
      else
        with :ok <- migrate_legacy_entries(ctx, merged) do
          live_keys =
            merged
            |> Enum.filter(fn {_k, class} -> class in [:live, :legacy_live] end)
            |> Enum.map(fn {k, _} -> k end)

          {:ok, live_keys}
        end
      end
    end
  end

  defp collect_v2_entries(ctx) do
    case lstat_managed_dir(ctx.ns_dir) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}

      {:ok, :directory} ->
        collect_v2_names(ctx)
    end
  end

  defp collect_v2_names(ctx) do
    with {:ok, names} <- File.ls(ctx.ns_dir) do
      Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
        reduce_v2_name(ctx, name, acc)
      end)
    end
  end

  defp reduce_v2_name(ctx, name, acc) do
    cond do
      temp_name?(name) ->
        {:cont, {:ok, acc}}

      String.ends_with?(name, ".json") ->
        case ingest_v2_name(ctx, name) do
          {:ok, key, class} -> {:cont, {:ok, Map.put(acc, key, class)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      true ->
        {:cont, {:ok, acc}}
    end
  end

  defp ingest_v2_name(ctx, name) do
    path = Path.join(ctx.ns_dir, name)
    stem = String.trim_trailing(name, ".json")

    with {:ok, real_file} <- open_managed_regular_file(ctx.real_base, ctx.ns_dir, path),
         true <- Regex.match?(@digest_hex_re, stem) || {:error, :identity_mismatch},
         {:ok, json} <- File.read(real_file),
         {:ok, decoded} <- Jason.decode(json),
         :ok <- require_keys(decoded, ["version", "namespace", "key", "entry"]),
         :ok <- match_version(decoded["version"]),
         :ok <- match_namespace(decoded["namespace"], ctx.namespace),
         key when is_binary(key) <- decoded["key"] || {:error, :malformed_envelope},
         {:ok, key} <- validate_key(key),
         :ok <- verify_digest_filename(key, stem),
         {:ok, entry} <- decode_entry(decoded["entry"], key) do
      class =
        case entry do
          %Record{} -> :live
          {:tombstone, _} -> :tombstone
        end

      {:ok, key, class}
    else
      {:error, :enoent} -> {:error, :malformed_envelope}
      {:error, reason} -> {:error, reason}
      false -> {:error, :identity_mismatch}
      _ -> {:error, :malformed_envelope}
    end
  end

  defp collect_legacy_entries(%{legacy_dir: nil}, _v2_entries), do: {:ok, %{}}

  defp collect_legacy_entries(ctx, v2_entries) do
    legacy_dir = ctx.legacy_dir

    # For named namespaces, missing legacy dir is empty. For nil namespace the
    # legacy dir is the real base (already a verified directory).
    case lstat_managed_dir(legacy_dir) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}

      {:ok, :directory} ->
        collect_legacy_names(ctx, v2_entries)
    end
  end

  defp collect_legacy_names(ctx, v2_entries) do
    with {:ok, names} <- File.ls(ctx.legacy_dir) do
      Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
        reduce_legacy_name(ctx, v2_entries, name, acc)
      end)
    end
  end

  defp reduce_legacy_name(ctx, v2_entries, name, acc) do
    if String.ends_with?(name, ".json") do
      key = String.trim_trailing(name, ".json")
      reduce_legacy_json(ctx, v2_entries, name, key, acc)
    else
      {:cont, {:ok, acc}}
    end
  end

  defp reduce_legacy_json(ctx, v2_entries, name, key, acc) do
    cond do
      Map.has_key?(v2_entries, key) ->
        {:cont, {:ok, acc}}

      not legacy_safe_identity?(ctx.namespace, key) ->
        # Unsafe legacy filenames are not inventory authority; skip rather than
        # interpolating them into managed paths.
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

  defp migrate_legacy_entries(ctx, merged) do
    legacy_keys =
      merged
      |> Enum.filter(fn {_k, class} -> class == :legacy_live end)
      |> Enum.map(fn {k, _} -> k end)

    Enum.reduce_while(legacy_keys, :ok, fn key, :ok ->
      opts =
        [base_dir: ctx.real_base] ++
          if is_nil(ctx.namespace), do: [], else: [name: ctx.namespace]

      case key_context(key, opts) do
        {:ok, key_ctx} ->
          case load_legacy_or_absent(key_ctx, true) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp temp_name?(name) when is_binary(name), do: Regex.match?(@temp_name_re, name)
end
