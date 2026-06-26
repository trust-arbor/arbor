defmodule ArborTui.CLI do
  @moduledoc """
  escript entry point for the Arbor TUI client.

  Usage:

      arbor-tui [--agent agent_30b4…] [--url ws://localhost:4000] [--key PATH]

  No flag is required. Settings resolve with the precedence **CLI flag > config
  file (`~/.arbor/tui.conf`) > env var > built-in default** (see
  `ArborTui.Config`). With no agent resolved, the client starts UNATTACHED — use
  `/agent <id>` inside the TUI to attach.

  Loads the client identity from the resolved `.arbor.key` path, then launches
  the TermUI application.
  """

  alias ArborTui.Config

  @runtime_name ArborTui.Runtime

  @switches [agent: :string, url: :string, key: :string]
  @aliases [a: :agent, u: :url, k: :key]

  def main(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    config = Config.load()
    state = Config.load_state()
    key_path = Config.resolve_key(opts, config)

    case ArborTui.Signer.load_key(key_path) do
      {:ok, identity} ->
        run(identity, Config.resolve_agent(opts, config, state), Config.resolve_url(opts, config))

      {:error, reason} ->
        abort(reason)
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

  defp abort(reason) do
    IO.puts(:stderr, "arbor-tui: #{format_error(reason)}")
    System.halt(1)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
