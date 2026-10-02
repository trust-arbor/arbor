defmodule ConversationDemo.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link(
      [
        {Phoenix.PubSub, name: ConversationDemo.PubSub},
        ConversationDemo.Endpoint
      ],
      strategy: :one_for_one,
      name: ConversationDemo.Supervisor
    )
  end
end
