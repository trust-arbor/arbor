defmodule Arbor.Gateway.Chat.Config do
  @moduledoc false

  @spec agent_facade() :: module() | nil
  def agent_facade do
    case Application.get_env(:arbor_gateway, :chat_agent_facade) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> nil
    end
  end
end
