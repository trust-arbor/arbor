defmodule Mix.Tasks.Arbor.Approve do
  @shortdoc "Respond to a pending Arbor approval request from the shell"
  @moduledoc """
  Approve or reject a pending interaction (an `irq_...` request) on the
  running Arbor node.

  Interactions live in the running node's registry, so this task RPCs into it.
  Calling `Arbor.Comms.respond_to_interaction/3` via `mix run -e` instead
  starts a SEPARATE BEAM whose registry is empty, and the request is simply
  reported as not found — a silent, confusing failure this task exists to
  prevent.

  ## Usage

      mix arbor.approve --list
      mix arbor.approve irq_56c6b9f2826a0fab
      mix arbor.approve irq_56c6b9f2826a0fab --reject
      mix arbor.approve irq_56c6b9f2826a0fab --basis "confined to isolated worktree"

  ## Options

    * `--list` — show pending requests and exit
    * `--reject` — respond `:rejected` instead of `:approved`
    * `--basis` — why the decision was made; recorded in the response
      metadata so the decision stays auditable
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @rpc_timeout_ms 15_000
  @max_basis_bytes 512
  @request_id_pattern ~r/^irq_[a-f0-9]{8,64}$/

  @impl true
  def run(args) do
    case execute(args) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args, runtime_opts \\ []) when is_list(args) and is_list(runtime_opts) do
    with {:ok, cli} <- parse_args(args),
         {:ok, target} <- discover_target(runtime_opts) do
      dispatch(cli, target, runtime_opts)
    end
  end

  defp parse_args(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [list: :boolean, reject: :boolean, basis: :string]
      )

    cond do
      opts[:list] ->
        {:ok, %{action: :list}}

      positional == [] ->
        {:error, "missing request id. Try: mix arbor.approve --list"}

      not Regex.match?(@request_id_pattern, hd(positional)) ->
        {:error, "not a valid interaction id: #{inspect(hd(positional))} (expected irq_...)"}

      true ->
        {:ok,
         %{
           action: :respond,
           request_id: hd(positional),
           response: if(opts[:reject], do: :rejected, else: :approved),
           basis: bounded_basis(opts[:basis])
         }}
    end
  end

  defp bounded_basis(basis) when is_binary(basis) do
    if String.valid?(basis) and byte_size(basis) <= @max_basis_bytes,
      do: basis,
      else: String.slice(basis, 0, @max_basis_bytes)
  end

  defp bounded_basis(_basis), do: nil

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
      _ ->
        {:error,
         "no reachable Arbor node. Approvals live in the running node's registry — " <>
           "start the server (mix arbor.start) and retry."}
    end
  end

  defp dispatch(%{action: :list}, target, runtime_opts) do
    case rpc(runtime_opts, target, Arbor.Comms.InteractionRegistry, :list_pending, []) do
      pending when is_list(pending) -> {:ok, render_pending(pending)}
      other -> {:error, "could not list pending requests: #{inspect(other)}"}
    end
  end

  defp dispatch(%{action: :respond} = cli, target, runtime_opts) do
    metadata =
      %{"approver" => "mix arbor.approve"}
      |> maybe_put_basis(cli.basis)

    case rpc(runtime_opts, target, Arbor.Comms, :respond_to_interaction, [
           cli.request_id,
           cli.response,
           metadata
         ]) do
      :ok ->
        {:ok, "#{cli.response}: #{cli.request_id}"}

      {:error, reason} ->
        {:error, "#{cli.request_id} not #{cli.response}: #{inspect(reason)}"}

      other ->
        {:error, "unexpected response for #{cli.request_id}: #{inspect(other)}"}
    end
  end

  defp maybe_put_basis(metadata, basis) when is_binary(basis),
    do: Map.put(metadata, "basis", basis)

  defp maybe_put_basis(metadata, _basis), do: metadata

  defp render_pending([]), do: "no pending approval requests"

  defp render_pending(pending) do
    pending
    |> Enum.map_join("\n", fn interaction ->
      map = if is_struct(interaction), do: Map.from_struct(interaction), else: interaction

      "#{map[:request_id]}  #{map[:kind]}  #{map[:resource_uri]}\n  #{map[:description]}"
    end)
  end

  defp rpc(runtime_opts, target, module, function, args) do
    rpc_call =
      Keyword.get(runtime_opts, :rpc_call, fn node, mod, fun, a, timeout ->
        :rpc.call(node, mod, fun, a, timeout)
      end)

    case rpc_call.(target, module, function, args, @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, {:rpc_unavailable, reason}}
      result -> result
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_callback(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end
end
