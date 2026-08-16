defmodule Mix.Tasks.Arbor.Packaging.SafeRecoveryProfile do
  @shortdoc "Reviewed safe-recovery profile evidence check"

  @moduledoc """
  Deterministic E0B1 safe-recovery profile evidence from the fixed reviewed
  candidate.

      mix arbor.packaging.safe_recovery_profile
      mix arbor.packaging.safe_recovery_profile --check
      mix arbor.packaging.safe_recovery_profile --json
      mix arbor.packaging.safe_recovery_profile --check --json

  Production reads only
  `apps/arbor_commands/priv/packaging/safe_recovery_profile.v1.json`.
  Report and check both emit the admitted evidence. Check succeeds after
  exact fixed-candidate admission; `architecture_status=blocked` is not a
  check failure while the reviewed blocker set remains exact. This command
  does not claim architecture readiness.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.SafeRecoveryProfile
  alias Arbor.Commands.SafeRecoveryProfile.Encode

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
      opts = [mode: cli.mode, json: cli.json, root: cli.root]

      case SafeRecoveryProfile.run(opts) do
        {:ok, result} -> {:ok, result, cli}
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
            check: :boolean,
            json: :boolean,
            root: :string
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

  defp raw_option_occurrences(argv), do: raw_option_occurrences(argv, [])

  defp raw_option_occurrences([], acc), do: Enum.reverse(acc)

  defp raw_option_occurrences(["--check" | rest], acc),
    do: raw_option_occurrences(rest, [{:check, true} | acc])

  defp raw_option_occurrences(["--check=" <> value | rest], acc),
    do: raw_boolean_occurrence(:check, value, rest, acc)

  defp raw_option_occurrences(["--no-check" | rest], acc),
    do: raw_option_occurrences(rest, [{:check, false} | acc])

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
    case Enum.find(opts, fn {key, value} -> key in [:check, :json] and value != true end) do
      nil -> :ok
      {key, _value} -> {:error, {:arguments, {:invalid_boolean_switch, key}}}
    end
  end

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
         {:ok, profile} <- fetch_map(result, "profile"),
         {:ok, digest} <- fetch_binary(result, "profile_digest"),
         :ok <- Encode.validate_profile(profile) do
      blockers = Map.fetch!(profile, "blockers")

      {:ok,
       "safe-recovery-profile #{mode} profile=#{profile["profile"]} " <>
         "evidence_status=#{profile["evidence_status"]} " <>
         "architecture_status=#{profile["architecture_status"]} " <>
         "blockers=#{length(blockers)} digest=#{digest}"}
    end
  end

  defp encode_result(result) do
    with {:ok, mode} <- fetch_binary(result, "mode"),
         {:ok, output} <- fetch_binary(result, "output"),
         {:ok, profile} <- fetch_map(result, "profile"),
         {:ok, digest} <- fetch_binary(result, "profile_digest"),
         :ok <- Encode.validate_profile(profile),
         {:ok, expected_digest} <- Encode.profile_digest(profile),
         :ok <- match_digest(digest, expected_digest),
         {:ok, profile_bytes} <- Encode.encode_profile(profile),
         {:ok, ordered_profile} <- Jason.decode(profile_bytes, objects: :ordered_objects) do
      encoded =
        [
          {"mode", mode},
          {"output", output},
          {"profile", ordered_profile},
          {"profile_digest", digest}
        ]
        |> Jason.OrderedObject.new()
        |> Jason.encode!()

      {:ok, encoded}
    end
  end

  defp match_digest(digest, digest), do: :ok
  defp match_digest(_actual, _expected), do: {:error, :digest_mismatch}

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
  defp format_error(other), do: "safe-recovery-profile failed: #{inspect(other)}"
end
