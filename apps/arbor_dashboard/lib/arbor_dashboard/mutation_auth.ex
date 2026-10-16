defmodule Arbor.Dashboard.MutationAuth do
  @moduledoc false

  alias Arbor.Dashboard.Config

  # Nav binds the browser subject and its proof. Route/event parameters select
  # only a target; local-dev identity assertions confer no mutation authority.
  def authorize(socket, resource, action) do
    with actor when is_binary(actor) and actor != "" <- socket.assigns[:current_agent_id],
         token when is_binary(token) and token != "" <- socket.assigns[:session_token],
         {:ok, :authorized} <-
           Config.mutation_security_api().authorize(actor, resource, action, session_token: token) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end
end
