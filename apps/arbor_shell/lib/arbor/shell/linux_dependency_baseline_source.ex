defmodule Arbor.Shell.LinuxDependencyBaselineSource do
  @moduledoc false

  # Imperative filesystem verifier for an offline root-owned Linux dependency
  # baseline source tree. Pins and walks a declared source root + manifest,
  # validates the actual inventory through LinuxDependencyBaselineCore, and
  # returns evidence-only Binding / plan / receipt values.
  #
  # This module is not a GenServer, materializer, public facade, or authority.
  # It never copies, chmods, mkdirs a destination, claims provisioning readiness,
  # or changes the spawn backend. Uses File/:file and TrustedPath only.

  import Bitwise

  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @max_manifest_bytes 32 * 1024 * 1024
  @chunk_size 65_536

  defmodule Binding do
    @moduledoc false

    @enforce_keys [
      :source_identity,
      :manifest_identity,
      :entry_identities,
      :state,
      :receipt
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            source_identity: Identity.t(),
            manifest_identity: Identity.t(),
            entry_identities: %{optional(String.t()) => Identity.t()},
            state: map(),
            receipt: map()
          }
  end

  @type trusted_path_module :: module()

  @doc """
  Pin and verify a source tree against its offline JSON baseline document.

  Both locators must already be lexically canonical absolute paths. Returns a
  `Binding` holding private pinned identities plus the actual validated state and
  compact receipt. Evidence only — never executable authority and never a claim
  that a private writable copy exists.
  """
  @spec pin(term(), term(), trusted_path_module()) ::
          {:ok, Binding.t()} | {:error, term()}
  def pin(source_root, manifest_path, trusted_path \\ TrustedPath)

  def pin(source_root, manifest_path, trusted_path)
      when is_binary(source_root) and is_binary(manifest_path) and is_atom(trusted_path) do
    limits = Core.limits()

    with {:ok, source_root} <- require_lexical_absolute(source_root, limits),
         {:ok, manifest_path} <- require_lexical_absolute(manifest_path, limits),
         :ok <- reject_locator_overlap(source_root, manifest_path),
         {:ok, source_identity} <- pin_source_root(source_root, trusted_path),
         {:ok, manifest_identity} <- pin_manifest(manifest_path, trusted_path),
         :ok <- enforce_manifest_size(manifest_identity),
         {:ok, declared_state, declared_entries} <-
           read_and_validate_declared(manifest_identity, trusted_path),
         {:ok, actual_entries, entry_identities} <-
           walk_source_tree(source_identity, limits, trusted_path),
         :ok <- reverify_all(source_identity, manifest_identity, entry_identities, trusted_path),
         {:ok, actual_state} <-
           validate_actual(declared_state, actual_entries, declared_entries) do
      binding = %Binding{
        source_identity: source_identity,
        manifest_identity: manifest_identity,
        entry_identities: entry_identities,
        state: actual_state,
        receipt: Core.show(actual_state)
      }

      {:ok, binding}
    end
  end

  def pin(_source_root, _manifest_path, _trusted_path), do: {:error, :invalid_locator}

  @doc """
  Re-verify every retained source, manifest, and entry identity.

  Fails closed on the first drift. Bound by the already-pinned entry set; used by
  a later owner before handing an evidence-only materialization plan to a copier.
  """
  @spec verify(Binding.t(), trusted_path_module()) :: :ok | {:error, term()}
  def verify(binding, trusted_path \\ TrustedPath)

  def verify(%Binding{} = binding, trusted_path) when is_atom(trusted_path) do
    with :ok <- validate_binding_shape(binding) do
      reverify_all(
        binding.source_identity,
        binding.manifest_identity,
        binding.entry_identities,
        trusted_path
      )
    end
  end

  def verify(_binding, _trusted_path), do: {:error, :invalid_binding}

  @doc """
  Project an evidence-only materialization plan from a verified Binding.

  Includes normalized inventory for a later copier. Never claims a private
  writable destination exists, never includes executable authority, and never
  reports provisioning status ready.
  """
  @spec plan(Binding.t()) :: map() | {:error, term()}
  def plan(%Binding{} = binding) do
    with :ok <- validate_binding_shape(binding),
         {:ok, entries} <- safe_materialization_entries(binding.state),
         {:ok, encoded} <- encode_entries(entries) do
      %{
        "kind" => "linux_dependency_baseline_source",
        "source_root" => binding.source_identity.path,
        "manifest_path" => binding.manifest_identity.path,
        "receipt" => binding.receipt,
        "materialization_entries" => encoded,
        "evidence_only" => true
      }
    end
  end

  def plan(_binding), do: {:error, :invalid_binding}

  # --- Binding shape validation (typed errors, never raise) ---

  defp validate_binding_shape(%Binding{
         source_identity: source_identity,
         manifest_identity: manifest_identity,
         entry_identities: entry_identities,
         state: state,
         receipt: receipt
       })
       when is_map(entry_identities) and is_map(state) and is_map(receipt) do
    with :ok <- validate_identity_shape(source_identity, :directory),
         :ok <- validate_identity_shape(manifest_identity, :regular),
         :ok <- validate_entry_identities_shape(entry_identities) do
      :ok
    end
  end

  defp validate_binding_shape(_binding), do: {:error, :invalid_binding}

  defp validate_identity_shape(
         %Identity{
           path: path,
           type: type,
           device: device,
           inode: inode,
           size: size,
           mtime: mtime,
           ctime: ctime,
           mode: mode,
           uid: uid,
           gid: gid,
           sha256: sha256,
           executable_required: executable_required
         },
         expected_type
       )
       when is_binary(path) and path != "" and type == expected_type and is_integer(device) and
              device >= 0 and is_integer(inode) and inode >= 0 and is_integer(size) and size >= 0 and
              is_integer(mtime) and is_integer(ctime) and is_integer(mode) and mode >= 0 and
              is_integer(uid) and uid >= 0 and is_integer(gid) and gid >= 0 and
              is_boolean(executable_required) do
    case {expected_type, sha256} do
      {:directory, nil} -> :ok
      {:regular, digest} when is_binary(digest) and digest != "" -> :ok
      _other -> {:error, :invalid_binding}
    end
  end

  defp validate_identity_shape(_identity, _expected_type), do: {:error, :invalid_binding}

  defp validate_entry_identities_shape(entry_identities) when is_map(entry_identities) do
    Enum.reduce_while(entry_identities, :ok, fn
      {path, %Identity{type: type} = identity}, :ok
      when is_binary(path) and path != "" and type in [:directory, :regular] ->
        case validate_identity_shape(identity, type) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, :ok ->
        {:halt, {:error, :invalid_binding}}
    end)
  end

  defp validate_entry_identities_shape(_), do: {:error, :invalid_binding}

  defp safe_materialization_entries(%{entries: entries}) when is_list(entries), do: {:ok, entries}
  defp safe_materialization_entries(_state), do: {:error, :invalid_binding}

  # --- Locator validation ---

  defp require_lexical_absolute(path, limits) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :empty_path}

      byte_size(path) > limits.max_path_bytes ->
        {:error, :path_too_long}

      not String.valid?(path) ->
        {:error, :invalid_utf8}

      String.contains?(path, <<0>>) ->
        {:error, :nul_byte}

      has_control_char?(path) ->
        {:error, :control_char}

      Path.type(path) != :absolute ->
        {:error, :relative_path}

      String.contains?(path, "//") ->
        {:error, :non_canonical_path}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, :trailing_slash}

      Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
        {:error, :dot_segment}

      true ->
        {:ok, path}
    end
  end

  defp require_lexical_absolute(_path, _limits), do: {:error, :invalid_path}

  defp reject_locator_overlap(source_root, manifest_path) do
    if segment_path_overlap?(source_root, manifest_path) do
      {:error, :locator_overlap}
    else
      :ok
    end
  end

  # Segment-aware ancestor/descendant rejection. Sibling prefixes such as
  # /baseline/source and /baseline/source-manifest do not overlap.
  defp segment_path_overlap?(path_a, path_b) when path_a == path_b, do: true

  defp segment_path_overlap?(path_a, path_b) do
    segments_a = Path.split(path_a)
    segments_b = Path.split(path_b)

    List.starts_with?(segments_a, segments_b) or List.starts_with?(segments_b, segments_a)
  end

  # --- Pinning ---

  defp pin_source_root(source_root, trusted_path) do
    with {:ok, lstat} <- lstat_entry(source_root),
         :ok <- require_directory_lstat(lstat),
         {:ok, identity} <- do_pin_source_root(source_root, trusted_path),
         :ok <-
           match_pinned_identity(identity, lstat, source_root, :directory, identity.device) do
      {:ok, identity}
    end
  end

  defp do_pin_source_root(source_root, trusted_path) do
    case trusted_path.pin_root_owned_directory(source_root) do
      {:ok, %Identity{type: :directory, path: ^source_root} = identity} ->
        {:ok, identity}

      {:ok, %Identity{type: :directory, path: _other}} ->
        {:error, :identity_path_mismatch}

      {:ok, %Identity{}} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_identity}
    end
  end

  # Preflight with File.lstat before TrustedPath so an already-oversized manifest
  # is rejected as :manifest_too_large without TrustedPath's generic 512 MiB
  # hash pass. TrustedPath is intentionally not expanded.
  defp pin_manifest(manifest_path, trusted_path) do
    with {:ok, lstat} <- preflight_manifest_lstat(manifest_path),
         {:ok, identity} <- do_pin_manifest(manifest_path, trusted_path),
         :ok <-
           match_pinned_identity(identity, lstat, manifest_path, :regular, lstat.major_device) do
      {:ok, identity}
    end
  end

  defp preflight_manifest_lstat(manifest_path) do
    case File.lstat(manifest_path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        cond do
          not valid_link_count?(stat.links) ->
            {:error, :hardlink_rejected}

          executable_mode?(stat.mode) ->
            {:error, :executable_manifest}

          not is_integer(stat.size) or stat.size < 0 ->
            {:error, :invalid_stat}

          stat.size > @max_manifest_bytes ->
            {:error, :manifest_too_large}

          true ->
            {:ok, stat}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, :not_a_regular_file}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_regular_file}

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :manifest_stat_failed}
    end
  end

  defp do_pin_manifest(manifest_path, trusted_path) do
    case trusted_path.pin_root_owned_regular_file(manifest_path, executable: false) do
      {:ok, %Identity{type: :regular, path: ^manifest_path} = identity} ->
        {:ok, identity}

      {:ok, %Identity{type: :regular, path: _other}} ->
        {:error, :identity_path_mismatch}

      {:ok, %Identity{}} ->
        {:error, :not_a_regular_file}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_identity}
    end
  end

  defp enforce_manifest_size(%Identity{size: size})
       when is_integer(size) and size >= 0 and size <= @max_manifest_bytes do
    :ok
  end

  defp enforce_manifest_size(%Identity{size: size})
       when is_integer(size) and size > @max_manifest_bytes do
    {:error, :manifest_too_large}
  end

  defp enforce_manifest_size(_identity), do: {:error, :invalid_identity}

  # --- Manifest document ---

  defp read_and_validate_declared(%Identity{} = manifest_identity, trusted_path) do
    with {:ok, bytes} <- read_bounded_file(manifest_identity.path, manifest_identity.size),
         :ok <- match_manifest_digest(bytes, manifest_identity.sha256),
         {:ok, document} <- decode_manifest_json(bytes),
         {:ok, declared_state} <- Core.new(document),
         :ok <- trusted_path.verify_pinned(manifest_identity) do
      {:ok, declared_state, Core.materialization_entries(declared_state)}
    end
  end

  defp read_bounded_file(path, expected_size)
       when is_binary(path) and is_integer(expected_size) and expected_size >= 0 do
    if expected_size > @max_manifest_bytes do
      {:error, :manifest_too_large}
    else
      case :file.open(path_charlist(path), [:read, :raw, :binary]) do
        {:ok, io} ->
          try do
            read_chunks(io, expected_size, 0, [])
          after
            :file.close(io)
          end

        {:error, :enoent} ->
          {:error, :path_not_found}

        {:error, _reason} ->
          {:error, :manifest_read_failed}
      end
    end
  end

  defp read_chunks(io, expected_size, read_so_far, acc) when read_so_far == expected_size do
    case :file.read(io, 1) do
      :eof ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, _extra} ->
        {:error, :manifest_size_mismatch}

      {:error, _reason} ->
        {:error, :manifest_read_failed}
    end
  end

  defp read_chunks(io, expected_size, read_so_far, acc) when read_so_far < expected_size do
    to_read = min(@chunk_size, expected_size - read_so_far)

    case :file.read(io, to_read) do
      :eof ->
        {:error, :manifest_size_mismatch}

      {:ok, data} ->
        new_size = read_so_far + byte_size(data)

        if new_size > @max_manifest_bytes do
          {:error, :manifest_too_large}
        else
          read_chunks(io, expected_size, new_size, [data | acc])
        end

      {:error, _reason} ->
        {:error, :manifest_read_failed}
    end
  end

  defp match_manifest_digest(bytes, expected_hex)
       when is_binary(bytes) and is_binary(expected_hex) do
    actual =
      :crypto.hash(:sha256, bytes)
      |> Base.encode16(case: :lower)

    if actual == expected_hex do
      :ok
    else
      {:error, :manifest_digest_mismatch}
    end
  end

  defp match_manifest_digest(_bytes, _expected), do: {:error, :manifest_digest_mismatch}

  defp decode_manifest_json(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, document} when is_map(document) ->
        {:ok, document}

      {:ok, _other} ->
        {:error, :invalid_manifest_json}

      {:error, _reason} ->
        {:error, :invalid_manifest_json}
    end
  end

  # --- Source tree walk ---

  defp walk_source_tree(%Identity{path: source_root, device: root_device}, limits, trusted_path) do
    case walk_directory(
           source_root,
           "",
           root_device,
           limits,
           trusted_path,
           [],
           %{},
           MapSet.new(),
           0,
           0
         ) do
      {:ok, entries, identities, _seen, _total_bytes, _entry_count} ->
        {:ok, Enum.reverse(entries), identities}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_directory(
         abs_dir,
         rel_prefix,
         root_device,
         limits,
         trusted_path,
         entries,
         identities,
         seen_inodes,
         total_bytes,
         entry_count
       ) do
    remaining = limits.max_entries - entry_count

    case list_directory_names(abs_dir, remaining) do
      {:ok, names} ->
        Enum.reduce_while(
          names,
          {:ok, entries, identities, seen_inodes, total_bytes, entry_count},
          fn name, {:ok, acc_entries, acc_identities, acc_seen, acc_bytes, acc_count} ->
            case admit_child(
                   abs_dir,
                   rel_prefix,
                   name,
                   root_device,
                   limits,
                   trusted_path,
                   acc_entries,
                   acc_identities,
                   acc_seen,
                   acc_bytes,
                   acc_count
                 ) do
              {:ok, next_entries, next_identities, next_seen, next_bytes, next_count} ->
                {:cont, {:ok, next_entries, next_identities, next_seen, next_bytes, next_count}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # File.ls/1 may allocate the full directory listing (OTP has no streaming
  # readdir). Bound subsequent work against remaining max_entries before sort.
  defp list_directory_names(_abs_dir, remaining) when is_integer(remaining) and remaining < 0 do
    {:error, :too_many_entries}
  end

  defp list_directory_names(abs_dir, remaining) when is_integer(remaining) and remaining >= 0 do
    case File.ls(abs_dir) do
      {:ok, names} ->
        case take_names_bounded(names, remaining) do
          {:ok, bounded} ->
            {:ok, Enum.sort(bounded)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :source_list_failed}
    end
  end

  # Accept at most `remaining` names; reject after observing one extra name
  # without sorting the unbounded tail.
  defp take_names_bounded(names, remaining) do
    take_names_bounded(names, remaining, 0, [])
  end

  defp take_names_bounded([], _remaining, _count, acc), do: {:ok, acc}

  defp take_names_bounded([_name | _rest], remaining, count, _acc) when count >= remaining do
    {:error, :too_many_entries}
  end

  defp take_names_bounded([name | rest], remaining, count, acc) do
    take_names_bounded(rest, remaining, count + 1, [name | acc])
  end

  defp admit_child(
         abs_dir,
         rel_prefix,
         name,
         root_device,
         limits,
         trusted_path,
         entries,
         identities,
         seen_inodes,
         total_bytes,
         entry_count
       ) do
    with :ok <- validate_name_component(name, limits),
         rel_path = join_rel(rel_prefix, name),
         :ok <- validate_relative_path(rel_path, limits),
         abs_path = Path.join(abs_dir, name),
         {:ok, lstat} <- lstat_entry(abs_path),
         :ok <- reject_device_crossing(lstat, root_device) do
      case lstat.type do
        :directory ->
          admit_directory(
            abs_path,
            rel_path,
            lstat,
            root_device,
            limits,
            trusted_path,
            entries,
            identities,
            seen_inodes,
            total_bytes,
            entry_count
          )

        :regular ->
          admit_regular(
            abs_path,
            rel_path,
            lstat,
            root_device,
            limits,
            trusted_path,
            entries,
            identities,
            seen_inodes,
            total_bytes,
            entry_count
          )

        :symlink ->
          {:error, :symlink_rejected}

        _other ->
          {:error, :unsupported_source_entry_type}
      end
    end
  end

  defp admit_directory(
         abs_path,
         rel_path,
         lstat,
         root_device,
         limits,
         trusted_path,
         entries,
         identities,
         seen_inodes,
         total_bytes,
         entry_count
       ) do
    if entry_count >= limits.max_entries do
      {:error, :too_many_entries}
    else
      with {:ok, identity} <- pin_entry_directory(abs_path, trusted_path),
           :ok <- match_pinned_identity(identity, lstat, abs_path, :directory, root_device) do
        entry = %{path: rel_path, type: "directory"}
        next_entries = [entry | entries]
        next_identities = Map.put(identities, rel_path, identity)

        walk_directory(
          abs_path,
          rel_path,
          root_device,
          limits,
          trusted_path,
          next_entries,
          next_identities,
          seen_inodes,
          total_bytes,
          entry_count + 1
        )
      end
    end
  end

  defp admit_regular(
         abs_path,
         rel_path,
         lstat,
         root_device,
         limits,
         trusted_path,
         entries,
         identities,
         seen_inodes,
         total_bytes,
         entry_count
       ) do
    inode_key = {lstat.major_device, lstat.inode}
    size = lstat.size

    cond do
      entry_count >= limits.max_entries ->
        {:error, :too_many_entries}

      not valid_link_count?(lstat.links) ->
        {:error, :hardlink_rejected}

      MapSet.member?(seen_inodes, inode_key) ->
        {:error, :hardlink_rejected}

      not is_integer(size) or size < 0 ->
        {:error, :invalid_stat}

      total_bytes + size > limits.max_total_bytes ->
        {:error, :total_bytes_exceeded}

      true ->
        with {:ok, identity} <- pin_entry_regular(abs_path, trusted_path),
             :ok <- match_pinned_identity(identity, lstat, abs_path, :regular, root_device),
             :ok <- confirm_pinned_regular_size(identity, size, total_bytes, limits) do
          new_total = total_bytes + identity.size

          entry = %{
            path: rel_path,
            type: "regular",
            size: identity.size,
            sha256: identity.sha256,
            executable: executable_mode?(identity.mode)
          }

          {:ok, [entry | entries], Map.put(identities, rel_path, identity),
           MapSet.put(seen_inodes, inode_key), new_total, entry_count + 1}
        end
    end
  end

  defp confirm_pinned_regular_size(%Identity{size: pinned_size}, lstat_size, total_bytes, limits)
       when is_integer(pinned_size) and pinned_size >= 0 do
    cond do
      pinned_size != lstat_size ->
        {:error, :identity_mismatch}

      total_bytes + pinned_size > limits.max_total_bytes ->
        {:error, :total_bytes_exceeded}

      true ->
        :ok
    end
  end

  defp confirm_pinned_regular_size(_identity, _lstat_size, _total_bytes, _limits) do
    {:error, :invalid_identity}
  end

  defp pin_entry_directory(abs_path, trusted_path) do
    case trusted_path.pin_root_owned_directory(abs_path) do
      {:ok, %Identity{type: :directory, path: ^abs_path} = identity} ->
        {:ok, identity}

      {:ok, %Identity{type: :directory, path: _other}} ->
        {:error, :identity_path_mismatch}

      {:ok, %Identity{}} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_identity}
    end
  end

  defp pin_entry_regular(abs_path, trusted_path) do
    case trusted_path.pin_root_owned_regular_file(abs_path, executable: false) do
      {:ok, %Identity{type: :regular, path: ^abs_path, sha256: sha256} = identity}
      when is_binary(sha256) ->
        {:ok, identity}

      {:ok, %Identity{type: :regular, path: _other}} ->
        {:error, :identity_path_mismatch}

      {:ok, %Identity{type: :regular, sha256: nil}} ->
        {:error, :invalid_identity}

      {:ok, %Identity{}} ->
        {:error, :not_a_regular_file}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_identity}
    end
  end

  # Require pinned Identity fields to match the pre-pin lstat observation and
  # remain on the source root's pinned device before accepting/descending.
  defp match_pinned_identity(
         %Identity{} = identity,
         %File.Stat{} = lstat,
         expected_path,
         expected_type,
         root_device
       )
       when is_binary(expected_path) and expected_type in [:directory, :regular] and
              is_integer(root_device) do
    cond do
      identity.path != expected_path ->
        {:error, :identity_path_mismatch}

      identity.type != expected_type ->
        {:error, :identity_mismatch}

      identity.device != root_device ->
        {:error, :device_crossing}

      identity.device != lstat.major_device ->
        {:error, :identity_mismatch}

      identity.inode != lstat.inode ->
        {:error, :identity_mismatch}

      identity.size != lstat.size ->
        {:error, :identity_mismatch}

      identity.mode != lstat.mode ->
        {:error, :identity_mismatch}

      identity.uid != lstat.uid ->
        {:error, :identity_mismatch}

      identity.gid != lstat.gid ->
        {:error, :identity_mismatch}

      identity.mtime != lstat.mtime ->
        {:error, :identity_mismatch}

      identity.ctime != lstat.ctime ->
        {:error, :identity_mismatch}

      true ->
        :ok
    end
  end

  defp match_pinned_identity(_identity, _lstat, _path, _type, _root_device) do
    {:error, :invalid_identity}
  end

  defp lstat_entry(abs_path) do
    case File.lstat(abs_path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :source_stat_failed}
    end
  end

  defp require_directory_lstat(%File.Stat{type: :directory}), do: :ok
  defp require_directory_lstat(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  defp require_directory_lstat(%File.Stat{}), do: {:error, :not_a_directory}

  defp reject_device_crossing(%File.Stat{major_device: device}, root_device)
       when device == root_device do
    :ok
  end

  defp reject_device_crossing(%File.Stat{}, _root_device), do: {:error, :device_crossing}

  # Reject every regular file whose link count is not exactly 1, including when
  # the second hardlink lives outside source_root.
  defp valid_link_count?(1), do: true
  defp valid_link_count?(_links), do: false

  defp validate_name_component(name, limits) when is_binary(name) do
    cond do
      name == "" ->
        {:error, :empty_path_segment}

      name == "." ->
        {:error, :dot_path_segment}

      name == ".." ->
        {:error, :dotdot_path_segment}

      byte_size(name) > limits.max_component_bytes ->
        {:error, :path_component_too_long}

      not String.valid?(name) ->
        {:error, :invalid_utf8}

      String.contains?(name, <<0>>) or has_control_char?(name) ->
        {:error, :unsafe_path}

      String.contains?(name, "/") ->
        {:error, :unsafe_path}

      true ->
        :ok
    end
  end

  defp validate_name_component(_name, _limits), do: {:error, :unsafe_path}

  defp validate_relative_path(path, limits) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :empty_path}

      byte_size(path) > limits.max_path_bytes ->
        {:error, :path_too_long}

      String.starts_with?(path, "/") ->
        {:error, :absolute_path}

      String.ends_with?(path, "/") ->
        {:error, :trailing_slash}

      not String.valid?(path) ->
        {:error, :invalid_utf8}

      String.contains?(path, <<0>>) or has_control_char?(path) ->
        {:error, :unsafe_path}

      true ->
        segments = String.split(path, "/", trim: false)

        cond do
          Enum.any?(segments, &(&1 == "")) ->
            {:error, :empty_path_segment}

          length(segments) > limits.max_path_depth ->
            {:error, :path_depth_exceeded}

          Enum.any?(segments, &(&1 == ".")) ->
            {:error, :dot_path_segment}

          Enum.any?(segments, &(&1 == "..")) ->
            {:error, :dotdot_path_segment}

          Enum.any?(segments, &(byte_size(&1) > limits.max_component_bytes)) ->
            {:error, :path_component_too_long}

          true ->
            :ok
        end
    end
  end

  defp validate_relative_path(_path, _limits), do: {:error, :invalid_entry_path}

  defp join_rel("", name), do: name
  defp join_rel(prefix, name), do: prefix <> "/" <> name

  # --- Re-verify and actual validation ---

  defp reverify_all(source_identity, manifest_identity, entry_identities, trusted_path) do
    with :ok <- trusted_path.verify_pinned(source_identity),
         :ok <- trusted_path.verify_pinned(manifest_identity) do
      entry_identities
      |> Enum.sort_by(fn {path, _identity} -> path end)
      |> Enum.reduce_while(:ok, fn {_path, identity}, :ok ->
        case trusted_path.verify_pinned(identity) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_actual(declared_state, actual_entries, declared_entries) do
    document = %{
      manifest: %{
        schema: declared_state.schema,
        platform: declared_state.platform,
        image_index_digest: declared_state.image_index_digest,
        image_manifest_digest: declared_state.image_manifest_digest,
        mix_lock_digest: declared_state.mix_lock_digest,
        baseline_tree_digest: declared_state.baseline_tree_digest,
        toolchain: declared_state.toolchain,
        entry_count: declared_state.entry_count,
        total_bytes: declared_state.total_bytes
      },
      entries: actual_entries
    }

    case Core.new(document) do
      {:ok, actual_state} ->
        actual_materialized = Core.materialization_entries(actual_state)

        if actual_materialized == declared_entries do
          {:ok, actual_state}
        else
          {:error, :inventory_mismatch}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case encode_entry(entry) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_entries(_entries), do: {:error, :invalid_binding}

  defp encode_entry(%{path: path, type: "directory"}) when is_binary(path) do
    {:ok, %{"path" => path, "type" => "directory"}}
  end

  defp encode_entry(%{
         path: path,
         type: "regular",
         size: size,
         sha256: sha256,
         executable: executable
       })
       when is_binary(path) and is_integer(size) and size >= 0 and is_binary(sha256) and
              is_boolean(executable) do
    {:ok,
     %{
       "path" => path,
       "type" => "regular",
       "size" => size,
       "sha256" => sha256,
       "executable" => executable
     }}
  end

  defp encode_entry(_entry), do: {:error, :invalid_binding}

  defp executable_mode?(mode) when is_integer(mode), do: (mode &&& 0o111) != 0
  defp executable_mode?(_mode), do: false

  defp path_charlist(path) when is_binary(path), do: String.to_charlist(path)

  defp has_control_char?(value) when is_binary(value), do: has_control_char_bytes?(value)

  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)
end
