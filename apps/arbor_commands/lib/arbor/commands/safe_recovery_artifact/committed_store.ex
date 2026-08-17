defmodule Arbor.Commands.SafeRecoveryArtifact.CommittedStore do
  @moduledoc false

  # The ONLY writer for the committed E0B2C3c1 safe-recovery artifact pair.
  # Destinations are hardcoded to exactly the two SourcePolicy-excluded
  # committed paths; write/3 takes no path arguments, so no caller can select
  # or add a destination. Reads are bounded and refuse symlinks anywhere in
  # the path chain.

  alias Arbor.Commands.SafeRecoveryArtifact.SourcePolicy
  alias Arbor.Common.SafePath

  @before_publish_event [:arbor, :commands, :safe_recovery_artifact, :before_publish]
  @max_temp_attempts 8

  @envelope_rel "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json"
  @payload_rel "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"

  @max_envelope_bytes 4_096
  @max_payload_bytes 16_777_216

  @spec paths() :: [String.t()]
  def paths, do: [@envelope_rel, @payload_rel]

  @doc "Both committed destinations stay exactly the SourcePolicy exclusions."
  @spec paths_bound_to_source_policy?() :: boolean()
  def paths_bound_to_source_policy? do
    MapSet.new(paths()) == SourcePolicy.excluded_paths()
  end

  @doc """
  Read both committed artifact files with bounded, symlink-refusing reads.

  A fully absent pair (the pre-first-write state) is `{:error,
  :artifact_missing}`; a half-present pair is reported per file so a torn
  write fails loudly and specifically.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(root) when is_binary(root) do
    with {:ok, envelope_bytes} <-
           read_one(root, @envelope_rel, @max_envelope_bytes, :envelope),
         {:ok, payload_bytes} <- read_one(root, @payload_rel, @max_payload_bytes, :payload) do
      {:ok, %{envelope_bytes: envelope_bytes, payload_bytes: payload_bytes}}
    else
      {:error, :envelope_missing} -> read_payload_only(root)
      {:error, _reason} = error -> error
    end
  end

  def read(_root), do: {:error, :invalid_root}

  defp read_payload_only(root) do
    case read_one(root, @payload_rel, @max_payload_bytes, :payload) do
      {:ok, _payload_bytes} -> {:error, :envelope_missing}
      {:error, :payload_missing} -> {:error, :artifact_missing}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Create or replace exactly the two committed artifact files.

  Takes no path arguments. Every existing ancestor is validated WITHOUT
  following symlinks before anything is created; missing ancestors are then
  created one component at a time with post-create re-validation. Each file
  is published through an exclusive temporary file inside the validated
  parent followed by an atomic rename over the destination (rename replaces
  the directory entry itself, so a destination swapped to a symlink after
  admission can never redirect the bytes outside the root). A destination
  that is already a symlink, non-regular, or under a redirected parent
  fails closed. The payload is written before the envelope; the readback
  byte-compares both files. On success exactly the two committed paths
  remain -- temporary files exist only transiently and are removed on every
  failure path.
  """
  @spec write(String.t(), binary(), binary()) :: :ok | {:error, term()}
  def write(root, envelope_bytes, payload_bytes)
      when is_binary(root) and is_binary(envelope_bytes) and is_binary(payload_bytes) do
    with :ok <- require_policy_bound(),
         true <- byte_size(envelope_bytes) <= @max_envelope_bytes || {:error, :envelope_unbounded},
         true <- byte_size(payload_bytes) >= 1 || {:error, :invalid_payload},
         true <- byte_size(payload_bytes) <= @max_payload_bytes || {:error, :payload_unbounded},
         :ok <- prepare_destination(root, @payload_rel),
         :ok <- prepare_destination(root, @envelope_rel),
         :ok <- emit_before_publish(root),
         :ok <- write_one(root, @payload_rel, payload_bytes),
         :ok <- write_one(root, @envelope_rel, envelope_bytes) do
      readback(root, envelope_bytes, payload_bytes)
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_input}
    end
  end

  def write(_root, _envelope_bytes, _payload_bytes), do: {:error, :invalid_input}

  # -- read -----------------------------------------------------------------

  defp read_one(root, rel, ceiling, prefix) do
    with {:ok, lexical} <- join_within(root, rel),
         {:ok, stat} <- lstat_destination(lexical, prefix),
         :ok <- require_regular(stat, prefix),
         :ok <- require_single_link(stat, prefix),
         :ok <- require_size(stat, ceiling, prefix),
         :ok <- require_unredirected(lexical, root, prefix),
         {:ok, bytes} <- read_bounded(lexical, ceiling, prefix) do
      admit_read(lexical, stat, bytes, prefix)
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

  defp lstat_destination(path, prefix) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, missing_error(prefix)}
      {:error, _reason} -> {:error, read_error(prefix)}
    end
  end

  defp missing_error(:envelope), do: :envelope_missing
  defp missing_error(:payload), do: :payload_missing

  defp read_error(:envelope), do: :envelope_unreadable
  defp read_error(:payload), do: :payload_unreadable

  defp require_regular(%File.Stat{type: :regular}, _prefix), do: :ok

  defp require_regular(_stat, :envelope), do: {:error, :envelope_not_regular}
  defp require_regular(_stat, :payload), do: {:error, :payload_not_regular}

  defp require_single_link(%File.Stat{links: 1}, _prefix), do: :ok

  defp require_single_link(_stat, :envelope), do: {:error, :envelope_not_regular}
  defp require_single_link(_stat, :payload), do: {:error, :payload_not_regular}

  defp require_size(%File.Stat{size: size}, ceiling, prefix)
       when is_integer(size) and size >= 0 do
    if size <= ceiling, do: :ok, else: {:error, unbounded_error(prefix)}
  end

  defp require_size(_stat, _ceiling, prefix), do: {:error, unbounded_error(prefix)}

  defp unbounded_error(:envelope), do: :envelope_unbounded
  defp unbounded_error(:payload), do: :payload_unbounded

  # The root is resolved to its real path by the caller; a differing real
  # path for the destination therefore means a symlinked ancestor or a
  # symlinked file -- both refused.
  defp require_unredirected(lexical, root, prefix) do
    case SafePath.resolve_real(lexical) do
      {:ok, ^lexical} ->
        if SafePath.within?(lexical, root), do: :ok, else: {:error, :path_escape}

      _other ->
        {:error, redirected_error(prefix)}
    end
  end

  defp redirected_error(:envelope), do: :envelope_symlink_redirection
  defp redirected_error(:payload), do: :payload_symlink_redirection

  defp read_bounded(path, ceiling, prefix) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          case :file.read(io, ceiling + 1) do
            {:ok, bytes} -> {:ok, bytes}
            :eof -> {:ok, ""}
            {:error, _reason} -> {:error, read_error(prefix)}
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, missing_error(prefix)}

      {:error, _reason} ->
        {:error, read_error(prefix)}
    end
  end

  # A racing or lying stat cannot force an unbounded read (ceiling+1 above)
  # and a file that changed size between stat and read fails closed.
  defp admit_read(_lexical, %File.Stat{size: size}, bytes, prefix)
       when byte_size(bytes) == size do
    if byte_size(bytes) <= ceiling_of(prefix),
      do: {:ok, bytes},
      else: {:error, unbounded_error(prefix)}
  end

  defp admit_read(_lexical, _stat, _bytes, :envelope),
    do: {:error, :envelope_changed_during_read}

  defp admit_read(_lexical, _stat, _bytes, :payload),
    do: {:error, :payload_changed_during_read}

  defp ceiling_of(:envelope), do: @max_envelope_bytes
  defp ceiling_of(:payload), do: @max_payload_bytes

  # -- write ----------------------------------------------------------------

  defp require_policy_bound do
    if paths_bound_to_source_policy?(), do: :ok, else: {:error, :destination_policy_drift}
  end

  defp prepare_destination(root, rel) do
    with {:ok, lexical} <- join_within(root, rel),
         {:ok, _parent} <- prepare_parent(lexical, root),
         :ok <- admit_existing_destination(lexical) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp prepare_parent(lexical, root) do
    parent = Path.dirname(lexical)

    with :ok <- require_within(parent, root),
         {:ok, root_identity} <- identity_of(root),
         {:ok, missing} <- validate_existing_ancestors(root, parent),
         :ok <- create_missing_ancestors(missing),
         :ok <- require_parent_unredirected(parent, root),
         :ok <- require_same_identity(root, root_identity) do
      {:ok, parent}
    end
  end

  # Walk the ancestor chain top-down (just under the root). Every component
  # that already exists must be a real directory per lstat -- a symlinked
  # ancestor is rejected WITHOUT following it, so nothing is ever created
  # through a redirection. Components deeper than a missing one must also be
  # missing (an existing child of a missing parent means a race).
  defp validate_existing_ancestors(root, parent) do
    rel = Path.relative_to(parent, root)

    if rel == parent do
      {:error, :destination_path_escape}
    else
      rel
      |> Path.split()
      |> Enum.reduce_while({:ok, root, false, []}, fn component,
                                                      {:ok, current, saw_missing, missing} ->
        path = Path.join(current, component)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            if saw_missing,
              do: {:halt, {:error, :destination_parent_not_directory}},
              else: {:cont, {:ok, path, saw_missing, missing}}

          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, :destination_parent_symlink}}

          {:ok, _other} ->
            {:halt, {:error, :destination_parent_not_directory}}

          {:error, :enoent} ->
            # Chain deeper missing components from this (missing) path.
            {:cont, {:ok, path, true, missing ++ [path]}}

          {:error, _reason} ->
            {:halt, {:error, :destination_not_writable}}
        end
      end)
      |> case do
        {:ok, _current, _saw_missing, missing} -> {:ok, missing}
        {:error, _reason} = error -> error
      end
    end
  end

  # Create each missing ancestor one component at a time. Immediately
  # before each mkdir the immediate parent is re-lstat'd (must still be a
  # real directory), and after each mkdir the created component is
  # re-lstat'd and resolved to its real path, which must be unchanged and
  # inside the root -- so a component swapped to a symlink mid-walk is
  # caught and the walk never proceeds through it.
  defp create_missing_ancestors([]), do: :ok

  defp create_missing_ancestors([path | rest]) do
    parent = Path.dirname(path)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(parent),
         :ok <- mkdir_one(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, ^path} <- SafePath.resolve_real(path) do
      create_missing_ancestors(rest)
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :destination_parent_symlink}
      {:ok, _other} -> {:error, :destination_parent_not_directory}
      {:error, _reason} -> {:error, :destination_not_writable}
      _other -> {:error, :destination_parent_symlink}
    end
  end

  defp mkdir_one(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _reason} -> {:error, :destination_not_writable}
    end
  end

  defp require_within(path, root) do
    if SafePath.within?(path, root), do: :ok, else: {:error, :destination_path_escape}
  end

  defp require_parent_unredirected(parent, root) do
    case SafePath.resolve_real(parent) do
      {:ok, ^parent} ->
        if SafePath.within?(parent, root), do: :ok, else: {:error, :destination_path_escape}

      _other ->
        {:error, :destination_parent_symlink}
    end
  end

  # A destination may be created (absent) or replaced (a regular file with a
  # single link). Symlinks and every other shape are refused -- never written
  # through.
  defp admit_existing_destination(lexical) do
    case File.lstat(lexical) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :destination_symlink}
      {:ok, _other} -> {:error, :destination_not_regular}
      {:error, _reason} -> {:error, :destination_not_writable}
    end
  end

  # Publish through an exclusive temporary file inside the validated
  # parent plus an atomic rename. rename/2 replaces the destination's
  # directory entry itself and never follows a symlink parked at the
  # destination, so a post-admission symlink swap cannot redirect the bytes
  # outside the root; the verified parent's identity is revalidated
  # immediately before the rename.
  defp write_one(root, rel, bytes) do
    dest = Path.join(root, rel)
    parent = Path.dirname(dest)

    with {:ok, parent_identity} <- identity_of(parent) do
      case open_exclusive_temp(parent) do
        {:ok, temp} ->
          with :ok <- write_temp(temp, bytes),
               :ok <- require_same_identity(parent, parent_identity) do
            case :file.rename(temp.path, dest) do
              :ok ->
                :ok

              {:error, _reason} ->
                discard_temp(temp.path)
                {:error, :write_failed}
            end
          else
            {:error, _reason} = error ->
              discard_temp(temp.path)
              error
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp open_exclusive_temp(parent), do: open_exclusive_temp(parent, 0)

  defp open_exclusive_temp(parent, attempt) when attempt < @max_temp_attempts do
    name = ".safe_recovery_artifact.tmp.#{System.unique_integer([:positive, :monotonic])}"
    path = Path.join(parent, name)

    case File.open(path, [:write, :exclusive, :raw, :binary]) do
      {:ok, io} ->
        {:ok, %{path: path, io: io}}

      {:error, :eexists} ->
        open_exclusive_temp(parent, attempt + 1)

      {:error, _reason} ->
        {:error, :destination_not_writable}
    end
  end

  defp open_exclusive_temp(_parent, _attempt), do: {:error, :temp_unavailable}

  defp write_temp(%{path: path, io: io}, bytes) do
    case :file.write(io, bytes) do
      :ok ->
        :file.close(io)
        :ok

      {:error, _reason} ->
        :file.close(io)
        discard_temp(path)
        {:error, :write_failed}
    end
  end

  defp discard_temp(path) do
    _ = File.rm(path)
    :ok
  end

  defp identity_of(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.inode, stat.major_device, stat.minor_device}}

      {:ok, _other} ->
        {:error, :destination_parent_not_directory}

      {:error, _reason} ->
        {:error, :destination_not_writable}
    end
  end

  defp require_same_identity(path, identity) do
    with {:ok, identity_now} <- identity_of(path) do
      if identity_now == identity, do: :ok, else: {:error, :destination_parent_changed}
    end
  end

  # Post-admission, pre-publication TOCTOU seam used by the security
  # regression tests (mirrors the safe-recovery profile reader seam).
  defp emit_before_publish(root) do
    :telemetry.execute(@before_publish_event, %{count: 1}, %{root: root})
    :ok
  end

  defp readback(root, envelope_bytes, payload_bytes) do
    case read(root) do
      {:ok, %{envelope_bytes: ^envelope_bytes, payload_bytes: ^payload_bytes}} -> :ok
      {:ok, _other} -> {:error, :writeback_mismatch}
      {:error, _reason} -> {:error, :writeback_mismatch}
    end
  end
end
