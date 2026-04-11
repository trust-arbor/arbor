defmodule Mix.Tasks.Arbor.Signer do
  @shortdoc "MCP stdio signing proxy for an external Arbor agent"

  @moduledoc """
  Stdio MCP signing proxy for an external Arbor agent.

  Run as a subprocess of an MCP client (Claude Code, etc.). Reads JSON-RPC
  requests from stdin, signs each one with the agent's Ed25519 private key,
  forwards them to the upstream Arbor gateway over HTTP, and writes the
  JSON-RPC response back to stdout.

  Stdout is reserved for MCP protocol traffic. All log output goes to
  stderr — anything written to stdout that isn't a valid JSON-RPC frame
  will break the parent client.

  ## Usage

      mix arbor.signer --key-file ~/.claude/arbor-personal/claude_cli_mbp.arbor.key
      mix arbor.signer --key-file /path/to/agent.key --upstream http://10.42.42.42:4000/mcp

  ## Options

    * `--key-file <path>` (required) — path to the agent's `.arbor.key` file
      (the same format the dashboard's External Agents page produces)
    * `--upstream <url>` (optional, default `http://localhost:4000/mcp`) —
      the Arbor gateway's MCP endpoint

  ## MCP client configuration

  In Claude Code's MCP config, replace the direct gateway HTTP entry with
  a stdio entry that spawns this task:

      {
        "arbor": {
          "command": "mix",
          "args": [
            "arbor.signer",
            "--key-file",
            "$HOME/.claude/arbor-personal/claude_cli_mbp.arbor.key"
          ]
        }
      }

  Each Claude Code session spawns its own proxy subprocess; the proxy
  exits cleanly when the parent closes its end of the pipe.

  ## Why a subprocess instead of a daemon

  Stdio is the security boundary. There is no listening port that another
  process on the box could connect to in order to impersonate the agent.
  See `Arbor.Gateway.Signer.Proxy` and the Phase 0 design discussion in
  `.arbor/roadmap/0-inbox/external-agent-registration-mcp.md` for the
  full reasoning.
  """

  use Mix.Task

  # Opt out of the default `app.start` prereq. Starting the project's apps
  # would (a) collide with the dev server on port 4000 if it is running,
  # and (b) drag in the entire umbrella dep graph including memento/mnesia,
  # which has its own load issues. We only need :inets (OTP built-in) for
  # the :httpc upstream call, and we start it explicitly inside run/1.
  @requirements ["loadpaths"]

  alias Arbor.Gateway.Signer.Proxy

  @impl Mix.Task
  def run(argv) do
    # The proxy bypasses the local gateway entirely — it signs and forwards
    # to a remote upstream. Starting :arbor_gateway here would try to boot
    # the gateway HTTP listener on port 4000, which collides with the dev
    # server when it is already running.
    #
    # We only need :inets (OTP built-in) for the upstream POST via :httpc.
    # The SignedRequest contracts and crypto helpers are pure modules
    # already loaded by Mix at task-launch time. No umbrella dep graph
    # gets dragged in this way.
    {:ok, _} = Application.ensure_all_started(:inets)

    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          key_file: :string,
          upstream: :string
        ]
      )

    case Proxy.start(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "arbor.signer: #{format_error(reason)}")
        # Non-zero exit so the parent MCP client knows the proxy didn't start
        exit({:shutdown, 1})
    end
  end

  defp format_error({:missing_required_option, key}),
    do: "missing required option --#{String.replace(to_string(key), "_", "-")}"

  defp format_error({:key_file_read_failed, path, reason}),
    do: "failed to read key file #{path}: #{:file.format_error(reason)}"

  defp format_error({:missing_field, field}),
    do: "key file is missing required field: #{field}"

  defp format_error({:empty_field, field}),
    do: "key file field is empty: #{field}"

  defp format_error({:invalid_private_key_size, size}),
    do: "private_key_b64 decodes to #{size} bytes; expected 32 or 64 (Ed25519)"

  defp format_error(:invalid_private_key_base64),
    do: "private_key_b64 is not valid base64"

  defp format_error({:invalid_agent_id, id}),
    do: "agent_id does not look like an Arbor agent ID: #{inspect(id)}"

  defp format_error(other),
    do: "unexpected error: #{inspect(other)}"
end
