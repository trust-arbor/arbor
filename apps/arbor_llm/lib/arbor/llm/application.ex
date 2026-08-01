defmodule Arbor.LLM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arbor.LLM.OAuth.Login.PendingStore
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.LLM.Supervisor)
  end
end
