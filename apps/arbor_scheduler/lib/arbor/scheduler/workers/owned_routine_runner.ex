defmodule Arbor.Scheduler.Workers.OwnedRoutineRunner do
  @moduledoc "Executes an owner-signed routine after authoritative job-attempt admission."
  use Oban.Worker, queue: :pipelines, max_attempts: 3

  alias Arbor.Scheduler.OwnedRoutines

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) when is_integer(id) and id > 0 do
    # The caller's args, owner hints and job state are never authority.
    case OwnedRoutines.perform(id) do
      :ok -> :ok
      {:error, :routine_unavailable} = error -> error
      {:error, reason} -> {:discard, reason}
    end
  end

  def perform(_), do: {:discard, :invalid_routine_job}
end
