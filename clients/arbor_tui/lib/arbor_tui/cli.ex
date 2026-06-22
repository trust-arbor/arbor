defmodule ArborTui.CLI do
  @moduledoc """
  escript entry point for the Arbor TUI client.

  Usage:

      arbor-tui --agent agent_30b4… [--url ws://localhost:4000] [--key PATH]

  Loads the client identity from a `.arbor.key` file, then launches the TermUI
  application (which connects to the Gateway chat WebSocket and attaches to the
  target agent). `--key` defaults to `$ARBOR_KEY` or `~/.arbor/client.arbor.key`.
  """

  @runtime_name ArborTui.Runtime

  @switches [agent: :string, url: :string, key: :string]
  @aliases [a: :agent, u: :url, k: :key]

  def main(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    with {:ok, agent_id} <- fetch_agent(opts),
         key_path = key_path(opts),
         {:ok, identity} <- ArborTui.Signer.load_key(key_path) do
      run(identity, agent_id, gateway_url(opts))
    else
      {:error, reason} -> abort(reason)
    end
  end

  defp run(identity, agent_id, gateway_url) do
    TermUI.Runtime.run(
      root: ArborTui.App,
      name: @runtime_name,
      identity: identity,
      target_agent_id: agent_id,
      gateway_url: gateway_url,
      runtime_name: @runtime_name
    )
  end

  defp fetch_agent(opts) do
    case opts[:agent] do
      nil -> {:error, "missing --agent <agent_id>"}
      agent_id -> {:ok, agent_id}
    end
  end

  defp gateway_url(opts),
    do: opts[:url] || System.get_env("ARBOR_GATEWAY_URL") || "ws://localhost:4000"

  defp key_path(opts),
    do:
      opts[:key] || System.get_env("ARBOR_KEY") ||
        Path.join([System.user_home!(), ".arbor", "client.arbor.key"])

  defp abort(reason) do
    IO.puts(:stderr, "arbor-tui: #{format_error(reason)}")
    System.halt(1)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
