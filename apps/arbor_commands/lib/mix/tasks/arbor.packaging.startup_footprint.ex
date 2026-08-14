defmodule Mix.Tasks.Arbor.Packaging.StartupFootprint do
  @shortdoc "K3B startup-footprint probe for Common/Signals/Monitor merge candidates"

  @moduledoc """
  Isolated startup-footprint probe for the reversible K3 merge decision.

  Compiles a tracked probe fixture with the umbrella locked `deps/` cache,
  then measures baseline, proposed-gated, and proposed-eager scenarios in
  separate fresh OS/BEAM processes.

      mix arbor.packaging.startup_footprint
      mix arbor.packaging.startup_footprint --json
      mix arbor.packaging.startup_footprint --check
      mix arbor.packaging.startup_footprint --check --json

  This task is not installed in the root `quality` alias. It never runs
  `deps.get`, honors the standard `MIX_DEPS_PATH` for isolated worktrees,
  and never writes the umbrella `mix.lock` or dependency cache. The matching
  ExUnit production-path test is skipped unless `ARBOR_APP_ENV_PROBES=1`
  so a root-wide `mix test` does not nest a probe compile.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.Encode

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, report, cli} ->
        emit(report, cli.json)

        if cli.mode == "check" and report["status"] == "failed" do
          exit({:shutdown, 1})
        else
          :ok
        end

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
        policy: cli.policy
      ]

      case Keyword.keys(runtime_opts) do
        [] ->
          case StartupFootprint.run(opts) do
            {:ok, report} -> {:ok, report, cli}
            {:error, _} = err -> err
          end

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
          json: :boolean,
          root: :string,
          policy: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional}}

      true ->
        {:ok,
         %{
           mode: if(opts[:check] == true, do: "check", else: "report"),
           json: Keyword.get(opts, :json, false) == true,
           root: opts[:root],
           policy: opts[:policy]
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
    samples = report["samples"] || %{}
    failures = get_in(report, ["comparison", "failure_count"]) || 0

    lines =
      for scenario <- StartupFootprint.scenarios() do
        sample = samples[scenario] || %{}

        "#{scenario} process_delta=#{sample["process_count_delta"]} " <>
          "children=#{sample["supervisor_children"]} " <>
          "ets=#{sample["ets_table_count_delta"]} " <>
          "mem=#{sample["beam_memory_bytes_delta"]} " <>
          "boot_us=#{sample["boot_time_us"]} " <>
          "filter=#{sample["logger_filter_count"]} " <>
          "tel=#{sample["telemetry_handler_count"]}"
      end

    [
      "startup-footprint #{report["mode"]} status=#{report["status"]}",
      Enum.join(lines, "\n"),
      "failure_count=#{failures}"
    ]
    |> Enum.join("\n")
  end

  defp format_error({:arguments, reason}), do: "arguments: #{reason}"
  defp format_error({:mode, reason}), do: "mode: #{reason}"
  defp format_error(message) when is_binary(message), do: message
  defp format_error(other), do: "startup-footprint failed: #{inspect(other)}"
end
