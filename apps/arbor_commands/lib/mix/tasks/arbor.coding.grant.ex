defmodule Mix.Tasks.Arbor.Coding.Grant do
  @shortdoc "Grant authority-horizon capability URIs named by coding dispatch readiness"
  @moduledoc """
  Closes the authority-horizon grant loop operators otherwise run by hand.

  Runs coding dispatch readiness for the plan against the coordinator, grants
  each capability URI readiness names as missing to the principal that finding
  names (key-file caller or `--agent-id` coordinator) through
  `Arbor.Security.grant/1`, and repeats until no role has missing findings or
  the configured maximum number of readiness rounds is reached.

      mix arbor.coding.grant --plan path/to/plan.json --agent-id agent_<coordinator>
      mix arbor.coding.grant --plan path/to/plan.json --agent-id agent_<coordinator> \
        --key-file ~/.arbor/identity.key --max-rounds 5
      mix arbor.coding.grant --plan path/to/plan.json --agent-id agent_<coordinator> \
        --dry-run

  After capability convergence the task also closes execution-principal coding
  trust rules for each required `arbor://action/coding/` URI that has no matching
  rule, mirroring same-parent sibling modes. `--no-trust-rules` skips that
  layer. Dry-run lists rules it would install and never calls `set_rule`.

  ## Options

    * `--plan` — plan JSON path (required)
    * `--agent-id` — coordinator agent id (required)
    * `--key-file` — caller key file (default `~/.arbor/identity.key`)
    * `--max-rounds` — readiness invocations allowed (default 5, valid 1..20)
    * `--dry-run` — every round invokes readiness and emits the full list of
      missing URIs named that round (no dedupe), grouped by principal role
      and id. Dry-run never emits a grant. It
      halts converged only when a report names nothing; otherwise it ends
      unconverged at max-rounds. After capability convergence it lists the
      execution-principal trust rules it would install and never calls
      `Arbor.Trust.set_rule/3`.
    * `--no-trust-rules` — restore capability-only behaviour; do not explain
      or install trust rules.

  Each grant uses the principal the finding names. A URI is never granted to a
  principal the readiness report did not name. Wildcard and root URIs are
  refused. A malformed or truncated readiness report fails closed: no sibling
  URI is granted. Any non-converged halt exits non-zero.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.CodingGrantCore
  alias Arbor.Commands.CodingGrantTrustCore
  alias Arbor.Contracts.Security.CapabilityUri
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
          | {:plan, map()}

  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(args), do: run(args, [])

  @doc false
  @spec run([String.t()], [runtime_opt()]) :: :ok | no_return()
  def run(args, runtime_opts) do
    case execute(args, runtime_opts) do
      {:ok, result} ->
        Mix.shell().info(CodingGrantCore.show(result))
        maybe_emit_trust(:info, result)
        :ok

      {:error, result} when is_map(result) ->
        Mix.shell().error(CodingGrantCore.show(result))
        maybe_emit_trust(:error, result)
        emit_trust_install_error(result)
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
         {:ok, plan} <- resolve_plan(cli, runtime_opts),
         {:ok, caller_id} <- resolve_caller(cli, runtime_opts),
         {:ok, target} <- discover_target(runtime_opts),
         {:ok, state} <-
           CodingGrantCore.new(max_rounds: cli.max_rounds, dry_run: cli.dry_run) do
      ctx = %{
        target: target,
        caller_id: caller_id,
        agent_id: cli.agent_id,
        plan: plan,
        runtime_opts: runtime_opts,
        trust_rules: cli.trust_rules,
        dry_run: cli.dry_run
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
          dry_run: :boolean,
          trust_rules: :boolean
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
           dry_run: Keyword.get(opts, :dry_run, false),
           trust_rules: Keyword.get(opts, :trust_rules, true)
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

  defp resolve_plan(cli, runtime_opts) do
    case Keyword.fetch(runtime_opts, :plan) do
      {:ok, plan} when is_map(plan) and not is_struct(plan) -> {:ok, plan}
      {:ok, _other} -> {:error, halt_error(:invalid_options)}
      :error -> read_plan(cli.plan)
    end
  end

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
    report =
      case invoke_readiness(ctx) do
        {:ok, report} -> report
        :error -> :unavailable
      end

    ctx = remember_report(ctx, report)
    {state, effect} = CodingGrantCore.step(state, {:readiness, report})
    interpret(state, effect, ctx)
  end

  defp interpret(state, {:grant, %{principal_id: id, uri: uri} = target}, ctx) do
    case allowed_grantee?(ctx, target) do
      {:ok, ^id} ->
        result = invoke_grant(ctx, id, uri)
        {state, effect} = CodingGrantCore.step(state, {:grant_result, target, result})
        interpret(state, effect, ctx)

      {:error, reason} ->
        {state, effect} = CodingGrantCore.step(state, {:grant_result, target, {:error, reason}})
        interpret(state, effect, ctx)
    end
  end

  defp interpret(state, {:emit, text}, ctx) do
    Mix.shell().info(text)
    # Listing ack, not a grant. :after_emit / :after_emit_halt ignore URI and result.
    {state, effect} = CodingGrantCore.step(state, {:grant_result, :emit_ack, :ok})
    interpret(state, effect, ctx)
  end

  defp interpret(_state, {:halt, %{status: :converged} = result}, ctx) do
    finish_ok(result, ctx)
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
      _other -> :error
    end
  end

  defp allowed_grantee?(ctx, %{principal_role: "authenticated_caller", principal_id: id})
       when is_binary(id) and id != "" do
    if id == ctx.caller_id, do: {:ok, id}, else: {:error, :unnamed_principal}
  end

  defp allowed_grantee?(ctx, %{principal_role: "execution_principal", principal_id: id})
       when is_binary(id) and id != "" do
    if id == ctx.agent_id, do: {:ok, id}, else: {:error, :unnamed_principal}
  end

  defp allowed_grantee?(_ctx, _target), do: {:error, :unnamed_principal}

  defp invoke_grant(ctx, principal, uri) do
    case rpc(
           ctx,
           Arbor.Security,
           :grant,
           [[principal: principal, resource: uri]],
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

  defp remember_report(ctx, report) when is_map(report), do: Map.put(ctx, :last_report, report)
  defp remember_report(ctx, _report), do: ctx

  defp finish_ok(result, ctx) do
    case close_trust_rules(result, ctx) do
      {:ok, result} -> {:ok, result}
      {:error, result} -> {:error, result}
    end
  end

  defp close_trust_rules(result, %{trust_rules: false}), do: {:ok, result}

  defp close_trust_rules(result, ctx) do
    case coding_required_uris(Map.get(ctx, :last_report)) do
      [] ->
        {:ok, result}

      uris ->
        apply_trust_decisions(result, ctx, uris)
    end
  end

  defp apply_trust_decisions(result, ctx, uris) do
    principal = ctx.agent_id
    sibling_rules = fetch_sibling_rules(ctx, principal)
    explanations = fetch_explanations(ctx, principal, uris)

    case CodingGrantTrustCore.decide(%{
           principal_id: principal,
           required_resources: uris,
           explanations: explanations,
           sibling_rules: sibling_rules,
           named_execution_principal: named_execution_principal(Map.get(ctx, :last_report)),
           dry_run: ctx.dry_run == true
         }) do
      {:ok, trust} ->
        install_trust_rules(result, ctx, trust)

      {:error, :invalid_input} ->
        {:error, Map.put(result, :trust, {:error, :invalid_input})}
    end
  end

  defp install_trust_rules(result, %{dry_run: true}, trust) do
    {:ok, Map.put(result, :trust, trust)}
  end

  defp install_trust_rules(result, ctx, trust) do
    installs = Enum.filter(trust.decisions, &(&1.action == :install))

    case install_each(ctx, installs) do
      :ok ->
        {:ok, Map.put(result, :trust, trust)}

      {:error, uri, reason} ->
        {:error, Map.merge(result, %{trust: trust, trust_install_error: {uri, reason}})}
    end
  end

  defp install_each(_ctx, []), do: :ok

  defp install_each(ctx, [decision | rest]) do
    case invoke_set_rule(ctx, ctx.agent_id, decision.uri, decision.mode) do
      :ok -> install_each(ctx, rest)
      {:error, reason} -> {:error, decision.uri, reason}
    end
  end

  defp fetch_sibling_rules(ctx, principal) do
    case rpc(ctx, Arbor.Trust, :get_trust_profile, [principal], @grant_rpc_timeout_ms) do
      {:ok, profile} when is_map(profile) ->
        Map.get(profile, :rules) || Map.get(profile, "rules") || %{}

      _other ->
        %{}
    end
  end

  defp fetch_explanations(ctx, principal, uris) do
    Map.new(uris, fn uri ->
      case rpc(ctx, Arbor.Trust, :explain, [principal, uri], @grant_rpc_timeout_ms) do
        result when is_map(result) -> {uri, result}
        _other -> {uri, %{error: :rpc}}
      end
    end)
  end

  defp invoke_set_rule(ctx, principal, uri, mode) do
    case rpc(ctx, Arbor.Trust, :set_rule, [principal, uri, mode], @grant_rpc_timeout_ms) do
      {:ok, _profile} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      {:badrpc, reason} -> {:error, {:rpc_unavailable, reason}}
      other -> {:error, other}
    end
  end

  defp coding_required_uris(report) do
    case extract_required_resources(report) do
      {:ok, uris} -> Enum.filter(uris, &coding_namespace_uri?/1)
      :error -> []
    end
  end

  defp extract_required_resources(report) when is_map(report) do
    horizon =
      get_in(report, ["planes", "executor", "details", "projection", "authority_horizon"])

    case horizon do
      %{"required_resources" => required} -> normalize_required(required)
      _other -> :error
    end
  end

  defp extract_required_resources(_report), do: :error

  defp normalize_required(required) when is_list(required) do
    if Enum.all?(required, &is_binary/1), do: {:ok, required}, else: :error
  end

  defp normalize_required(%{"resource_uris" => uris}) when is_list(uris) do
    if Enum.all?(uris, &is_binary/1), do: {:ok, uris}, else: :error
  end

  defp normalize_required(_required), do: :error

  defp coding_namespace_uri?(uri) when is_binary(uri) do
    match?({:ok, _parsed}, CapabilityUri.parse(uri)) and
      CapabilityUri.prefix_match?("arbor://action/coding", uri)
  end

  defp coding_namespace_uri?(_uri), do: false

  defp named_execution_principal(report) when is_map(report) do
    horizon =
      get_in(report, ["planes", "executor", "details", "projection", "authority_horizon"]) || %{}

    horizon
    |> Map.get("principals")
    |> execution_principal_id()
  end

  defp named_execution_principal(_report), do: nil

  defp execution_principal_id(list) when is_list(list) do
    Enum.find_value(list, &execution_principal_entry/1)
  end

  defp execution_principal_id(_list), do: nil

  defp execution_principal_entry(entry) when is_map(entry) do
    role = Map.get(entry, "principal_role") || Map.get(entry, "role")
    id = Map.get(entry, "principal_id")

    if role == "execution_principal" and is_binary(id) and id != "", do: id
  end

  defp execution_principal_entry(_entry), do: nil

  defp maybe_emit_trust(kind, result) do
    case trust_output(result) do
      nil -> :ok
      text when kind == :info -> Mix.shell().info(text)
      text -> Mix.shell().error(text)
    end
  end

  defp emit_trust_install_error(result) do
    case Map.get(result, :trust_install_error) do
      {uri, reason} ->
        Mix.shell().error("trust rule failed: #{uri} (#{inspect(reason)})")

      reason when reason != nil ->
        Mix.shell().error("trust rule failed: #{inspect(reason)}")

      nil ->
        :ok
    end
  end

  defp trust_output(result) when is_map(result) do
    case Map.get(result, :trust) do
      {:error, :invalid_input} = err ->
        CodingGrantTrustCore.show(err)

      %{decisions: decisions} = trust ->
        if Enum.any?(decisions, &(&1.action in [:install, :refuse])) do
          CodingGrantTrustCore.show(trust)
        end

      _other ->
        nil
    end
  end

  defp halt_error(status) do
    %{status: status, rounds: 0, granted: [], failed: [], remaining: []}
  end
end
