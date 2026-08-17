defmodule Mix.Tasks.Arbor.Packaging.SafeRecoveryArtifact do
  @shortdoc "Committed safe-recovery artifact evidence check"

  @moduledoc """
  Closed CLI over the committed E0B2C3c1 safe-recovery artifact.

      mix arbor.packaging.safe_recovery_artifact
      mix arbor.packaging.safe_recovery_artifact --check
      mix arbor.packaging.safe_recovery_artifact --build-verify
      mix arbor.packaging.safe_recovery_artifact --write
      mix arbor.packaging.safe_recovery_artifact --check --json

  Production reads only the two committed files
  `apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json` and
  `apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json`
  (report/check), composes a fresh two-build manifest for comparison
  (build-verify), or composes and republishes exactly those two files
  (write). This task is a closed CLI over
  `Arbor.Commands.SafeRecoveryArtifact` -- it is not a second builder, takes
  no destination, executable, MFA, digest, or sandbox override, and forbids
  runtime hooks. `architecture_status=blocked` passes check only with the
  unchanged reviewed blocker set; it is not architecture readiness. E0B3
  is a separate fresh-VM closure proof and is not implemented here.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.SafeRecoveryArtifact

  @mode_keys [:check, :build_verify, :write]
  @bool_keys [:check, :json, :build_verify, :write]

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
  def exit_reason(mode, result) when is_binary(mode) and is_map(result), do: :ok
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

  defp run_mode("report", opts), do: SafeRecoveryArtifact.report(opts)
  defp run_mode("check", opts), do: SafeRecoveryArtifact.check(opts)

  defp run_mode("build_verify", opts) do
    with {:ok, _started} <- ensure_live_runtime() do
      SafeRecoveryArtifact.build_verify(opts)
    end
  end

  defp run_mode("write", opts) do
    with {:ok, _started} <- ensure_live_runtime() do
      SafeRecoveryArtifact.write(opts)
    end
  end

  # The two live modes drive the production two-build compose, which needs
  # the arbor_shell supervision tree (owned-tree registry, toolchain
  # authority). Starting it here is closed production bootstrapping, not a
  # caller-supplied hook.
  defp ensure_live_runtime do
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
            build_verify: :boolean,
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
            Map.get(parsed, :build_verify, false) -> "build_verify"
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

  defp raw_option_occurrences(["--build-verify" | rest], acc),
    do: raw_option_occurrences(rest, [{:build_verify, true} | acc])

  defp raw_option_occurrences(["--build-verify=" <> value | rest], acc),
    do: raw_boolean_occurrence(:build_verify, value, rest, acc)

  defp raw_option_occurrences(["--no-build-verify" | rest], acc),
    do: raw_option_occurrences(rest, [{:build_verify, false} | acc])

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
    case Enum.find(opts, fn {key, value} -> key in @bool_keys and value != true end) do
      nil -> :ok
      {key, _value} -> {:error, {:arguments, {:invalid_boolean_switch, key}}}
    end
  end

  # Any two or more mode selectors on one command line are a mode conflict,
  # reported with the flags in CLI order.
  defp reject_conflicting_modes(opts) do
    flags =
      for {key, true} <- opts, key in @mode_keys, do: flag_name(key)

    if length(flags) >= 2 do
      {:error, {:arguments, {:conflicting_mode, flags}}}
    else
      :ok
    end
  end

  defp flag_name(:check), do: "--check"
  defp flag_name(:build_verify), do: "--build-verify"
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
         {:ok, schema} <- fetch_binary(result, "schema"),
         {:ok, digest} <- fetch_binary(result, "manifest_digest"),
         {:ok, findings} <- fetch_count(result, "findings_count"),
         {:ok, repro} <- fetch_binary(result, "reproducibility_status"),
         {:ok, line} <- base_line(mode, schema, findings, repro, digest) do
      mode_suffix(mode, result, line)
    end
  end

  defp base_line(mode, schema, findings, repro, digest) do
    {:ok,
     "safe-recovery-artifact #{mode} schema=#{schema} " <>
       "evidence_status=conformant architecture_status=blocked " <>
       "findings=#{findings} reproducibility=#{repro} digest=#{digest}"}
  end

  defp mode_suffix("check", result, line) do
    with {:ok, inputs} <- fetch_count(result, "inputs_checked"),
         {:ok, head} <- fetch_binary(result, "head_commit"),
         {:ok, tree} <- fetch_binary(result, "head_tree") do
      {:ok, line <> " inputs=#{inputs} head=#{head} tree=#{tree}"}
    end
  end

  defp mode_suffix("build_verify", result, line) do
    with {:ok, committed} <- fetch_binary(result, "committed_manifest_digest"),
         {:ok, fresh} <- fetch_binary(result, "fresh_manifest_digest") do
      {:ok, line <> " committed_digest=#{committed} fresh_digest=#{fresh} equality=verified"}
    end
  end

  defp mode_suffix("write", result, line) do
    with {:ok, payload_sha} <- fetch_binary(result, "payload_sha256"),
         {:ok, written} <- fetch_list(result, "written_paths") do
      {:ok, line <> " wrote=#{length(written)} payload_sha256=#{payload_sha}"}
    end
  end

  defp mode_suffix(_mode, _result, line), do: {:ok, line}

  defp encode_result(result) do
    with {:ok, mode} <- fetch_binary(result, "mode"),
         {:ok, output} <- fetch_binary(result, "output"),
         {:ok, schema} <- fetch_binary(result, "schema"),
         {:ok, manifest_digest} <- fetch_binary(result, "manifest_digest"),
         {:ok, payload_sha} <- fetch_binary(result, "payload_sha256"),
         {:ok, payload_size} <- fetch_count(result, "payload_byte_size"),
         {:ok, findings} <- fetch_count(result, "findings_count"),
         {:ok, repro} <- fetch_binary(result, "reproducibility_status"),
         {:ok, extras} <- mode_json_fields(mode, result) do
      pairs =
        [
          {"mode", mode},
          {"output", output},
          {"schema", schema},
          {"manifest_digest", manifest_digest},
          {"payload_sha256", payload_sha},
          {"payload_byte_size", payload_size},
          {"findings_count", findings},
          {"reproducibility_status", repro}
        ] ++ extras

      encoded =
        pairs
        |> Jason.OrderedObject.new()
        |> Jason.encode!()

      {:ok, encoded}
    end
  end

  defp mode_json_fields("check", result) do
    with {:ok, inputs} <- fetch_count(result, "inputs_checked"),
         {:ok, head} <- fetch_binary(result, "head_commit"),
         {:ok, tree} <- fetch_binary(result, "head_tree") do
      {:ok, [{"inputs_checked", inputs}, {"head_commit", head}, {"head_tree", tree}]}
    end
  end

  defp mode_json_fields("build_verify", result) do
    with {:ok, committed} <- fetch_binary(result, "committed_manifest_digest"),
         {:ok, fresh} <- fetch_binary(result, "fresh_manifest_digest"),
         {:ok, equality} <- fetch_binary(result, "equality") do
      {:ok,
       [
         {"committed_manifest_digest", committed},
         {"fresh_manifest_digest", fresh},
         {"equality", equality}
       ]}
    end
  end

  defp mode_json_fields("write", result) do
    with {:ok, written} <- fetch_list(result, "written_paths") do
      {:ok, [{"written_paths", written}]}
    end
  end

  defp mode_json_fields(_mode, _result), do: {:ok, []}

  defp fetch_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_result_field, key}}
    end
  end

  defp fetch_count(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
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
  defp format_error(other), do: "safe-recovery-artifact failed: #{inspect(other)}"
end
