defmodule Mix.Tasks.Arbor.Packaging.SourceCoupling do
  @shortdoc "Source-coupling census and baseline guard (SPIKE-3B)"

  @moduledoc """
  Deterministic packaging preflight: census of cross-app module references
  from Git-tracked umbrella `mix.exs` + `lib/**/*.{ex,exs}`, compared to a
  reviewed baseline.

      mix arbor.packaging.source_coupling
      mix arbor.packaging.source_coupling --check
      mix arbor.packaging.source_coupling --write-baseline
      mix arbor.packaging.source_coupling --compatibility-integrations
      mix arbor.packaging.source_coupling --json

  Without `--json`, prints a human summary only. With `--json`, prints the
  canonical JSON report. Check mode never writes the baseline. Replacement
  requires `--write-baseline`. Scanned source is never compiled or executed.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.SourceCoupling
  alias Arbor.Commands.SourceCoupling.Encode

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
      # Production Mix task never forwards synthetic injection keys.
      opts = [
        mode: cli.mode,
        json: cli.json,
        root: cli.root,
        baseline: cli.baseline,
        compatibility_integrations: cli.compatibility_integrations,
        unresolved_review: cli.unresolved_review
      ]

      # Test-only runtime hooks must use SourceCoupling.run_for_test/1 directly.
      # If runtime_opts sneak synthetic keys in, refuse them here.
      case Keyword.keys(runtime_opts) -- [:allow_write] do
        [] ->
          case SourceCoupling.run(Keyword.merge(opts, runtime_opts)) do
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
          write_baseline: :boolean,
          compatibility_integrations: :boolean,
          json: :boolean,
          root: :string,
          baseline: :string,
          unresolved_review: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional}}

      opts[:check] && opts[:write_baseline] ->
        {:error, {:mode, :conflicting_check_and_write}}

      true ->
        mode =
          cond do
            opts[:write_baseline] -> "write_baseline"
            opts[:check] -> "check"
            true -> "report"
          end

        {:ok,
         %{
           mode: mode,
           json: Keyword.get(opts, :json, false) == true,
           root: opts[:root],
           baseline: opts[:baseline],
           compatibility_integrations: Keyword.get(opts, :compatibility_integrations, false),
           unresolved_review: opts[:unresolved_review]
         }}
    end
  end

  defp emit(report, json?) when is_boolean(json?) do
    if json? or report["output"] == "json" do
      case Encode.encode_report(Map.drop(report, ["write_plan"])) do
        {:ok, bytes} -> Mix.shell().info(bytes)
        {:error, _} -> Mix.shell().info(inspect(report, pretty: true, limit: 50))
      end
    else
      Mix.shell().info(human_summary(report))
    end
  end

  defp human_summary(report) do
    u = get_in(report, ["undeclared", "occurrence_count"]) || 0
    pairs = get_in(report, ["undeclared", "app_pair_count"]) || 0
    up = get_in(report, ["summaries", "hierarchy_direction", "level_upward"]) || 0
    fate = get_in(report, ["summaries", "fate"]) || %{}

    [
      "source-coupling #{report["mode"]} status=#{report["status"]}",
      "undeclared_occurrences=#{u} app_pairs=#{pairs} level_upward=#{up}",
      "band_fate intra=#{fate["intra_band"]} down=#{fate["downward"]} up=#{fate["upward"]}"
    ]
    |> Enum.join("\n")
  end

  defp format_error({:arguments, reason}), do: "arguments: #{reason}"
  defp format_error({:mode, reason}), do: "mode: #{reason}"
  defp format_error(:missing), do: "baseline missing (run --write-baseline first)"
  defp format_error(:invalid), do: "baseline invalid JSON"
  defp format_error(other), do: "source-coupling failed: #{inspect(other)}"
end
