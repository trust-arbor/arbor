defmodule Arbor.Common.Commands.Clear do
  @moduledoc "Clear session context and start fresh."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "clear"

  @impl true
  def description, do: "Clear session context"

  @impl true
  def usage, do: "/clear"

  @impl true
  def available?(context), do: context[:session_pid] != nil

  @impl true
  def execute(_args, context) do
    case context[:clear_fn] do
      fun when is_function(fun, 0) ->
        case fun.() do
          :ok -> {:ok, "Session context cleared."}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, "Clear not available — no active session."}
    end
  end
end
