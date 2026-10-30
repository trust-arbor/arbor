defmodule Arbor.Security.AuditJournalRecovery do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.AuditJournalFileProofs

  @journal_name "audit_journal.v1.log"
  @quarantine_name ".audit-quarantine"
  @recovery_marker "recovery-required.json"
  @max_reason_bytes 64

  @spec recover_torn_tail(AuditJournalFile.t()) :: {:ok, AuditJournalFile.t()} | {:error, term()}
  def recover_torn_tail(%AuditJournalFile{torn_tail: %{byte_size: byte_size}} = handle)
      when is_integer(byte_size) and byte_size > 0 do
    candidate = recovery_candidate_path(handle.path)

    with {:ok, source} <-
           AuditJournalFileCore.source_binding(handle.digest, handle.frames, handle.offset),
         {:ok, compacted, snapshot, pending} <-
           AuditJournalCore.compact(handle.core, source, retire: false),
         {:ok, clean_bytes, expected} <-
           AuditJournalFileCore.encode_compacted(snapshot, pending),
         {:ok, corrupt_bytes} <- snapshot_torn_source(handle),
         {:ok, quarantine_path} <- preserve_torn_bytes(handle.root, corrupt_bytes),
         :ok <- write_rotation_event(quarantine_path, :torn_tail),
         :ok <- publish_candidate(candidate, clean_bytes, compacted, expected),
         {:ok, same_bytes} <- snapshot_torn_source(handle),
         true <- same_bytes == corrupt_bytes,
         :ok <- File.rename(candidate, handle.path),
         :ok <- AuditJournalFileProofs.fsync_directory(Path.dirname(handle.path)),
         :ok <- AuditJournalFile.close(handle),
         {:ok, recovered} <- AuditJournalFile.open(root: handle.root, path: handle.path),
         :ok <- require_recovered(recovered, compacted, expected) do
      emit_recovery_event(:torn_tail, quarantine_path)
      {:ok, recovered}
    else
      false ->
        cleanup_candidate(candidate)
        _ = AuditJournalFile.close(handle)
        {:error, :source_changed}

      {:error, reason} ->
        cleanup_candidate(candidate)
        _ = AuditJournalFile.close(handle)
        {:error, reason}

      _ ->
        cleanup_candidate(candidate)
        _ = AuditJournalFile.close(handle)
        {:error, :recovery_failed}
    end
  rescue
    _ ->
      cleanup_candidate(recovery_candidate_path(handle.path))
      _ = AuditJournalFile.close(handle)
      {:error, :recovery_failed}
  catch
    _, _ ->
      cleanup_candidate(recovery_candidate_path(handle.path))
      _ = AuditJournalFile.close(handle)
      {:error, :recovery_failed}
  end

  def recover_torn_tail(_handle), do: {:error, :not_torn}

  @spec quarantine_and_reset(String.t(), term()) ::
          {:ok, AuditJournalFile.t()} | {:error, term()}
  def quarantine_and_reset(root, reason) when is_binary(root) do
    with {:ok, real_root} <- admit_root(root),
         {:ok, source} <- SafePath.safe_join(real_root, @journal_name),
         {:ok, quarantine_dir} <- ensure_quarantine_dir(real_root),
         {:ok, target} <- corrupt_quarantine_path(quarantine_dir),
         :ok <- write_recovery_marker(quarantine_dir, Path.basename(target), reason),
         :ok <- File.rename(source, target),
         :ok <- AuditJournalFileProofs.fsync_directory(quarantine_dir),
         :ok <- AuditJournalFileProofs.fsync_directory(real_root),
         {:ok, handle} <- AuditJournalFile.open(root: real_root) do
      emit_recovery_event(:corrupt, target)
      {:ok, handle}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recovery_failed}
    end
  rescue
    _ -> {:error, :recovery_failed}
  catch
    _, _ -> {:error, :recovery_failed}
  end

  def quarantine_and_reset(_root, _reason), do: {:error, :invalid_root}

  @spec recovery_required?(String.t()) :: boolean()
  def recovery_required?(root) when is_binary(root) do
    marker = Path.join([Path.expand(root), @quarantine_name, @recovery_marker])

    case File.lstat(marker) do
      {:ok, %File.Stat{type: :regular}} -> true
      {:ok, _other} -> true
      {:error, :enoent} -> false
      {:error, _reason} -> true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  def recovery_required?(_root), do: true

  defp snapshot_torn_source(handle) do
    with {:ok, fstat} <- AuditJournalFileProofs.fstat_io(handle.fd),
         {:ok, lstat} <- AuditJournalFileProofs.lstat_file(handle.path),
         :ok <- AuditJournalFileProofs.require_regular(fstat),
         :ok <- AuditJournalFileProofs.require_regular(lstat),
         :ok <- AuditJournalFileProofs.require_single_link(fstat),
         :ok <- AuditJournalFileProofs.require_file_mode_0600(fstat),
         :ok <- AuditJournalFileProofs.require_bound_identity(handle.identity, fstat),
         :ok <- AuditJournalFileProofs.require_bound_identity(handle.identity, lstat),
         {:ok, bytes} <- pread_exact(handle.fd, handle.file_size),
         {:ok, empty} <- AuditJournalFileCore.new(),
         {:ok, replay} <- AuditJournalFileCore.consume(empty, bytes),
         true <- same_torn_replay?(handle, replay) do
      {:ok, bytes}
    else
      false -> {:error, :source_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :source_changed}
    end
  end

  defp same_torn_replay?(handle, replay) do
    replay.digest == handle.digest and replay.offset == handle.offset and
      replay.frames == handle.frames and replay.torn_tail == handle.torn_tail and
      AuditJournalFileCore.core_match?(replay.core, handle.core)
  end

  defp preserve_torn_bytes(root, bytes) do
    with {:ok, quarantine_dir} <- ensure_quarantine_dir(root),
         {:ok, path} <- torn_quarantine_path(quarantine_dir),
         :ok <- write_private_file(path, bytes),
         :ok <- verify_private_file(path, bytes),
         :ok <- AuditJournalFileProofs.fsync_directory(quarantine_dir) do
      {:ok, path}
    end
  end

  defp publish_candidate(path, bytes, compacted, expected) do
    with :ok <- remove_stale_candidate(path),
         :ok <- write_private_file(path, bytes),
         :ok <- verify_private_file(path, bytes),
         {:ok, empty} <- AuditJournalFileCore.new(),
         {:ok, replay} <- AuditJournalFileCore.consume(empty, bytes),
         true <- replay.torn_tail == nil,
         true <- AuditJournalFileCore.core_match?(replay.core, compacted),
         true <- replay.digest == expected.digest,
         true <- replay.offset == expected.offset,
         true <- replay.frames == expected.frames do
      :ok
    else
      false -> {:error, :candidate_proof_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :candidate_proof_failed}
    end
  end

  defp require_recovered(handle, compacted, expected) do
    cond do
      handle.torn_tail != nil ->
        {:error, :recovery_replay_failed}

      not AuditJournalFileCore.core_match?(handle.core, compacted) ->
        {:error, :recovery_replay_failed}

      handle.digest != expected.digest ->
        {:error, :recovery_replay_failed}

      handle.offset != expected.offset ->
        {:error, :recovery_replay_failed}

      handle.frames != expected.frames ->
        {:error, :recovery_replay_failed}

      true ->
        :ok
    end
  end

  defp admit_root(root) do
    expanded = Path.expand(root)

    with true <- Path.type(root) == :absolute,
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(expanded),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, real} <- SafePath.resolve_real(expanded),
         true <- real == expanded do
      {:ok, real}
    else
      _ -> {:error, :invalid_root}
    end
  end

  defp ensure_quarantine_dir(root) do
    with {:ok, path} <- SafePath.safe_join(root, @quarantine_name) do
      case File.lstat(path) do
        {:error, :enoent} ->
          with :ok <- File.mkdir(path),
               :ok <- File.chmod(path, 0o700),
               :ok <- admit_quarantine_dir(path) do
            {:ok, path}
          end

        {:ok, _stat} ->
          with :ok <- admit_quarantine_dir(path), do: {:ok, path}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp admit_quarantine_dir(path) do
    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, real} <- SafePath.resolve_real(path),
         true <- real == Path.expand(path) do
      :ok
    else
      _ -> {:error, :quarantine_unavailable}
    end
  end

  defp recovery_candidate_path(path) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.recovery.#{suffix}.tmp")
  end

  defp torn_quarantine_path(dir) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    {:ok, Path.join(dir, "torn-tail-#{suffix}.log")}
  end

  defp corrupt_quarantine_path(dir) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    {:ok, Path.join(dir, "corrupt-#{suffix}.log")}
  end

  defp write_recovery_marker(dir, evidence_name, reason) do
    path = Path.join(dir, @recovery_marker)

    document = %{
      "version" => 1,
      "kind" => "arbor.security.audit_journal_recovery_required.v1",
      "evidence" => evidence_name,
      "reason" => reason_class(reason),
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case Jason.encode(document) do
      {:ok, bytes} -> write_private_file(path, bytes)
      {:error, _reason} -> {:error, :recovery_marker_failed}
    end
  end

  defp write_rotation_event(evidence_path, kind) do
    dir = Path.dirname(evidence_path)
    evidence_name = Path.basename(evidence_path)
    path = Path.join(dir, "recovery-event-#{evidence_name}.json")

    document = %{
      "version" => 1,
      "kind" => "arbor.security.audit_journal_forensic_rotation.v1",
      "cause" => Atom.to_string(kind),
      "evidence" => evidence_name,
      "action" => "quarantine_and_replace",
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    with {:ok, bytes} <- Jason.encode(document),
         :ok <- write_private_file(path, bytes),
         :ok <- verify_private_file(path, bytes),
         :ok <- AuditJournalFileProofs.fsync_directory(dir) do
      :ok
    else
      _ -> {:error, :recovery_event_failed}
    end
  end

  defp reason_class(reason) do
    value =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        {class, _detail} when is_atom(class) -> Atom.to_string(class)
        _ -> "journal_open_failed"
      end

    if byte_size(value) <= @max_reason_bytes, do: value, else: "journal_open_failed"
  end

  defp write_private_file(path, bytes) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read, :write, :exclusive]) do
      {:ok, fd} ->
        result =
          with :ok <- :file.change_mode(String.to_charlist(path), 0o600),
               :ok <- :file.pwrite(fd, 0, bytes),
               :ok <- :file.sync(fd) do
            :ok
          end

        _ = :file.close(fd)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(path)
            {:error, reason}
        end

      {:error, :eexist} ->
        {:error, :candidate_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_private_file(path, expected) do
    with {:ok, %File.Stat{type: :regular, links: 1, mode: mode, size: size}} <-
           File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         true <- size == byte_size(expected),
         {:ok, actual} <- File.read(path),
         true <- actual == expected do
      :ok
    else
      _ -> {:error, :candidate_proof_failed}
    end
  end

  defp pread_exact(_fd, 0), do: {:ok, <<>>}

  defp pread_exact(fd, size) when is_integer(size) and size > 0 do
    case :file.pread(fd, 0, size) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _ -> {:error, :read_failed}
    end
  end

  defp remove_stale_candidate(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o600,
          do: File.rm(path),
          else: {:error, :candidate_exists}

      _ ->
        {:error, :candidate_exists}
    end
  end

  defp cleanup_candidate(path) when is_binary(path) do
    _ = remove_stale_candidate(path)
    :ok
  end

  defp emit_recovery_event(kind, evidence_path) do
    :telemetry.execute(
      [:arbor, :security, :audit_journal, :recovered],
      %{count: 1},
      %{kind: kind, evidence: Path.basename(evidence_path)}
    )

    :ok
  end
end
