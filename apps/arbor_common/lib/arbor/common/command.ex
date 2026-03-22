defmodule Arbor.Common.Command do
  @moduledoc """
  Behaviour for slash commands in agent chat.

  Commands intercept user input before it reaches the LLM, providing
  fast operations like `/help`, `/model`, `/status`, and `/compact`.

  ## Context

  The `context` map is built by the caller (Session, Manager, CLI) and
  contains whatever state is available at that entry point:

      %{
        agent_id: "agent_abc123",
        session_pid: pid,
        model: "anthropic/claude-sonnet-4",
        trust_profile: %{...},
        # ... caller-specific keys
      }

  Commands should degrade gracefully when context keys are missing.

  ## Example

      defmodule Arbor.Common.Commands.Help do
        @behaviour Arbor.Common.Command

        @impl true
        def name, do: "help"

        @impl true
        def aliases, do: ["h", "?"]

        @impl true
        def description, do: "List available commands"

        @impl true
        def usage, do: "/help [command]"

        @impl true
        def execute(_args, context) do
          commands = Arbor.Common.CommandRouter.list_commands(context)
          {:ok, format_commands(commands)}
        end

        @impl true
        def available?(_context), do: true
      end
  """

  @doc "Primary command name (e.g. \"help\", \"model\")."
  @callback name() :: String.t()

  @doc "Alternative names (e.g. [\"h\", \"?\"] for help)."
  @callback aliases() :: [String.t()]

  @doc "Short description shown in /help listing."
  @callback description() :: String.t()

  @doc "Usage string (e.g. \"/model [provider/model]\")."
  @callback usage() :: String.t()

  @doc """
  Execute the command with parsed arguments and caller context.

  Returns `{:ok, text}` for display, or `{:error, reason}`.
  """
  @callback execute(args :: String.t(), context :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Whether this command is visible/available given the current context.

  Used for trust-aware filtering — e.g., `/shell` only available when
  the agent's trust profile allows `arbor://shell/exec`.
  """
  @callback available?(context :: map()) :: boolean()

  @optional_callbacks [aliases: 0]
end
