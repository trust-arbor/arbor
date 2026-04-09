defmodule Arbor.Contracts.Commands.Result do
  @moduledoc """
  Output of a slash command's pure `execute/2` callback.

  A `Result` carries the text to display to the user plus an optional
  `:action` description that the caller (entry point or CommandIntake helper)
  should perform after presenting the text. This separation keeps commands
  pure: data in (Context), data out (Result), no side effects inside the
  command itself.

  ## Why action descriptions instead of callback functions

  The previous design passed action callbacks via the Context map
  (`:clear_fn`, `:compact_fn`, `:switch_model_fn`). That had several problems:

  - Functions in maps are unserializable, untestable, and untyped
  - Each new action needed a new fn slot in the Context (growth without limit)
  - Commands were impure (mixed display + side effects)
  - Each entry point had to know which fns to populate, coupling commands to
    every host

  Action descriptions are plain data, serializable, easy to test, and the
  caller decides how to dispatch them. A new action is just a new tag — no
  changes to the Context. New entry points just need to interpret action tags,
  not populate fn fields.

  ## Action tags

  Currently defined action tags (extend as needed):

  - `nil` — display-only command, no follow-up action
  - `:clear` — caller should clear the current session's context
  - `:compact` — caller should compact the current session's messages
  - `{:switch_model, name :: String.t()}` — caller should switch the current
    agent to the named model

  Future: `{:spawn_agent, template}`, `{:delete_agent, id}`,
  `{:dispatch_action, fully_qualified, args}`, etc.

  ## Result types

  - `:info` — normal informational output (the default)
  - `:error` — command-level error message (e.g. "unknown command")
  - `:command_action` — display + action; the caller should perform the action
  """

  use TypedStruct

  @type result_type :: :info | :error | :command_action

  @type action ::
          nil
          | :clear
          | :compact
          | {:switch_model, String.t()}

  typedstruct do
    @typedoc "Output of a slash command"

    field(:text, String.t(), enforce: true)
    field(:type, result_type(), default: :info)
    field(:action, action(), default: nil)
  end

  @doc """
  Quick constructor for a display-only info Result.
  """
  @spec ok(String.t()) :: t()
  def ok(text) when is_binary(text) do
    %__MODULE__{text: text, type: :info, action: nil}
  end

  @doc """
  Constructor for a Result that includes an action description for the caller
  to execute.
  """
  @spec action(String.t(), action()) :: t()
  def action(text, action) when is_binary(text) do
    %__MODULE__{text: text, type: :command_action, action: action}
  end

  @doc """
  Constructor for a command-level error Result. Used when the command itself
  decides it can't run (e.g. invalid args), distinct from `{:error, term}`
  returns which signal infrastructure failures.
  """
  @spec error(String.t()) :: t()
  def error(text) when is_binary(text) do
    %__MODULE__{text: text, type: :error, action: nil}
  end
end
