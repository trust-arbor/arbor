defmodule Arbor.Shell.TrustedBuild.PostPhase do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Shell.TrustedBuild.BeamIdentity
  alias Arbor.Shell.TrustedBuild.Identity
  alias Arbor.Shell.TrustedBuild.Inventory
  alias Arbor.Shell.TrustedBuild.NativeFs
  alias Arbor.Shell.TrustedBuild.NativeOverlay
  alias Arbor.Shell.TrustedBuild.Plan

  @max_selector_bytes 4_096
  @max_term_body 256 * 1024

  @spec verify_pinned_source_tree(map()) :: :ok | {:error, atom()}
  def verify_pinned_source_tree(%{
        source: source,
        source_owned: source_owned,
        project: project,
        wrapper: wrapper,
        overlay: overlay,
        source_tree_digest: digest
      })
      when is_binary(digest) do
    with :ok <- verify_source_pins(source_owned, source, project, wrapper, overlay),
         {:ok, ^digest} <- Identity.tree_digest(source_owned.path),
         :ok <- verify_source_pins(source_owned, source, project, wrapper, overlay) do
      :ok
    else
      false -> {:error, :identity_mismatch}
      {:ok, _other} -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_pinned_source_tree(_identities), do: {:error, :identity_mismatch}

  @spec stage(map()) :: {:ok, map(), map()} | {:error, atom()} | {:lock, atom()}
  def stage(%{identities: identities, roots: roots} = state) do
    dest_rel = NativeOverlay.dest_rel()

    with :ok <- verify_pinned_source_tree(identities),
         :ok <- Identity.verify_writable(roots.deps),
         {:ok, bytes} <- read_pinned_overlay(identities.overlay),
         :ok <- verify_pinned_source_tree(identities),
         {:ok, contained} <- SafePath.safe_join(roots.deps.path, dest_rel),
         dest_path = Path.join([roots.deps.path | NativeOverlay.dest_segments()]),
         true <- Path.expand(contained) == Path.expand(dest_path),
         :ok <- ensure_dest_parents(roots.deps, dest_rel),
         {:ok, dest} <-
           stage_destination(
             dest_path,
             bytes,
             identities.overlay,
             roots.deps,
             state.fault
           ),
         :ok <- verify_staged_native_identity(dest, roots.deps),
         :ok <- verify_pinned_source_tree(identities) do
      {:ok,
       %{
         "schema" => "arbor.shell.trusted_build.native_stage.v1",
         "path" => dest_rel,
         "size" => NativeOverlay.size(),
         "sha256" => NativeOverlay.sha256()
       }, dest}
    else
      false -> {:lock, :identity_mismatch}
      {:lock, reason} -> {:lock, reason}
      {:error, reason} -> classify_stage_error(reason)
    end
  end

  def stage(_state), do: {:lock, :identity_mismatch}

  @spec remove_cookie(map()) :: {:ok, map()} | {:error, atom()} | {:lock, atom()}
  def remove_cookie(%{roots: roots} = state) do
    cookie_rel = NativeOverlay.cookie_rel()

    with :ok <- Identity.verify_writable(roots.build),
         {:ok, contained} <- SafePath.safe_join(roots.build.path, cookie_rel),
         cookie_path = Path.join([roots.build.path | NativeOverlay.cookie_segments()]),
         true <- Path.expand(contained) == Path.expand(cookie_path),
         :ok <- require_cookie_present(cookie_path),
         :ok <- maybe_hardlink(cookie_path, state.fault, :force_cookie_hardlink_before_unlink),
         :ok <- quarantine_cookie(cookie_path, roots.build, NativeOverlay.cookie_segments()),
         :ok <- maybe_recreate_cookie(cookie_path, state.fault),
         :ok <- prove_path_absent(cookie_path, :cookie) do
      {:ok,
       %{
         "schema" => "arbor.shell.trusted_build.cookie.v1",
         "path" => NativeOverlay.cookie_inventory_path(),
         "removed" => true
       }}
    else
      false -> {:lock, :identity_mismatch}
      {:error, :trusted_build_release_cookie_absent} = error -> error
      {:lock, reason} -> {:lock, reason}
      {:error, reason} -> {:lock, lock_reason(reason)}
    end
  end

  def remove_cookie(_state), do: {:lock, :identity_mismatch}

  @spec read_descriptor(map(), term()) :: {:ok, map()} | {:error, atom()} | {:lock, atom()}
  def read_descriptor(%{release_inventory: inventory, roots: roots}, selector)
      when is_map(inventory) do
    with {:ok, rel} <- admit_selector(selector),
         {:ok, entry} <- attested_entry(inventory, rel),
         :ok <- Identity.verify_writable(roots.build),
         {:ok, _path} <- SafePath.safe_join(roots.build.path, Path.join("rel", rel)),
         {:ok, bytes} <-
           NativeFs.read_descriptor(roots.build, rel, entry["size"], entry["sha256"]),
         :ok <- Identity.verify_writable(roots.build) do
      {:ok, %{"path" => rel, "bytes" => bytes}}
    else
      {:lock, reason} -> {:lock, reason}
      {:error, reason} -> classify_read_error(reason)
    end
  end

  def read_descriptor(_state, _selector), do: {:error, :trusted_build_release_absent}

  @spec rescan_deps_document(map()) :: {:ok, map()} | {:error, atom()}
  def rescan_deps_document(%{roots: %{deps: deps}} = state) do
    with :ok <- verify_staged_native(state),
         {:ok, document} <- Inventory.deps_document(deps.path),
         :ok <- verify_staged_native(state) do
      {:ok, document}
    end
  end

  def rescan_deps_document(_state), do: {:error, :identity_mismatch}

  @spec verify_staged_native(map()) :: :ok | {:error, atom()}
  def verify_staged_native(%{native_staged: dest, roots: %{deps: deps}})
      when is_map(dest) do
    verify_staged_native_identity(dest, deps)
  end

  def verify_staged_native(_state), do: {:error, :identity_mismatch}

  @spec scan_release_document(map()) :: {:ok, map()} | {:error, atom()}
  def scan_release_document(%{roots: %{build: build}} = state) do
    with :ok <- Identity.verify_writable(build),
         :ok <- maybe_normalize_release_beams(state),
         {:ok, document} <- Inventory.release_document(build.path),
         :ok <- Identity.verify_writable(build) do
      {:ok, document}
    end
  end

  def scan_release_document(_state), do: {:error, :identity_mismatch}

  defp maybe_normalize_release_beams(%{
         roots: %{build: %{path: build_path}, parent: %{path: workspace_path}},
         identities: %{source_owned: %{path: identity_path}}
       })
       when is_binary(build_path) and is_binary(workspace_path) and is_binary(identity_path) do
    replacements =
      BeamIdentity.replacements(path_spellings(identity_path), path_spellings(workspace_path))

    BeamIdentity.normalize_release_tree(Path.join(build_path, "rel"), replacements)
  end

  defp maybe_normalize_release_beams(_state), do: :ok

  defp path_spellings(path) do
    expanded = Path.expand(path)

    resolved =
      case SafePath.resolve_real(path) do
        {:ok, real} -> [real]
        _other -> []
      end

    Enum.uniq([path, expanded | resolved])
  end

  defp verify_source_pins(source_owned, source, project, wrapper, overlay) do
    with :ok <- Identity.verify_owned_identity(source_owned),
         :ok <- Identity.verify_directory(source),
         :ok <- Identity.verify_directory(project),
         :ok <- Identity.verify_file(wrapper),
         :ok <- Identity.verify_file(overlay),
         true <- NativeOverlay.matches_pin?(overlay),
         :ok <- Identity.verify_ancestry(source_owned, source, ["source"]),
         :ok <- Identity.verify_ancestry(source, project, Plan.project_root_segments()),
         :ok <- Identity.verify_ancestry(source, wrapper, ["bin", "mix"]),
         :ok <-
           Identity.verify_ancestry(source_owned, overlay, NativeOverlay.staging_segments()) do
      :ok
    else
      false -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_staged_native_identity(dest, deps) do
    with :ok <- Identity.verify_writable(deps),
         {:ok, current} <- pin_staged_native(deps),
         true <- current == dest,
         true <- NativeOverlay.matches_pin?(current),
         :ok <- Identity.verify_writable(deps) do
      :ok
    else
      false -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_pinned_overlay(overlay) do
    with :ok <- Identity.verify_file(overlay),
         true <- NativeOverlay.matches_pin?(overlay),
         {:ok, io} <- open_read(overlay.path) do
      try do
        with {:ok, opened} <- fd_regular_identity(io),
             :ok <- path_matches_fd(overlay.path, opened),
             {:ok, bytes} <- read_exact(io, NativeOverlay.size()),
             {:ok, final} <- fd_regular_identity(io),
             true <- same_fd_identity?(opened, final),
             :ok <- path_matches_fd(overlay.path, final),
             true <- sha256_hex(bytes) == NativeOverlay.sha256() do
          {:ok, bytes}
        else
          false -> {:lock, :identity_mismatch}
          {:error, reason} -> {:lock, lock_reason(reason)}
        end
      after
        :file.close(io)
      end
    else
      false -> {:lock, :identity_mismatch}
      {:error, reason} -> {:lock, lock_reason(reason)}
    end
  end

  defp ensure_dest_parents(deps, dest_rel) do
    parents = dest_rel |> Path.split() |> Enum.drop(-1)

    Enum.reduce_while(parents, {:ok, deps.path}, fn segment, {:ok, acc} ->
      if segment in ["", ".", ".."] or String.contains?(segment, ["/", "\\", <<0>>]) do
        {:halt, {:lock, :identity_mismatch}}
      else
        next = Path.join(acc, segment)

        case admit_or_create_dir(next, deps) do
          :ok -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:lock, lock_reason(reason)}}
        end
      end
    end)
    |> case do
      {:ok, parent_path} ->
        verify_dest_parent(deps, parent_path, parents)

      other ->
        other
    end
  end

  defp admit_or_create_dir(path, deps) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: :directory} = stat} ->
        if stat.major_device == deps.device do
          :ok
        else
          {:error, :identity_mismatch}
        end

      {:ok, %File.Stat{}} ->
        {:error, :not_a_directory}

      {:error, :enoent} ->
        case :file.make_dir(String.to_charlist(path)) do
          :ok ->
            :ok

          {:error, :eexist} ->
            admit_or_create_dir(path, deps)

          {:error, _reason} ->
            {:error, :owned_tree_create_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_dest_parent(deps, parent_path, parent_segments) do
    case Identity.pin_directory(parent_path) do
      {:ok, parent} -> Identity.verify_ancestry(deps, parent, parent_segments)
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_destination(dest_path, bytes, overlay, deps, fault) do
    case exclusive_write_dest(dest_path, bytes, overlay, deps, fault) do
      {:exists, :destination} ->
        with :ok <-
               maybe_hardlink(
                 dest_path,
                 fault,
                 :force_native_dest_hardlink_before_admission
               ),
             {:ok, dest} <- pin_staged_native(deps),
             true <- NativeOverlay.matches_pin?(dest),
             :ok <- Identity.verify_file(overlay) do
          {:ok, dest}
        else
          false -> {:lock, :trusted_build_native_replacement}
          {:lock, reason} -> {:lock, reason}
          {:error, reason} -> {:lock, lock_reason(reason)}
        end

      result ->
        result
    end
  end

  defp pin_staged_native(deps) do
    NativeFs.pin_native_overlay(deps, NativeOverlay.size(), NativeOverlay.sha256())
  end

  defp maybe_recreate_cookie(cookie_path, :force_cookie_recreate_after_unlink) do
    case exclusive_create_decoy(cookie_path) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_recreate_cookie(_cookie_path, _fault), do: :ok

  defp maybe_hardlink(path, fault, fault)
       when fault in [
              :force_native_dest_hardlink_before_admission,
              :force_cookie_hardlink_before_unlink
            ] do
    extra = path <> ".arbor-link"

    case :file.make_link(String.to_charlist(path), String.to_charlist(extra)) do
      :ok -> :ok
      {:error, reason} -> {:lock, lock_reason(reason)}
    end
  end

  defp maybe_hardlink(_path, _fault, _expected), do: :ok

  defp quarantine_cookie(path, root, segments) do
    parent_segments = Enum.drop(segments, -1)

    with {:ok, parent} <- Identity.pin_directory(Path.dirname(path)),
         :ok <- Identity.verify_ancestry(root, parent, parent_segments),
         :ok <- NativeFs.quarantine_cookie(root),
         :ok <- prove_path_absent(path, :cookie),
         :ok <- Identity.verify_writable(root),
         :ok <- Identity.verify_directory(parent),
         :ok <- Identity.verify_ancestry(root, parent, parent_segments) do
      :ok
    else
      {:error, reason} when reason in [:enoent, :path_not_found] ->
        {:lock, :trusted_build_cookie_replacement}

      {:lock, reason} ->
        {:lock, reason}

      {:error, reason} ->
        {:lock, lock_reason(reason)}
    end
  end

  # The verified 0700 dependency root is the permission boundary. Keep the
  # exclusive descriptor held throughout; a pathname chmod here could follow a
  # raced symlink and mutate a different inode.
  defp exclusive_write_dest(dest_path, bytes, overlay, deps, fault) do
    case :file.open(String.to_charlist(dest_path), [:read, :write, :raw, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- write_all(io, bytes),
               {:ok, 0} <- :file.position(io, 0),
               {:ok, written} <- read_exact(io, byte_size(bytes)),
               true <- written == bytes,
               {:ok, opened} <- fd_regular_identity(io),
               true <- opened.size == byte_size(bytes) and opened.nlink == 1,
               :ok <- path_matches_fd(dest_path, opened),
               true <- sha256_hex(written) == NativeOverlay.sha256(),
               :ok <- maybe_replace_dest_before_seal(dest_path, fault),
               {:ok, after_write} <- fd_regular_identity(io),
               true <- same_fd_identity?(opened, after_write),
               :ok <- path_matches_fd(dest_path, after_write),
               {:ok, dest} <- pin_staged_native(deps),
               true <- NativeOverlay.matches_pin?(dest),
               true <- same_staged_destination?(dest, after_write),
               :ok <- path_matches_fd(dest_path, after_write),
               :ok <- Identity.verify_file(overlay) do
            {:ok, dest}
          else
            false -> {:lock, :identity_mismatch}
            {:error, :eexist} -> {:lock, :trusted_build_native_replacement}
            {:error, reason} -> {:lock, lock_reason(reason)}
          end
        after
          :file.close(io)
        end

      {:error, :eexist} ->
        {:exists, :destination}

      {:error, reason} ->
        {:lock, lock_reason(reason)}
    end
  end

  defp maybe_replace_dest_before_seal(dest_path, :force_native_dest_symlink_before_seal) do
    parent_depth = NativeOverlay.dest_segments() |> Enum.drop(-1) |> length()
    relative_root = List.duplicate("..", parent_depth) |> Path.join()

    with :ok <- File.rm(dest_path) do
      :file.make_symlink(String.to_charlist(relative_root), String.to_charlist(dest_path))
    end
  end

  defp maybe_replace_dest_before_seal(_dest_path, _fault), do: :ok

  defp require_cookie_present(path) do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} -> {:error, :trusted_build_release_cookie_absent}
      {:ok, %File.Stat{type: :symlink}} -> {:lock, :symlink_rejected}
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:lock, :hardlink_rejected}
      {:ok, %File.Stat{}} -> {:lock, :not_a_regular_file}
      {:error, reason} -> {:lock, lock_reason(reason)}
    end
  end

  defp prove_path_absent(path, kind) do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{}} -> {:lock, replacement_reason(kind)}
      {:error, reason} -> {:lock, lock_reason(reason)}
    end
  end

  defp exclusive_create_decoy(path) do
    case :file.open(String.to_charlist(path), [:write, :raw, :binary, :exclusive]) do
      {:ok, io} ->
        _ = :file.write(io, "decoy")
        :file.close(io)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admit_selector(selector) when is_binary(selector) do
    cond do
      selector == "" ->
        {:error, :invalid_trusted_build_descriptor}

      byte_size(selector) > @max_selector_bytes ->
        {:error, :invalid_trusted_build_descriptor}

      not String.valid?(selector) ->
        {:error, :invalid_trusted_build_descriptor}

      String.contains?(selector, <<0>>) ->
        {:error, :invalid_trusted_build_descriptor}

      Path.type(selector) == :absolute ->
        {:error, :invalid_trusted_build_descriptor}

      not (String.ends_with?(selector, ".app") or String.ends_with?(selector, ".rel")) ->
        {:error, :trusted_build_descriptor_unattested}

      true ->
        segments = Path.split(selector)

        if Enum.any?(segments, &(&1 in ["", ".", ".."])) or
             Enum.any?(segments, &String.contains?(&1, ["\\", <<0>>])) do
          {:error, :invalid_trusted_build_descriptor}
        else
          {:ok, selector}
        end
    end
  end

  defp admit_selector(_selector), do: {:error, :invalid_trusted_build_descriptor}

  defp attested_entry(%{"regular_files" => files}, rel) when is_list(files) do
    case Enum.find(files, &(&1["path"] == rel)) do
      %{"size" => size, "sha256" => digest} = entry
      when is_integer(size) and is_binary(digest) ->
        if size > @max_term_body do
          {:error, :trusted_build_descriptor_unbounded}
        else
          {:ok, entry}
        end

      nil ->
        {:error, :trusted_build_descriptor_unattested}

      _other ->
        {:error, :trusted_build_descriptor_unattested}
    end
  end

  defp attested_entry(_inventory, _rel), do: {:error, :trusted_build_release_absent}

  defp open_read(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_all(io, bytes) do
    case :file.write(io, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_exact(io, size) do
    case :file.read(io, size + 1) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      {:ok, bytes} when byte_size(bytes) > size -> {:error, :identity_changed}
      {:ok, _bytes} -> {:error, :identity_changed}
      :eof when size == 0 -> {:ok, ""}
      :eof -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fd_regular_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        stat = File.Stat.from_record(info)
        regular_fd_identity(stat)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp regular_fd_identity(%File.Stat{type: :regular} = stat) do
    {:ok,
     %{
       type: :regular,
       device: stat.major_device,
       minor_device: stat.minor_device,
       inode: stat.inode,
       size: stat.size,
       mtime: stat.mtime,
       ctime: stat.ctime,
       nlink: stat.links
     }}
  end

  defp regular_fd_identity(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  defp regular_fd_identity(%File.Stat{}), do: {:error, :not_a_regular_file}

  defp path_matches_fd(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        case regular_fd_identity(stat) do
          {:ok, ^expected} -> :ok
          {:ok, _other} -> {:error, :identity_changed}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_regular_file}

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_fd_identity?(left, right) do
    left == right
  end

  defp same_staged_destination?(pinned, fd) do
    pinned.device == fd.device and pinned.inode == fd.inode and pinned.size == fd.size and
      pinned.nlink == fd.nlink
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp classify_stage_error(reason) when reason in [:path_not_found, :not_a_regular_file],
    do: {:lock, :identity_mismatch}

  defp classify_stage_error(reason), do: {:lock, lock_reason(reason)}

  defp classify_read_error(reason)
       when reason in [
              :invalid_trusted_build_descriptor,
              :trusted_build_descriptor_unattested,
              :trusted_build_descriptor_unbounded,
              :trusted_build_release_absent
            ],
       do: {:error, reason}

  defp classify_read_error(reason), do: {:lock, lock_reason(reason)}

  defp replacement_reason(:cookie), do: :trusted_build_cookie_replacement
  defp replacement_reason(_kind), do: :trusted_build_native_replacement

  defp lock_reason(reason)
       when reason in [
              :identity_mismatch,
              :identity_changed,
              :hardlink_rejected,
              :symlink_rejected,
              :not_a_regular_file,
              :trusted_build_native_replacement,
              :trusted_build_cookie_replacement,
              :trusted_build_post_phase_timeout,
              :trusted_build_post_phase_launch_failed,
              :trusted_build_unavailable,
              :trusted_build_wrapper_identity_mismatch,
              :untrusted_mode,
              :untrusted_owner,
              :file_too_large,
              :stat_failed,
              :path_not_found,
              :invalid_path,
              :invalid_identity
            ],
       do: reason

  defp lock_reason(_reason), do: :identity_mismatch
end
