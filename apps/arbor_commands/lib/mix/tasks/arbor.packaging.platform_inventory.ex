defmodule Mix.Tasks.Arbor.Packaging.PlatformInventory do
  @shortdoc "Platform source inventory and reviewed-classification guard"

  @moduledoc """
  Deterministic Platform (E0A) source inventory from exact stage-0 Git blobs.

      mix arbor.packaging.platform_inventory
      mix arbor.packaging.platform_inventory --check
      mix arbor.packaging.platform_inventory --json
      mix arbor.packaging.platform_inventory --review path/to/review.json

  Report mode emits `unreviewed` or `mismatch` without failing. Check mode exits
  nonzero unless the reviewed classification status is exactly `match`.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.PlatformInventory
  alias Arbor.Commands.PlatformInventory.Encode
  alias Arbor.Commands.SourceCoupling

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, report, cli} ->
        case finish_report(report, cli) do
          :ok -> :ok
          {:error, error} -> fail(error)
        end

      {:error, error} ->
        fail(error)
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(argv, runtime_opts \\ [])

  def execute(argv, runtime_opts) when is_list(argv) and is_list(runtime_opts) do
    case execute_with_cli(argv, runtime_opts) do
      {:ok, report, _cli} -> {:ok, report}
      {:error, error} -> {:error, error}
    end
  end

  def execute(_argv, _runtime_opts), do: {:error, {:arguments, :invalid_argv}}

  @doc false
  @spec finish_report(map(), map()) :: :ok | {:error, term()}
  def finish_report(report, cli) when is_map(report) and is_map(cli) do
    with :ok <- emit(report, Map.get(cli, :json, false) == true) do
      case exit_reason(Map.get(cli, :mode, "report"), report["status"]) do
        :ok -> :ok
        reason -> exit(reason)
      end
    end
  end

  @doc false
  @spec exit_reason(String.t(), term()) :: :ok | {:shutdown, 1}
  def exit_reason("check", "match"), do: :ok
  def exit_reason("check", _status), do: {:shutdown, 1}
  def exit_reason(_mode, _status), do: :ok

  @doc false
  @spec render_report(map(), boolean()) :: {:ok, binary()} | {:error, term()}
  def render_report(report, json?) when is_map(report) and is_boolean(json?) do
    if json? or report["output"] == "json" do
      Encode.encode_report(report)
    else
      {:ok, human_summary(report)}
    end
  end

  def render_report(_report, _json?), do: {:error, :invalid_report_render}

  defp execute_with_cli(argv, runtime_opts \\ []) do
    with {:ok, cli} <- parse_args(argv),
         :ok <- admit_runtime_opts(runtime_opts) do
      opts = [mode: cli.mode, json: cli.json, root: cli.root, review: cli.review]

      SourceCoupling.with_direct_runtime(fn ->
        case PlatformInventory.run(opts) do
          {:ok, report} -> {:ok, report, cli}
          {:error, _} = error -> error
        end
      end)
    end
  end

  defp admit_runtime_opts([]), do: :ok

  defp admit_runtime_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:error, {:production_task_forbids_runtime_hooks, Keyword.keys(opts)}}
    else
      {:error, :invalid_runtime_opts}
    end
  end

  defp admit_runtime_opts(_opts), do: {:error, :invalid_runtime_opts}

  defp parse_args(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) do
      {opts, positional, invalid} =
        OptionParser.parse(argv,
          strict: [
            check: :boolean,
            json: :boolean,
            root: :string,
            review: :string
          ]
        )

      with :ok <- reject_invalid_parse(invalid, positional),
           :ok <- reject_repeated_or_conflicting(raw_option_occurrences(argv)),
           :ok <- reject_negative_switches(opts) do
        parsed = Map.new(opts)

        {:ok,
         %{
           mode: if(Map.get(parsed, :check, false), do: "check", else: "report"),
           json: Map.get(parsed, :json, false),
           root: Map.get(parsed, :root),
           review: Map.get(parsed, :review)
         }}
      end
    else
      {:error, {:arguments, :invalid_argv}}
    end
  end

  defp parse_args(_argv), do: {:error, {:arguments, :invalid_argv}}

  defp reject_invalid_parse(invalid, _positional) when invalid != [],
    do: {:error, {:arguments, :unknown_or_invalid_option}}

  defp reject_invalid_parse([], positional) when positional != [],
    do: {:error, {:arguments, :unexpected_positional}}

  defp reject_invalid_parse([], []), do: :ok

  defp raw_option_occurrences(argv), do: raw_option_occurrences(argv, [])

  defp raw_option_occurrences([], acc), do: Enum.reverse(acc)

  defp raw_option_occurrences(["--check" | rest], acc),
    do: raw_option_occurrences(rest, [{:check, true} | acc])

  defp raw_option_occurrences(["--no-check" | rest], acc),
    do: raw_option_occurrences(rest, [{:check, false} | acc])

  defp raw_option_occurrences(["--json" | rest], acc),
    do: raw_option_occurrences(rest, [{:json, true} | acc])

  defp raw_option_occurrences(["--no-json" | rest], acc),
    do: raw_option_occurrences(rest, [{:json, false} | acc])

  defp raw_option_occurrences(["--root", value | rest], acc),
    do: raw_option_occurrences(rest, [{:root, value} | acc])

  defp raw_option_occurrences(["--review", value | rest], acc),
    do: raw_option_occurrences(rest, [{:review, value} | acc])

  defp raw_option_occurrences(["--root=" <> value | rest], acc),
    do: raw_option_occurrences(rest, [{:root, value} | acc])

  defp raw_option_occurrences(["--review=" <> value | rest], acc),
    do: raw_option_occurrences(rest, [{:review, value} | acc])

  defp raw_option_occurrences([_other | rest], acc), do: raw_option_occurrences(rest, acc)

  defp reject_repeated_or_conflicting(occurrences) do
    occurrences
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.find(fn {_key, values} -> length(values) > 1 end)
    |> case do
      nil ->
        :ok

      {key, values} ->
        reason =
          if length(Enum.uniq(values)) == 1, do: :repeated_option, else: :conflicting_option

        {:error, {:arguments, {reason, key}}}
    end
  end

  defp reject_negative_switches(opts) do
    case Enum.find(opts, fn {key, value} -> key in [:check, :json] and value != true end) do
      nil -> :ok
      {key, _value} -> {:error, {:arguments, {:invalid_boolean_switch, key}}}
    end
  end

  defp emit(report, json?) do
    case render_report(report, json?) do
      {:ok, output} ->
        Mix.shell().info(output)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp human_summary(report) do
    counts = report["counts"] || %{}
    failures = get_in(report, ["comparison", "failure_count"]) || 0

    [
      "platform-inventory #{report["mode"]} status=#{report["status"]}",
      "files=#{counts["total_files"]} reviewed=#{counts["reviewed_files"]} " <>
        "unreviewed=#{counts["unreviewed_files"]} failures=#{failures}"
    ]
    |> Enum.join("\n")
  end

  defp fail(error) do
    Mix.shell().error(format_error(error))
    exit({:shutdown, 1})
  end

  defp format_error({:arguments, reason}), do: "arguments: #{inspect(reason)}"
  defp format_error(other), do: "platform-inventory failed: #{inspect(other)}"
end
