defmodule Mix.Tasks.Arbor.Acp.Probe do
  @shortdoc "Probe whether a CLI agent speaks ACP over stdio (initialize handshake)"

  @moduledoc """
  Sends an ACP `initialize` JSON-RPC handshake to a configured CLI agent and
  classifies the response. Settles empirically whether a candidate agent speaks
  ACP natively, only responds to JSON-RPC (version/param mismatch), needs auth,
  or doesn't speak ACP over the configured command (→ needs an adapter).

      mix arbor.acp.probe                 # probes grok and agy (the unverified ones)
      mix arbor.acp.probe grok            # probe one agent
      mix arbor.acp.probe grok agy --timeout 10000

  The command is read from `Arbor.AI.AcpSession.Config` (the same registry the
  council uses), so this also validates the config entries. Agents configured
  with an adapter (claude/codex/pi) are reported as adapter-handled and skipped —
  their ACP compatibility comes from the adapter, not a native stdio handshake.

  Note: agents may require prior auth (e.g. `grok login`). An auth-shaped failure
  is reported distinctly from a protocol failure.
  """

  use Mix.Task

  @default_agents ~w(grok agy)
  @default_timeout 8_000

  @impl Mix.Task
  def run(argv) do
    {opts, agents, _} = OptionParser.parse(argv, switches: [timeout: :integer])
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    agents = if agents == [], do: @default_agents, else: agents

    Mix.shell().info("ACP handshake probe — initialize, protocolVersion=1, #{timeout}ms/agent\n")
    Enum.each(agents, &probe(&1, timeout))
  end

  defp probe(agent_str, timeout) do
    Mix.shell().info("── #{agent_str} " <> String.duplicate("─", max(0, 40 - String.length(agent_str))))

    with {:ok, agent} <- to_provider_atom(agent_str),
         {:ok, conf} <- resolve(agent) do
      cond do
        adapter = get(conf, :adapter) ->
          Mix.shell().info("  adapter-handled by #{inspect(adapter)} — ACP via adapter, no raw handshake needed.\n")

        command = get(conf, :command) ->
          handshake(command, timeout)

        true ->
          Mix.shell().info("  config has neither :command nor :adapter — #{inspect(conf)}\n")
      end
    else
      {:error, :unknown_atom} ->
        Mix.shell().info("  not a known provider (atom doesn't exist) — add it to :acp_providers first.\n")

      {:error, reason} ->
        Mix.shell().info("  not configured: #{inspect(reason)}\n")
    end
  end

  defp handshake([exe | args] = command, timeout) do
    case System.find_executable(exe) do
      nil ->
        Mix.shell().info("  command #{inspect(command)} — #{exe} not found in PATH.\n")

      exe_path ->
        Mix.shell().info("  command: #{Enum.join(command, " ")}")

        port =
          Port.open({:spawn_executable, to_charlist(exe_path)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            :hide,
            args: Enum.map(args, &to_charlist/1)
          ])

        Port.command(port, Jason.encode!(initialize_msg()) <> "\n")

        deadline = System.monotonic_time(:millisecond) + timeout
        result = collect(port, deadline, "")
        classify(result)
    end
  end

  defp initialize_msg do
    %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{
        "clientInfo" => %{"name" => "arbor-acp-probe", "version" => "0.1.0"},
        "protocolVersion" => 1,
        "clientCapabilities" => %{}
      },
      "id" => 1
    }
  end

  defp collect(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port)
      {:timeout, acc}
    else
      receive do
        {^port, {:data, data}} ->
          acc = acc <> data

          case find_response(acc) do
            {:ok, resp} -> close(port) && {:response, resp, acc}
            :none -> collect(port, deadline, acc)
          end

        {^port, {:exit_status, status}} ->
          {:exit, status, acc}
      after
        remaining ->
          close(port)
          {:timeout, acc}
      end
    end
  end

  # Look for a complete newline-delimited JSON-RPC object that answers our id.
  defp find_response(acc) do
    acc
    |> String.split("\n", trim: true)
    |> Enum.find_value(:none, fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => _} = msg} when is_map_key(msg, "result") or is_map_key(msg, "error") ->
          {:ok, msg}

        _ ->
          nil
      end
    end)
  end

  defp classify({:response, %{"result" => result}, _raw}) do
    cond do
      is_map(result) and (Map.has_key?(result, "protocolVersion") or Map.has_key?(result, "agentCapabilities")) ->
        Mix.shell().info("  ✅ SPEAKS ACP — initialize result: #{inspect(result, limit: 8)}\n")

      true ->
        Mix.shell().info("  ⚠️  JSON-RPC result, but not an ACP initialize shape: #{inspect(result, limit: 8)}\n")
    end
  end

  defp classify({:response, %{"error" => error}, _raw}) do
    Mix.shell().info(
      "  ⚠️  Responds to JSON-RPC but rejected initialize (likely ACP-aware; check protocolVersion/params): #{inspect(error, limit: 8)}\n"
    )
  end

  defp classify({:exit, status, acc}) do
    hint = auth_or_kind(acc)
    Mix.shell().info("  ❌ Process exited (status=#{status}) without an ACP response. #{hint}")
    Mix.shell().info(preview(acc) <> "\n")
  end

  defp classify({:timeout, acc}) do
    hint = auth_or_kind(acc)
    Mix.shell().info("  ❌ No ACP response before timeout. #{hint}")
    Mix.shell().info(preview(acc) <> "\n")
  end

  defp auth_or_kind(acc) do
    down = String.downcase(acc)

    cond do
      String.contains?(down, "login") or String.contains?(down, "sign in") or
        String.contains?(down, "unauthorized") or String.contains?(down, "not authenticated") ->
        "Looks like AUTH is required — try logging the CLI in first, then re-probe."

      acc == "" ->
        "(No output — likely interactive/waiting, or wrong invocation. May need an adapter.)"

      true ->
        "(Non-ACP output below — likely interactive/TUI or wrong flag. May need an adapter.)"
    end
  end

  defp preview(""), do: "       (no output captured)"

  defp preview(acc) do
    snippet = acc |> String.slice(0, 300) |> String.replace("\n", "\n       ")
    "       raw: " <> snippet
  end

  defp close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    true
  rescue
    _ -> true
  end

  # ── config access (robust to map-or-keyword return shape) ──

  defp resolve(agent) do
    cond do
      not Code.ensure_loaded?(Arbor.AI.AcpSession.Config) ->
        {:error, :acp_config_unavailable}

      true ->
        apply(Arbor.AI.AcpSession.Config, :resolve, [agent])
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get(conf, key) when is_map(conf), do: Map.get(conf, key)
  defp get(conf, key) when is_list(conf), do: Keyword.get(conf, key)
  defp get(_, _), do: nil

  defp to_provider_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> {:error, :unknown_atom}
  end
end
