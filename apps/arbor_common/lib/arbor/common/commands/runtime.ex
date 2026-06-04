defmodule Arbor.Common.Commands.Runtime do
  @moduledoc """
  Show or switch the current agent's runtime without changing the model.

  ## Usage

      /runtime              # show current runtime
      /runtime arbor        # switch to in-BEAM runtime (default)
      /runtime acp          # switch to subprocess CLI runtime

  Pair with `/model` when you want to change both at once
  (`/model claude-opus-4-6 runtime=acp`).

  ## Why this is a separate command

  The slash-command-over-GUI architectural decision (`.arbor/decisions/
  2026-06-04-slash-commands-for-runtime-config.md`) chose to expose the
  runtime axis as a first-class command rather than a dropdown. Keeps
  the surface composable — adding skill catalogs, fallback chain pins,
  or future axes is another `/<axis>` command, not another dropdown
  per axis.
  """

  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @valid_runtimes [:arbor, :acp]

  @impl true
  def name, do: "runtime"

  @impl true
  def description, do: "Show or switch the agent's runtime (arbor or acp)"

  @impl true
  def usage, do: "/runtime [arbor|acp]"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute("", %Context{} = ctx) do
    case current_runtime(ctx) do
      nil -> {:ok, Result.ok("Current runtime: arbor (default)")}
      runtime -> {:ok, Result.ok("Current runtime: #{runtime}")}
    end
  end

  def execute(arg, %Context{} = ctx) do
    case Context.has_agent?(ctx) do
      false ->
        {:ok, Result.error("Cannot switch runtime: no current agent in this context.")}

      true ->
        case parse_runtime(arg) do
          {:ok, runtime} ->
            {:ok,
             Result.action(
               "Switching runtime to: #{runtime}",
               {:switch_runtime, runtime}
             )}

          :error ->
            {:ok,
             Result.error(
               "Unknown runtime '#{String.trim(arg)}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
             )}
        end
    end
  end

  # `Context` doesn't yet carry a :runtime field as of Phase 2c; future
  # patches can add it the same way :model and :provider are tracked
  # (see Arbor.Contracts.Commands.Context). Until then, /runtime without
  # arg always shows "arbor (default)" — accurate, since :arbor is the
  # default and Context can't say otherwise. The setter side (action
  # tag) still works.
  defp current_runtime(%Context{} = ctx) do
    Map.get(ctx, :runtime)
  end

  defp parse_runtime(arg) do
    case arg |> String.trim() |> String.downcase() do
      "arbor" -> {:ok, :arbor}
      "acp" -> {:ok, :acp}
      _ -> :error
    end
  end
end
