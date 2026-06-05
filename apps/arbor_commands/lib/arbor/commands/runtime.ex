defmodule Arbor.Commands.Runtime do
  @moduledoc """
  Show or switch the current agent's runtime without changing the model.

  ## Usage

      /runtime              # show current runtime
      /runtime arbor        # switch to in-BEAM runtime (default)
      /runtime acp          # switch to subprocess CLI runtime

  Pair with `/model` when you want to change both at once
  (`/model claude-opus-4-6 runtime=acp`).

  ## Why this lives in arbor_commands

  Performs a side effect — `Arbor.Orchestrator.Session.set_runtime/2`.
  arbor_commands depends on arbor_orchestrator directly, so the call is
  compile-time-checked. The pure-read commands (Help, Status, etc.) stay
  in arbor_common; side-effecting commands like this one live here.

  See `.arbor/decisions/2026-06-04-slash-commands-for-runtime-config.md`
  for the slash-command-over-GUI design context.
  """

  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}
  alias Arbor.Orchestrator.Session

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
          {:ok, runtime} -> apply_runtime(runtime, ctx)
          :error -> {:ok, unknown_runtime_error(arg)}
        end
    end
  end

  defp apply_runtime(runtime, %Context{session_pid: pid}) when is_pid(pid) do
    cond do
      not Process.alive?(pid) ->
        {:ok, Result.error("Cannot switch runtime: session process is no longer alive.")}

      true ->
        case safe_call(fn -> Session.set_runtime(pid, runtime) end) do
          {:ok, _} ->
            {:ok,
             Result.ok(
               "Runtime set to #{runtime} (effective on next turn).",
               runtime_changed: runtime
             )}

          {:error, reason} ->
            {:ok, Result.error("/runtime failed: #{inspect(reason)}")}
        end
    end
  end

  defp apply_runtime(_runtime, _ctx) do
    {:ok, Result.error("Cannot switch runtime: session pid missing from context.")}
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp unknown_runtime_error(arg) do
    Result.error(
      "Unknown runtime '#{String.trim(arg)}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
    )
  end

  # `Context` doesn't yet carry a :runtime field as of Phase 2c; future
  # patches can add it the same way :model and :provider are tracked
  # (see Arbor.Contracts.Commands.Context). Until then, /runtime without
  # arg always shows "arbor (default)" — accurate, since :arbor is the
  # default and Context can't say otherwise.
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
