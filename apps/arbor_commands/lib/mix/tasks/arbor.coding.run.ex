defmodule Mix.Tasks.Arbor.Coding.Run do
  @shortdoc "Run a coding plan from file to terminal outcome"
  @moduledoc """
  Operator command that takes a coding plan from a file to a terminal
  outcome: stamp and validate, grant the authority horizon, check
  dispatch readiness, dispatch, follow, and answer approvals.

  Following is unconditional. `--max-wait-ms` bounds the whole command
  (grant, readiness, dispatch, polling, and RPCs). Remaining budget is
  clamped into every sleep and RPC timeout; the run exits 1 when none
  remains.

      mix arbor.coding.run path/to/plan.json --agent-id agent_<coordinator>
      mix arbor.coding.run path/to/plan.json --agent-id agent_<coordinator> \
        --key-file ~/.arbor/identity.key --approve-as-dispatcher \
        --allow-paths '^apps/arbor_commands/' --poll-ms 10000 --max-wait-ms 5400000

  ## Options

    * `--agent-id` — coordinator agent id (required)
    * `--key-file` — caller key file (default `~/.arbor/identity.key`)
    * `--approve-as-dispatcher` — auto-approve `coding_reviewed_validation`;
      auto-approve `coding_reviewed_commit` only when every changed path
      matches `--allow-paths`
    * `--allow-paths` — regex that every `git status --porcelain=v1 -z`
      path must match for a commit-gate auto-approve
    * `--poll-ms` — status poll interval (default 10000)
    * `--max-wait-ms` — wall-clock budget for the entire command

  ## Exit codes

    * `0` — `change_committed`, `pr_created`, or `no_changes`
    * `2` — `human_review_required`
    * `1` — any other terminal, blocked readiness, grant non-convergence,
      unexpected commit-gate files, deadline, or transport error

  Approvals are answered only by the key-file principal and only for the
  task this command dispatched. A commit gate is never answered unless a
  successful bounded git status was obtained and every path matched
  `--allow-paths`.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.CodingGrantCore
  alias Arbor.Commands.CodingRun.GitStatus
  alias Arbor.Commands.CodingRunCore
  alias Mix.Tasks.Arbor.Coding.Grant
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @max_plan_bytes 256_000
  @max_path_bytes 4_096
  @max_id_bytes 256
  @default_key_path "~/.arbor/identity.key"
  @default_poll_ms 10_000

  @type runtime_opt ::
          {:rpc_call, (node(), module(), atom(), [term()], pos_integer() -> term())}
          | {:ensure_distribution, (-> term())}
          | {:server_running?, (-> boolean())}
          | {:target_node, (-> node())}
          | {:caller_resolver, (map() -> {:ok, String.t()} | {:error, term()})}
          | {:now_ms, (-> integer())}
          | {:now_iso, (-> String.t() | nil)}
          | {:sleep, (non_neg_integer() -> :ok)}
          | {:git_status, (String.t() -> {:ok, binary()} | {:error, term()})}
          | {:prompt, (String.t() -> boolean())}
          | {:grant_execute,
             ([String.t()], keyword() -> {:ok, map()} | {:error, map() | String.t()})}

  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(args), do: run(args, [])

  @doc false
  @spec run([String.t()], [runtime_opt()]) :: :ok | no_return()
  def run(args, runtime_opts) do
    case execute(args, runtime_opts) do
      {:ok, result} ->
        Mix.shell().info(CodingRunCore.show(result))
        :ok

      {:error, %{exit_code: code} = result} when is_integer(code) ->
        Mix.shell().error(CodingRunCore.show(result))
        exit({:shutdown, code})

      {:error, result} when is_map(result) ->
        Mix.shell().error(CodingRunCore.show(result))
        exit({:shutdown, Map.get(result, :exit_code, 1)})

      {:error, message} when is_binary(message) ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], [runtime_opt()]) :: {:ok, map()} | {:error, map() | String.t()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    now_ms = Keyword.get(runtime_opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    started = safe_now(now_ms)

    with {:ok, cli} <- parse_args(args),
         {:ok, decoded} <- read_plan(cli.plan),
         {:ok, caller_id} <- resolve_caller(cli, runtime_opts),
         {:ok, target} <- discover_target(runtime_opts),
         {:ok, state} <-
           CodingRunCore.new(
             plan: decoded,
             agent_id: cli.agent_id,
             caller_id: caller_id,
             approve_as_dispatcher: cli.approve_as_dispatcher,
             allow_paths: cli.allow_paths,
             poll_ms: cli.poll_ms,
             max_wait_ms: cli.max_wait_ms,
             now_ms: started,
             now_iso: safe_iso(runtime_opts)
           ),
         {:ok, state} <- run_grant(state, cli, target, caller_id, runtime_opts, now_ms) do
      ctx = %{
        target: target,
        runtime_opts: runtime_opts,
        now_ms: now_ms,
        deadline_ms: state.deadline_ms
      }

      {state, effect} = CodingRunCore.step(touch(state, ctx), :start)
      interpret(state, effect, ctx)
    else
      {:error, :invalid_allow_paths} ->
        {:error, halt_error(:invalid_allow_paths, "invalid --allow-paths regex")}

      {:error, :invalid_options} ->
        {:error, halt_error(:invalid_options, "invalid options")}

      {:error, :invalid_plan} ->
        {:error, halt_error(:invalid_plan, "invalid plan")}

      {:error, :invalid_wrapper} ->
        {:error, halt_error(:invalid_wrapper, "invalid coding_change wrapper")}

      {:error, {:invalid_field, field, reason}} ->
        {:error, halt_error(:invalid_plan, "invalid plan field #{field}: #{inspect(reason)}")}

      {:error, {:missing_field, field}} ->
        {:error, halt_error(:invalid_plan, "missing plan field #{field}")}

      {:error, result} ->
        {:error, result}
    end
  end

  def execute(_args, _runtime_opts),
    do: {:error, halt_error(:invalid_options, "invalid options")}

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          agent_id: :string,
          key_file: :string,
          approve_as_dispatcher: :boolean,
          allow_paths: :string,
          poll_ms: :integer,
          max_wait_ms: :integer
        ]
      )

    plan_path =
      case positional do
        [path] -> path
        [] -> nil
        _other -> :too_many
      end

    cond do
      invalid != [] ->
        {:error, :invalid_options}

      plan_path == :too_many ->
        {:error, :invalid_options}

      not is_binary(plan_path) ->
        {:error, :invalid_options}

      not is_binary(opts[:agent_id]) ->
        {:error, :invalid_options}

      not valid_agent_id?(opts[:agent_id]) ->
        {:error, :invalid_options}

      not valid_poll_ms?(Keyword.get(opts, :poll_ms, @default_poll_ms)) ->
        {:error, :invalid_options}

      not valid_max_wait?(Keyword.get(opts, :max_wait_ms)) ->
        {:error, :invalid_options}

      true ->
        {:ok,
         %{
           plan: plan_path,
           agent_id: opts[:agent_id],
           key_file: Path.expand(opts[:key_file] || @default_key_path),
           approve_as_dispatcher: Keyword.get(opts, :approve_as_dispatcher, false),
           allow_paths: opts[:allow_paths],
           poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
           max_wait_ms: opts[:max_wait_ms]
         }}
    end
  end

  defp valid_poll_ms?(value), do: is_integer(value) and value > 0
  defp valid_max_wait?(nil), do: true
  defp valid_max_wait?(value), do: is_integer(value) and value > 0

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

  defp read_plan(path) when is_binary(path) do
    invalid_path? =
      not String.valid?(path) or byte_size(path) > @max_path_bytes or
        String.contains?(path, <<0>>) or String.trim(path) == ""

    if invalid_path? do
      {:error, :invalid_options}
    else
      path
      |> Path.expand()
      |> read_plan_file()
    end
  end

  defp read_plan(_path), do: {:error, :invalid_options}

  defp read_plan_file(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.size <= @max_plan_bytes,
         {:ok, content} <- File.read(path),
         true <- byte_size(content) <= @max_plan_bytes,
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      _other -> {:error, :invalid_options}
    end
  end

  defp resolve_caller(cli, runtime_opts) do
    resolver = Keyword.get(runtime_opts, :caller_resolver, &key_file_caller/1)

    case safe_callback(resolver, [cli]) do
      {:ok, caller_id} when is_binary(caller_id) and caller_id != "" -> {:ok, caller_id}
      {:error, _reason} -> {:error, :invalid_options}
      _other -> {:error, :invalid_options}
    end
  end

  defp key_file_caller(cli) do
    Arbor.Security.key_file_principal(cli.key_file)
  end

  defp discover_target(runtime_opts) do
    ensure_distribution =
      Keyword.get(runtime_opts, :ensure_distribution, &ArborConfig.ensure_distribution/0)

    server_running = Keyword.get(runtime_opts, :server_running?, &ArborConfig.server_running?/0)
    target_node = Keyword.get(runtime_opts, :target_node, &ArborConfig.full_node_name/0)

    with :ok <- safe_callback(ensure_distribution, []),
         true <- safe_callback(server_running, []),
         target when is_atom(target) <- safe_callback(target_node, []) do
      {:ok, target}
    else
      _other -> {:error, :invalid_options}
    end
  end

  defp run_grant(state, cli, target, caller_id, runtime_opts, now_ms) do
    grant_execute = Keyword.get(runtime_opts, :grant_execute, &Grant.execute/2)
    rpc_call = clamped_rpc(runtime_opts, state.deadline_ms, now_ms)

    grant_opts = [
      plan: state.envelope,
      rpc_call: rpc_call,
      caller_resolver: fn _cli -> {:ok, caller_id} end,
      ensure_distribution: fn -> :ok end,
      server_running?: fn -> true end,
      target_node: fn -> target end
    ]

    args = ["--plan", cli.plan, "--agent-id", cli.agent_id, "--key-file", cli.key_file]

    case safe_callback(grant_execute, [args, grant_opts]) do
      {:ok, result} ->
        Mix.shell().info(CodingGrantCore.show(result))

        {:ok,
         touch(state, %{
           now_ms: now_ms,
           deadline_ms: state.deadline_ms,
           runtime_opts: runtime_opts
         })}

      {:error, result} when is_map(result) ->
        Mix.shell().error(CodingGrantCore.show(result))

        {:error, halt_error(:grant_unconverged, "grant loop did not converge; not dispatching")}

      _other ->
        {:error, halt_error(:grant_unconverged, "grant loop did not converge; not dispatching")}
    end
  end

  defp interpret(state, {:rpc, module, function, args, timeout}, ctx) do
    result = rpc(ctx, module, function, args, timeout)
    event = rpc_event(state.phase, module, function, result)
    {state, effect} = CodingRunCore.step(touch(state, ctx), event)
    interpret(state, effect, ctx)
  end

  defp interpret(state, {:emit, text}, ctx) do
    Mix.shell().info(text)
    {state, effect} = CodingRunCore.step(touch(state, ctx), :continue)
    interpret(state, effect, ctx)
  end

  defp interpret(state, {:prompt, text}, ctx) do
    prompt = Keyword.get(ctx.runtime_opts, :prompt, &default_prompt/1)
    yes? = safe_callback(prompt, [text]) == true
    {state, effect} = CodingRunCore.step(touch(state, ctx), {:prompt_reply, yes?})
    interpret(state, effect, ctx)
  end

  defp interpret(state, {:sleep, ms}, ctx) do
    sleeper = Keyword.get(ctx.runtime_opts, :sleep, &Process.sleep/1)
    _ = safe_callback(sleeper, [ms])
    {state, effect} = CodingRunCore.step(touch(state, ctx), :slept)
    interpret(state, effect, ctx)
  end

  defp interpret(state, {:git_status_porcelain, worktree, timeout_ms}, ctx) do
    runner = Keyword.get(ctx.runtime_opts, :git_status, &GitStatus.run/2)
    result = safe_git(runner, worktree, timeout_ms)
    {state, effect} = CodingRunCore.step(touch(state, ctx), {:git_status, result})
    interpret(state, effect, ctx)
  end

  defp interpret(_state, {:halt, 0, result}, _ctx), do: {:ok, result}

  defp interpret(_state, {:halt, _code, result}, _ctx), do: {:error, result}

  defp rpc_event(:awaiting_readiness, _mod, _fun, result), do: {:readiness, result}
  defp rpc_event(:awaiting_dispatch, _mod, _fun, result), do: {:dispatch, result}
  defp rpc_event(:awaiting_status, _mod, _fun, result), do: {:status, result}

  defp rpc_event(:awaiting_approvals, _mod, _fun, result) do
    {:approvals, project_approvals(result)}
  end

  defp rpc_event(:awaiting_answer, _mod, _fun, result), do: {:answer, result}
  defp rpc_event(:awaiting_result, _mod, _fun, result), do: {:result, result}
  defp rpc_event(_phase, _mod, _fun, result), do: {:rpc_result, result}

  # Bound before projecting: a large response must not cost more than the
  # 64 approvals the core will look at.
  defp project_approvals({:ok, list}) when is_list(list) do
    {:ok, list |> Enum.take(64) |> Enum.map(&project_approval/1)}
  end

  defp project_approvals(other), do: other

  @doc false
  def __project_approvals_for_test__(list) when is_list(list),
    do: Enum.map(list, &project_approval/1)

  defp project_approval(%{"id" => id, "action" => action} = view)
       when is_binary(id) and is_binary(action) do
    view
    |> Map.put_new("task_id", nil)
    |> Map.put_new("worktree", nil)
  end

  # Documented PendingApproval shape (Arbor.Agent.Orchestration): the task
  # identity is provenance metadata — `metadata.approval_context.provenance
  # .task_id` (mirrored at `metadata.provenance.task_id`) — and the worktree
  # is `metadata.approval_context.path`. Nothing else is consulted; an
  # approval without that provenance has no task identity and is ignored.
  defp project_approval(%{id: id} = approval) do
    metadata = Map.get(approval, :metadata) || %{}
    approval_context = documented_map(metadata, "approval_context")

    task_id =
      documented_meta(documented_map(approval_context, "provenance"), "task_id") ||
        documented_meta(documented_map(metadata, "provenance"), "task_id")

    %{
      "id" => to_string(id),
      "action" => action_name(Map.get(approval, :action)),
      "task_id" => task_id,
      "worktree" => documented_meta(approval_context, "path")
    }
  end

  defp project_approval(_approval) do
    %{"id" => "", "action" => "", "task_id" => nil, "worktree" => nil}
  end

  defp documented_meta(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> value
      _other -> nil
    end
  end

  defp documented_meta(_map, _key), do: nil

  defp documented_map(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> value
      _other -> %{}
    end
  end

  defp documented_map(_map, _key), do: %{}

  defp action_name(action) when is_atom(action), do: Atom.to_string(action)
  defp action_name(action) when is_binary(action), do: action
  defp action_name(_action), do: ""

  defp default_prompt(text) do
    Mix.shell().yes?(text)
  end

  defp rpc(ctx, module, function, args, timeout) do
    rpc_call =
      Keyword.get(ctx.runtime_opts, :rpc_call, fn node, mod, fun, rpc_args, rpc_timeout ->
        :rpc.call(node, mod, fun, rpc_args, rpc_timeout)
      end)

    timeout = clamp_ms(ctx.deadline_ms, safe_now(ctx.now_ms), timeout)

    if timeout <= 0 do
      {:error, :deadline_exceeded}
    else
      rpc_call.(ctx.target, module, function, args, timeout)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp clamped_rpc(runtime_opts, deadline_ms, now_ms) do
    rpc_call =
      Keyword.get(runtime_opts, :rpc_call, fn node, mod, fun, args, timeout ->
        :rpc.call(node, mod, fun, args, timeout)
      end)

    fn node, mod, fun, args, timeout ->
      timeout = clamp_ms(deadline_ms, safe_now(now_ms), timeout)

      if timeout <= 0 do
        {:error, :deadline_exceeded}
      else
        rpc_call.(node, mod, fun, args, timeout)
      end
    end
  end

  defp clamp_ms(nil, _now, timeout), do: timeout

  defp clamp_ms(deadline, now, timeout)
       when is_integer(deadline) and is_integer(now) and is_integer(timeout) do
    rem = deadline - now
    if rem <= 0, do: 0, else: min(timeout, rem)
  end

  defp clamp_ms(_deadline, _now, timeout), do: timeout

  defp touch(state, ctx) do
    iso =
      case Keyword.get(ctx.runtime_opts || [], :now_iso) do
        fun when is_function(fun, 0) -> safe_callback(fun, [])
        _other -> nil
      end

    iso =
      cond do
        is_binary(iso) -> iso
        is_binary(state.now_iso) -> state.now_iso
        true -> DateTime.to_iso8601(DateTime.utc_now())
      end

    %{state | now_ms: safe_now(ctx.now_ms), now_iso: iso}
  end

  defp safe_now(fun) when is_function(fun, 0) do
    case safe_callback(fun, []) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp safe_now(value) when is_integer(value) and value >= 0, do: value
  defp safe_now(_value), do: 0

  defp safe_iso(runtime_opts) do
    case Keyword.get(runtime_opts, :now_iso) do
      fun when is_function(fun, 0) ->
        value = safe_callback(fun, [])
        if is_binary(value), do: value, else: nil

      _other ->
        nil
    end
  end

  # Test seams may inject an arity-1 runner; production uses GitStatus.run/2
  # with the deadline the core clamped to the remaining command budget.
  defp safe_git(fun, worktree, timeout_ms) do
    args =
      case Function.info(fun, :arity) do
        {:arity, 1} -> [worktree]
        _ -> [worktree, [timeout_ms: timeout_ms]]
      end

    case safe_callback(fun, args) do
      {:ok, binary} when is_binary(binary) -> {:ok, binary}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :port_failed}
    end
  end

  defp safe_callback(fun, args) when is_function(fun) do
    apply(fun, args)
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp halt_error(reason, summary) do
    %{exit_code: 1, reason: reason, summary: summary, task_id: nil}
  end
end
