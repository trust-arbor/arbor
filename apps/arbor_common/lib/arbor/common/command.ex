defmodule Arbor.Common.Command do
  @moduledoc """
  Behaviour for slash commands in agent chat.

  Commands intercept user input before it reaches the LLM, providing fast
  operations like `/help`, `/model`, `/status`, and `/compact`. They are
  invoked the same way from every entry point — dashboard, arbor_comms,
  ACP, CLI — by going through `Arbor.Common.CommandIntake.handle/3`.

  ## Pure functions, no side effects

  Commands are PURE: data in (`%Context{}`), data out (`%Result{}`). They
  do not perform side effects directly. If a command needs the caller to
  do something (clear a session, switch a model, etc.), it returns a
  `%Result{}` with an `:action` field describing what should happen. The
  caller (CommandIntake.handle's invoker) interprets the action and
  performs the side effect.

  This separation makes commands trivially testable in isolation, lets
  them work from any entry point without coupling, and removes the
  fn-in-context anti-pattern of the original design.

  ## Example — display command

      defmodule Arbor.Common.Commands.Status do
        @behaviour Arbor.Common.Command

        alias Arbor.Contracts.Commands.{Context, Result}

        @impl true
        def name, do: "status"

        @impl true
        def description, do: "Show agent status (model, session, trust)"

        @impl true
        def usage, do: "/status"

        @impl true
        def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

        @impl true
        def execute(_args, %Context{} = ctx) do
          text = "Agent: \#{ctx.display_name}\\nModel: \#{ctx.model}"
          {:ok, Result.ok(text)}
        end
      end

  ## Example — action command

      defmodule Arbor.Common.Commands.Clear do
        @behaviour Arbor.Common.Command

        alias Arbor.Contracts.Commands.{Context, Result}

        @impl true
        def name, do: "clear"

        @impl true
        def description, do: "Clear session context"

        @impl true
        def usage, do: "/clear"

        @impl true
        def available?(%Context{} = ctx), do: Context.has_session?(ctx)

        @impl true
        def execute(_args, %Context{}) do
          {:ok, Result.action("Session context cleared.", :clear)}
        end
      end

  The command itself does NOT call `Session.clear/1`. The caller of
  `CommandIntake.handle` sees `result.action == :clear` and routes the
  side effect to the appropriate handler (Session for agent-bound
  actions, Manager for system-wide actions, etc.).
  """

  alias Arbor.Contracts.Commands.{Context, Result}

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

  Returns `{:ok, %Result{}}` for both display-only commands and commands
  that need the caller to perform an action (the action is described in
  `result.action`). Returns `{:error, reason}` for infrastructure failures
  that the command itself can't represent (e.g. malformed args). For
  command-level errors that should be displayed to the user, return
  `{:ok, Result.error("...")}`.
  """
  @callback execute(args :: String.t(), context :: Context.t()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc """
  Whether this command is visible/available given the current context.

  Used by `/help` to filter the command list and by `CommandIntake` to
  reject commands that can't run in the current context (e.g. agent-bound
  commands when no agent is selected).
  """
  @callback available?(context :: Context.t()) :: boolean()

  @optional_callbacks [aliases: 0]
end
