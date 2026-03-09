defmodule Arbor.Orchestrator.Engine.Placement do
  @moduledoc """
  Resolves node placement for distributed pipeline execution.

  Parses the `placement` attribute on DOT graph nodes and resolves it to a
  target BEAM node via the Cartographer Scheduler. When a node has placement
  requirements, the executor RPCs the handler execution to the resolved node.

  ## Placement Syntax

  DOT nodes can specify placement via the `placement` attribute:

      # Capability requirements (resolved via Scheduler)
      analyze [type="exec" action="shell.execute"
               placement="os=windows,has=strings,has=sigcheck"]

      # Explicit node (escape hatch)
      deploy [type="exec" placement="node:arbor_dev@10.42.42.206"]

      # Strategy only (no capability filter)
      balance [type="compute" placement="strategy:least_loaded"]

      # Combined requirements + strategy
      inference [type="compute"
                 placement="gpu=true,min_memory_gb=64,strategy:most_resources"]

  ## Requirement Keys

  - `os=windows|linux|macos` — operating system
  - `arch=x86_64|aarch64|arm64` — CPU architecture
  - `min_memory_gb=N` — minimum system RAM
  - `min_cpus=N` — minimum CPU count
  - `gpu=true` — has any GPU
  - `has=NAME` — executable available in PATH
  - `tag=NAME` — has a capability tag
  - `strategy:NAME` — scheduling strategy (first_match, least_loaded, most_resources, round_robin)
  - `node:NAME` — explicit node target (bypasses scheduler)
  """

  require Logger

  alias Arbor.Common.SafeAtom
  alias Arbor.Orchestrator.Engine.Outcome

  @type parsed :: %{
          requirements: [{atom(), term()}],
          strategy: atom(),
          node: node() | nil
        }

  @doc """
  Parse a placement string into requirements, strategy, and optional explicit node.

  Returns `nil` if placement is nil or empty.
  """
  @spec parse(String.t() | nil) :: parsed() | nil
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(placement) when is_binary(placement) do
    parts = String.split(placement, ",") |> Enum.map(&String.trim/1)

    Enum.reduce(parts, %{requirements: [], strategy: :first_match, node: nil}, fn part, acc ->
      parse_part(String.trim(part), acc)
    end)
  end

  @doc """
  Resolve placement to a target node.

  Returns `{:ok, node}` where node may be `Node.self()` (local execution),
  `{:error, reason}` if no matching node found, or `nil` if no placement.
  """
  @spec resolve(parsed() | nil) :: {:ok, node()} | {:error, term()} | nil
  def resolve(nil), do: nil

  def resolve(%{node: node}) when not is_nil(node) do
    if node in [Node.self() | Node.list()] do
      {:ok, node}
    else
      {:error, {:node_unreachable, node}}
    end
  end

  def resolve(%{requirements: requirements, strategy: strategy}) do
    if Code.ensure_loaded?(Arbor.Cartographer.Scheduler) do
      Arbor.Cartographer.Scheduler.select_node(
        requirements: requirements,
        strategy: strategy
      )
    else
      # No scheduler available — execute locally
      {:ok, Node.self()}
    end
  end

  @doc """
  Execute a handler on a remote node via RPC.

  Only works with module-based handlers (not function closures).
  Returns an Outcome struct.
  """
  @spec remote_execute(node(), module(), term(), term(), term(), keyword()) :: Outcome.t()
  def remote_execute(target_node, handler, node, context, graph, opts) do
    Logger.info("Placement: executing #{node.id} on #{target_node}")

    # Strip non-serializable opts (functions can't cross RPC boundary)
    clean_opts = strip_function_opts(opts)

    case :rpc.call(
           target_node,
           __MODULE__,
           :local_execute,
           [handler, node, context, graph, clean_opts],
           rpc_timeout(opts)
         ) do
      %Outcome{} = outcome ->
        # Tag the outcome with placement metadata
        notes = outcome.notes || ""

        suffix =
          if notes == "",
            do: "[executed on #{target_node}]",
            else: " [executed on #{target_node}]"

        %{outcome | notes: notes <> suffix}

      {:badrpc, reason} ->
        Logger.error("Placement: RPC to #{target_node} failed: #{inspect(reason)}")

        %Outcome{
          status: :fail,
          failure_reason: "placement RPC failed: #{inspect(reason)}"
        }
    end
  end

  @doc """
  Execute a handler locally. Called via RPC on the target node.
  """
  @spec local_execute(module(), term(), term(), term(), keyword()) :: Outcome.t()
  def local_execute(handler, node, context, graph, opts) do
    if function_exported?(handler, :execute, 4) do
      handler.execute(node, context, graph, opts)
    else
      %Outcome{
        status: :fail,
        failure_reason: "handler #{inspect(handler)} not available on #{Node.self()}"
      }
    end
  end

  # --- Private ---

  defp parse_part("node:" <> node_str, acc) do
    # Node names must contain "@" — validate before creating atom
    if String.contains?(node_str, "@") do
      node =
        case SafeAtom.to_existing(node_str) do
          {:ok, atom} -> atom
          {:error, _} -> String.to_atom(node_str)
        end

      %{acc | node: node}
    else
      Logger.warning("Placement: invalid node name (missing @): #{inspect(node_str)}")
      acc
    end
  end

  defp parse_part("strategy:" <> strategy_str, acc) do
    strategy =
      case strategy_str do
        "first_match" -> :first_match
        "least_loaded" -> :least_loaded
        "most_resources" -> :most_resources
        "round_robin" -> :round_robin
        other -> String.to_existing_atom(other)
      end

    %{acc | strategy: strategy}
  rescue
    ArgumentError -> acc
  end

  defp parse_part("os=" <> os, acc) do
    os_atom =
      case os do
        "windows" -> :windows
        "linux" -> :linux
        "macos" -> :macos
        other -> String.to_existing_atom(other)
      end

    %{acc | requirements: [{:os, os_atom} | acc.requirements]}
  rescue
    ArgumentError -> acc
  end

  defp parse_part("arch=" <> arch, acc) do
    arch_atom =
      case arch do
        "x86_64" -> :x86_64
        "aarch64" -> :aarch64
        "arm64" -> :arm64
        other -> String.to_existing_atom(other)
      end

    %{acc | requirements: [{:arch, arch_atom} | acc.requirements]}
  rescue
    ArgumentError -> acc
  end

  defp parse_part("min_memory_gb=" <> val, acc) do
    case Float.parse(val) do
      {n, _} -> %{acc | requirements: [{:min_memory_gb, n} | acc.requirements]}
      :error -> acc
    end
  end

  defp parse_part("min_cpus=" <> val, acc) do
    case Integer.parse(val) do
      {n, _} -> %{acc | requirements: [{:min_cpus, n} | acc.requirements]}
      :error -> acc
    end
  end

  defp parse_part("gpu=" <> val, acc) do
    gpu = val in ["true", "1", "yes"]
    %{acc | requirements: [{:gpu, gpu} | acc.requirements]}
  end

  defp parse_part("has=" <> executable, acc) do
    %{acc | requirements: [{:has_executable, executable} | acc.requirements]}
  end

  defp parse_part("tag=" <> tag, acc) do
    case SafeAtom.to_existing(tag) do
      {:ok, tag_atom} ->
        %{acc | requirements: [{:tag, tag_atom} | acc.requirements]}

      {:error, _} ->
        Logger.warning("Placement: unknown tag #{inspect(tag)}, skipping")
        acc
    end
  end

  defp parse_part(unknown, acc) do
    Logger.warning("Placement: ignoring unknown requirement: #{inspect(unknown)}")
    acc
  end

  defp strip_function_opts(opts) do
    Keyword.drop(opts, [:authorizer, :signer, :sleep_fn, :rand_fn, :event_handler])
  end

  defp rpc_timeout(opts) do
    Keyword.get(opts, :placement_timeout, 60_000)
  end
end
