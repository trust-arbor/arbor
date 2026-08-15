defmodule Arbor.Commands.SourceCoupling.GitInventory do
  @moduledoc """
  Imperative Git inventory for source-coupling census.

  Enumerates stage-0 tracked paths and reads exact blob bytes via
  argv-safe `git cat-file --batch` (OIDs on stdin). The E0A selected-source
  API admits only production Elixir sources at
  `apps/<selected_app>/lib/<one-or-more-segments>.ex`.
  """

  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  # Exact regular-file modes only — never symlinks (120000), gitlinks, or trees.
  @accepted_modes MapSet.new(["100644", "100755"])
  @symlink_mode "120000"
  @max_blob_bytes 1_048_576
  @max_total_bytes 64 * 1024 * 1024
  @max_files 50_000
  @max_path_bytes 4096
  @max_selected_apps 256
  @max_app_bytes 255
  @batch_size 64
  @selected_index_domain "arbor.git_inventory.selected_index.v1\0"
  @app_name_re ~r/\A[a-z][a-z0-9_]*\z/

  @type file_entry :: %{
          path: String.t(),
          blob_oid: String.t(),
          mode: String.t(),
          byte_size: non_neg_integer(),
          bytes: binary()
        }

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
  Load every tracked `*.ex`/`*.exs` blob, including root `mix.exs`.

  Lists the full stage-0 index, then keeps Elixir source paths **before**
  applying regular-file mode checks so unrelated gitlinks/symlinks cannot
  abort the census. Source entries still fail closed on symlink, invalid
  mode, non-zero stage, malformed records, and missing/oversize blobs.
  """
  @spec load_elixir_index(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_elixir_index(root, opts \\ []) when is_binary(root) and is_list(opts) do
    run_git = Keyword.get(opts, :run_git, &default_run_git/3)
    max_blob = Keyword.get(opts, :max_blob_bytes, @max_blob_bytes)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes * 2)

    with {:ok, tree_oid} <- rev_parse_tree(root, run_git),
         {:ok, staged} <- ls_files_stage_all(root, run_git),
         {:ok, admitted} <- admit_elixir_source_entries(staged),
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

  @doc false
  @spec parse_stage_fields(binary()) :: {:ok, map()} | {:error, term()}
  def parse_stage_fields(line) when is_binary(line) do
    line = String.trim_trailing(line, "\n")

    case Regex.run(~r/\A([0-7]{6}) ([0-9a-f]+) ([0-3])\t(.+)\z/, line) do
      [_, mode, oid, stage_s, path] ->
        {:ok, %{mode: mode, blob_oid: oid, stage: String.to_integer(stage_s), path: path}}

      _ ->
        {:error, {:malformed_stage_line, line}}
    end
  end

  def parse_stage_fields(_), do: {:error, :malformed_stage_line}

  @doc false
  @spec elixir_source_path?(term()) :: boolean()
  def elixir_source_path?(path) when is_binary(path) do
    String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")
  end

  def elixir_source_path?(_), do: false

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

  @doc "Reviewed argv/cat-file chunk ceiling for K4 destination queries."
  @spec destination_query_batch() :: pos_integer()
  def destination_query_batch, do: @batch_size

  @doc "Admit a repo-relative literal path (no IO)."
  @spec admit_literal_path(term()) :: :ok | {:error, term()}
  def admit_literal_path(path), do: literal_repo_path(path)

  @doc """
  Load selected-app production Elixir source blobs from the full index.

  Selection is exactly `apps/<selected_app>/lib/<one-or-more-segments>.ex`.
  Tracked app metadata, configuration, `priv`, tests, `.exs` files, unselected
  apps, and `apps/arbor_integrations` are ignored before selected-entry
  mode/stage/OID admission, just like every other unrelated path. A malformed
  path that structurally targets the selected production scope remains in
  scope and fails closed during admission.

  The returned `files` are read from the stage-0 **index** (`git ls-files
  --stage`), not from a tree object. `head_tree_oid` is `HEAD^{tree}`,
  recorded as separately named provenance for audit/display only — it is
  **not** proof that the returned blob bytes came from that tree. When the
  working index has staged-but-uncommitted changes, the index and
  `HEAD^{tree}` diverge for the affected paths.

  `selected_index_digest` binds the exact sorted selected production-source
  `{path, mode, blob_oid}` set. It is domain-separated index provenance and
  must never be labeled as HEAD-tree content. Consumer-specific report
  digests belong in the consumer encoder.
  """
  @spec load_selected_blobs(String.t(), [String.t()], keyword()) ::
          {:ok,
           %{
             files: [file_entry()],
             object_format: String.t(),
             head_tree_oid: String.t(),
             selected_index_digest: String.t()
           }}
          | {:error, term()}
  def load_selected_blobs(root, selected_apps, opts \\ [])

  def load_selected_blobs(root, selected_apps, opts)
      when is_binary(root) and is_list(selected_apps) and is_list(opts) do
    run_git = Keyword.get(opts, :run_git, &default_run_git/3)
    max_blob = Keyword.get(opts, :max_blob_bytes, @max_blob_bytes)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)

    with {:ok, selected_apps} <- admit_selected_apps(selected_apps),
         {:ok, head_tree_oid} <- rev_parse_tree(root, run_git),
         {:ok, staged} <- ls_files_stage_all(root, run_git),
         {:ok, admitted} <- admit_selected_production_entries(staged, selected_apps),
         :ok <- check_file_count(admitted),
         {:ok, object_format} <- infer_selected_object_format(admitted, head_tree_oid),
         :ok <- match_head_tree_format(head_tree_oid, object_format),
         {:ok, files} <- read_blobs(root, admitted, run_git, max_blob, max_total),
         {:ok, selected_index_digest} <- selected_index_digest(index_triples(files)) do
      {:ok,
       %{
         files: files,
         object_format: object_format,
         head_tree_oid: head_tree_oid,
         selected_index_digest: selected_index_digest
       }}
    end
  end

  def load_selected_blobs(_, _, _), do: {:error, :invalid_selected_apps}

  @doc """
  Domain-separated digest of the exact sorted selected production-source set.

  Every triple path must have the exact production-source shape
  `apps/<app>/lib/<one-or-more-segments>.ex`; `apps/arbor_integrations` is
  excluded. This binds stage-0 index content only. It is not a `HEAD^{tree}`
  digest and must not be labeled as tree content.
  """
  @spec selected_index_digest([{String.t(), String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, term()}
  def selected_index_digest(triples) when is_list(triples) do
    with {:ok, admitted} <- admit_index_triples(triples) do
      digest =
        admitted
        |> Enum.sort_by(&elem(&1, 0))
        |> hash_framed_triples(@selected_index_domain)

      {:ok, digest}
    end
  end

  def selected_index_digest(_), do: {:error, :invalid_selected_index}

  @doc """
  Query explicit index blobs in argv-bounded chunks.

  Each chunk is at most `destination_query_batch/0` paths. Results are
  merged and sorted by path. Missing paths are returned in `:absent`.
  """
  @spec query_indexed_blobs_batched(String.t(), [String.t()], keyword()) ::
          {:ok, %{present: [file_entry()], absent: [String.t()]}} | {:error, term()}
  def query_indexed_blobs_batched(root, paths, opts \\ [])

  def query_indexed_blobs_batched(root, paths, opts)
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
        with :ok <- check_file_count(paths),
             :ok <- admit_literal_paths(paths) do
          query_batched_chunks(root, paths, run_git, max_blob, max_total)
        end
    end
  end

  def query_indexed_blobs_batched(_, _, _), do: {:error, :invalid_paths}

  @doc """
  List stage records under explicit prefixes without reading blobs.

  Used to prove old source roots are absent. Prefix argv stays bounded.
  """
  @spec list_stage_prefixes(String.t(), [String.t()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_stage_prefixes(root, prefixes, opts \\ [])

  def list_stage_prefixes(root, prefixes, opts)
      when is_binary(root) and is_list(prefixes) and is_list(opts) do
    run_git = Keyword.get(opts, :run_git, &default_run_git/3)

    cond do
      prefixes == [] ->
        {:ok, []}

      not Enum.all?(prefixes, &is_binary/1) ->
        {:error, :invalid_paths}

      length(prefixes) != length(Enum.uniq(prefixes)) ->
        {:error, :duplicate_paths}

      true ->
        selected_apps = Enum.flat_map(prefixes, &prefix_app/1)

        with :ok <- check_file_count(prefixes),
             :ok <- admit_literal_paths(prefixes),
             {:ok, staged} <- ls_files_stage_prefixes(root, prefixes, run_git),
             {:ok, admitted} <- admit_selected_stage_entries(staged, selected_apps) do
          {:ok, admitted}
        end
    end
  end

  def list_stage_prefixes(_, _, _), do: {:error, :invalid_paths}

  defp admit_selected_apps(apps) when is_list(apps) do
    cond do
      apps == [] ->
        {:error, :invalid_selected_apps}

      length(apps) > @max_selected_apps ->
        {:error, :selected_app_limit}

      length(apps) != length(Enum.uniq(apps)) ->
        {:error, :duplicate_selected_apps}

      not Enum.all?(apps, &valid_selected_app?/1) ->
        {:error, :invalid_selected_apps}

      true ->
        {:ok, MapSet.new(apps)}
    end
  end

  defp admit_selected_apps(_), do: {:error, :invalid_selected_apps}

  defp admit_selected_production_entries(entries, selected_apps) do
    admit_selected_stage_entries(entries, selected_apps, &selected_production_source_path?/2)
  end

  defp admit_selected_stage_entries(entries, selected_apps) do
    admit_selected_stage_entries(entries, selected_apps, &selected_app_path?/2)
  end

  defp admit_selected_stage_entries(entries, selected_apps, selected_path?) do
    selected_apps = MapSet.new(selected_apps)

    selected =
      Enum.filter(entries, fn entry ->
        selected_path?.(entry.path, selected_apps)
      end)

    paths = Enum.map(selected, & &1.path)

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :index_conflict}

      true ->
        Enum.reduce_while(selected, {:ok, []}, fn entry, {:ok, acc} ->
          case admit_selected_entry(entry) do
            {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          err -> err
        end
    end
  end

  defp selected_app_path?(path, selected_apps) when is_binary(path) do
    case Path.split(path) do
      ["apps", "arbor_integrations" | _] ->
        false

      ["apps", app | _] ->
        MapSet.member?(selected_apps, app)

      _ ->
        false
    end
  end

  defp selected_app_path?(_, _), do: false

  defp selected_production_source_path?(path, selected_apps) when is_binary(path) do
    case :binary.split(path, "/", [:global]) do
      ["apps", "arbor_integrations" | _] ->
        false

      ["apps", app | suffix] ->
        MapSet.member?(selected_apps, app) and
          (production_source_suffix?(suffix) or traversal_production_source_suffix?(suffix))

      _ ->
        false
    end
  end

  defp selected_production_source_path?(_, _), do: false

  defp production_source_path?(path) when is_binary(path) do
    case :binary.split(path, "/", [:global]) do
      ["apps", app, "lib" | source_segments] when source_segments != [] ->
        app != "arbor_integrations" and valid_selected_app?(app) and
          ex_source_name?(List.last(source_segments))

      _ ->
        false
    end
  end

  defp production_source_path?(_), do: false

  defp production_source_suffix?(["lib" | source_segments]) when source_segments != [],
    do: ex_source_name?(List.last(source_segments))

  defp production_source_suffix?(_), do: false

  defp traversal_production_source_suffix?(segments) do
    Enum.any?(segments, &(&1 in ["", ".", ".."])) and "lib" in segments and
      ex_source_name?(List.last(segments))
  end

  defp ex_source_name?(name) when is_binary(name) and byte_size(name) >= 3,
    do: binary_part(name, byte_size(name) - 3, 3) == ".ex"

  defp ex_source_name?(_), do: false

  defp valid_selected_app?(app) when is_binary(app) do
    String.valid?(app) and byte_size(app) <= @max_app_bytes and Regex.match?(@app_name_re, app)
  end

  defp valid_selected_app?(_), do: false

  defp admit_selected_entry(%{mode: mode, blob_oid: oid, stage: stage, path: path} = entry) do
    with :ok <- literal_repo_path(path),
         :ok <- check_path_size(path) do
      cond do
        not Regex.match?(@oid_re, oid) ->
          {:error, {:invalid_oid, oid}}

        stage != 0 ->
          {:error, {:unsupported_selected_stage, path, stage}}

        MapSet.member?(@accepted_modes, mode) ->
          {:ok, entry}

        true ->
          {:error, {:unsupported_selected_mode, mode, path}}
      end
    end
  end

  defp admit_selected_entry(_), do: {:error, :malformed_stage_line}

  defp check_path_size(path) when byte_size(path) > @max_path_bytes,
    do: {:error, {:invalid_path, :unbounded}}

  defp check_path_size(_), do: :ok

  defp match_head_tree_format(head_tree_oid, "sha1")
       when byte_size(head_tree_oid) == 40,
       do: :ok

  defp match_head_tree_format(head_tree_oid, "sha256")
       when byte_size(head_tree_oid) == 64,
       do: :ok

  defp match_head_tree_format(_head_tree_oid, _object_format),
    do: {:error, {:oid_format_mismatch, :head_tree}}

  defp index_triples(files) do
    Enum.map(files, &{&1.path, &1.mode, &1.blob_oid})
  end

  defp admit_index_triples(triples) do
    cond do
      length(triples) > @max_files ->
        {:error, :file_limit}

      true ->
        Enum.reduce_while(triples, {:ok, []}, fn triple, {:ok, acc} ->
          case admit_index_triple(triple) do
            {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, acc} -> finish_index_triples(Enum.reverse(acc))
          err -> err
        end
    end
  end

  defp finish_index_triples(admitted) do
    paths = Enum.map(admitted, &elem(&1, 0))
    oid_lengths = admitted |> Enum.map(fn {_, _, oid} -> byte_size(oid) end) |> Enum.uniq()

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :duplicate_selected_paths}

      oid_lengths not in [[], [40], [64]] ->
        {:error, :mixed_object_format}

      true ->
        {:ok, admitted}
    end
  end

  defp admit_index_triple({path, mode, oid})
       when is_binary(path) and is_binary(mode) and is_binary(oid) do
    with :ok <- literal_repo_path(path),
         :ok <- check_path_size(path),
         true <- production_source_path?(path) do
      cond do
        not MapSet.member?(@accepted_modes, mode) ->
          {:error, :invalid_selected_index}

        not Regex.match?(@oid_re, oid) ->
          {:error, :invalid_selected_index}

        true ->
          {:ok, {path, mode, oid}}
      end
    else
      false -> {:error, :invalid_selected_index}
      {:error, _} -> {:error, :invalid_selected_index}
    end
  end

  defp admit_index_triple(_), do: {:error, :invalid_selected_index}

  defp hash_framed_triples(triples, domain) do
    Enum.reduce(
      triples,
      :crypto.hash_init(:sha256) |> :crypto.hash_update(domain),
      fn {path, mode, oid}, acc ->
        :crypto.hash_update(acc, [
          <<byte_size(path)::unsigned-big-32>>,
          path,
          <<byte_size(mode)::unsigned-big-32>>,
          mode,
          <<byte_size(oid)::unsigned-big-32>>,
          oid
        ])
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp infer_object_format([]), do: {:ok, "sha1"}

  defp infer_object_format(entries) when is_list(entries) do
    lengths =
      entries
      |> Enum.map(&byte_size(&1.blob_oid))
      |> Enum.uniq()

    case lengths do
      [40] -> {:ok, "sha1"}
      [64] -> {:ok, "sha256"}
      _ -> {:error, :mixed_object_format}
    end
  end

  defp infer_selected_object_format([], head_tree_oid) when byte_size(head_tree_oid) == 40,
    do: {:ok, "sha1"}

  defp infer_selected_object_format([], head_tree_oid) when byte_size(head_tree_oid) == 64,
    do: {:ok, "sha256"}

  defp infer_selected_object_format(entries, _head_tree_oid), do: infer_object_format(entries)

  defp query_batched_chunks(root, paths, run_git, max_blob, max_total) do
    paths
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, [], [], 0}, fn chunk, {:ok, present_acc, absent_acc, total} ->
      case query_selected_chunk(root, chunk, run_git, max_blob, max_total - total) do
        {:ok, %{present: present, absent: absent, bytes: used}} ->
          {:cont, {:ok, present_acc ++ present, absent_acc ++ absent, total + used}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, present, absent, _total} ->
        present = Enum.sort_by(present, & &1.path)

        case infer_object_format(present) do
          {:ok, _} -> {:ok, %{present: present, absent: absent}}
          err -> err
        end

      err ->
        err
    end
  end

  defp query_selected_chunk(root, chunk, run_git, max_blob, remaining_total) do
    with {:ok, staged} <- ls_files_stage_path_fields(root, chunk, run_git),
         {:ok, %{admitted: admitted, absent: absent}} <- query_explicit_paths(staged, chunk),
         {:ok, selected} <- admit_selected_list(admitted),
         {:ok, object_format} <- infer_object_format(selected),
         :ok <- check_chunk_format(object_format),
         {:ok, files} <- read_blobs(root, selected, run_git, max_blob, remaining_total) do
      used = Enum.reduce(files, 0, &(&1.byte_size + &2))
      {:ok, %{present: files, absent: absent, bytes: used}}
    end
  end

  defp check_chunk_format("sha1"), do: :ok
  defp check_chunk_format("sha256"), do: :ok
  defp check_chunk_format(_), do: {:error, :mixed_object_format}

  defp admit_selected_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case admit_selected_entry(entry) do
        {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp ls_files_stage_path_fields(root, paths, run_git) do
    args = ["--literal-pathspecs", "ls-files", "-z", "--stage", "--"] ++ paths

    case run_git.(root, args, "") do
      {:ok, out} -> parse_stage_fields_output(out)
      {:error, reason} -> {:error, {:git_ls_files, reason}}
    end
  end

  defp ls_files_stage_prefixes(root, prefixes, run_git) do
    args = ["ls-files", "-z", "--stage", "--"] ++ prefixes

    case run_git.(root, args, "") do
      {:ok, out} -> parse_stage_fields_output(out)
      {:error, reason} -> {:error, {:git_ls_files, reason}}
    end
  end

  defp prefix_app(prefix) when is_binary(prefix) do
    case Path.split(prefix) do
      ["apps", app | _] -> [app]
      _ -> []
    end
  end

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

  defp ls_files_stage_all(root, run_git) do
    args = ["ls-files", "-z", "--stage"]

    case run_git.(root, args, "") do
      {:ok, out} -> parse_stage_fields_output(out)
      {:error, reason} -> {:error, {:git_ls_files, reason}}
    end
  end

  defp parse_stage_fields_output(out) when is_binary(out) do
    out
    |> String.split("\0", trim: true)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case parse_stage_fields(chunk) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp admit_elixir_source_entries(entries) do
    sources = Enum.filter(entries, &elixir_candidate?/1)
    paths = Enum.map(sources, & &1.path)

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :index_conflict}

      true ->
        Enum.reduce_while(sources, {:ok, []}, fn entry, {:ok, acc} ->
          case admit_elixir_source_entry(entry) do
            {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          err -> err
        end
    end
  end

  defp elixir_candidate?(entry) do
    elixir_source_path?(entry.path)
  end

  defp admit_elixir_source_entry(%{mode: mode, blob_oid: oid, stage: stage, path: path} = entry) do
    cond do
      not Regex.match?(@oid_re, oid) ->
        {:error, {:invalid_oid, oid}}

      stage != 0 ->
        {:error, {:non_zero_stage, path, stage}}

      mode == @symlink_mode ->
        {:error, {:symlink_blob, path}}

      MapSet.member?(@accepted_modes, mode) ->
        {:ok, entry}

      true ->
        {:error, {:invalid_mode, mode, path}}
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

          %{
            path: entry.path,
            blob_oid: entry.blob_oid,
            mode: entry.mode,
            byte_size: byte_size(bytes),
            bytes: bytes
          }
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
