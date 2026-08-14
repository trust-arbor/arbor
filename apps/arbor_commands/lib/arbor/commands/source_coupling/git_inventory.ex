defmodule Arbor.Commands.SourceCoupling.GitInventory do
  @moduledoc """
  Imperative Git inventory for source-coupling census.

  Enumerates stage-0 tracked paths and reads exact blob bytes via
  argv-safe `git cat-file --batch` (OIDs on stdin).
  """

  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  # Exact regular-file modes only — never symlinks (120000), gitlinks, or trees.
  @accepted_modes MapSet.new(["100644", "100755"])
  @symlink_mode "120000"
  @max_blob_bytes 1_048_576
  @max_total_bytes 64 * 1024 * 1024
  @max_files 50_000
  @batch_size 64

  @type file_entry :: %{path: String.t(), blob_oid: String.t(), bytes: binary()}

  @doc """
  Read exact index blobs for an explicit path list.

  Does not wildcard the filesystem. Rejects non-regular modes and missing
  index entries. Intended for reviewed formatter/Boundary path sets.
  """
  @spec read_indexed_blobs(String.t(), [String.t()], keyword()) ::
          {:ok, [file_entry()]} | {:error, term()}
  def read_indexed_blobs(root, paths, opts \\ [])

  def read_indexed_blobs(root, paths, opts)
      when is_binary(root) and is_list(paths) and is_list(opts) do
    case query_indexed_blobs(root, paths, opts) do
      {:ok, %{present: files, absent: []}} ->
        {:ok, files}

      {:ok, %{absent: [missing | _]}} ->
        {:error, {:blob_missing, missing}}

      {:error, _} = err ->
        err
    end
  end

  def read_indexed_blobs(_, _, _), do: {:error, :invalid_paths}

  @doc """
  Query exact index blobs for an explicit path list.

  Missing paths are returned in `:absent` and do not fail the query.
  Required-path enforcement is the caller's job.
  """
  @spec query_indexed_blobs(String.t(), [String.t()], keyword()) ::
          {:ok, %{present: [file_entry()], absent: [String.t()]}} | {:error, term()}
  def query_indexed_blobs(root, paths, opts \\ [])

  def query_indexed_blobs(root, paths, opts)
      when is_binary(root) and is_list(paths) and is_list(opts) do
    run_git = Keyword.get(opts, :run_git, &default_run_git/3)
    max_blob = Keyword.get(opts, :max_blob_bytes, @max_blob_bytes)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)

    cond do
      paths == [] ->
        {:ok, %{present: [], absent: []}}

      not Enum.all?(paths, &is_binary/1) ->
        {:error, :invalid_paths}

      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :duplicate_paths}

      true ->
        with :ok <- admit_literal_paths(paths),
             {:ok, staged} <- ls_files_stage_paths(root, paths, run_git),
             {:ok, %{admitted: admitted, absent: absent}} <- query_explicit_paths(staged, paths),
             {:ok, files} <- read_blobs(root, admitted, run_git, max_blob, max_total) do
          {:ok, %{present: files, absent: absent}}
        end
    end
  end

  def query_indexed_blobs(_, _, _), do: {:error, :invalid_paths}

  @doc """
  List and load canonical tracked files under root.

  Returns `{:ok, %{files: [...], tree_oid: oid, object_format: fmt}}`.
  """
  @spec load_canonical(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_canonical(root, opts \\ []) when is_binary(root) and is_list(opts) do
    run_git = Keyword.get(opts, :run_git, &default_run_git/3)
    max_blob = Keyword.get(opts, :max_blob_bytes, @max_blob_bytes)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)

    with {:ok, tree_oid} <- rev_parse_tree(root, run_git),
         {:ok, staged} <- ls_files_stage(root, run_git),
         {:ok, admitted} <- admit_stage_entries(staged),
         :ok <- check_file_count(admitted),
         {:ok, files} <- read_blobs(root, admitted, run_git, max_blob, max_total) do
      object_format =
        case admitted do
          [%{blob_oid: oid} | _] when byte_size(oid) == 64 -> "sha256"
          _ -> "sha1"
        end

      {:ok, %{files: files, tree_oid: tree_oid, object_format: object_format}}
    end
  end

  @doc """
  Parse a single ls-files --stage line: mode SP oid SP stage TAB path.

  Accepted modes are **exactly** `100644` and `100755` (regular blobs).
  Symlink mode `120000` and every other mode are rejected — canonical census
  bytes must come from index-backed regular blobs only.
  """
  @spec parse_stage_line(binary()) :: {:ok, map()} | {:error, term()}
  def parse_stage_line(line) when is_binary(line) do
    line = String.trim_trailing(line, "\n")

    case Regex.run(~r/\A([0-7]{6}) ([0-9a-f]+) ([0-3])\t(.+)\z/, line) do
      [_, mode, oid, stage_s, path] ->
        stage = String.to_integer(stage_s)

        cond do
          not Regex.match?(@oid_re, oid) ->
            {:error, {:invalid_oid, oid}}

          stage != 0 ->
            {:error, {:non_zero_stage, path, stage}}

          mode == @symlink_mode ->
            {:error, {:symlink_blob, path}}

          MapSet.member?(@accepted_modes, mode) ->
            {:ok, %{mode: mode, blob_oid: oid, stage: stage, path: path}}

          true ->
            {:error, {:invalid_mode, mode, path}}
        end

      _ ->
        {:error, {:malformed_stage_line, line}}
    end
  end

  def parse_stage_line(_), do: {:error, :malformed_stage_line}

  @doc false
  @spec accepted_modes() :: MapSet.t(String.t())
  def accepted_modes, do: @accepted_modes

  defp rev_parse_tree(root, run_git) do
    case run_git.(root, ["rev-parse", "HEAD^{tree}"], "") do
      {:ok, out} ->
        oid = String.trim(out)

        if Regex.match?(@oid_re, oid),
          do: {:ok, oid},
          else: {:error, {:invalid_tree_oid, oid}}

      {:error, reason} ->
        {:error, {:git_rev_parse, reason}}
    end
  end

  defp admit_literal_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case literal_repo_path(path) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp literal_repo_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, {:invalid_path, :empty}}

      not String.valid?(path) ->
        {:error, {:invalid_path, :encoding}}

      String.contains?(path, <<0>>) ->
        {:error, {:invalid_path, :nul}}

      String.starts_with?(path, "/") ->
        {:error, {:invalid_path, :absolute}}

      String.contains?(path, "\\") ->
        {:error, {:invalid_path, :absolute}}

      pathspec_magic?(path) ->
        {:error, {:invalid_path, :pathspec_magic}}

      traversal_segment?(path) ->
        {:error, {:invalid_path, :traversal}}

      true ->
        :ok
    end
  end

  defp literal_repo_path(_), do: {:error, :invalid_paths}

  defp pathspec_magic?(path) do
    String.starts_with?(path, ":") or
      String.contains?(path, "*") or
      String.contains?(path, "?") or
      String.contains?(path, "[") or
      String.contains?(path, "]") or
      String.contains?(path, "~")
  end

  defp traversal_segment?(path) do
    path
    |> String.split("/")
    |> Enum.any?(&(&1 in ["..", "", "."]))
  end

  defp ls_files_stage_paths(root, paths, run_git) do
    # --literal-pathspecs is a Git global option and must precede ls-files.
    args = ["--literal-pathspecs", "ls-files", "-z", "--stage", "--"] ++ paths

    case run_git.(root, args, "") do
      {:ok, out} -> parse_stage_output(out)
      {:error, reason} -> {:error, {:git_ls_files, reason}}
    end
  end

  defp query_explicit_paths(entries, requested) do
    paths = Enum.map(entries, & &1.path)

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :index_conflict}

      true ->
        by_path = Map.new(entries, &{&1.path, &1})

        {admitted, absent} =
          Enum.reduce(requested, {[], []}, fn path, {have, missing} ->
            case Map.fetch(by_path, path) do
              {:ok, entry} -> {[entry | have], missing}
              :error -> {have, [path | missing]}
            end
          end)

        {:ok, %{admitted: Enum.reverse(admitted), absent: Enum.reverse(absent)}}
    end
  end

  defp ls_files_stage(root, run_git) do
    # List staged paths under apps/; admit_stage_entries filters mix.exs + lib source.
    # Avoid `**` pathspecs (not portable across Git versions).
    args = ["ls-files", "-z", "--stage", "--", "apps/"]

    case run_git.(root, args, "") do
      {:ok, out} -> parse_stage_output(out)
      {:error, reason} -> {:error, {:git_ls_files, reason}}
    end
  end

  defp parse_stage_output(out) when is_binary(out) do
    entries =
      out
      |> String.split("\0", trim: true)
      |> Enum.map(fn chunk ->
        # with -z --stage, records are NUL-separated stage lines without trailing NUL path split issues
        parse_stage_line(chunk)
      end)

    errors = Enum.filter(entries, &match?({:error, _}, &1))

    # Distinguish conflict (multiple stages) vs other errors
    if Enum.any?(errors, &match?({:error, {:non_zero_stage, _, _}}, &1)) do
      {:error, :index_conflict_or_non_zero_stage}
    else
      case Enum.reject(entries, &match?({:error, _}, &1)) do
        ok when is_list(ok) ->
          # also surface hard parse errors
          hard =
            Enum.find(errors, fn
              {:error, {:non_zero_stage, _, _}} -> false
              {:error, _} -> true
            end)

          if hard, do: hard, else: {:ok, Enum.map(ok, fn {:ok, e} -> e end)}
      end
    end
  end

  defp admit_stage_entries(entries) do
    # Detect duplicate paths (conflict residue)
    paths = Enum.map(entries, & &1.path)

    if length(paths) != length(Enum.uniq(paths)) do
      {:error, :index_conflict}
    else
      admitted =
        Enum.filter(entries, fn e ->
          app_ok?(e.path) and not integrations?(e.path) and
            (mix_path?(e.path) or lib_path?(e.path))
        end)

      {:ok, admitted}
    end
  end

  defp app_ok?(path) do
    case Path.split(path) do
      ["apps", app | _] -> Regex.match?(~r/\Aarbor_[a-z0-9_]+\z/, app)
      _ -> false
    end
  end

  defp integrations?(path), do: String.starts_with?(path, "apps/arbor_integrations/")

  defp mix_path?(path) do
    case Path.split(path) do
      ["apps", _app, "mix.exs"] -> true
      _ -> false
    end
  end

  defp lib_path?(path) do
    parts = Path.split(path)

    case parts do
      ["apps", _app, "lib" | rest] when rest != [] ->
        name = List.last(parts)
        String.ends_with?(name, ".ex") or String.ends_with?(name, ".exs")

      _ ->
        false
    end
  end

  defp check_file_count(list) when length(list) > @max_files, do: {:error, :file_limit}
  defp check_file_count(_), do: :ok

  defp read_blobs(root, admitted, run_git, max_blob, max_total) do
    admitted
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, [], 0}, fn batch, {:ok, acc, total} ->
      case read_blob_batch(root, batch, run_git, max_blob) do
        {:ok, files} ->
          size = Enum.reduce(files, 0, &(&1.bytes |> byte_size() |> Kernel.+(&2)))

          if total + size > max_total do
            {:halt, {:error, :total_byte_limit}}
          else
            {:cont, {:ok, acc ++ files, total + size}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, files, _total} -> {:ok, files}
      err -> err
    end
  end

  defp read_blob_batch(root, batch, run_git, max_blob) do
    # batch-check then batch fetch
    oids = Enum.map(batch, & &1.blob_oid)
    stdin = Enum.join(oids, "\n") <> "\n"

    with {:ok, check_out} <- run_git.(root, ["cat-file", "--batch-check"], stdin),
         {:ok, specs} <- parse_batch_check(check_out, batch, max_blob),
         fetch_stdin <- Enum.join(Enum.map(specs, & &1.oid), "\n") <> "\n",
         {:ok, batch_out} <- run_git.(root, ["cat-file", "--batch"], fetch_stdin),
         {:ok, payloads} <- parse_batch_payloads(batch_out, specs) do
      files =
        Enum.map(batch, fn entry ->
          bytes = Map.fetch!(payloads, entry.blob_oid)
          %{path: entry.path, blob_oid: entry.blob_oid, bytes: bytes}
        end)

      {:ok, files}
    end
  end

  defp parse_batch_check(output, batch, max_blob) do
    lines =
      output
      |> String.split("\n", trim: true)

    if length(lines) != length(batch) do
      {:error, :batch_check_count_mismatch}
    else
      Enum.zip(batch, lines)
      |> Enum.reduce_while({:ok, []}, fn {entry, line}, {:ok, acc} ->
        case String.split(line, " ") do
          [oid, "blob", size_s] ->
            size = String.to_integer(size_s)

            cond do
              oid != entry.blob_oid ->
                {:halt, {:error, {:oid_mismatch, entry.path}}}

              size > max_blob ->
                {:halt, {:error, {:blob_too_large, entry.path, size}}}

              true ->
                {:cont, {:ok, [%{oid: oid, size: size, path: entry.path} | acc]}}
            end

          [oid, "missing"] ->
            {:halt, {:error, {:blob_missing, oid, entry.path}}}

          other ->
            {:halt, {:error, {:batch_check_line, other}}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        err -> err
      end
    end
  end

  defp parse_batch_payloads(output, specs) do
    parse_payloads(output, specs, %{})
  end

  defp parse_payloads(_rest, [], acc), do: {:ok, acc}

  defp parse_payloads(rest, [spec | specs], acc) do
    case next_header(rest) do
      {:ok, oid, "blob", size, after_header} ->
        if oid != spec.oid or size != spec.size do
          {:error, {:payload_header_mismatch, spec.path}}
        else
          if byte_size(after_header) < size + 1 do
            {:error, :payload_truncated}
          else
            content = binary_part(after_header, 0, size)
            # trailing newline after content
            next = binary_part(after_header, size + 1, byte_size(after_header) - size - 1)
            parse_payloads(next, specs, Map.put(acc, oid, content))
          end
        end

      {:error, _} = err ->
        err
    end
  end

  defp next_header(bin) do
    case :binary.split(bin, "\n") do
      [header, rest] ->
        case String.split(header, " ") do
          [oid, type, size_s] ->
            {:ok, oid, type, String.to_integer(size_s), rest}

          _ ->
            {:error, {:bad_header, header}}
        end

      _ ->
        {:error, :missing_header}
    end
  end

  defp default_run_git(root, args, stdin) do
    # Reuse shell stdin plumbing (argv-safe: OIDs only on stdin for cat-file).
    full_args =
      [
        "--no-replace-objects",
        "-C",
        root,
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.pager=cat"
      ] ++ args

    env = %{
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_NO_LAZY_FETCH" => "1",
      "GIT_NO_REPLACE_OBJECTS" => "1",
      "LC_ALL" => "C"
    }

    opts =
      [
        sandbox: :none,
        timeout: 120_000,
        max_output_bytes: @max_total_bytes * 2,
        clear_env: true,
        env: env
      ]
      |> then(fn o ->
        if is_binary(stdin) and byte_size(stdin) > 0, do: Keyword.put(o, :stdin, stdin), else: o
      end)

    case Arbor.Shell.execute_direct("git", full_args, opts) do
      {:ok, %{timed_out: true}} ->
        {:error, :git_timeout}

      {:ok, %{output_limit_exceeded: true}} ->
        {:error, :git_output_too_large}

      {:ok, %{exit_code: 0, stdout: output}} when is_binary(output) ->
        {:ok, output}

      {:ok, %{exit_code: code, stdout: output}} ->
        out = if is_binary(output), do: String.slice(output, 0, 500), else: ""
        {:error, {:git_exit, code, out}}

      {:error, reason} ->
        {:error, {:git_execution_failed, inspect(reason)}}
    end
  catch
    :exit, reason -> {:error, {:git_shell_unavailable, inspect(reason)}}
  end
end
