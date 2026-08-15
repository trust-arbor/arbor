defmodule Mix.Tasks.Arbor.Packaging.KernelMaterialization do
  @shortdoc "K4A kernel materialization plan and checker"

  @moduledoc """
  Deterministic Git-index-backed K4 materialization plan and checker.

      mix arbor.packaging.kernel_materialization --check --phase planned
      mix arbor.packaging.kernel_materialization --check --phase materialized
      mix arbor.packaging.kernel_materialization --phase planned --json
      mix arbor.packaging.kernel_materialization --write-plan

  `--phase` is required except `--write-plan`. Check never writes. The
  checked plan is phase-independent; phase and status belong only to the
  runtime report. Manifests are read from the Git index.

  This task uses `Arbor.Shell.start_direct_runtime/1`. It does not start
  the `:arbor_shell` application.

  Not installed in the root `quality` alias.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.KernelMaterialization
  alias Arbor.Commands.KernelMaterialization.Encode
  alias Arbor.Commands.SourceCoupling

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, report, cli} ->
        emit(report, cli.json)

        if cli.mode == "check" and report["status"] != "ok" do
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
        phase: cli.phase,
        json: cli.json,
        root: cli.root,
        plan: cli.plan,
        transform_evidence: cli.transform_evidence
      ]

      opts =
        if cli.mode == "write_plan",
          do: Keyword.put(opts, :allow_write, Keyword.get(runtime_opts, :allow_write, true)),
          else: opts

      case Keyword.keys(runtime_opts) -- [:allow_write] do
        [] ->
          SourceCoupling.with_direct_runtime(fn ->
            case KernelMaterialization.run(
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
          write_plan: :boolean,
          json: :boolean,
          phase: :string,
          root: :string,
          plan: :string,
          transform_evidence: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional}}

      opts[:check] && opts[:write_plan] ->
        {:error, {:mode, :conflicting_check_and_write}}

      true ->
        mode =
          cond do
            opts[:write_plan] -> "write_plan"
            opts[:check] -> "check"
            true -> "report"
          end

        phase = opts[:phase]

        cond do
          mode != "write_plan" and phase not in ["planned", "materialized"] ->
            if is_nil(phase) do
              {:error, {:phase, :required}}
            else
              {:error, {:phase, :invalid}}
            end

          true ->
            {:ok,
             %{
               mode: mode,
               phase: phase,
               json: Keyword.get(opts, :json, false) == true,
               root: opts[:root],
               plan: opts[:plan],
               transform_evidence: opts[:transform_evidence]
             }}
        end
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
    digest = report["plan_digest"] || ""
    prefix = String.slice(digest, 0, 12)
    failures = get_in(report, ["comparison", "failure_count"]) || 0

    [
      "kernel-materialization #{report["mode"]} phase=#{report["phase"]} status=#{report["status"]} runtime=direct",
      "sources=#{counts["source_entries"]} exact_moves=#{counts["exact_moves"]} " <>
        "transform_inputs=#{counts["transform_inputs"]} collisions=#{counts["collision_destinations"]}",
      "plan=#{prefix} failure_count=#{failures}"
    ]
    |> Enum.join("\n")
  end

  defp format_error({:arguments, reason}), do: "arguments: #{reason}"
  defp format_error({:mode, reason}), do: "mode: #{reason}"
  defp format_error({:phase, reason}), do: "phase: #{reason}"
  defp format_error(other), do: "kernel-materialization failed: #{inspect(other)}"
end
