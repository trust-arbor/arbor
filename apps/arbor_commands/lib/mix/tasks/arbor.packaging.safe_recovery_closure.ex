defmodule Mix.Tasks.Arbor.Packaging.SafeRecoveryClosure do
  @shortdoc "Committed safe-recovery closure evidence check"

  @moduledoc """
  Closed CLI over E0B3 fresh-VM executable-closure evidence.

      mix arbor.packaging.safe_recovery_closure
      mix arbor.packaging.safe_recovery_closure --check
      mix arbor.packaging.safe_recovery_closure --measure
      mix arbor.packaging.safe_recovery_closure --write
      mix arbor.packaging.safe_recovery_closure --check --json

  Production report/check read only
  `apps/arbor_commands/priv/packaging/safe_recovery_closure.v1.json`.
  They never start a peer, inject a cookie, or compose a release.
  `--measure` and `--write` are manager-owned: they stage one
  trusted-build, hold `rel/arbor_trust`, probe it, and always clean
  up. Write publishes exactly the committed evidence path. This
  command is not installed in the root quality alias until a reviewed
  evidence file exists. `architecture_status=blocked` is not
  architecture readiness. A passing artifact check is not an E0B3
  result.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.SafeRecoveryClosure
  alias Arbor.Commands.SafeRecoveryClosure.Encode

  @mode_keys [:check, :measure, :write]
  @bool_keys [:check, :json, :measure, :write]

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, result, cli} ->
        case finish_report(result, cli) do
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
      {:ok, result, _cli} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  def execute(_argv, _runtime_opts), do: {:error, {:arguments, :invalid_argv}}

  @doc false
  @spec finish_report(map(), map()) :: :ok | {:error, term()}
  def finish_report(result, cli) when is_map(result) and is_map(cli) do
    with :ok <- emit(result, Map.get(cli, :json, false) == true) do
      case exit_reason(Map.get(cli, :mode, "report"), result) do
        :ok -> :ok
        reason -> exit(reason)
      end
    end
  end

  @doc false
  @spec exit_reason(String.t(), term()) :: :ok | {:shutdown, 1}
  def exit_reason("check", result) when is_map(result), do: :ok
  def exit_reason("report", result) when is_map(result), do: :ok
  def exit_reason("measure", result) when is_map(result), do: :ok
  def exit_reason("write", result) when is_map(result), do: :ok
  def exit_reason(_mode, _result), do: {:shutdown, 1}

  @doc false
  @spec render_report(map(), boolean()) :: {:ok, binary()} | {:error, term()}
  def render_report(result, json?) when is_map(result) and is_boolean(json?) do
    if json? or result["output"] == "json" do
      encode_result(result)
    else
      human_summary(result)
    end
  end

  def render_report(_result, _json?), do: {:error, :invalid_result_render}

  defp execute_with_cli(argv, runtime_opts \\ []) do
    with {:ok, cli} <- parse_args(argv),
         :ok <- admit_runtime_opts(runtime_opts) do
      opts = [json: cli.json, root: cli.root]

      case run_mode(cli.mode, opts) do
        {:ok, result} -> {:ok, result, cli}
        {:error, _} = error -> error
      end
    end
  end

  defp run_mode("report", opts), do: SafeRecoveryClosure.report(opts)
  defp run_mode("check", opts), do: SafeRecoveryClosure.check(opts)

  defp run_mode("measure", opts) do
    with {:ok, _started} <- ensure_live_runtime() do
      SafeRecoveryClosure.measure(opts)
    end
  end

  defp run_mode("write", opts) do
    with {:ok, _started} <- ensure_live_runtime() do
      SafeRecoveryClosure.write(opts)
    end
  end

  defp ensure_live_runtime do
    Application.delete_env(:arbor_shell, :apple_container_unit_journal_path)

    case Application.ensure_all_started(:arbor_shell) do
      {:ok, _apps} -> {:ok, :started}
      {:error, reason} -> {:error, {:live_runtime_start_failed, reason}}
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
            measure: :boolean,
            write: :boolean,
            json: :boolean,
            root: :string
          ]
        )

      with :ok <- reject_invalid_parse(invalid, positional),
           :ok <- reject_repeated_or_conflicting(raw_option_occurrences(argv)),
           :ok <- reject_negative_switches(opts),
           :ok <- reject_conflicting_modes(opts) do
        parsed = Map.new(opts)

        mode =
          cond do
            Map.get(parsed, :check, false) -> "check"
            Map.get(parsed, :measure, false) -> "measure"
            Map.get(parsed, :write, false) -> "write"
            true -> "report"
          end

        {:ok, %{mode: mode, json: Map.get(parsed, :json, false), root: Map.get(parsed, :root)}}
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

  defp raw_option_occurrences(["--check=" <> value | rest], acc),
    do: raw_boolean_occurrence(:check, value, rest, acc)

  defp raw_option_occurrences(["--no-check" | rest], acc),
    do: raw_option_occurrences(rest, [{:check, false} | acc])

  defp raw_option_occurrences(["--measure" | rest], acc),
    do: raw_option_occurrences(rest, [{:measure, true} | acc])

  defp raw_option_occurrences(["--measure=" <> value | rest], acc),
    do: raw_boolean_occurrence(:measure, value, rest, acc)

  defp raw_option_occurrences(["--no-measure" | rest], acc),
    do: raw_option_occurrences(rest, [{:measure, false} | acc])

  defp raw_option_occurrences(["--write" | rest], acc),
    do: raw_option_occurrences(rest, [{:write, true} | acc])

  defp raw_option_occurrences(["--write=" <> value | rest], acc),
    do: raw_boolean_occurrence(:write, value, rest, acc)

  defp raw_option_occurrences(["--no-write" | rest], acc),
    do: raw_option_occurrences(rest, [{:write, false} | acc])

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

  defp raw_boolean_occurrence(_key, _value, rest, acc), do: raw_option_occurrences(rest, acc)

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
    case Enum.find(opts, fn {key, value} -> key in @bool_keys and value != true end) do
      nil -> :ok
      {key, _value} -> {:error, {:arguments, {:invalid_boolean_switch, key}}}
    end
  end

  defp reject_conflicting_modes(opts) do
    flags = for {key, true} <- opts, key in @mode_keys, do: flag_name(key)

    if length(flags) >= 2 do
      {:error, {:arguments, {:conflicting_mode, flags}}}
    else
      :ok
    end
  end

  defp flag_name(:check), do: "--check"
  defp flag_name(:measure), do: "--measure"
  defp flag_name(:write), do: "--write"

  defp emit(result, json?) do
    case render_report(result, json?) do
      {:ok, output} ->
        Mix.shell().info(output)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp human_summary(result) do
    with {:ok, mode} <- fetch_binary(result, "mode"),
         {:ok, status} <- fetch_binary(result, "closure_status"),
         {:ok, digest} <- fetch_binary(result, "evidence_digest"),
         {:ok, evidence} <- fetch_map(result, "evidence"),
         :ok <- Encode.validate_evidence(evidence) do
      {:ok,
       "safe-recovery-closure #{mode} closure_status=#{status} " <>
         "architecture_status=#{evidence["architecture_status"]} " <>
         "findings=#{result["findings_count"]} digest=#{digest}"}
    end
  end

  defp encode_result(result) do
    with {:ok, evidence} <- fetch_map(result, "evidence"),
         :ok <- Encode.validate_evidence(evidence),
         {:ok, bytes} <- Encode.canonical_json(result) do
      {:ok, bytes}
    end
  end

  defp fetch_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_result_field, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) and not is_struct(value) -> {:ok, value}
      _ -> {:error, {:invalid_result_field, key}}
    end
  end

  defp fail(error) do
    Mix.shell().error(format_error(error))
    exit({:shutdown, 1})
  end

  defp format_error({:arguments, reason}), do: "arguments: #{inspect(reason)}"
  defp format_error(other), do: "safe-recovery-closure failed: #{inspect(other)}"
end
