defmodule Mix.Tasks.Arbor.Packaging.SafeManagementSurface do
  @shortdoc "P1A safe-management surface decision (presentation only)"

  @moduledoc """
  Closed Mix adapter over `Arbor.KernelRuntime.SafeManagementSurface.Core`.

      mix arbor.packaging.safe_management_surface --operation list --receipt path.json
      mix arbor.packaging.safe_management_surface --operation revoke --receipt path.json --json

  The task gathers a closed operation (`list`, `revoke`, `disable`,
  `rollback`, `clean`) and a size-bounded SafePath receipt JSON, then
  emits the Core decision document. Production injects absent
  authorization independently. A receipt is never bearer authority, and
  this command cannot mark authorization verified.

  Denied decisions still emit the Core document. This adapter never
  applies mutation effects and does not claim architecture readiness.
  `architecture_status=blocked` is expected.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.SafeManagementSurface

  @operations MapSet.new(["clean", "disable", "list", "revoke", "rollback"])

  @document_keys [
    "architecture_status",
    "authorization_status",
    "decision",
    "effects",
    "error",
    "operation",
    "receipt",
    "schema",
    "version"
  ]

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, document, cli} ->
        case finish_report(document, cli) do
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
      {:ok, document, _cli} -> {:ok, document}
      {:error, error} -> {:error, error}
    end
  end

  def execute(_argv, _runtime_opts), do: {:error, {:arguments, :invalid_argv}}

  @doc false
  @spec finish_report(map(), map()) :: :ok | {:error, term()}
  def finish_report(document, cli) when is_map(document) and is_map(cli) do
    with :ok <- emit(document, Map.get(cli, :json, false) == true) do
      case exit_reason(document) do
        :ok -> :ok
        reason -> exit(reason)
      end
    end
  end

  @doc false
  @spec exit_reason(term()) :: :ok | {:shutdown, 1}
  def exit_reason(document) when is_map(document), do: :ok
  def exit_reason(_document), do: {:shutdown, 1}

  @doc false
  @spec render_report(map(), boolean()) :: {:ok, binary()} | {:error, term()}
  def render_report(document, json?) when is_map(document) and is_boolean(json?) do
    if json? do
      encode_result(document)
    else
      human_summary(document)
    end
  end

  def render_report(_document, _json?), do: {:error, :invalid_result_render}

  defp execute_with_cli(argv, runtime_opts \\ []) do
    with {:ok, cli} <- parse_args(argv),
         :ok <- admit_runtime_opts(runtime_opts) do
      opts = [operation: cli.operation, receipt: cli.receipt, root: cli.root]

      case SafeManagementSurface.run(opts) do
        {:ok, document} -> {:ok, document, cli}
        {:error, _} = error -> error
      end
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
            operation: :string,
            receipt: :string,
            json: :boolean,
            root: :string
          ]
        )

      with :ok <- reject_invalid_parse(invalid, positional),
           :ok <- reject_repeated_or_conflicting(raw_option_occurrences(argv)),
           :ok <- reject_negative_switches(opts),
           :ok <- require_cli_options(opts) do
        parsed = Map.new(opts)

        {:ok,
         %{
           operation: parsed.operation,
           receipt: parsed.receipt,
           json: Map.get(parsed, :json, false),
           root: Map.get(parsed, :root)
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

  defp require_cli_options(opts) do
    parsed = Map.new(opts)

    cond do
      not Map.has_key?(parsed, :operation) ->
        {:error, {:arguments, :missing_operation}}

      not Map.has_key?(parsed, :receipt) ->
        {:error, {:arguments, :missing_receipt}}

      not MapSet.member?(@operations, parsed.operation) ->
        {:error, {:arguments, :invalid_operation}}

      not is_binary(parsed.receipt) or parsed.receipt == "" ->
        {:error, {:arguments, :invalid_receipt}}

      true ->
        :ok
    end
  end

  defp raw_option_occurrences(argv), do: raw_option_occurrences(argv, [])

  defp raw_option_occurrences([], acc), do: Enum.reverse(acc)

  defp raw_option_occurrences(["--operation", value | rest], acc),
    do: raw_option_occurrences(rest, [{:operation, value} | acc])

  defp raw_option_occurrences(["--operation=" <> value | rest], acc),
    do: raw_option_occurrences(rest, [{:operation, value} | acc])

  defp raw_option_occurrences(["--receipt", value | rest], acc),
    do: raw_option_occurrences(rest, [{:receipt, value} | acc])

  defp raw_option_occurrences(["--receipt=" <> value | rest], acc),
    do: raw_option_occurrences(rest, [{:receipt, value} | acc])

  defp raw_option_occurrences(["--json" | rest], acc),
    do: raw_option_occurrences(rest, [{:json, true} | acc])

  defp raw_option_occurrences(["--json=" <> value | rest], acc),
    do: raw_boolean_occurrence(:json, value, rest, acc)

  defp raw_option_occurrences(["--no-json" | rest], acc),
    do: raw_option_occurrences(rest, [{:json, false} | acc])

  defp raw_option_occurrences(["--root", value | rest], acc),
    do: raw_option_occurrences(rest, [{:root, value} | acc])

  defp raw_option_occurrences(["--root=" <> value | rest], acc),
    do: raw_option_occurrences(rest, [{:root, value} | acc])

  defp raw_option_occurrences([_other | rest], acc), do: raw_option_occurrences(rest, acc)

  defp raw_boolean_occurrence(key, "true", rest, acc),
    do: raw_option_occurrences(rest, [{key, true} | acc])

  defp raw_boolean_occurrence(key, "false", rest, acc),
    do: raw_option_occurrences(rest, [{key, false} | acc])

  defp raw_boolean_occurrence(_key, _value, rest, acc),
    do: raw_option_occurrences(rest, acc)

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
    case Enum.find(opts, fn {key, value} -> key == :json and value != true end) do
      nil -> :ok
      {key, _value} -> {:error, {:arguments, {:invalid_boolean_switch, key}}}
    end
  end

  defp emit(document, json?) do
    case render_report(document, json?) do
      {:ok, output} ->
        Mix.shell().info(output)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp human_summary(document) do
    with {:ok, operation} <- fetch_binary(document, "operation"),
         {:ok, authorization_status} <- fetch_binary(document, "authorization_status"),
         {:ok, decision} <- fetch_binary(document, "decision"),
         {:ok, architecture_status} <- fetch_binary(document, "architecture_status"),
         {:ok, effects} <- fetch_list(document, "effects") do
      error = format_error_field(Map.get(document, "error"))

      {:ok,
       "safe-management-surface operation=#{operation} " <>
         "authorization_status=#{authorization_status} " <>
         "decision=#{decision} error=#{error} " <>
         "architecture_status=#{architecture_status} " <>
         "effects=#{length(effects)}"}
    end
  end

  defp format_error_field(nil), do: "-"
  defp format_error_field(error) when is_binary(error), do: error
  defp format_error_field(_other), do: "-"

  defp encode_result(document) do
    with :ok <- require_document_keys(document) do
      encoded =
        @document_keys
        |> Enum.map(&{&1, Map.fetch!(document, &1)})
        |> Jason.OrderedObject.new()
        |> Jason.encode!()

      {:ok, encoded}
    end
  end

  defp require_document_keys(document) when is_map(document) and not is_struct(document) do
    if Enum.sort(Map.keys(document)) == Enum.sort(@document_keys) do
      :ok
    else
      {:error, :invalid_result_render}
    end
  end

  defp require_document_keys(_document), do: {:error, :invalid_result_render}

  defp fetch_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_result_field, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_result_field, key}}
    end
  end

  defp fail(error) do
    Mix.shell().error(format_error(error))
    exit({:shutdown, 1})
  end

  defp format_error({:arguments, reason}), do: "arguments: #{inspect(reason)}"
  defp format_error(other), do: "safe-management-surface failed: #{inspect(other)}"
end
