defmodule Mix.Tasks.Arbor.Approve do
  @shortdoc "Respond to a pending Arbor approval request from the shell"
  @moduledoc """
  Approve or reject a pending approval on the running Arbor node.

  Approvals live in the running node's registries, so this task RPCs into the
  authorized `Arbor.Agent.Orchestration` facade. The caller is resolved from a
  mode-private key file and must hold the relevant approval capability.

  ## Usage

      mix arbor.approve --list
      mix arbor.approve irq_56c6b9f2826a0fab
      mix arbor.approve irq_56c6b9f2826a0fab --reject
      mix arbor.approve irq_56c6b9f2826a0fab --basis "confined to isolated worktree"
      mix arbor.approve irq_design_abc123 --key-file ~/.arbor/identity.key

  ## Options

    * `--list` — show pending requests and exit
    * `--reject` — answer `:deny` instead of `:approve`
    * `--basis` — why the decision was made; recorded in the response
      metadata so the decision stays auditable
    * `--key-file` — caller key file (default `~/.arbor/identity.key`)
    * `--as` — optional caller claim; must match the key-file principal

  ## Decision vocabulary

  This task calls `Arbor.Agent.Orchestration.answer_approval/3` with a
  DECISION (`:approve` / `:deny`), not a response. `Arbor.Contracts.Comms.ApprovalAnswer`
  normalizes the pair — the response (`:approved` / `:rejected`) and the
  decision refinement (`:approve` / `:deny` / `:rework`) are two different
  fields, not two spellings of one value. Read that contract before changing
  what is sent here.
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig
  alias Arbor.Contracts.Comms.ApprovalAnswer

  @rpc_timeout_ms 15_000
  @max_basis_bytes 512
  @default_key_path "~/.arbor/identity.key"
  @switches [list: :boolean, reject: :boolean, basis: :string, key_file: :string, as: :string]

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
         {:ok, caller_id} <- resolve_caller(cli, runtime_opts),
         {:ok, target} <- discover_target(runtime_opts) do
      dispatch(cli, caller_id, target, runtime_opts)
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] ->
        {:error, "unknown or invalid option: #{inspect(invalid)}"}

      duplicate_options(opts) != [] ->
        {:error, "duplicate option: #{inspect(duplicate_options(opts))}"}

      opts[:list] == true and
          (positional != [] or opts[:reject] == true or not is_nil(opts[:basis])) ->
        {:error, "--list cannot be combined with a request id, --reject, or --basis"}

      opts[:list] == true ->
        {:ok, caller_options(%{action: :list}, opts)}

      positional == [] ->
        {:error, "missing request id. Try: mix arbor.approve --list"}

      length(positional) != 1 ->
        {:error, "expected exactly one approval request id"}

      true ->
        with {:ok, request_id} <- validate_request_id(hd(positional)),
             {:ok, basis} <- validate_basis(opts[:basis]) do
          {:ok,
           caller_options(
             %{
               action: :respond,
               request_id: request_id,
               decision: if(opts[:reject], do: :deny, else: :approve),
               basis: basis
             },
             opts
           )}
        end
    end
  end

  defp validate_request_id(id) do
    case ApprovalAnswer.validate_request_id(id) do
      {:ok, valid} -> {:ok, valid}
      {:error, reason} -> {:error, "not a valid approval id: #{inspect(id)} (#{reason})"}
    end
  end

  defp validate_basis(nil), do: {:ok, nil}

  defp validate_basis(basis) when is_binary(basis) do
    cond do
      byte_size(basis) > @max_basis_bytes ->
        {:error, "--basis exceeds #{@max_basis_bytes} bytes"}

      true ->
        case ApprovalAnswer.validate_note(basis) do
          {:ok, valid} -> {:ok, valid}
          {:error, reason} -> {:error, "invalid --basis: #{reason}"}
        end
    end
  end

  defp caller_options(cli, opts) do
    Map.merge(cli, %{
      caller_claim: opts[:as],
      key_file: Path.expand(opts[:key_file] || @default_key_path)
    })
  end

  defp duplicate_options(opts) do
    opts
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp resolve_caller(cli, runtime_opts) do
    resolver = Keyword.get(runtime_opts, :caller_resolver, &key_file_caller/1)

    case safe_callback(resolver, cli) do
      {:ok, caller_id} when is_binary(caller_id) and caller_id != "" -> {:ok, caller_id}
      {:error, reason} -> {:error, "could not resolve approval caller: #{inspect(reason)}"}
      _ -> {:error, "could not resolve approval caller: invalid key-file identity"}
    end
  end

  defp key_file_caller(cli) do
    with {:ok, caller_id} <- Arbor.Security.key_file_principal(cli.key_file),
         :ok <- caller_claim_matches(cli.caller_claim, caller_id) do
      {:ok, caller_id}
    end
  end

  defp caller_claim_matches(nil, _actual), do: :ok
  defp caller_claim_matches(actual, actual), do: :ok

  defp caller_claim_matches(claimed, actual),
    do: {:error, {:principal_mismatch, claimed, actual}}

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

  defp dispatch(%{action: :list}, caller_id, target, runtime_opts) do
    case rpc(runtime_opts, target, Arbor.Agent.Orchestration, :list_pending_approvals, [
           [caller_id: caller_id]
         ]) do
      {:ok, pending} when is_list(pending) -> {:ok, render_pending(pending)}
      {:error, reason} -> {:error, "could not list pending requests: #{inspect(reason)}"}
      other -> {:error, "could not list pending requests: #{inspect(other)}"}
    end
  end

  defp dispatch(%{action: :respond} = cli, caller_id, target, runtime_opts) do
    case rpc(runtime_opts, target, Arbor.Agent.Orchestration, :answer_approval, [
           cli.request_id,
           cli.decision,
           [caller_id: caller_id, note: cli.basis]
         ]) do
      :ok ->
        {:ok, "#{cli.decision}: #{cli.request_id}"}

      {:error, reason} ->
        {:error, "#{cli.request_id} not #{cli.decision}: #{inspect(reason)}"}

      other ->
        {:error, "unexpected response for #{cli.request_id}: #{inspect(other)}"}
    end
  end

  defp render_pending([]), do: "no pending approval requests"

  defp render_pending(pending) do
    pending
    |> Enum.map_join("\n", fn interaction ->
      map = if is_struct(interaction), do: Map.from_struct(interaction), else: interaction

      "#{value(map, :id) || value(map, :request_id)}  " <>
        "#{value(map, :source) || value(map, :kind)}  #{value(map, :resource_uri)}\n  " <>
        "#{value(map, :description)}"
    end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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

  defp safe_callback(fun, arg) when is_function(fun, 1) do
    fun.(arg)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end
end
