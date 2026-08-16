defmodule Arbor.Commands.ImmutableGitSource.Reconstruct do
  @moduledoc false

  alias Arbor.Commands.ImmutableGitSource.Git
  alias Arbor.Common.SafePath

  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @max_path_bytes 4_096
  @private_dir_mode 0o700

  @type identity :: %{
          path: String.t(),
          type: :directory,
          device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer()
        }

  @type limits :: %{
          required(:max_entries) => pos_integer(),
          required(:max_listing_bytes) => pos_integer(),
          required(:max_object_bytes) => pos_integer(),
          required(:max_total_bytes) => pos_integer(),
          required(:max_symlink_bytes) => pos_integer()
        }

  @spec run(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          identity(),
          limits(),
          keyword()
        ) :: :ok | {:error, String.t()}
  def run(source, relative_dest, commit_oid, expected_tree, identity, limits, opts)
      when is_binary(source) and is_binary(relative_dest) and is_binary(commit_oid) and
             is_binary(expected_tree) and is_map(identity) and is_map(limits) and is_list(opts) do
    require_private? = Keyword.get(opts, :require_private, false)
    branch = Keyword.get(opts, :branch, "source")
    timeout = Keyword.get(opts, :timeout_ms, 300_000)

    with true <- valid_branch?(branch),
         {:ok, timeout_ms} <- admit_timeout(timeout),
         {:ok, commit_oid} <- admit_oid(commit_oid),
         {:ok, expected_tree} <- admit_oid(expected_tree),
         :ok <- admit_relative_dest(relative_dest),
         :ok <- Git.reject_object_alternates(source, timeout_ms),
         {:ok, dest} <-
           create_destination(identity, relative_dest, require_private?),
         :ok <-
           reconstruct_into(
             source,
             dest,
             commit_oid,
             expected_tree,
             limits,
             branch,
             Git.deadline(timeout_ms)
           ) do
      :ok
    else
      false -> {:error, "invalid_reconstruct_request"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "invalid_reconstruct_request"}
    end
  end

  def run(_source, _relative_dest, _commit, _tree, _identity, _limits, _opts),
    do: {:error, "invalid_reconstruct_request"}

  defp valid_branch?(branch) when branch in ["source", "benchmark"], do: true
  defp valid_branch?(_branch), do: false

  defp admit_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= 3_600_000,
       do: {:ok, timeout_ms}

  defp admit_timeout(_timeout), do: {:error, "invalid_reconstruct_request"}

  defp admit_oid(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if Regex.match?(@oid_pattern, normalized) do
      {:ok, normalized}
    else
      {:error, "invalid_reconstruct_request"}
    end
  end

  defp admit_oid(_value), do: {:error, "invalid_reconstruct_request"}

  defp create_destination(identity, relative_dest, require_private?) do
    with :ok <- admit_relative_dest(relative_dest),
         :ok <- verify_parent_identity(identity, require_private?),
         {:ok, dest} <- resolve_relative_dest(identity.path, relative_dest),
         {:error, :enoent} <- File.lstat(dest),
         :ok <- verify_parent_identity(identity, require_private?),
         :ok <- mkdir_private(dest),
         :ok <- verify_parent_identity(identity, require_private?),
         {:ok, real_dest} <- canonicalize_created_dest(dest, identity) do
      {:ok, real_dest}
    else
      {:ok, %File.Stat{}} -> {:error, "invalid_reconstruct_request"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "invalid_reconstruct_request"}
    end
  end

  defp verify_parent_identity(
         %{
           path: path,
           type: :directory,
           device: device,
           minor_device: minor_device,
           inode: inode
         },
         require_private?
       )
       when is_binary(path) and is_integer(device) and is_integer(minor_device) and
              is_integer(inode) do
    case File.lstat(path) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: ^device,
         minor_device: ^minor_device,
         inode: ^inode
       } = stat} ->
        if require_private? and Bitwise.band(stat.mode, 0o777) != @private_dir_mode do
          {:error, "parent_not_private"}
        else
          :ok
        end

      {:ok, %File.Stat{}} ->
        {:error, "parent_identity_mismatch"}

      {:error, _reason} ->
        {:error, "parent_identity_mismatch"}
    end
  end

  defp verify_parent_identity(_identity, _require_private?),
    do: {:error, "invalid_reconstruct_request"}

  defp admit_relative_dest(relative_dest) when is_binary(relative_dest) do
    segments = Path.split(relative_dest)

    cond do
      byte_size(relative_dest) > @max_path_bytes ->
        {:error, "invalid_reconstruct_request"}

      not String.valid?(relative_dest) or String.contains?(relative_dest, <<0>>) ->
        {:error, "invalid_reconstruct_request"}

      Path.type(relative_dest) != :relative ->
        {:error, "invalid_reconstruct_request"}

      length(segments) != 1 ->
        {:error, "invalid_reconstruct_request"}

      hd(segments) in ["", ".", ".."] or String.downcase(hd(segments)) == ".git" ->
        {:error, "invalid_reconstruct_request"}

      byte_size(hd(segments)) > 255 ->
        {:error, "invalid_reconstruct_request"}

      true ->
        :ok
    end
  end

  defp admit_relative_dest(_relative_dest), do: {:error, "invalid_reconstruct_request"}

  defp resolve_relative_dest(parent, relative_dest) when is_binary(relative_dest) do
    with :ok <- admit_relative_dest(relative_dest) do
      dest = Path.join(parent, hd(Path.split(relative_dest)))

      case SafePath.resolve_within(dest, parent) do
        {:ok, ^dest} -> {:ok, dest}
        _other -> {:error, "invalid_reconstruct_request"}
      end
    end
  end

  defp resolve_relative_dest(_parent, _relative_dest),
    do: {:error, "invalid_reconstruct_request"}

  defp mkdir_private(path) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @private_dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, "mkdir_failed:#{reason}"}
    end
  end

  defp reconstruct_into(source, destination, commit_oid, expected_tree, limits, branch, deadline) do
    with {:ok, entries} <-
           tree_entries(source, commit_oid, expected_tree, limits, deadline),
         :ok <- initialize_repository(destination, commit_oid, branch, deadline),
         {:ok, objects} <-
           load_objects(source, commit_oid, expected_tree, entries, limits, deadline, branch),
         :ok <- import_objects(destination, objects),
         :ok <- materialize_tree(destination, entries, objects, limits),
         :ok <- attach_commit(destination, commit_oid, branch, deadline),
         {:ok, head_commit} <-
           git_output(destination, ["rev-parse", "--verify", "HEAD^{commit}"], deadline),
         true <- head_commit == commit_oid,
         {:ok, actual_tree} <-
           git_output(destination, ["rev-parse", "--verify", "HEAD^{tree}"], deadline),
         :ok <- matching_head_tree(actual_tree, expected_tree),
         {:ok, ""} <-
           git_output(
             destination,
             ["status", "--porcelain=v1", "--untracked-files=all"],
             deadline
           ) do
      :ok
    else
      false ->
        {:error, "reconstruction_attestation_failed"}

      {:ok, dirty} when is_binary(dirty) and dirty != "" ->
        {:error, "repository_not_clean"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _other ->
        {:error, "reconstruction_attestation_failed"}
    end
  end

  defp tree_entries(source, commit_oid, expected_tree, limits, timeout_ms) do
    with {:ok, listing} <-
           Git.run(
             source,
             ["ls-tree", "-r", "-t", "-z", "--full-tree", commit_oid],
             timeout_ms,
             max_output_bytes: limits.max_listing_bytes
           ),
         {:ok, entries} <- parse_tree(listing),
         true <- length(entries) <= limits.max_entries,
         true <- Enum.all?(entries, &supported_entry?/1),
         true <- Enum.all?(entries, &safe_path?(&1.path)),
         {:ok, tree_oid} <-
           git_output(source, ["rev-parse", "--verify", "#{commit_oid}^{tree}"], timeout_ms),
         :ok <- matching_tree(tree_oid, expected_tree) do
      {:ok, entries}
    else
      false -> {:error, "unsupported_or_oversized_tree"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "invalid_tree"}
    end
  end

  defp parse_tree(listing) do
    listing
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case Regex.run(~r/\A([0-7]{6}) (blob|tree) ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)\z/s, record) do
        [_, mode, type, oid, path] ->
          {:cont, {:ok, [%{mode: mode, oid: oid, path: path, type: type} | acc]}}

        _other ->
          {:halt, {:error, "invalid_tree_entry"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp supported_entry?(%{type: "tree", mode: "040000"}), do: true

  defp supported_entry?(%{type: "blob", mode: mode})
       when mode in ["100644", "100755", "120000"],
       do: true

  defp supported_entry?(_entry), do: false

  defp safe_path?(path) do
    segments = Path.split(path)

    String.valid?(path) and path != "" and not String.contains?(path, <<0>>) and
      Path.type(path) != :absolute and byte_size(path) <= @max_path_bytes and
      length(segments) <= 48 and
      Enum.all?(segments, fn segment ->
        segment not in ["", ".", ".."] and String.downcase(segment) != ".git" and
          byte_size(segment) <= 255
      end)
  end

  defp initialize_repository(destination, commit_oid, branch, timeout_ms) do
    template = Path.join(destination, ".empty-git-template")
    object_format = if byte_size(commit_oid) == 64, do: "sha256", else: "sha1"

    with :ok <- mkdir(template),
         {:ok, _output} <-
           Git.run(
             destination,
             [
               "init",
               "--quiet",
               "--initial-branch=#{branch}",
               "--object-format=#{object_format}",
               "--template=#{template}",
               "."
             ],
             timeout_ms
           ),
         :ok <- remove_empty_directory(template),
         {:ok, _output} <-
           Git.run(destination, ["config", "--local", "core.hooksPath", "/dev/null"], timeout_ms),
         {:ok, _output} <-
           Git.run(destination, ["config", "--local", "core.filemode", "true"], timeout_ms),
         {:ok, %{type: :directory}} <- File.lstat(Path.join(destination, ".git")) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "repository_init_failed"}
    end
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "mkdir_failed:#{reason}"}
    end
  end

  defp remove_empty_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "template_cleanup_failed:#{reason}"}
    end
  end

  defp load_objects(source, commit_oid, root_tree_oid, entries, limits, timeout_ms, branch) do
    requests =
      [%{oid: commit_oid, type: "commit"}, %{oid: root_tree_oid, type: "tree"}] ++
        Enum.map(entries, &Map.take(&1, [:oid, :type]))

    opts = [
      max_object_bytes: limits.max_object_bytes,
      max_total_bytes: limits.max_total_bytes
    ]

    opts =
      if branch == "benchmark" do
        Keyword.put(opts, :compat_telemetry, true)
      else
        opts
      end

    Git.read_objects(source, requests, timeout_ms, opts)
  end

  defp import_objects(destination, objects) when is_map(objects) do
    Enum.reduce_while(objects, :ok, fn {oid, %{type: type, content: content}}, :ok ->
      case write_loose_object(destination, type, content, oid) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_loose_object(destination, type, content, expected_oid) do
    object = [type, " ", Integer.to_string(byte_size(content)), <<0>>, content]
    object = IO.iodata_to_binary(object)
    algorithm = if byte_size(expected_oid) == 40, do: :sha, else: :sha256
    actual_oid = :crypto.hash(algorithm, object) |> Base.encode16(case: :lower)

    object_path =
      Path.join([
        destination,
        ".git",
        "objects",
        String.slice(actual_oid, 0, 2),
        String.slice(actual_oid, 2..-1//1)
      ])

    with true <- actual_oid == expected_oid,
         :ok <- File.mkdir_p(Path.dirname(object_path)),
         :ok <- write_exclusive_file(object_path, :zlib.compress(object)) do
      :ok
    else
      false -> {:error, "object_attestation_failed"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "object_write_failed"}
    end
  end

  defp materialize_tree(destination, entries, objects, limits) when is_map(objects) do
    entries
    |> Enum.filter(&(&1.type == "blob"))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      with {:ok, path} <- SafePath.safe_join(destination, entry.path),
           {:ok, ^path} <- SafePath.resolve_within(path, destination),
           :ok <- ensure_parent(Path.dirname(path), destination),
           {:ok, %{type: "blob", content: content}} <- Map.fetch(objects, entry.oid),
           :ok <- materialize_entry(path, content, entry.mode, destination, limits) do
        {:cont, :ok}
      else
        :error -> {:halt, {:error, "object_missing_for_materialization"}}
        {:error, reason} when is_binary(reason) -> {:halt, {:error, reason}}
        _other -> {:halt, {:error, "materialization_failed"}}
      end
    end)
  end

  defp materialize_entry(path, content, "120000", destination, limits) do
    with true <- byte_size(content) in 1..limits.max_symlink_bytes,
         true <- String.valid?(content) and not String.contains?(content, <<0>>),
         true <- Path.type(content) == :relative,
         resolved = Path.expand(content, Path.dirname(path)),
         {:ok, ^resolved} <- SafePath.resolve_within(resolved, destination),
         false <- git_metadata_path?(resolved, destination),
         :ok <- File.ln_s(content, path) do
      :ok
    else
      _other -> {:error, "unsafe_symlink"}
    end
  end

  defp materialize_entry(path, content, mode, _destination, _limits)
       when mode in ["100644", "100755"] do
    with :ok <- write_exclusive_file(path, content),
         :ok <- File.chmod(path, if(mode == "100755", do: 0o755, else: 0o644)) do
      :ok
    end
  end

  defp canonicalize_created_dest(dest, identity) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dest),
         {:ok, real_dest} <- SafePath.resolve_real(dest),
         {:ok, real_parent} <- SafePath.resolve_real(identity.path),
         {:ok, ^real_dest} <- SafePath.resolve_within(real_dest, real_parent),
         true <- Path.dirname(real_dest) == real_parent do
      {:ok, real_dest}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "unsafe_parent"}
    end
  end

  defp ensure_parent(parent, destination) do
    with {:ok, lexical} <- SafePath.resolve_within(parent, destination),
         :ok <- File.mkdir_p(lexical),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(lexical),
         {:ok, real_dest} <- SafePath.resolve_real(destination),
         {:ok, real_parent} <- SafePath.resolve_real(lexical),
         {:ok, ^real_parent} <- SafePath.resolve_within(real_parent, real_dest) do
      :ok
    else
      _other -> {:error, "unsafe_parent"}
    end
  end

  defp write_exclusive_file(path, content) do
    case File.open(path, [:write, :binary, :exclusive], fn io -> IO.binwrite(io, content) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, "write_failed:#{reason}"}
      {:error, reason} -> {:error, "write_failed:#{reason}"}
    end
  end

  defp attach_commit(destination, commit_oid, branch, timeout_ms) do
    with :ok <- write_exclusive_file(Path.join(destination, ".git/shallow"), commit_oid <> "\n"),
         {:ok, _output} <- Git.run(destination, ["read-tree", commit_oid], timeout_ms),
         {:ok, _output} <-
           Git.run(destination, ["update-ref", "refs/heads/#{branch}", commit_oid], timeout_ms),
         {:ok, _output} <-
           Git.run(destination, ["symbolic-ref", "HEAD", "refs/heads/#{branch}"], timeout_ms) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_metadata_path?(path, root) do
    case path |> Path.relative_to(root) |> Path.split() do
      [first | _rest] -> String.downcase(first) == ".git"
      [] -> false
    end
  end

  defp matching_tree(actual, expected) do
    if String.downcase(actual) == expected, do: :ok, else: {:error, "invalid_tree"}
  end

  defp matching_head_tree(actual, expected) do
    if String.downcase(actual) == expected, do: :ok, else: {:error, "base_tree_oid_mismatch"}
  end

  defp git_output(workdir, args, timeout_ms) do
    case Git.run(workdir, args, timeout_ms) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end
end
