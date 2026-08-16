defmodule Arbor.Commands.SafeRecoveryArtifact.SourceStaging do
  @moduledoc false

  alias Arbor.Commands.ImmutableGitSource
  alias Arbor.Commands.ImmutableGitSource.Git
  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SafeRecoveryArtifact.{Encode, Overlay, SourceLease, SourcePolicy}
  alias Arbor.Common.SafePath

  @production_opt_keys MapSet.new([:root, :timeout_ms])
  @test_opt_keys MapSet.new([
                   :root,
                   :timeout_ms,
                   :overlay_bytes,
                   :overlay_sha256,
                   :cleanup_fault,
                   :max_entries,
                   :max_listing_bytes,
                   :max_object_bytes,
                   :max_total_bytes,
                   :max_symlink_bytes
                 ])
  @default_timeout_ms 300_000
  @max_timeout_ms 3_600_000
  @max_create_attempts 16
  @root_token_bytes 32
  @max_file_bytes 16_777_216
  @max_total_bytes 268_435_456
  @ls_files_chunk 64
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @stage_line ~r/\A([0-7]{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-3])\t(.+)\z/
  @cleanup_opts [max_entries: 1_000_000, timeout_ms: 10_000]

  @spec stage(keyword(), :production | :test) :: {:ok, map()} | {:error, term()}
  def stage(opts, kind) when is_list(opts) and kind in [:production, :test] do
    with {:ok, admitted} <- admit_opts(opts, kind),
         {:ok, root} <- resolve_root(admitted.root),
         {:ok, timeout_ms} <- admit_timeout(admitted.timeout_ms),
         :ok <- reject_source_alternates(root, timeout_ms),
         {:ok, head} <- bind_head(root, timeout_ms),
         {:ok, blobs} <- list_commit_blobs(root, head.commit, timeout_ms),
         {:ok, selected} <- SourcePolicy.select(blobs),
         :ok <- enforce_source_count(selected),
         :ok <- prove_selected_equality(root, head, selected, blobs, timeout_ms),
         :ok <- classify_status(root, timeout_ms),
         :ok <- reject_ignored_selected(root, timeout_ms) do
      continue_after_proof(root, head, selected, blobs, admitted, timeout_ms, kind)
    end
  end

  def stage(_opts, _kind), do: {:error, :invalid_opts}

  @spec release(term()) :: :ok | {:error, term()}
  def release(lease) do
    with {:ok, admitted} <- SourceLease.admit(lease) do
      remove_identity(SourceLease.owned_identity(admitted))
    end
  end

  @spec release_for_test(term()) :: :ok | {:error, term()}
  def release_for_test(lease) do
    with {:ok, admitted} <- SourceLease.admit_for_test(lease) do
      remove_identity(SourceLease.owned_identity(admitted))
    end
  end

  @spec release_for_test(term(), :force_cleanup_failure) :: :ok | {:error, term()}
  def release_for_test(lease, :force_cleanup_failure) do
    with {:ok, admitted} <- SourceLease.admit_for_test(lease),
         :ok <- force_identity_mismatch(SourceLease.owned_identity(admitted)) do
      remove_identity(SourceLease.owned_identity(admitted))
    end
  end

  def release_for_test(_lease, _fault), do: {:error, :invalid_opts}

  defp continue_after_proof(root, head, selected, blobs, admitted, timeout_ms, kind) do
    case create_owned_root() do
      {:ok, identity} ->
        after_root_created(root, head, selected, blobs, admitted, timeout_ms, kind, identity)

      {:error, {:owned_tree_cleanup_retained, reason, %{identity: retained}}}
      when is_map(retained) ->
        {:error, {:cleanup_retained, reason, retained}}

      {:error, _reason} ->
        {:error, :root_create_failed}
    end
  end

  defp after_root_created(root, head, selected, blobs, admitted, timeout_ms, kind, identity) do
    if kind == :test and admitted.cleanup_fault == :fail_release_after_error do
      fail_release_after_error(identity)
    else
      finish_staging(root, head, selected, blobs, admitted, timeout_ms, kind, identity)
    end
  end

  defp finish_staging(root, head, selected, blobs, admitted, timeout_ms, kind, identity) do
    with :ok <-
           reconstruct_source(root, head, identity, admitted, timeout_ms, kind),
         source_root = Path.join(identity.path, "source"),
         {:ok, facts} <-
           reconstructed_facts(source_root, selected, blobs, head.object_format),
         {:ok, overlay} <- bind_overlay(root, admitted, kind),
         {:ok, overlay_path} <- stage_overlay(identity, overlay) do
      inputs =
        [%{"path" => overlay.path, "sha256" => overlay.sha256} | facts]
        |> Enum.sort_by(& &1["path"])

      attrs = %{
        "commit" => head.commit,
        "tree" => head.tree,
        "object_format" => head.object_format,
        "reconstructed_tree" => head.tree,
        "build_inputs" => inputs,
        "source_root" => source_root,
        "overlay_path" => overlay_path,
        "identity" => identity
      }

      if kind == :test do
        SourceLease.build_for_test(attrs)
      else
        SourceLease.build(attrs)
      end
    else
      {:error, reason} ->
        settle_failure(identity, reason)
    end
  end

  defp fail_release_after_error(identity) do
    _ = force_identity_mismatch(identity)

    case remove_identity(identity) do
      :ok -> {:error, :root_create_failed}
      {:error, {:cleanup_retained, _, _}} = error -> error
      {:error, reason} -> {:error, {:cleanup_retained, reason, identity}}
    end
  end

  defp settle_failure(identity, reason) do
    case remove_identity(identity) do
      :ok -> wrap_reconstruct(reason)
      {:error, {:cleanup_retained, _, _}} = error -> error
      {:error, cleanup} -> {:error, {:cleanup_retained, cleanup, identity}}
    end
  end

  defp wrap_reconstruct(reason) when is_atom(reason), do: {:error, reason}
  defp wrap_reconstruct({:cleanup_retained, _, _} = reason), do: {:error, reason}
  defp wrap_reconstruct(reason), do: {:error, {:reconstruct, reason}}

  defp reconstruct_source(root, head, identity, admitted, timeout_ms, :test) do
    limits =
      admitted
      |> Map.take([
        :max_entries,
        :max_listing_bytes,
        :max_object_bytes,
        :max_total_bytes,
        :max_symlink_bytes
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ImmutableGitSource.reconstruct_for_test(
      root,
      "source",
      head.commit,
      head.tree,
      identity,
      [timeout_ms: timeout_ms] ++ limits
    )
  end

  defp reconstruct_source(root, head, identity, _admitted, timeout_ms, :production) do
    ImmutableGitSource.reconstruct(root, "source", head.commit, head.tree, identity,
      timeout_ms: timeout_ms
    )
  end

  defp bind_overlay(root, admitted, :test)
       when is_binary(admitted.overlay_bytes) and is_binary(admitted.overlay_sha256) do
    with :ok <- write_test_overlay(root, admitted.overlay_bytes) do
      Overlay.bind_expected(root, byte_size(admitted.overlay_bytes), admitted.overlay_sha256)
    end
  end

  defp bind_overlay(root, _admitted, _kind), do: Overlay.bind(root)

  defp stage_overlay(identity, %{bytes: bytes, sha256: digest}) do
    dest = SourceLease.expected_overlay_path(identity.path)

    with true <- String.starts_with?(dest, identity.path <> "/"),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- write_exclusive_file(dest, bytes),
         {:ok, reread} <- read_bound_file(dest, byte_size(bytes), :reconstructed),
         true <- sha256_hex(reread) == digest and byte_size(reread) == byte_size(bytes) do
      {:ok, dest}
    else
      false -> {:error, :overlay_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_exclusive_file(path, content) do
    case File.open(path, [:write, :binary, :exclusive], fn io -> IO.binwrite(io, content) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _reason}} -> {:error, :overlay_missing}
      {:error, _reason} -> {:error, :overlay_missing}
    end
  end

  defp enforce_source_count(selected) when is_list(selected) do
    if length(selected) > SourcePolicy.max_source_rows() do
      {:error, :file_limit}
    else
      :ok
    end
  end

  defp write_test_overlay(root, bytes) do
    with {:ok, path} <- SafePath.safe_join(root, Overlay.logical_path()),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      :ok
    else
      _other -> {:error, :overlay_missing}
    end
  end

  defp admit_opts(opts, kind) do
    allowed = if kind == :production, do: @production_opt_keys, else: @test_opt_keys

    Enum.reduce_while(opts, {:ok, default_opts()}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        cond do
          not MapSet.member?(allowed, key) ->
            {:halt, {:error, :invalid_opts}}

          Map.has_key?(acc, :_seen) and MapSet.member?(acc._seen, key) ->
            {:halt, {:error, :invalid_opts}}

          true ->
            case validate_opt(key, value) do
              :ok ->
                seen = Map.get(acc, :_seen, MapSet.new())

                {:cont,
                 {:ok, acc |> Map.put(key, value) |> Map.put(:_seen, MapSet.put(seen, key))}}

              {:error, _} = error ->
                {:halt, error}
            end
        end

      _other, _acc ->
        {:halt, {:error, :invalid_opts}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Map.delete(acc, :_seen)}
      error -> error
    end
  end

  defp default_opts do
    %{
      root: nil,
      timeout_ms: @default_timeout_ms,
      overlay_bytes: nil,
      overlay_sha256: nil,
      cleanup_fault: :none,
      max_entries: nil,
      max_listing_bytes: nil,
      max_object_bytes: nil,
      max_total_bytes: nil,
      max_symlink_bytes: nil
    }
  end

  defp validate_opt(:root, nil), do: :ok
  defp validate_opt(:root, value) when is_binary(value), do: :ok

  defp validate_opt(:timeout_ms, value)
       when is_integer(value) and value > 0 and value <= @max_timeout_ms,
       do: :ok

  defp validate_opt(:overlay_bytes, value) when is_binary(value), do: :ok
  defp validate_opt(:overlay_sha256, value) when is_binary(value), do: Encode.valid_digest?(value)

  defp validate_opt(:cleanup_fault, value) when value in [:none, :fail_release_after_error],
    do: :ok

  defp validate_opt(key, value)
       when key in [
              :max_entries,
              :max_listing_bytes,
              :max_object_bytes,
              :max_total_bytes,
              :max_symlink_bytes
            ] and is_integer(value) and value > 0,
       do: :ok

  defp validate_opt(_key, _value), do: {:error, :invalid_opts}

  defp admit_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms,
       do: {:ok, timeout_ms}

  defp admit_timeout(_timeout), do: {:error, :invalid_opts}

  defp resolve_root(path) do
    with {:ok, root} <- PackagingRoot.resolve(path),
         :ok <- reject_root_symlink(root),
         {:ok, real} <- SafePath.resolve_real(root) do
      {:ok, real}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, :umbrella_root_not_found} -> {:error, :invalid_root_marker}
      {:error, :invalid_root_marker} = error -> error
      {:error, :root_symlink_redirection} = error -> error
      {:error, _} -> {:error, :invalid_root}
    end
  end

  defp reject_root_symlink(root) do
    case File.read_link(root) do
      {:ok, _} -> {:error, :root_symlink_redirection}
      {:error, :einval} -> :ok
      {:error, :enoent} -> {:error, :invalid_root_marker}
      {:error, _reason} -> {:error, :invalid_root}
    end
  end

  defp bind_head(root, timeout_ms) do
    with {:ok, commit} <- git_oid(root, ["rev-parse", "--verify", "HEAD^{commit}"], timeout_ms),
         {:ok, tree} <- git_oid(root, ["rev-parse", "--verify", "HEAD^{tree}"], timeout_ms),
         {:ok, format} <- object_format(commit, tree) do
      {:ok, %{commit: commit, tree: tree, object_format: format}}
    else
      {:error, :mixed_object_format} = error -> error
      _other -> {:error, :invalid_head}
    end
  end

  defp object_format(commit, tree) do
    cond do
      byte_size(commit) == 40 and byte_size(tree) == 40 -> {:ok, "sha1"}
      byte_size(commit) == 64 and byte_size(tree) == 64 -> {:ok, "sha256"}
      true -> {:error, :mixed_object_format}
    end
  end

  defp list_commit_blobs(root, commit, timeout_ms) do
    with {:ok, listing} <-
           Git.run(root, ["ls-tree", "-r", "-z", "--full-tree", commit], timeout_ms,
             max_output_bytes: 16_777_216
           ) do
      parse_blob_listing(listing)
    end
  end

  defp parse_blob_listing(listing) do
    listing
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case parse_ls_tree_record(record) do
        {:ok, :tree} -> {:cont, {:ok, acc}}
        {:ok, blob} -> {:cont, {:ok, [blob | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_ls_tree_record(record) do
    case Regex.run(~r/\A([0-7]{6}) (blob|tree) ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)\z/s, record) do
      [_, _mode, "tree", _oid, _path] ->
        {:ok, :tree}

      [_, mode, "blob", oid, path] ->
        {:ok, %{path: path, mode: mode, oid: String.downcase(oid)}}

      _other ->
        {:error, :invalid_path}
    end
  end

  defp prove_selected_equality(root, head, selected, blobs, timeout_ms) do
    by_path = Map.new(blobs, &{&1.path, &1})

    with :ok <- prove_index(root, selected, by_path, timeout_ms),
         {:ok, objects} <- load_selected_blobs(root, selected, by_path, timeout_ms) do
      prove_worktree_files(root, selected, by_path, objects, head.object_format)
    end
  end

  defp prove_index(root, selected, by_path, timeout_ms) do
    selected
    |> Enum.chunk_every(@ls_files_chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case prove_index_chunk(root, chunk, by_path, timeout_ms) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prove_index_chunk(root, paths, by_path, timeout_ms) do
    args = ["--literal-pathspecs", "ls-files", "-z", "--stage", "--"] ++ paths

    case Git.run(root, args, timeout_ms, max_output_bytes: 8_388_608) do
      {:ok, output} ->
        match_index_records(output, paths, by_path)

      {:error, _reason} ->
        {:error, :selected_index_drift}
    end
  end

  defp match_index_records(output, requested, by_path) do
    records =
      output
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))

    with {:ok, staged} <- parse_stage_records(records) do
      by_index = Map.new(staged, &{&1.path, &1})

      Enum.reduce_while(requested, :ok, fn path, :ok ->
        commit = Map.fetch!(by_path, path)

        case Map.fetch(by_index, path) do
          {:ok, %{stage: 0, mode: mode, oid: oid}}
          when mode in ["100644", "100755"] and oid == commit.oid ->
            {:cont, :ok}

          :error ->
            {:halt, {:error, :selected_index_drift}}

          {:ok, _other} ->
            {:halt, {:error, :selected_index_drift}}
        end
      end)
    end
  end

  defp parse_stage_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case Regex.run(@stage_line, record) do
        [_, mode, oid, stage, path] ->
          {:cont,
           {:ok,
            [
              %{
                mode: mode,
                oid: String.downcase(oid),
                stage: String.to_integer(stage),
                path: path
              }
              | acc
            ]}}

        _other ->
          {:halt, {:error, :selected_index_drift}}
      end
    end)
  end

  defp load_selected_blobs(root, selected, by_path, timeout_ms) do
    requests =
      selected
      |> Enum.map(fn path -> %{oid: Map.fetch!(by_path, path).oid, type: "blob"} end)
      |> Enum.uniq_by(& &1.oid)

    if requests == [] do
      {:ok, %{}}
    else
      case Git.read_objects(root, requests, timeout_ms,
             max_object_bytes: @max_file_bytes,
             max_total_bytes: @max_total_bytes
           ) do
        {:ok, objects} -> {:ok, objects}
        {:error, "object_attestation_failed"} -> {:error, :total_byte_limit}
        {:error, "git_object_request_limit"} -> {:error, :file_limit}
        {:error, _reason} -> {:error, :selected_worktree_drift}
      end
    end
  end

  defp prove_worktree_files(root, selected, by_path, objects, object_format) do
    Enum.reduce_while(selected, {:ok, 0}, fn path, {:ok, total} ->
      blob = Map.fetch!(by_path, path)
      payload = Map.fetch!(objects, blob.oid)
      content = payload.content

      cond do
        byte_size(content) > @max_file_bytes ->
          {:halt, {:error, :input_too_large}}

        total + byte_size(content) > @max_total_bytes ->
          {:halt, {:error, :total_byte_limit}}

        true ->
          case prove_one_worktree(root, path, blob, content, object_format) do
            :ok -> {:cont, {:ok, total + byte_size(content)}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, _total} -> :ok
      error -> error
    end
  end

  defp prove_one_worktree(root, rel, blob, expected, object_format) do
    with {:ok, path} <- SafePath.safe_join(root, rel),
         {:ok, bytes, identity} <-
           read_bound_file_with_identity(path, @max_file_bytes, :worktree),
         :ok <- prove_exec_mode(identity.mode, blob.mode) do
      actual_oid = git_blob_oid(bytes, object_format)

      cond do
        bytes != expected -> {:error, :selected_worktree_drift}
        actual_oid != blob.oid -> {:error, :selected_worktree_drift}
        true -> :ok
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _other ->
        {:error, :selected_worktree_drift}
    end
  end

  defp prove_exec_mode(mode, "100644") when is_integer(mode) do
    if Bitwise.band(mode, 0o111) == 0 do
      :ok
    else
      {:error, :selected_worktree_drift}
    end
  end

  defp prove_exec_mode(mode, "100755") when is_integer(mode) do
    if Bitwise.band(mode, 0o111) != 0 do
      :ok
    else
      {:error, :selected_worktree_drift}
    end
  end

  defp prove_exec_mode(_mode, _blob_mode), do: {:error, :unsupported_mode}

  defp classify_status(root, timeout_ms) do
    case Git.run(
           root,
           ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
           timeout_ms,
           max_output_bytes: 8_388_608
         ) do
      {:ok, output} -> classify_status_output(output)
      {:error, _reason} -> {:error, :selected_worktree_drift}
    end
  end

  defp reject_ignored_selected(root, timeout_ms) do
    args =
      ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"] ++
        SourcePolicy.app_roots()

    case Git.run(root, args, timeout_ms, max_output_bytes: 8_388_608) do
      {:ok, output} ->
        output
        |> :binary.split(<<0>>, [:global])
        |> Enum.reject(&(&1 == ""))
        |> Enum.reduce_while(:ok, fn path, :ok ->
          if SourcePolicy.selected_path?(path) do
            {:halt, {:error, :selected_untracked}}
          else
            {:cont, :ok}
          end
        end)

      {:error, _reason} ->
        {:error, :selected_worktree_drift}
    end
  end

  defp reject_source_alternates(root, timeout_ms) do
    case Git.reject_object_alternates(root, timeout_ms) do
      :ok -> :ok
      {:error, "source_object_alternates"} -> {:error, :source_object_alternates}
      {:error, _reason} -> {:error, :invalid_head}
    end
  end

  defp classify_status_output(output) do
    records =
      output
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))

    consume_status(records)
  end

  defp consume_status([]), do: :ok

  defp consume_status([<<x, y, " ", path::binary>> | rest]) when path != "" do
    case rename_or_copy_paths(x, y, path, rest) do
      {:ok, paths, rest} ->
        case classify_status_paths(x, y, paths) do
          :ok -> consume_status(rest)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_status(_records), do: {:error, :selected_worktree_drift}

  defp rename_or_copy_paths(x, y, path, rest) do
    if rename_or_copy?(x) or rename_or_copy?(y) do
      case rest do
        [orig | rest2] when is_binary(orig) and orig != "" ->
          {:ok, [path, orig], rest2}

        _other ->
          {:error, :selected_worktree_drift}
      end
    else
      {:ok, [path], rest}
    end
  end

  defp rename_or_copy?(code) when code in [?R, ?C], do: true
  defp rename_or_copy?(_code), do: false

  defp classify_status_paths(x, y, paths) do
    if Enum.any?(paths, &SourcePolicy.selected_path?/1) do
      cond do
        x == ?! and y == ?! -> {:error, :selected_untracked}
        x == ?? and y == ?? -> {:error, :selected_untracked}
        x != ?\s -> {:error, :selected_index_drift}
        y != ?\s -> {:error, :selected_worktree_drift}
        true -> {:error, :selected_worktree_drift}
      end
    else
      :ok
    end
  end

  defp reconstructed_facts(source_root, selected, blobs, _object_format) do
    by_path = Map.new(blobs, &{&1.path, &1})

    if length(selected) > SourcePolicy.max_source_rows() do
      {:error, :file_limit}
    else
      Enum.reduce_while(selected, {:ok, []}, fn path, {:ok, acc} ->
        blob = Map.fetch!(by_path, path)

        case fact_from_reconstructed(source_root, path, blob) do
          {:ok, fact} -> {:cont, {:ok, [fact | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, facts} -> {:ok, Enum.sort_by(facts, & &1["path"])}
        error -> error
      end
    end
  end

  defp fact_from_reconstructed(source_root, rel, blob) do
    with {:ok, path} <- SafePath.safe_join(source_root, rel),
         {:ok, bytes} <- read_bound_file(path, @max_file_bytes, :reconstructed),
         :ok <- Encode.valid_path?(rel) do
      digest = sha256_hex(bytes)

      if git_blob_oid(bytes, oid_format(blob.oid)) == blob.oid do
        {:ok, %{"path" => rel, "sha256" => digest}}
      else
        {:error, :reconstructed_source_mismatch}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :reconstructed_source_mismatch}
    end
  end

  defp oid_format(oid) when byte_size(oid) == 64, do: "sha256"
  defp oid_format(_oid), do: "sha1"

  defp read_bound_file(path, max_bytes, kind) do
    case read_bound_file_with_identity(path, max_bytes, kind) do
      {:ok, bytes, _identity} -> {:ok, bytes}
      {:error, _reason} = error -> error
    end
  end

  defp read_bound_file_with_identity(path, max_bytes, kind) do
    change_error = change_error(kind)
    missing_error = missing_error(kind)

    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, opened} <- file_identity(io, kind),
               :ok <- verify_path_file_identity(path, opened, kind),
               {:ok, bytes} <- read_fd(io, max_bytes, kind),
               {:ok, final} <- file_identity(io, kind),
               true <- final == opened,
               :ok <- verify_path_file_identity(path, final, kind) do
            {:ok, bytes, opened}
          else
            false -> {:error, change_error}
            {:error, _} = error -> error
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, missing_error}

      {:error, _reason} ->
        {:error, missing_error}
    end
  end

  defp file_identity(io, kind) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> info |> File.Stat.from_record() |> regular_file_identity(kind)
      {:error, _reason} -> {:error, change_error(kind)}
    end
  end

  defp verify_path_file_identity(path, expected, kind) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        case regular_file_identity(stat, kind) do
          {:ok, ^expected} -> :ok
          {:ok, _other} -> {:error, change_error(kind)}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, missing_error(kind)}

      {:error, _reason} ->
        {:error, change_error(kind)}
    end
  end

  defp regular_file_identity(%File.Stat{type: :regular, links: 1} = stat, _kind) do
    {:ok,
     %{
       type: stat.type,
       inode: stat.inode,
       major_device: stat.major_device,
       minor_device: stat.minor_device,
       size: stat.size,
       mtime: stat.mtime,
       ctime: stat.ctime,
       mode: stat.mode
     }}
  end

  defp regular_file_identity(%File.Stat{type: :regular, links: links}, _kind) when links != 1,
    do: {:error, :source_hardlink}

  defp regular_file_identity(%File.Stat{type: :symlink}, _kind), do: {:error, :symlink_input}
  defp regular_file_identity(%File.Stat{}, kind), do: {:error, missing_error(kind)}

  defp read_fd(io, max_bytes, kind) do
    case :file.read(io, max_bytes + 1) do
      {:ok, bytes} when byte_size(bytes) > max_bytes -> {:error, :input_too_large}
      {:ok, bytes} -> {:ok, bytes}
      :eof -> {:ok, ""}
      {:error, _reason} -> {:error, change_error(kind)}
    end
  end

  defp change_error(:worktree), do: :source_changed_during_read
  defp change_error(:reconstructed), do: :reconstructed_source_mismatch

  defp missing_error(:worktree), do: :selected_worktree_drift
  defp missing_error(:reconstructed), do: :reconstructed_source_mismatch

  defp git_blob_oid(bytes, "sha256") do
    :crypto.hash(:sha256, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    |> Base.encode16(case: :lower)
  end

  defp git_blob_oid(bytes, _format) do
    :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    |> Base.encode16(case: :lower)
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp git_oid(root, args, timeout_ms) do
    case Git.run(root, args, timeout_ms) do
      {:ok, output} ->
        oid = output |> String.trim() |> String.downcase()

        if Regex.match?(@oid_pattern, oid) do
          {:ok, oid}
        else
          {:error, :invalid_head}
        end

      {:error, _reason} ->
        {:error, :invalid_head}
    end
  end

  defp create_owned_root do
    case SafePath.resolve_real(System.tmp_dir!()) do
      {:ok, tmp} -> exclusive_create(tmp, @max_create_attempts)
      _other -> {:error, :root_create_failed}
    end
  end

  defp exclusive_create(_tmp, 0), do: {:error, :root_create_failed}

  defp exclusive_create(tmp, remaining) when remaining > 0 do
    token = :crypto.strong_rand_bytes(@root_token_bytes) |> Base.encode16(case: :lower)
    path = Path.join(tmp, "arbor-e0b2c-source-" <> token)

    case Arbor.Shell.create_private_owned_tree(path) do
      {:ok, identity} ->
        {:ok, canonicalize_identity(identity)}

      {:error, :root_exists} ->
        exclusive_create(tmp, remaining - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonicalize_identity(%{path: path} = identity) when is_binary(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} when real != path ->
        case File.lstat(real) do
          {:ok, %File.Stat{major_device: device, minor_device: minor, inode: inode}}
          when device == identity.device and minor == identity.minor_device and
                 inode == identity.inode ->
            %{identity | path: real}

          _other ->
            identity
        end

      _other ->
        identity
    end
  end

  defp canonicalize_identity(identity), do: identity

  defp remove_identity(identity) when is_map(identity) do
    case Arbor.Shell.remove_owned_tree(identity, @cleanup_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cleanup_retained, reason, identity}}
    end
  end

  defp force_identity_mismatch(%{path: path}) when is_binary(path) do
    kept = path <> ".kept"

    with :ok <- rename_or_ok(path, kept),
         :ok <- File.mkdir(path) do
      :ok
    else
      _other -> {:error, :root_create_failed}
    end
  end

  defp rename_or_ok(path, kept) do
    case File.rename(path, kept) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
