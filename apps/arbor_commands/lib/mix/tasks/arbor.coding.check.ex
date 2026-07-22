defmodule Mix.Tasks.Arbor.Coding.Check do
  @shortdoc "Check coding-plan readiness"
  @moduledoc """
  Checks whether a reviewed coding plan can start without acquiring a
  workspace or starting a coding worker.

      mix arbor.coding.check --plan path/to/plan.json
      mix arbor.coding.check --plan path/to/plan.json --static --json
      mix arbor.coding.check --plan path/to/plan.json --live

  Without an explicit mode, a reachable Arbor node is preferred. If no node is
  reachable, the task performs the non-mutating local checks instead.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Contracts.Coding.{Plan, ReadinessReport}
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @max_plan_bytes 256_000
  @max_path_bytes 4_096
  @rpc_timeout_ms 5_000
  @max_human_diagnostics 6
  @human_text_bytes 160

  @type runtime_opt ::
          {:readiness_checker, (term(), keyword() -> term())}
          | {:rpc_call, (node(), module(), atom(), [term()], pos_integer() -> term())}
          | {:ensure_distribution, (-> term())}
          | {:server_running?, (-> boolean())}
          | {:target_node, (-> node())}
          | {:observed_at, String.t()}
          | {:repo_roots, [String.t()]}
          | {:worktree_roots, [String.t()]}
          | {:template_path, String.t()}
          | {:template_source, String.t()}
          | {:action_catalog, map()}

  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    case execute_with_cli(args, []) do
      {:ok, report, cli} ->
        emit_report(report, cli.json)
        maybe_exit(report, cli.json)

      {:error, error, cli} ->
        emit_error(error, cli.json)
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], [runtime_opt()]) :: {:ok, map()} | {:error, map()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    case execute_with_cli(args, runtime_opts) do
      {:ok, report, _cli} -> {:ok, report}
      {:error, error, _cli} -> {:error, error}
    end
  end

  def execute(_args, _runtime_opts), do: command_error("arguments", "expected_lists")

  @doc false
  @spec exit_code(String.t()) :: 0 | 1
  def exit_code(status) when status in ["ready", "degraded"], do: 0
  def exit_code("blocked"), do: 1
  def exit_code(_status), do: 1

  defp execute_with_cli(args, runtime_opts) do
    with {:ok, cli} <- parse_args(args),
         {:ok, plan_input} <- read_plan(cli.plan),
         {:ok, report} <- check(plan_input, cli.mode, runtime_opts),
         {:ok, report} <- normalize_report(report) do
      {:ok, report, cli}
    else
      {:error, error} ->
        cli = cli_from_args(args)
        {:error, error, cli}
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        aliases: [p: :plan, s: :static, l: :live],
        strict: [plan: :string, static: :boolean, live: :boolean, json: :boolean]
      )

    static = Keyword.get(opts, :static, false)
    live = Keyword.get(opts, :live, false)

    cond do
      invalid != [] ->
        command_error("arguments", "unknown_or_invalid_option")

      positional != [] ->
        command_error("arguments", "unexpected_positional_argument")

      static and live ->
        command_error("mode", "conflicting_modes")

      not is_binary(opts[:plan]) ->
        command_error("plan", "required")

      true ->
        {:ok,
         %{
           plan: opts[:plan],
           mode:
             cond do
               static -> :static
               live -> :live
               true -> :auto
             end,
           json: Keyword.get(opts, :json, false)
         }}
    end
  end

  defp cli_from_args(args) when is_list(args) do
    {opts, _positional, _invalid} = OptionParser.parse(args, strict: [json: :boolean])
    %{json: Keyword.get(opts, :json, false)}
  end

  defp cli_from_args(_args), do: %{json: false}

  defp read_plan(path) when is_binary(path) do
    cond do
      not String.valid?(path) or byte_size(path) > @max_path_bytes or
        String.contains?(path, <<0>>) or String.trim(path) == "" ->
        command_error("plan", "invalid_path")

      true ->
        path
        |> Path.expand()
        |> read_plan_file()
    end
  end

  defp read_plan(_path), do: command_error("plan", "invalid_path")

  defp read_plan_file(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.size <= @max_plan_bytes,
         {:ok, content} <- File.read(path),
         true <- byte_size(content) <= @max_plan_bytes,
         {:ok, decoded} <- Jason.decode(content) do
      decode_plan(decoded)
    else
      {:error, :enoent} -> command_error("plan", "not_found")
      {:error, :enotdir} -> command_error("plan", "not_found")
      {:error, %Jason.DecodeError{}} -> command_error("plan", "invalid_json")
      {:error, _reason} -> command_error("plan", "unreadable")
      false -> command_error("plan", "too_large_or_not_regular")
      _other -> command_error("plan", "invalid_json")
    end
  end

  defp decode_plan(decoded) when is_map(decoded) do
    case Plan.new(decoded) do
      {:ok, plan} -> {:ok, {:valid, Plan.to_map(plan)}}
      {:error, _reason} -> {:ok, {:invalid, decoded}}
    end
  rescue
    _exception -> {:ok, {:invalid, decoded}}
  catch
    _, _reason -> {:ok, {:invalid, decoded}}
  end

  defp decode_plan(_decoded), do: command_error("plan", "expected_object")

  defp check(plan_input, mode, runtime_opts) do
    case plan_input do
      {:invalid, raw_plan} ->
        if mode == :live,
          do: check_live(raw_plan, runtime_opts),
          else: invoke_check(raw_plan, :static, runtime_opts)

      {:valid, plan} ->
        case mode do
          :static -> invoke_check(plan, :static, runtime_opts)
          :live -> check_live(plan, runtime_opts)
          :auto -> check_auto(plan, runtime_opts)
        end
    end
  end

  defp check_auto(plan, runtime_opts) do
    case discover_target(runtime_opts) do
      {:ok, target} -> invoke_remote(target, plan, runtime_opts)
      :unavailable -> invoke_check(plan, :static, runtime_opts)
    end
  end

  defp check_live(plan, runtime_opts) do
    case discover_target(runtime_opts) do
      {:ok, target} -> invoke_remote(target, plan, runtime_opts)
      :unavailable -> command_error("live", "target_unavailable_start_server_or_use_static")
    end
  end

  defp invoke_check(plan, _mode, runtime_opts) do
    checker =
      Keyword.get(runtime_opts, :readiness_checker, &Arbor.Orchestrator.check_coding_readiness/2)

    readiness_opts =
      runtime_opts
      |> Keyword.take([
        :observed_at,
        :repo_roots,
        :worktree_roots,
        :template_path,
        :template_source,
        :action_catalog
      ])

    safe_invoke(fn -> checker.(plan, readiness_opts) end, :local)
  end

  defp invoke_remote(target, plan, runtime_opts) do
    readiness_opts =
      runtime_opts
      |> Keyword.take([
        :observed_at,
        :repo_roots,
        :worktree_roots,
        :template_path,
        :template_source,
        :action_catalog
      ])

    rpc_call =
      Keyword.get(runtime_opts, :rpc_call, fn node, module, function, args, timeout ->
        :rpc.call(node, module, function, args, timeout)
      end)

    safe_invoke(
      fn ->
        rpc_call.(
          target,
          Arbor.Orchestrator,
          :check_coding_readiness,
          [plan, readiness_opts],
          @rpc_timeout_ms
        )
      end,
      :remote
    )
  end

  defp discover_target(runtime_opts) do
    ensure_distribution =
      Keyword.get(runtime_opts, :ensure_distribution, &ArborConfig.ensure_distribution/0)

    server_running = Keyword.get(runtime_opts, :server_running?, &ArborConfig.server_running?/0)
    target_node = Keyword.get(runtime_opts, :target_node, &ArborConfig.full_node_name/0)

    with :ok <- safe_callback(ensure_distribution),
         true <- safe_callback(server_running),
         target when is_atom(target) <- safe_callback(target_node) do
      {:ok, target}
    else
      _other -> :unavailable
    end
  end

  defp safe_invoke(fun, location) do
    case fun.() do
      {:ok, report} ->
        {:ok, report}

      {:badrpc, _reason} when location == :remote ->
        command_error("live", "rpc_unavailable")

      {:error, _reason} ->
        command_error(location_field(location), "check_failed")

      _other ->
        command_error(location_field(location), "invalid_check_response")
    end
  rescue
    _exception -> command_error(location_field(location), "check_failed")
  catch
    :exit, _reason -> command_error(location_field(location), "check_failed")
    _, _reason -> command_error(location_field(location), "check_failed")
  end

  defp safe_callback(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      _exception -> :unavailable
    catch
      _, _reason -> :unavailable
    end
  end

  defp safe_callback(_fun), do: :unavailable

  defp normalize_report(report) do
    case ReadinessReport.normalize(report) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> command_error("readiness", "invalid_report")
    end
  end

  defp emit_report(report, true), do: Mix.shell().info(encode_json(report))

  defp emit_report(report, false) do
    status = report["status"]
    Mix.shell().info("Coding readiness: #{String.upcase(status)}")

    report["diagnostics"]
    |> Enum.filter(&(&1["decision"] in ["blocked", "degraded", "unavailable"]))
    |> Enum.take(@max_human_diagnostics)
    |> Enum.each(&emit_human_diagnostic/1)
  end

  defp emit_human_diagnostic(diagnostic) do
    code = bounded_display(diagnostic["code"])
    gate = bounded_display(diagnostic["gate_id"])
    Mix.shell().info("  #{gate}: #{code}")

    case diagnostic["remediation"] do
      remediation when is_binary(remediation) and remediation != "" ->
        Mix.shell().info("    remedy: #{bounded_display(remediation)}")

      _other ->
        :ok
    end
  end

  defp emit_error(error, true), do: Mix.shell().info(encode_json(error))

  defp emit_error(error, false) do
    Mix.shell().error("Coding readiness check failed: #{error["field"]} (#{error["reason"]}).")
  end

  defp maybe_exit(report, _json) do
    case exit_code(report["status"]) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  defp encode_json(value), do: Jason.encode!(value)

  defp bounded_display(value) when is_binary(value),
    do: String.slice(value, 0, @human_text_bytes)

  defp bounded_display(_value), do: "unknown"

  defp location_field(:remote), do: "live"
  defp location_field(:local), do: "readiness"

  defp command_error(field, reason) do
    {:error,
     %{
       "error" => "invalid_arbor_coding_check_command",
       "field" => field,
       "reason" => reason
     }}
  end
end
