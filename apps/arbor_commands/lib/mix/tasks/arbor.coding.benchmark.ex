defmodule Mix.Tasks.Arbor.Coding.Benchmark do
  @shortdoc "Run paired legacy/pipeline coding conformance fixtures"
  @moduledoc """
  Runs data-only benchmark manifests through trusted, named coding adapters and
  writes a JSON conformance report.

  ## Usage

      mix arbor.coding.benchmark \
        --manifest benchmarks/coding/manifest.json \
        --acp-agent grok \
        --repetitions 3 \
        --output reports/coding-benchmark.json

      mix arbor.coding.benchmark \
        --manifest benchmarks/coding/manifest.json \
        --dry-run \
        --seed 42

  ## Options

    * `--manifest` - required JSON manifest below the current working directory
    * `--acp-agent` - named ACP agent passed to trusted adapters
    * `--repetitions` - pair repetitions, from 1 through 100 (default: 1)
    * `--seed` - deterministic pair-order seed (manifest seed by default)
    * `--output` - report path below the current working directory
    * `--dry-run` - validate and emit deterministic skipped rows without adapters

  Adapter and verifier callbacks come only from trusted runtime configuration or
  the test-only `execute/2` options. A manifest cannot name executable modules or
  functions. Prepared publications that select the closed `exact_target_tree`
  verifier install Arbor's built-in implementation from validated target
  evidence; Application config cannot override that selector.

  Each invocation creates a collision-resistant execution namespace so production
  adapter task/run IDs cannot collide with a prior frozen-manifest run (including
  after BEAM restarts). That namespace stays harness-private and is not written
  into public report rows.
  """

  use Mix.Task

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.Catalog
  alias Arbor.Commands.CodingBenchmark.Runtime
  alias Arbor.Common.SafePath

  @default_output "coding-benchmark-report.json"
  @max_manifest_bytes 1_048_576
  @exact_target_tree_selector "exact_target_tree"

  @impl true
  def run(args) do
    case execute(args) do
      {:ok, %{output_path: output_path, report: report}} ->
        summary = report["summary"]

        Mix.shell().info(
          "Wrote #{summary["row_count"]} benchmark rows (#{summary["pair_count"]} pairs) to #{output_path}"
        )

      {:error, reason} ->
        Mix.raise(Jason.encode!(reason))
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) ::
          {:ok, %{output_path: String.t(), report: map()}} | {:error, map()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    with {:ok, cli} <- parse_args(args),
         {:ok, root} <- trusted_root(runtime_opts),
         {:ok, manifest_path} <- existing_json_path(cli.manifest, root, "manifest"),
         {:ok, manifest} <- read_manifest(manifest_path),
         {:ok, normalized_manifest} <- CodingBenchmark.validate_manifest(manifest),
         {:ok, exact_target_trees} <-
           validate_prepared_publication(manifest_path, manifest, normalized_manifest),
         {:ok, output_path} <- output_json_path(cli.output, root),
         :ok <- distinct_paths(manifest_path, output_path),
         :ok <-
           output_outside_fixtures(output_path, normalized_manifest, Path.dirname(manifest_path)),
         :ok <- artifact_root_disjoint(normalized_manifest, Path.dirname(manifest_path)),
         {:ok, benchmark_opts} <-
           benchmark_opts(cli, runtime_opts, Path.dirname(manifest_path), exact_target_trees),
         {:ok, report} <- CodingBenchmark.run(manifest, benchmark_opts),
         :ok <- write_report(output_path, report) do
      {:ok, %{output_path: output_path, report: report}}
    end
  end

  def execute(_args, _runtime_opts), do: task_error("arguments", "expected_lists")

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          acp_agent: :string,
          dry_run: :boolean,
          manifest: :string,
          output: :string,
          repetitions: :integer,
          seed: :integer
        ]
      )

    cond do
      invalid != [] ->
        task_error("arguments", "unknown_or_invalid_option")

      positional != [] ->
        task_error("arguments", "unexpected_positional_argument")

      not is_binary(opts[:manifest]) ->
        task_error("manifest", "required")

      not valid_repetitions?(Keyword.get(opts, :repetitions, 1)) ->
        task_error("repetitions", "out_of_bounds")

      not valid_seed?(Keyword.get(opts, :seed)) ->
        task_error("seed", "out_of_bounds")

      true ->
        {:ok,
         %{
           acp_agent: opts[:acp_agent],
           dry_run: Keyword.get(opts, :dry_run, false),
           manifest: opts[:manifest],
           output: Keyword.get(opts, :output, @default_output),
           repetitions: Keyword.get(opts, :repetitions, 1),
           seed: opts[:seed]
         }}
    end
  end

  defp valid_repetitions?(value), do: is_integer(value) and value in 1..100
  defp valid_seed?(nil), do: true
  defp valid_seed?(value), do: is_integer(value) and value in 0..2_147_483_647

  defp trusted_root(runtime_opts) do
    path = Keyword.get(runtime_opts, :root, configured_workspace_root())

    case Runtime.validate_trusted_root(path) do
      {:ok, real} ->
        {:ok, real}

      {:error, {:benchmark_setup_error, :broad_trusted_root}} ->
        task_error("root", "broad_trusted_root")

      {:error, {:benchmark_setup_error, _reason}} ->
        task_error("root", "directory_not_found")
    end
  end

  defp configured_workspace_root do
    case Runtime.load() do
      {:ok, runtime} -> runtime.workspace_root
      {:error, _reason} -> nil
    end
  end

  defp existing_json_path(path, root, field) when is_binary(path) do
    with :ok <- safe_cli_path(path, field),
         :ok <- json_extension(path, field),
         {:ok, lexical} <- SafePath.resolve_within(path, root),
         {:ok, real} <- SafePath.resolve_real(lexical),
         {:ok, ^real} <- SafePath.resolve_within(real, root),
         {:ok, stat} <- File.lstat(lexical),
         true <- stat.type == :regular do
      {:ok, real}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> task_error(field, "unsafe_or_missing_path")
    end
  end

  defp existing_json_path(_path, _root, field), do: task_error(field, "expected_path")

  defp output_json_path(path, root) when is_binary(path) do
    field = "output"

    with :ok <- safe_cli_path(path, field),
         :ok <- json_extension(path, field),
         {:ok, lexical} <- SafePath.resolve_within(path, root),
         parent <- Path.dirname(lexical),
         {:ok, real_parent} <- SafePath.resolve_real(parent),
         {:ok, ^real_parent} <- SafePath.resolve_within(real_parent, root),
         :ok <- safe_output_leaf(lexical) do
      {:ok, Path.join(real_parent, Path.basename(lexical))}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> task_error(field, "unsafe_path")
    end
  end

  defp output_json_path(_path, _root), do: task_error("output", "expected_path")

  defp safe_cli_path(path, field) do
    components = Path.split(path)

    cond do
      not String.valid?(path) or String.contains?(path, <<0>>) ->
        task_error(field, "invalid_path")

      Enum.any?(components, &(&1 in [".", "..", ""])) ->
        task_error(field, "unsafe_path")

      true ->
        case SafePath.validate(path) do
          :ok -> :ok
          {:error, _reason} -> task_error(field, "unsafe_path")
        end
    end
  end

  defp json_extension(path, field) do
    if String.downcase(Path.extname(path)) == ".json",
      do: :ok,
      else: task_error(field, "expected_json_path")
  end

  defp safe_output_leaf(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _other} -> task_error("output", "non_regular_file")
      {:error, :enoent} -> :ok
      {:error, _reason} -> task_error("output", "unreadable_path")
    end
  end

  defp distinct_paths(path, path), do: task_error("output", "would_overwrite_manifest")
  defp distinct_paths(_manifest_path, _output_path), do: :ok

  defp output_outside_fixtures(output_path, manifest, fixture_root) do
    Enum.reduce_while(manifest["fixtures"], :ok, fn fixture, :ok ->
      with {:ok, lexical} <- SafePath.safe_join(fixture_root, fixture["fixture_path"]),
           {:ok, real} <- SafePath.resolve_real(lexical),
           {:ok, ^real} <- SafePath.resolve_within(real, fixture_root) do
        if path_within?(output_path, real) do
          {:halt, task_error("output", "inside_fixture")}
        else
          {:cont, :ok}
        end
      else
        _other -> {:halt, task_error("manifest.fixture_path", "unsafe_or_missing_fixture")}
      end
    end)
  end

  defp path_within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp read_manifest(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_manifest_bytes,
         {:ok, json} <- File.read(path),
         {:ok, manifest} <- Jason.decode(json) do
      {:ok, manifest}
    else
      false -> task_error("manifest", "file_too_large")
      {:error, %Jason.DecodeError{}} -> task_error("manifest", "invalid_json")
      {:error, _reason} -> task_error("manifest", "unreadable")
    end
  end

  defp validate_prepared_publication(manifest_path, manifest, normalized_manifest) do
    root = Path.dirname(manifest_path)
    evidence_path = Path.join(root, "target-evidence.json")
    publication_path = Path.join(root, "publication.json")

    case {sidecar_state(evidence_path), sidecar_state(publication_path)} do
      {:absent, :absent} ->
        {:ok, nil}

      {:regular, :regular} ->
        with {:ok, target_evidence} <- read_publication_sidecar(evidence_path, "target_evidence"),
             {:ok, publication} <- read_publication_sidecar(publication_path, "publication"),
             :ok <-
               Catalog.validate_publication(
                 manifest,
                 normalized_manifest,
                 target_evidence,
                 publication
               ) do
          {:ok, prepared_exact_target_trees(normalized_manifest, target_evidence)}
        end

      {_evidence, _publication} ->
        task_error("publication", "incomplete_or_unsafe_publication")
    end
  end

  # Retain only fixture-bound target tree OIDs for the closed built-in selector.
  # Target OIDs remain harness-private and never enter adapter requests or reports.
  defp prepared_exact_target_trees(normalized_manifest, target_evidence) do
    evidence_fixtures = target_evidence["fixtures"]

    targets =
      normalized_manifest["fixtures"]
      |> Enum.filter(&(&1["verifier_id"] == @exact_target_tree_selector))
      |> Map.new(fn fixture ->
        fixture_id = fixture["fixture_id"]
        evidence = Map.fetch!(evidence_fixtures, fixture_id)
        {fixture_id, evidence["target_tree_oid"]}
      end)

    if targets == %{}, do: nil, else: targets
  end

  defp sidecar_state(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :regular
      {:error, :enoent} -> :absent
      _other -> :unsafe
    end
  end

  defp read_publication_sidecar(path, field) do
    with {:ok, identity} <- regular_file_identity(path),
         {:ok, json} <- read_bounded_file(path, Catalog.max_bytes()),
         {:ok, ^identity} <- regular_file_identity(path),
         {:ok, value} <- Jason.decode(json) do
      {:ok, value}
    else
      {:error, :file_too_large} -> task_error(field, "file_too_large")
      {:error, %Jason.DecodeError{}} -> task_error(field, "invalid_json")
      {:error, _reason} -> task_error(field, "unreadable")
    end
  end

  defp regular_file_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok,
       %File.Stat{
         type: :regular,
         major_device: device,
         minor_device: minor_device,
         inode: inode,
         size: size
       }} ->
        {:ok, {device, minor_device, inode, size}}

      _other ->
        {:error, :unsafe_path}
    end
  end

  defp read_bounded_file(path, maximum) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, maximum + 1) end) do
      {:ok, data} when is_binary(data) and byte_size(data) <= maximum -> {:ok, data}
      {:ok, data} when is_binary(data) -> {:error, :file_too_large}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp benchmark_opts(cli, runtime_opts, fixture_root, exact_target_trees) do
    configured_adapters =
      Keyword.get_lazy(runtime_opts, :adapters, fn ->
        Application.get_env(:arbor_commands, :coding_benchmark_adapters)
      end)

    configured_verifiers =
      Keyword.get_lazy(runtime_opts, :verifiers, fn ->
        Application.get_env(:arbor_commands, :coding_benchmark_verifiers)
      end)

    with {:ok, workspace_root} <- benchmark_workspace_root(runtime_opts) do
      opts =
        [
          acp_agent: cli.acp_agent,
          adapters: configured_adapters,
          dry_run: cli.dry_run,
          fixture_root: fixture_root,
          measure: Keyword.get(runtime_opts, :measure, &default_measure/1),
          repetitions: cli.repetitions,
          verifiers: configured_verifiers,
          workspace_root: workspace_root
        ]
        |> maybe_put_seed(cli.seed)
        |> maybe_put_exact_target_trees(exact_target_trees)

      {:ok, opts}
    end
  end

  defp maybe_put_exact_target_trees(opts, nil), do: opts

  defp maybe_put_exact_target_trees(opts, exact_target_trees) when is_map(exact_target_trees),
    do: Keyword.put(opts, :exact_target_trees, exact_target_trees)

  defp benchmark_workspace_root(runtime_opts) do
    case Keyword.fetch(runtime_opts, :workspace_root) do
      {:ok, workspace_root} ->
        {:ok, workspace_root}

      :error ->
        case Runtime.load() do
          {:ok, runtime} ->
            {:ok, runtime.workspace_root}

          {:error, {:benchmark_setup_error, reason}} ->
            task_error("benchmark_setup", inspect(reason))
        end
    end
  end

  defp default_measure(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds + 999, 1_000), result}
  end

  defp maybe_put_seed(opts, nil), do: opts
  defp maybe_put_seed(opts, seed), do: Keyword.put(opts, :seed, seed)

  defp artifact_root_disjoint(manifest, fixture_root) do
    fixture_paths = Enum.map(manifest["fixtures"], & &1["fixture_path"])

    with {:ok, runtime} <- Runtime.load(),
         :ok <-
           Runtime.ensure_artifact_root_disjoint(
             runtime.artifact_root,
             fixture_root,
             fixture_paths
           ) do
      :ok
    else
      {:error, {:benchmark_setup_error, :artifact_root_overlaps_fixture}} ->
        task_error("artifact_root", "overlaps_fixture")

      {:error, {:benchmark_setup_error, reason}} ->
        task_error("artifact_root", inspect(reason))

      {:error, _reason} ->
        task_error("artifact_root", "invalid_configuration")
    end
  end

  defp write_report(path, report) do
    encoded = [Jason.encode_to_iodata!(report, pretty: true), "\n"]

    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.open(temp, [:write, :exclusive]) do
      {:ok, device} ->
        result =
          try do
            with :ok <- IO.binwrite(device, encoded),
                 :ok <- File.close(device) do
              File.rename(temp, path)
            end
          after
            File.close(device)
            File.rm(temp)
          end

        case result do
          :ok -> :ok
          {:error, reason} -> task_error("output", "write_failed:#{reason}")
        end

      {:error, reason} ->
        task_error("output", "write_failed:#{reason}")
    end
  rescue
    exception -> task_error("output", "encode_failed:#{Exception.message(exception)}")
  end

  defp task_error(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_command",
       "field" => field,
       "reason" => reason
     }}
  end
end
