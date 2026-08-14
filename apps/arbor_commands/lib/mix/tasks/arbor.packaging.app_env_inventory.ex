defmodule Mix.Tasks.Arbor.Packaging.AppEnvInventory do
  @shortdoc "Retired app-env inventory and zero-residue check"

  @moduledoc """
  Git-index AST census of retired `:arbor_contracts`, `:arbor_common`,
  `:arbor_signals`, and `:arbor_monitor` application-env callers.

      mix arbor.packaging.app_env_inventory
      mix arbor.packaging.app_env_inventory --json
      mix arbor.packaging.app_env_inventory --check
      mix arbor.packaging.app_env_inventory --check --json

  `--check` never writes. It exits nonzero while any retired app-env caller
  or config block remains. Report mode prints the residue report and exits
  successfully. Scanned source is never compiled or executed.

  This task uses `Arbor.Shell.start_direct_runtime/1`. It does not start
  the `:arbor_shell` application.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.AppEnvInventory
  alias Arbor.Commands.AppEnvInventory.Encode
  alias Arbor.Commands.SourceCoupling

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, report, cli} ->
        finish_report(report, cli)

      {:error, error} ->
        Mix.shell().error(format_error(error))
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec finish_report(map(), map()) :: :ok
  def finish_report(report, cli) when is_map(report) and is_map(cli) do
    emit(report, Map.get(cli, :json, false) == true)

    case exit_reason(Map.get(cli, :mode, "report"), report["status"]) do
      :ok -> :ok
      reason -> exit(reason)
    end
  end

  @doc false
  @spec exit_reason(String.t(), term()) :: :ok | {:shutdown, 1}
  def exit_reason("check", "clean"), do: :ok
  def exit_reason("check", _status), do: {:shutdown, 1}
  def exit_reason(_mode, _status), do: :ok

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
      opts = [mode: cli.mode, json: cli.json, root: cli.root]

      case Keyword.keys(runtime_opts) do
        [] ->
          SourceCoupling.with_direct_runtime(fn ->
            case AppEnvInventory.run(opts) do
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
          json: :boolean,
          root: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional}}

      true ->
        mode = if opts[:check], do: "check", else: "report"

        {:ok,
         %{
           mode: mode,
           json: Keyword.get(opts, :json, false) == true,
           root: opts[:root]
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

    [
      "app-env-inventory #{report["mode"]} status=#{report["status"]}",
      "production=#{counts["production"]} test_support=#{counts["test_support"]} " <>
        "config_block=#{counts["config_block"]} untrusted=#{counts["untrusted"]} " <>
        "total=#{counts["total"]}",
      "by_class=#{inspect(counts["by_class"] || %{})} " <>
        "by_trust=#{inspect(counts["by_trust"] || %{})} " <>
        "by_owner=#{inspect(counts["by_owner"] || %{})}"
    ]
    |> Enum.join("\n")
  end

  defp format_error({:arguments, reason}), do: "arguments: #{reason}"
  defp format_error(other), do: "app-env-inventory failed: #{inspect(other)}"
end
