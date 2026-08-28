defmodule Mix.Tasks.Arbor.Coding.Grant do
  @shortdoc "Grant caller capability URIs named by coding dispatch readiness"
  @moduledoc """
  Closes the authority-horizon grant loop operators otherwise run by hand.

  Runs coding dispatch readiness for the plan against the coordinator, grants
  the capability URIs readiness names as missing for the key-file caller
  through `Arbor.Security.grant/1`, and repeats until readiness names nothing.

      mix arbor.coding.grant --plan path/to/plan.json --agent-id agent_<coordinator>
      mix arbor.coding.grant --plan path/to/plan.json --agent-id agent_<coordinator> \
        --key-file ~/.arbor/identity.key --max-rounds 5
      mix arbor.coding.grant --plan path/to/plan.json --agent-id agent_<coordinator> \
        --dry-run

  ## Options

    * `--plan` — plan JSON path (required)
    * `--agent-id` — coordinator agent id (required)
    * `--key-file` — caller key file (default `~/.arbor/identity.key`)
    * `--max-rounds` — readiness invocations allowed (default 5, valid 1..20)
    * `--dry-run` — every round invokes readiness and emits the full list of
      caller URIs named that round (no dedupe). Dry-run never emits a grant.
      It halts converged only when a report names nothing; otherwise it ends
      unconverged at max-rounds.

  Grants use the key-file principal as grantee. Wildcard and root URIs are
  refused. A malformed or truncated readiness report fails closed: no sibling
  URI is granted. Any non-converged halt exits non-zero.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.CodingGrantCore
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @rpc_timeout_ms 60_000
  @grant_rpc_timeout_ms 15_000
  @max_plan_bytes 256_000
  @max_path_bytes 4_096
  @max_id_bytes 256
  @default_key_path "~/.arbor/identity.key"
  @default_max_rounds 5

  @type runtime_opt ::
          {:rpc_call, (node(), module(), atom(), [term()], pos_integer() -> term())}
          | {:ensure_distribution, (-> term())}
          | {:server_running?, (-> boolean())}
          | {:target_node, (-> node())}
          | {:caller_resolver, (map() -> {:ok, String.t()} | {:error, term()})}

  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(args), do: run(args, [])

  @doc false
  @spec run([String.t()], [runtime_opt()]) :: :ok | no_return()
  def run(args, runtime_opts) do
    case execute(args, runtime_opts) do
      {:ok, result} ->
        Mix.shell().info(CodingGrantCore.show(result))
        :ok

      {:error, result} when is_map(result) ->
        Mix.shell().error(CodingGrantCore.show(result))
        exit({:shutdown, 1})

      {:error, message} when is_binary(message) ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], [runtime_opt()]) :: {:ok, map()} | {:error, map() | String.t()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    with {:ok, cli} <- parse_args(args),
         {:ok, plan} <- read_plan(cli.plan),
         {:ok, caller_id} <- resolve_caller(cli, runtime_opts),
         {:ok, target} <- discover_target(runtime_opts),
         {:ok, state} <-
           CodingGrantCore.new(max_rounds: cli.max_rounds, dry_run: cli.dry_run) do
      ctx = %{
        target: target,
        caller_id: caller_id,
        agent_id: cli.agent_id,
        plan: plan,
        runtime_opts: runtime_opts
      }

      interpret(state, :readiness, ctx)
    else
      {:error, :invalid_max_rounds} ->
        {:error, halt_error(:invalid_max_rounds)}

      {:error, :invalid_options} ->
        {:error, halt_error(:invalid_options)}

      {:error, result} ->
        {:error, result}
    end
  end

  def execute(_args, _runtime_opts), do: {:error, halt_error(:invalid_options)}

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        aliases: [p: :plan],
        strict: [
          plan: :string,
          agent_id: :string,
          key_file: :string,
          max_rounds: :integer,
          dry_run: :boolean
        ]
      )

    cond do
      invalid != [] ->
        {:error, halt_error(:invalid_options)}

      positional != [] ->
        {:error, halt_error(:invalid_options)}

      not is_binary(opts[:plan]) ->
        {:error, halt_error(:invalid_options)}

      not is_binary(opts[:agent_id]) ->
        {:error, halt_error(:invalid_options)}

      not valid_agent_id?(opts[:agent_id]) ->
        {:error, halt_error(:invalid_options)}

      not valid_max_rounds_option?(Keyword.get(opts, :max_rounds, @default_max_rounds)) ->
        {:error, :invalid_max_rounds}

      true ->
        {:ok,
         %{
           plan: opts[:plan],
           agent_id: opts[:agent_id],
           key_file: Path.expand(opts[:key_file] || @default_key_path),
           max_rounds: Keyword.get(opts, :max_rounds, @default_max_rounds),
           dry_run: Keyword.get(opts, :dry_run, false)
         }}
    end
  end

  defp valid_max_rounds_option?(value), do: is_integer(value) and value in 1..20

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
      {:error, halt_error(:invalid_options)}
    else
      path
      |> Path.expand()
      |> read_plan_file()
    end
  end

  defp read_plan(_path), do: {:error, halt_error(:invalid_options)}

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
      _other -> {:error, halt_error(:invalid_options)}
    end
  end

  defp resolve_caller(cli, runtime_opts) do
    resolver = Keyword.get(runtime_opts, :caller_resolver, &key_file_caller/1)

    case safe_callback(resolver, [cli]) do
      {:ok, caller_id} when is_binary(caller_id) and caller_id != "" -> {:ok, caller_id}
      {:error, _reason} -> {:error, halt_error(:invalid_options)}
      _other -> {:error, halt_error(:invalid_options)}
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
      _other -> {:error, halt_error(:invalid_options)}
    end
  end

  defp interpret(state, :readiness, ctx) do
    case invoke_readiness(ctx) do
      {:ok, report} ->
        {state, effect} = CodingGrantCore.step(state, {:readiness, report})
        interpret(state, effect, ctx)

      {:error, result} ->
        {:error, result}
    end
  end

  defp interpret(state, {:grant, uri}, ctx) do
    result = invoke_grant(ctx, uri)
    {state, effect} = CodingGrantCore.step(state, {:grant_result, uri, result})
    interpret(state, effect, ctx)
  end

  defp interpret(state, {:emit, text}, ctx) do
    Mix.shell().info(text)
    {state, effect} = CodingGrantCore.step(state, {:grant_result, "listed", :ok})
    interpret(state, effect, ctx)
  end

  defp interpret(_state, {:halt, %{status: :converged} = result}, _ctx) do
    {:ok, result}
  end

  defp interpret(_state, {:halt, result}, _ctx) do
    {:error, result}
  end

  defp invoke_readiness(ctx) do
    case rpc(
           ctx,
           Arbor.Agent,
           :coding_dispatch_readiness,
           [ctx.caller_id, ctx.agent_id, ctx.plan, []],
           @rpc_timeout_ms
         ) do
      {:ok, report} when is_map(report) -> {:ok, report}
      {:error, _reason} -> {:error, halt_error(:malformed_report)}
      _other -> {:error, halt_error(:malformed_report)}
    end
  end

  defp invoke_grant(ctx, uri) do
    case rpc(
           ctx,
           Arbor.Security,
           :grant,
           [[principal: ctx.caller_id, resource: uri]],
           @grant_rpc_timeout_ms
         ) do
      {:ok, _capability} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      {:badrpc, reason} -> {:error, {:rpc_unavailable, reason}}
      other -> {:error, other}
    end
  end

  defp rpc(ctx, module, function, args, timeout) do
    rpc_call =
      Keyword.get(ctx.runtime_opts, :rpc_call, fn node, mod, fun, rpc_args, rpc_timeout ->
        :rpc.call(node, mod, fun, rpc_args, rpc_timeout)
      end)

    rpc_call.(ctx.target, module, function, args, timeout)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_callback(fun, args) when is_function(fun) do
    apply(fun, args)
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp halt_error(status) do
    %{status: status, rounds: 0, granted: [], failed: [], remaining: []}
  end
end
