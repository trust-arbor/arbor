defmodule Mix.Tasks.Arbor.Coding.Benchmark.Prepare do
  @shortdoc "Materialize a coding-benchmark catalog into standalone fixtures"
  @moduledoc """
  Deterministically materializes a closed coding-benchmark catalog into
  standalone Git fixture repositories and a validated harness manifest.

  ## Usage

      mix arbor.coding.benchmark.prepare \\
        --catalog benchmarks/coding/catalog-v1.json \\
        --output tmp/coding-benchmark-prepared

      mix arbor.coding.benchmark.prepare \\
        --catalog benchmarks/coding/catalog-v1.json \\
        --output tmp/coding-benchmark-prepared \\
        --source .

  ## Options

    * `--catalog` - required catalog JSON path under the trusted root
    * `--output` - required prepared-output directory under the trusted root
    * `--source` - optional source Git repository within the trusted root
      (defaults to the trusted root / current working repository)

  The trusted root defaults to the process current working directory. Output is
  reserved with an exclusive private directory creation and refused when the
  destination already exists. `publication.json` is written last; failures
  remove only the exact unpublished root identity owned by this invocation.
  """

  use Mix.Task

  alias Arbor.Commands.CodingBenchmark.Materializer

  @impl true
  def run(args) do
    with {:ok, _started} <- Application.ensure_all_started(:arbor_shell),
         {:ok, result} <- execute(args) do
      Mix.shell().info(
        "Prepared coding benchmark fixtures at #{result.output_path} (catalog_digest=#{result.catalog_digest})"
      )
    else
      {:error, reason} when is_map(reason) -> Mix.raise(Jason.encode!(reason))
      {:error, reason} -> Mix.raise("could not start arbor_shell: #{inspect(reason)}")
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) ::
          {:ok, Materializer.result()} | {:error, map()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    with {:ok, cli} <- parse_args(args) do
      opts =
        runtime_opts
        |> Keyword.take([:root, :timeout_ms])
        |> maybe_put(:source, cli.source)

      Materializer.prepare(cli.catalog, cli.output, opts)
    end
  end

  def execute(_args, _runtime_opts),
    do: task_error("arguments", "expected_lists")

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          catalog: :string,
          output: :string,
          source: :string
        ]
      )

    cond do
      invalid != [] ->
        task_error("arguments", "unknown_or_invalid_option")

      positional != [] ->
        task_error("arguments", "unexpected_positional_argument")

      not is_binary(opts[:catalog]) ->
        task_error("catalog", "required")

      not is_binary(opts[:output]) ->
        task_error("output", "required")

      true ->
        {:ok,
         %{
           catalog: opts[:catalog],
           output: opts[:output],
           source: opts[:source]
         }}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp task_error(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_prepare_command",
       "field" => field,
       "reason" => reason
     }}
  end
end
