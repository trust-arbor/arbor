defmodule Mix.Tasks.Arbor.Coding.Reconcile do
  @shortdoc "Run an authorized coding-resource reconciliation dry-run"
  @moduledoc """
  Collects bounded coding inventories and persists a read-only reconciliation
  manifest. A reachable Arbor node is preferred; `--local` is available for a
  trusted in-process invocation.

  `--apply` is intentionally unsupported. Reconciliation apply authority waits
  for source-owned compare-and-swap identities.
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @rpc_timeout_ms 5_000
  @max_id_bytes 256

  @impl true
  def run(args) do
    case execute(args) do
      {:ok, report} ->
        emit_report(report)

      {:error, error} ->
        Mix.raise(Jason.encode!(error))
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map()} | {:error, map()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    with {:ok, cli} <- parse_args(args),
         {:ok, report} <- invoke(cli, runtime_opts) do
      {:ok, report}
    else
      {:error, error} -> {:error, error}
    end
  end

  def execute(_args, _runtime_opts), do: error("arguments", "expected_lists")

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          caller_id: :string,
          task_id: :string,
          principal_id: :string,
          max_items: :integer,
          dry_run: :boolean,
          local: :boolean,
          live: :boolean,
          apply: :boolean,
          json: :boolean
        ]
      )

    cond do
      invalid != [] ->
        error("arguments", "unknown_or_invalid_option")

      positional != [] ->
        error("arguments", "unexpected_positional_argument")

      Keyword.get(opts, :apply, false) ->
        error("mode", "apply_unsupported")

      Keyword.get(opts, :dry_run) == false ->
        error("mode", "dry_run_required")

      not is_binary(opts[:caller_id]) ->
        error("caller_id", "required")

      not valid_id?(opts[:caller_id]) ->
        error("caller_id", "invalid")

      Keyword.get(opts, :local, false) and Keyword.get(opts, :live, false) ->
        error("mode", "conflicting_modes")

      not valid_optional_id?(opts[:task_id]) ->
        error("task_id", "invalid")

      not valid_optional_id?(opts[:principal_id]) ->
        error("principal_id", "invalid")

      not valid_max_items?(Keyword.get(opts, :max_items, 64)) ->
        error("max_items", "invalid")

      true ->
        {:ok,
         %{
           caller_id: opts[:caller_id],
           task_id: opts[:task_id],
           principal_id: opts[:principal_id],
           max_items: Keyword.get(opts, :max_items, 64),
           local: Keyword.get(opts, :local, false),
           live: Keyword.get(opts, :live, false),
           json: Keyword.get(opts, :json, false)
         }}
    end
  end

  defp invoke(cli, runtime_opts) do
    opts =
      [
        caller_id: cli.caller_id,
        task_id: cli.task_id,
        principal_id: cli.principal_id,
        max_items: cli.max_items
      ]

    cond do
      cli.local ->
        invoke_local(opts, runtime_opts)

      cli.live ->
        invoke_live(opts, runtime_opts)

      true ->
        invoke_live(opts, runtime_opts)
    end
  end

  defp invoke_local(opts, runtime_opts) do
    reconciler =
      Keyword.get(runtime_opts, :reconciler, &Arbor.Orchestrator.reconcile_coding_resources/1)

    safe_invoke(fn -> reconciler.(opts) end, :local)
  end

  defp invoke_live(opts, runtime_opts) do
    case discover_target(runtime_opts) do
      {:ok, target} -> invoke_remote(target, opts, runtime_opts)
      :unavailable -> error("live", "target_unavailable")
    end
  end

  defp invoke_remote(target, opts, runtime_opts) do
    rpc_call =
      Keyword.get(runtime_opts, :rpc_call, fn node, module, function, args, timeout ->
        :rpc.call(node, module, function, args, timeout)
      end)

    safe_invoke(
      fn ->
        rpc_call.(
          target,
          Arbor.Orchestrator,
          :reconcile_coding_resources,
          [opts],
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
      _ -> :unavailable
    end
  end

  defp safe_invoke(fun, location) do
    case fun.() do
      {:ok, report} when is_map(report) -> {:ok, report}
      {:error, reason} -> error(location_field(location), error_reason(reason))
      {:badrpc, _reason} when location == :remote -> error("live", "rpc_unavailable")
      _other -> error(location_field(location), "invalid_reconciliation_response")
    end
  rescue
    _ -> error(location_field(location), "reconciliation_failed")
  catch
    :exit, _ -> error(location_field(location), "reconciliation_failed")
    _, _ -> error(location_field(location), "reconciliation_failed")
  end

  defp safe_callback(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      _ -> :unavailable
    catch
      _, _ -> :unavailable
    end
  end

  defp safe_callback(_fun), do: :unavailable

  defp emit_report(report) do
    Mix.shell().info(Jason.encode!(report))
  end

  defp error(field, reason), do: {:error, %{"field" => field, "error" => reason}}

  defp error_reason({:unauthorized, _}), do: "unauthorized"
  defp error_reason({:reconciliation_inventory_unavailable, _}), do: "inventory_unavailable"

  defp error_reason({:reconciliation_manifest_persistence_failed, _}),
    do: "manifest_persistence_failed"

  defp error_reason(_reason), do: "reconciliation_failed"

  defp location_field(:local), do: "local"
  defp location_field(:remote), do: "live"

  defp valid_optional_id?(nil), do: true
  defp valid_optional_id?(value), do: valid_id?(value)

  defp valid_id?(value) when is_binary(value) do
    byte_size(value) <= @max_id_bytes and String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, <<0>>) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value)
  end

  defp valid_id?(_value), do: false

  defp valid_max_items?(value), do: is_integer(value) and value in 1..1_000
end
