defmodule Mix.Tasks.Arbor.Baseline.Status do
  @shortdoc "Show Linux validation-runtime and baseline status"

  @moduledoc """
  Operator diagnostic for the validation runtime: driver, host/guest
  platform, mix.lock pin vs HEAD, and whether the image is reachable by
  digest.

  When a local Arbor node is reachable (the same detection `mix arbor.rpc`
  uses), observations come from that node's `Arbor.Shell` / `Arbor.Commands.Baseline`
  facades. Otherwise the report is computed in this Mix VM and labeled
  `source=local (node not running)`.

      mix arbor.baseline.status
      mix arbor.baseline.status --json
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.Baseline
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @impl Mix.Task
  def run(args) do
    ArborConfig.load_dotenv()
    ArborConfig.install_mix_shutdown_hooks()

    case execute(args) do
      {:ok, report, json?} ->
        Mix.shell().info(render(report, json?))
        :ok

      {:error, reason} ->
        Mix.shell().error("baseline status failed: #{format_error(reason)}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map(), boolean()} | {:error, term()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    if Keyword.keyword?(runtime_opts) do
      case OptionParser.parse(args, strict: [json: :boolean]) do
        {opts, [], []} ->
          maybe_start_shell(runtime_opts)

          case Baseline.status(with_node_source(runtime_opts)) do
            {:ok, report} -> {:ok, report, opts[:json] == true}
            {:error, reason} -> {:error, reason}
          end

        {_opts, _positional, _invalid} ->
          {:error, :invalid_arguments}
      end
    else
      {:error, :invalid_runtime_opts}
    end
  end

  def execute(_args, _runtime_opts), do: {:error, :invalid_arguments}

  defp with_node_source(runtime_opts) do
    {reachability, node_observations} = resolve_node_source(runtime_opts)

    runtime_opts
    |> Keyword.put(:reachability, reachability)
    |> Keyword.put(:node_observations, node_observations)
  end

  defp resolve_node_source(runtime_opts) do
    cond do
      Keyword.has_key?(runtime_opts, :reachability) ->
        {Keyword.get(runtime_opts, :reachability), Keyword.get(runtime_opts, :node_observations)}

      skip_live_node?(runtime_opts) ->
        {:unreachable, nil}

      true ->
        probe_live_node(runtime_opts)
    end
  end

  # Injected `:shell` without node callbacks is a local unit-test fixture.
  # Production `run/1` does not pass `:shell`, so it always probes the node.
  defp skip_live_node?(opts) do
    Keyword.has_key?(opts, :shell) and
      not Keyword.has_key?(opts, :server_running?) and
      not Keyword.has_key?(opts, :rpc)
  end

  defp probe_live_node(opts) do
    ensure = Keyword.get(opts, :ensure_distribution, &ArborConfig.ensure_distribution/0)
    running? = Keyword.get(opts, :server_running?, &ArborConfig.server_running?/0)
    target = Keyword.get(opts, :target_node, &ArborConfig.full_node_name/0)
    rpc = Keyword.get(opts, :rpc, &default_rpc/4)

    case safe_call(ensure) do
      :ok ->
        if safe_call(running?) == true do
          fetch_node_observations(rpc, safe_call(target))
        else
          {:unreachable, nil}
        end

      {:error, reason} ->
        {{:error, reason}, nil}

      other ->
        {{:error, other}, nil}
    end
  end

  defp fetch_node_observations(rpc, node) do
    case safe_rpc(rpc, node, Arbor.Commands.Baseline, :node_observations, [[]]) do
      {:badrpc, reason} -> {{:error, reason}, nil}
      {:error, reason} -> {{:error, reason}, nil}
      obs when is_map(obs) -> {:reachable, obs}
      nil -> {{:error, :rpc_unavailable}, nil}
      other -> {{:error, {:invalid_node_observations, other}}, nil}
    end
  end

  defp default_rpc(node, mod, fun, args) do
    :rpc.call(node, Arbor.KernelRuntime.RemoteCall, :apply_quiet, [mod, fun, args])
  end

  defp safe_call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_call(_fun), do: {:error, :invalid_callback}

  defp safe_rpc(rpc, node, mod, fun, args) when is_function(rpc, 4) do
    rpc.(node, mod, fun, args)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_rpc(_rpc, _node, _mod, _fun, _args), do: {:error, :invalid_rpc}

  defp maybe_start_shell(runtime_opts) do
    if Keyword.has_key?(runtime_opts, :shell) do
      :ok
    else
      _ = Application.ensure_all_started(:arbor_shell)
      :ok
    end
  end

  defp render(report, true) when is_map(report), do: Jason.encode!(report)

  defp render(report, false) when is_map(report) do
    """
    validation runtime
      source=#{report["source"]}
      driver=#{report["driver"]}
      runtime_state=#{report["runtime_state"]}
      baseline_state=#{report["baseline_state"]}
      host_platform=#{report["host_platform"]}
      guest_platform=#{report["guest_platform"]}
      mix_lock_digest=#{report["mix_lock_digest"]}
      mix_lock_matches_head=#{report["mix_lock_matches_head"]}
      image_reachable=#{report["image_reachable"]}
    """
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
