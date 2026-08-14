defmodule Mix.Tasks.Arbor.Packaging.KernelMigration do
  @shortdoc "PK-K0 kernel-migration evidence and disposition gate"

  @moduledoc """
  Deterministic pre-migration gate over the Git-index source-coupling census.

      mix arbor.packaging.kernel_migration
      mix arbor.packaging.kernel_migration --json
      mix arbor.packaging.kernel_migration --check
      mix arbor.packaging.kernel_migration --write-report

  Check mode never writes. It admits and byte-compares the checked-in
  normative report; a missing, invalid, tampered, or stale report fails
  closed. `--write-report` writes only that report. The disposition,
  Boundary, and formatter manifests are reviewed inputs and are never
  rewritten by check or write-report. The general source-coupling baseline
  is untouched.

  This task uses `Arbor.Shell.start_direct_runtime/1` (owned try/after
  cleanup). It does not start the `:arbor_shell` application.

  Not installed in the root `quality` alias — a second full Git-index census
  is not demonstrably fast. The exact gate is:

      ./bin/mix arbor.packaging.kernel_migration --check --json
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.KernelMigration
  alias Arbor.Commands.KernelMigration.Encode
  alias Arbor.Commands.SourceCoupling

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, report, cli} ->
        emit(report, cli.json)
        if report["status"] == "failed", do: exit({:shutdown, 1}), else: :ok

      {:error, error} ->
        Mix.shell().error(format_error(error))
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(argv, runtime_opts \\ []) when is_list(argv) and is_list(runtime_opts) do
    case execute_with_cli(argv, runtime_opts) do
      {:ok, report, _cli} -> {:ok, report}
      {:error, error} -> {:error, error}
    end
  end

  defp execute_with_cli(argv, runtime_opts \\ []) do
    with {:ok, cli} <- parse_args(argv) do
      opts = [
        mode: cli.mode,
        json: cli.json,
        root: cli.root,
        report: cli.report,
        disposition: cli.disposition,
        boundary: cli.boundary,
        formatter: cli.formatter
      ]

      opts =
        if cli.mode == "write_report",
          do: Keyword.put(opts, :allow_write, Keyword.get(runtime_opts, :allow_write, true)),
          else: opts

      case Keyword.keys(runtime_opts) -- [:allow_write] do
        [] ->
          SourceCoupling.with_direct_runtime(fn ->
            case KernelMigration.run(
                   Keyword.merge(opts, Keyword.take(runtime_opts, [:allow_write]))
                 ) do
              {:ok, report} -> {:ok, report, cli}
              {:error, _} = err -> err
            end
          end)

        unexpected ->
          {:error, {:production_task_forbids_runtime_hooks, unexpected}}
      end
    end
  end

  defp parse_args(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          check: :boolean,
          write_report: :boolean,
          json: :boolean,
          root: :string,
          report: :string,
          disposition: :string,
          boundary: :string,
          formatter: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional}}

      opts[:check] && opts[:write_report] ->
        {:error, {:mode, :conflicting_check_and_write}}

      true ->
        mode =
          cond do
            opts[:write_report] -> "write_report"
            opts[:check] -> "check"
            true -> "report"
          end

        {:ok,
         %{
           mode: mode,
           json: Keyword.get(opts, :json, false) == true,
           root: opts[:root],
           report: opts[:report],
           disposition: opts[:disposition],
           boundary: opts[:boundary],
           formatter: opts[:formatter]
         }}
    end
  end

  defp emit(report, json?) when is_boolean(json?) do
    if json? or report["output"] == "json" do
      case Encode.encode_report(report) do
        {:ok, bytes} -> Mix.shell().info(bytes)
        {:error, _} -> Mix.shell().info(inspect(report, pretty: true, limit: 50))
      end
    else
      Mix.shell().info(human_summary(report))
    end
  end

  defp human_summary(report) do
    counts = report["counts"] || %{}
    identity = report["identity"] || ""
    prefix = String.slice(identity, 0, 12)
    failures = get_in(report, ["comparison", "failure_count"]) || 0

    [
      "kernel-migration #{report["mode"]} status=#{report["status"]} runtime=direct",
      "total=#{counts["total"]} runtime=#{counts["runtime"]} mix_task=#{counts["mix_task"]} " <>
        "boundary=#{counts["boundary"]} formatter=#{counts["formatter"]}",
      "identity=#{prefix} failure_count=#{failures}"
    ]
    |> Enum.join("\n")
  end

  defp format_error({:arguments, reason}), do: "arguments: #{reason}"
  defp format_error({:mode, reason}), do: "mode: #{reason}"
  defp format_error(other), do: "kernel-migration failed: #{inspect(other)}"
end
