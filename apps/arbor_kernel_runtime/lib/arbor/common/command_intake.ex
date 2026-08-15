defmodule Arbor.Common.CommandIntake do
  @moduledoc """
  Centralized entry point for slash command handling.

  Every interface that takes user input from a human (dashboard ChatLive,
  arbor_comms.MessageHandler, ACP server, CLI, future Signal/Telegram bots)
  should funnel input through `handle/3` instead of routing directly to
  Session/Manager/etc.

  ## Why this exists

  Before this helper, slash command handling was bifurcated: the dashboard
  path went through `Session.send_message`'s intercept (which crashed on
  the very first try because of an Access bug that no test had caught), and
  arbor_comms had its own hardcoded `/help` returning a stub string. The
  "single intercept at Session.send_message" claim was aspirational, not
  real.

  CommandIntake makes the intercept explicit at the entry-point layer:
  every entry point parses commands the same way, builds a typed Context,
  calls the same CommandRouter, and gets back a typed Result. There is no
  shared mutable state and no fn-in-context coupling.

  ## Flow

      def handle_user_message(input, %Context{} = context, fallback_fn) do
        case CommandIntake.handle(input, context, fallback_fn) do
          {:command_result, %Result{action: nil} = result} ->
            display(result.text)

          {:command_result, %Result{action: action} = result} ->
            display(result.text)
            execute_action(action, context)

          {:command_error, message} ->
            display(message)

          other ->
            # The fallback_fn returned its own value (e.g. {:ok, response}
            # from Session.send_message) — pass it through.
            other
        end
      end

  Action dispatch (`execute_action`) is the entry point's responsibility,
  not the intake helper's. Different entry points may handle the same
  action differently (e.g. dashboard runs `:clear` against the local
  Session, Signal might refuse it with a "not available via SMS" message).

  ## Return shapes

  - `{:command_result, %Result{}}` — input was a command and it ran
    successfully (whether display-only or action-bearing)
  - `{:command_error, message}` — input was a command but the router
    returned an error (unknown, unavailable, command crashed)
  - whatever `fallback_fn.(text)` returns — input was a normal prompt,
    not a command, and was forwarded to the fallback handler
  """

  alias Arbor.Common.CommandRouter
  alias Arbor.Contracts.Commands.{Context, Result}

  @type intake_result ::
          {:command_result, Result.t()}
          | {:command_error, String.t()}
          | any()

  @doc """
  Parse `input` and route it.

  - If input is a slash command, runs it via `CommandRouter.execute/3`
    against the supplied Context. Returns `{:command_result, %Result{}}` or
    `{:command_error, message}`.
  - If input is a regular prompt, calls `fallback_fn.(text)` and returns
    whatever it returns.

  `fallback_fn` must be a 1-arity function that takes the prompt text. The
  text is the original input, unmodified, so existing callers (e.g.
  `Session.send_message`) work without changes.
  """
  @spec handle(String.t(), Context.t(), (String.t() -> any())) :: intake_result()
  def handle(input, %Context{} = context, fallback_fn)
      when is_binary(input) and is_function(fallback_fn, 1) do
    case CommandRouter.parse(input) do
      {:command, name, args} ->
        case CommandRouter.execute(name, args, context) do
          {:ok, %Result{} = result} ->
            {:command_result, result}

          {:error, {:unknown_command, msg}} ->
            {:command_error, msg}

          {:error, {:unavailable, msg}} ->
            {:command_error, msg}

          {:error, {:command_error, msg}} ->
            {:command_error, "Command error: #{msg}"}

          {:error, reason} ->
            {:command_error, "Error: #{inspect(reason)}"}
        end

      {:prompt, text} ->
        fallback_fn.(text)
    end
  end

  @doc """
  Parse `input` without executing. Convenience for callers that want to
  classify input before deciding what to do (e.g. for logging or for showing
  a different UI affordance for commands vs prompts).

  Returns `{:command, name, args}` or `{:prompt, text}` directly from
  `CommandRouter.parse/1`.
  """
  @spec classify(String.t()) ::
          {:command, String.t(), String.t()} | {:prompt, String.t()}
  def classify(input) when is_binary(input), do: CommandRouter.parse(input)
end
