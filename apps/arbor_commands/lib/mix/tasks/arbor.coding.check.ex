defmodule Mix.Tasks.Arbor.Coding.Check do
  @shortdoc "Check coding-plan readiness or verify a retained candidate"
  @moduledoc """
  Checks whether a reviewed coding plan can start without acquiring a
  workspace or starting a coding worker, or asks a running Arbor node to verify
  a retained candidate through the product validation boundary.

      mix arbor.coding.check --plan path/to/plan.json
      mix arbor.coding.check --plan path/to/plan.json --static --json
      mix arbor.coding.check --plan path/to/plan.json --live --agent-id agent_...
      mix arbor.coding.check --verify --plan path/to/plan.json \
        --agent-id agent_... --task-id task_... --workspace-id workspace_...

  Without an explicit mode, a reachable Arbor node is preferred. If no node is
  reachable, readiness performs the non-mutating local checks instead.
  Candidate verification is always live and never falls back to readiness.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Contracts.Coding.{Plan, ReadinessReport, VerificationReport}
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @max_plan_bytes 256_000
  @max_path_bytes 4_096
  @max_id_bytes 256
  @rpc_timeout_ms 5_000
  @verification_rpc_grace_ms 10_000
  @max_verification_rpc_timeout_ms 86_410_000
  @requester_shutdown_timeout_ms 1_000
  @max_human_diagnostics 6
  @human_text_bytes 160
  @readiness_runtime_options [
    :observed_at,
    :repo_roots,
    :worktree_roots,
    :template_path,
    :template_source,
    :action_catalog
  ]

  @type runtime_opt ::
          {:readiness_checker, (term(), keyword() -> term())}
          | {:rpc_call, (node(), module(), atom(), [term()], pos_integer() -> term())}
          | {:verification_spawn_request,
             (node(), module(), atom(), [term()], [term()] -> reference())}
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
  def run(args), do: run(args, [])

  @doc false
  @spec run([String.t()], [runtime_opt()]) :: :ok | no_return()
  def run(args, runtime_opts) do
    case execute_with_cli(args, runtime_opts) do
      {:ok, report, cli} ->
        emit_report(report, cli.operation, cli.json)
        maybe_exit(report)

      {:error, error, cli} ->
        emit_error(error, cli.operation, cli.json)
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
  def exit_code("passed"), do: 0
  def exit_code("blocked"), do: 1
  def exit_code(_status), do: 1

  defp execute_with_cli(args, runtime_opts) do
    with {:ok, cli} <- parse_args(args),
         {:ok, plan_input} <- read_plan(cli.plan),
         {:ok, report} <- execute_operation(plan_input, cli, runtime_opts),
         {:ok, report} <- normalize_report(report, cli) do
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
        strict: [
          plan: :string,
          static: :boolean,
          live: :boolean,
          verify: :boolean,
          agent_id: :string,
          task_id: :string,
          workspace_id: :string,
          review_attestation_id: :string,
          json: :boolean
        ]
      )

    static = Keyword.get(opts, :static, false)
    live = Keyword.get(opts, :live, false)
    verify = Keyword.get(opts, :verify, false)

    cond do
      invalid != [] ->
        command_error("arguments", "unknown_or_invalid_option")

      positional != [] ->
        command_error("arguments", "unexpected_positional_argument")

      static and live ->
        command_error("mode", "conflicting_modes")

      verify and static ->
        command_error("mode", "verification_is_live")

      not is_binary(opts[:plan]) ->
        command_error("plan", "required")

      true ->
        mode =
          cond do
            static -> :static
            live -> :live
            true -> :auto
          end

        with {:ok, agent_id} <- validate_agent_id_option(opts[:agent_id]),
             {:ok, task_id} <- validate_id_option(opts[:task_id], "task_id"),
             {:ok, workspace_id} <-
               validate_id_option(opts[:workspace_id], "workspace_id"),
             {:ok, review_attestation_id} <-
               validate_id_option(opts[:review_attestation_id], "review_attestation_id"),
             :ok <-
               validate_operation_options(
                 verify,
                 mode,
                 agent_id,
                 task_id,
                 workspace_id,
                 review_attestation_id
               ) do
          {:ok,
           %{
             plan: opts[:plan],
             mode: mode,
             agent_id: agent_id,
             operation: if(verify, do: :verification, else: :readiness),
             task_id: task_id,
             workspace_id: workspace_id,
             review_attestation_id: review_attestation_id,
             json: Keyword.get(opts, :json, false)
           }}
        end
    end
  end

  defp cli_from_args(args) when is_list(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args, strict: [json: :boolean, verify: :boolean])

    %{
      json: Keyword.get(opts, :json, false),
      operation: if(Keyword.get(opts, :verify, false), do: :verification, else: :readiness)
    }
  end

  defp cli_from_args(_args), do: %{json: false, operation: :readiness}

  defp read_plan(path) when is_binary(path) do
    invalid_path? =
      not String.valid?(path) or byte_size(path) > @max_path_bytes or
        String.contains?(path, <<0>>) or String.trim(path) == ""

    if invalid_path? do
      command_error("plan", "invalid_path")
    else
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

  defp execute_operation(plan_input, %{operation: :readiness} = cli, runtime_opts) do
    check(plan_input, cli.mode, cli.agent_id, runtime_opts)
  end

  defp execute_operation(plan_input, %{operation: :verification} = cli, runtime_opts) do
    verify(plan_input, cli, runtime_opts)
  end

  defp check(plan_input, mode, agent_id, runtime_opts) do
    case plan_input do
      {:invalid, raw_plan} ->
        if mode == :live,
          do: check_live(raw_plan, agent_id, runtime_opts),
          else: invoke_check(raw_plan, :static, agent_id, runtime_opts)

      {:valid, plan} ->
        case mode do
          :static -> invoke_check(plan, :static, agent_id, runtime_opts)
          :live -> check_live(plan, agent_id, runtime_opts)
          :auto -> check_auto(plan, agent_id, runtime_opts)
        end
    end
  end

  defp verify({:invalid, _raw_plan}, _cli, _runtime_opts),
    do: command_error("plan", "invalid")

  defp verify({:valid, plan}, cli, runtime_opts) do
    case discover_target(runtime_opts) do
      {:ok, target} ->
        request =
          %{
            "agent_id" => cli.agent_id,
            "task_id" => cli.task_id,
            "workspace_id" => cli.workspace_id
          }
          |> maybe_put("review_attestation_id", cli.review_attestation_id)

        invoke_remote_verification(
          target,
          plan,
          request,
          verification_rpc_timeout(plan),
          runtime_opts
        )

      :unavailable ->
        command_error("verification", "target_unavailable_start_server")
    end
  end

  defp check_auto(plan, agent_id, runtime_opts) do
    case discover_target(runtime_opts) do
      {:ok, target} ->
        with :ok <- require_live_agent_id(:live, agent_id) do
          invoke_remote(target, plan, agent_id, runtime_opts)
        end

      :unavailable ->
        invoke_check(plan, :static, agent_id, runtime_opts)
    end
  end

  defp check_live(plan, agent_id, runtime_opts) do
    case discover_target(runtime_opts) do
      {:ok, target} -> invoke_remote(target, plan, agent_id, runtime_opts)
      :unavailable -> command_error("live", "target_unavailable_start_server_or_use_static")
    end
  end

  defp invoke_check(plan, mode, agent_id, runtime_opts) do
    checker =
      Keyword.get(runtime_opts, :readiness_checker, &Arbor.Orchestrator.check_coding_readiness/2)

    readiness_opts = readiness_opts(mode, agent_id, runtime_opts)

    safe_invoke(fn -> checker.(plan, readiness_opts) end, :local)
  end

  defp invoke_remote(target, plan, agent_id, runtime_opts) do
    readiness_opts = readiness_opts(:live, agent_id, runtime_opts)

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

  defp invoke_remote_verification(target, plan, request, timeout, runtime_opts) do
    rpc_call =
      case Keyword.fetch(runtime_opts, :rpc_call) do
        {:ok, callback} ->
          callback

        :error ->
          spawn_request =
            Keyword.get(
              runtime_opts,
              :verification_spawn_request,
              &:erlang.spawn_request/5
            )

          fn node, module, function, args, rpc_timeout ->
            cancellable_verification_rpc(
              node,
              module,
              function,
              args,
              rpc_timeout,
              spawn_request
            )
          end
      end

    safe_invoke(
      fn ->
        rpc_call.(
          target,
          Arbor.Orchestrator,
          :verify_coding_candidate_for_operator,
          [plan, request],
          timeout
        )
      end,
      :verification
    )
  end

  @doc false
  @spec cancellable_verification_rpc(
          node(),
          module(),
          atom(),
          [term()],
          pos_integer(),
          (node(), module(), atom(), [term()], [term()] -> reference())
        ) :: term()
  def cancellable_verification_rpc(
        target,
        Arbor.Orchestrator,
        :verify_coding_candidate_for_operator,
        [plan, request],
        timeout,
        spawn_request
      )
      when is_atom(target) and is_integer(timeout) and timeout > 0 and
             is_function(spawn_request, 5) do
    correlation_id = :crypto.strong_rand_bytes(16)
    deadline = System.monotonic_time(:millisecond) + timeout
    parent = self()

    {requester, requester_monitor} =
      spawn_monitor(fn ->
        run_verification_requester(
          parent,
          target,
          correlation_id,
          plan,
          request,
          spawn_request
        )
      end)

    await_verification_result(
      requester,
      requester_monitor,
      correlation_id,
      deadline
    )
  rescue
    _exception -> {:badrpc, :verification_spawn_failed}
  catch
    _kind, _reason -> {:badrpc, :verification_spawn_failed}
  end

  def cancellable_verification_rpc(
        _target,
        _module,
        _function,
        _args,
        _timeout,
        _spawn_request
      ),
      do: {:badrpc, :invalid_verification_rpc}

  defp run_verification_requester(
         parent,
         target,
         correlation_id,
         plan,
         request,
         spawn_request
       ) do
    parent_monitor = Process.monitor(parent)

    request_id =
      spawn_request.(
        target,
        Arbor.Orchestrator,
        :verify_coding_candidate_for_operator_rpc,
        [self(), parent, correlation_id, plan, request],
        [:monitor]
      )

    send(parent, {:arbor_operator_candidate_requester_started, correlation_id, self()})
    await_remote_request(parent, parent_monitor, request_id, correlation_id)
  rescue
    _exception ->
      send(parent, {:arbor_operator_candidate_requester_error, correlation_id, :spawn_failed})
  catch
    _kind, _reason ->
      send(parent, {:arbor_operator_candidate_requester_error, correlation_id, :spawn_failed})
  end

  defp await_remote_request(parent, parent_monitor, request_id, correlation_id) do
    receive do
      {:spawn_reply, ^request_id, :ok, remote_pid} when is_pid(remote_pid) ->
        await_remote_request(parent, parent_monitor, request_id, correlation_id)

      {:spawn_reply, ^request_id, :error, reason} ->
        send(parent, {:arbor_operator_candidate_requester_error, correlation_id, reason})

      {:DOWN, ^request_id, :process, _remote_pid, reason} ->
        send(parent, {:arbor_operator_candidate_requester_down, correlation_id, reason})

      {:cancel_operator_candidate_verification, ^correlation_id} ->
        _ = :erlang.spawn_request_abandon(request_id)
        Process.demonitor(parent_monitor, [:flush])
        :ok

      {:stop_operator_candidate_requester, ^correlation_id} ->
        _ = :erlang.spawn_request_abandon(request_id)
        Process.demonitor(parent_monitor, [:flush])
        :ok

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        _ = :erlang.spawn_request_abandon(request_id)
        :ok
    end
  end

  defp await_verification_result(requester, requester_monitor, correlation_id, deadline) do
    receive do
      {:arbor_operator_candidate_verification_rpc_result, ^correlation_id, result} ->
        stop_requester(requester, requester_monitor, correlation_id)
        result

      {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, :ok} ->
        stop_requester(requester, requester_monitor, correlation_id)
        {:badrpc, :cancelled}

      {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, _status} ->
        stop_requester(requester, requester_monitor, correlation_id)
        {:badrpc, :cancellation_unconfirmed}

      {:arbor_operator_candidate_requester_started, ^correlation_id, ^requester} ->
        await_verification_result(requester, requester_monitor, correlation_id, deadline)

      {:arbor_operator_candidate_requester_error, ^correlation_id, reason} ->
        stop_requester(requester, requester_monitor, correlation_id)
        {:badrpc, reason}

      {:arbor_operator_candidate_requester_down, ^correlation_id, reason} ->
        await_terminal_message_after_remote_down(
          requester,
          requester_monitor,
          correlation_id,
          reason
        )

      {:DOWN, ^requester_monitor, :process, ^requester, reason} ->
        await_terminal_message_after_remote_down(
          requester,
          requester_monitor,
          correlation_id,
          reason
        )
    after
      remaining_ms(deadline) ->
        cancel_and_confirm(requester, requester_monitor, correlation_id)
    end
  end

  defp cancel_and_confirm(requester, requester_monitor, correlation_id) do
    send(requester, {:cancel_operator_candidate_verification, correlation_id})
    _ = await_requester_down(requester, requester_monitor)

    deadline =
      System.monotonic_time(:millisecond) +
        Arbor.Orchestrator.operator_candidate_cancellation_grace_ms()

    await_cancellation_confirmation(correlation_id, deadline)
  end

  defp await_cancellation_confirmation(correlation_id, deadline) do
    receive do
      {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, :ok} ->
        {:badrpc, :timeout}

      {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, _status} ->
        {:badrpc, :cancellation_unconfirmed}

      {:arbor_operator_candidate_verification_rpc_result, ^correlation_id, _result} ->
        {:badrpc, :timeout}
    after
      remaining_ms(deadline) -> {:badrpc, :cancellation_unconfirmed}
    end
  end

  defp await_terminal_message_after_remote_down(
         requester,
         requester_monitor,
         correlation_id,
         reason
       ) do
    receive do
      {:arbor_operator_candidate_verification_rpc_result, ^correlation_id, result} ->
        stop_requester(requester, requester_monitor, correlation_id)
        result

      {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, :ok} ->
        stop_requester(requester, requester_monitor, correlation_id)
        {:badrpc, :cancelled}

      {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, _status} ->
        stop_requester(requester, requester_monitor, correlation_id)
        {:badrpc, :cancellation_unconfirmed}
    after
      @requester_shutdown_timeout_ms ->
        stop_requester(requester, requester_monitor, correlation_id)
        {:badrpc, reason}
    end
  end

  defp stop_requester(requester, requester_monitor, correlation_id) do
    if Process.alive?(requester) do
      send(requester, {:stop_operator_candidate_requester, correlation_id})
      _ = await_requester_down(requester, requester_monitor)
    else
      Process.demonitor(requester_monitor, [:flush])
    end

    :ok
  end

  defp await_requester_down(requester, requester_monitor) do
    receive do
      {:DOWN, ^requester_monitor, :process, ^requester, _reason} ->
        :ok
    after
      @requester_shutdown_timeout_ms ->
        Process.exit(requester, :kill)

        receive do
          {:DOWN, ^requester_monitor, :process, ^requester, _reason} -> :ok
        after
          @requester_shutdown_timeout_ms ->
            Process.demonitor(requester_monitor, [:flush])
            :unconfirmed
        end
    end
  end

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp verification_rpc_timeout(plan) do
    wall_clock_ms = get_in(plan, ["budgets", "wall_clock_ms"])

    case wall_clock_ms do
      value when is_integer(value) and value > 0 ->
        min(value + @verification_rpc_grace_ms, @max_verification_rpc_timeout_ms)

      _invalid ->
        @rpc_timeout_ms
    end
  end

  defp readiness_opts(mode, agent_id, runtime_opts) when mode in [:static, :live] do
    agent_opts = if is_binary(agent_id), do: [agent_id: agent_id], else: []

    [mode: mode] ++ agent_opts ++ Keyword.take(runtime_opts, @readiness_runtime_options)
  end

  defp validate_agent_id_option(nil), do: {:ok, nil}

  defp validate_agent_id_option(agent_id) when is_binary(agent_id) do
    if valid_agent_id?(agent_id), do: {:ok, agent_id}, else: command_error("agent_id", "invalid")
  end

  defp validate_agent_id_option(_agent_id), do: command_error("agent_id", "invalid")

  defp validate_id_option(nil, _field), do: {:ok, nil}

  defp validate_id_option(value, field) when is_binary(value) do
    if safe_id?(value), do: {:ok, value}, else: command_error(field, "invalid")
  end

  defp validate_id_option(_value, field), do: command_error(field, "invalid")

  defp validate_operation_options(
         false,
         mode,
         agent_id,
         task_id,
         workspace_id,
         review_attestation_id
       ) do
    with :ok <- require_live_agent_id(mode, agent_id),
         :ok <- reject_readiness_candidate_option(task_id, "task_id"),
         :ok <- reject_readiness_candidate_option(workspace_id, "workspace_id") do
      reject_readiness_candidate_option(
        review_attestation_id,
        "review_attestation_id"
      )
    end
  end

  defp validate_operation_options(
         true,
         _mode,
         agent_id,
         task_id,
         workspace_id,
         _review_attestation_id
       ) do
    with :ok <- require_option(agent_id, "agent_id"),
         :ok <- require_option(task_id, "task_id") do
      require_option(workspace_id, "workspace_id")
    end
  end

  defp reject_readiness_candidate_option(nil, _field), do: :ok

  defp reject_readiness_candidate_option(_value, field),
    do: command_error(field, "requires_verify")

  defp require_option(nil, field), do: command_error(field, "required")
  defp require_option(_value, _field), do: :ok

  defp require_live_agent_id(:live, nil), do: command_error("agent_id", "required")
  defp require_live_agent_id(:live, _agent_id), do: :ok
  defp require_live_agent_id(_mode, _agent_id), do: :ok

  defp valid_agent_id?(agent_id) do
    byte_size(agent_id) > 6 and String.starts_with?(agent_id, "agent_") and safe_id?(agent_id)
  end

  defp safe_id?(value) do
    byte_size(value) > 0 and byte_size(value) <= @max_id_bytes and String.valid?(value) and
      String.trim(value) == value and not String.contains?(value, <<0>>) and
      not has_control_byte?(value)
  end

  defp has_control_byte?(<<>>), do: false
  defp has_control_byte?(<<byte, _rest::binary>>) when byte <= 0x1F or byte == 0x7F, do: true
  defp has_control_byte?(<<_byte, rest::binary>>), do: has_control_byte?(rest)

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

      {:badrpc, _reason} when location in [:remote, :verification] ->
        command_error(location_field(location), "rpc_unavailable")

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
    fun.()
  rescue
    _exception -> :unavailable
  catch
    _, _reason -> :unavailable
  end

  defp safe_callback(_fun), do: :unavailable

  defp normalize_report(report, %{operation: :readiness}) do
    case ReadinessReport.normalize(report) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> command_error("readiness", "invalid_report")
    end
  end

  defp normalize_report(report, %{operation: :verification} = cli) do
    case VerificationReport.normalize(report) do
      {:ok, normalized} ->
        if verification_identity_matches?(normalized, cli),
          do: {:ok, normalized},
          else: command_error("verification", "invalid_report")

      {:error, _reason} ->
        command_error("verification", "invalid_report")
    end
  end

  defp verification_identity_matches?(report, cli) do
    case report["provenance"] do
      %{
        "task_id" => task_id,
        "workspace_id" => workspace_id,
        "principal_id" => principal_id
      } ->
        task_id == cli.task_id and workspace_id == cli.workspace_id and
          principal_id == cli.agent_id

      _ ->
        false
    end
  end

  defp emit_report(report, _operation, true), do: Mix.shell().info(encode_json(report))

  defp emit_report(report, operation, false) do
    status = report["status"]
    Mix.shell().info("#{operation_label(operation)}: #{String.upcase(status)}")

    report["diagnostics"]
    |> human_diagnostics(operation)
    |> Enum.take(@max_human_diagnostics)
    |> Enum.each(&emit_human_diagnostic/1)
  end

  defp human_diagnostics(diagnostics, :verification), do: diagnostics

  defp human_diagnostics(diagnostics, :readiness) do
    Enum.filter(diagnostics, &(&1["decision"] in ["blocked", "degraded", "unavailable"]))
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

  defp emit_error(error, _operation, true), do: Mix.shell().info(encode_json(error))

  defp emit_error(error, operation, false) do
    Mix.shell().error(
      "#{operation_label(operation)} failed: #{error["field"]} (#{error["reason"]})."
    )
  end

  defp maybe_exit(report) do
    case exit_code(report["status"]) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  defp encode_json(value), do: value |> canonical_json() |> IO.iodata_to_binary()

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Jason.encode_to_iodata!(value)

  defp canonical_json(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} ->
        [Jason.encode_to_iodata!(key), ":", canonical_json(item)]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp bounded_display(value) when is_binary(value),
    do: String.slice(value, 0, @human_text_bytes)

  defp bounded_display(_value), do: "unknown"

  defp location_field(:remote), do: "live"
  defp location_field(:verification), do: "verification"
  defp location_field(:local), do: "readiness"

  defp operation_label(:verification), do: "Coding verification"
  defp operation_label(_readiness), do: "Coding readiness"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp command_error(field, reason) do
    {:error,
     %{
       "error" => "invalid_arbor_coding_check_command",
       "field" => field,
       "reason" => reason
     }}
  end
end
