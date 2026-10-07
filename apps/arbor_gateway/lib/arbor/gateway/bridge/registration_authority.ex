defmodule Arbor.Gateway.Bridge.RegistrationAuthority do
  @moduledoc """
  Supervised owner for Claude bridge registration mutations.

  The authenticated request principal selects only its own stored signing
  identity. Acquisition and mutation both run in this fixed process, because
  Security authorities are bound to the PID that opens them.
  """

  use GenServer

  alias Arbor.Gateway.Bridge.ClaudeSession

  @purpose :gateway_claude_bridge

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec authorize_tool(String.t(), String.t(), String.t(), map(), String.t()) ::
          {:ok, :authorized}
          | {:ok, :authorized, map()}
          | {:error, :unauthorized, String.t()}
  def authorize_tool(actor_id, session_id, tool_name, tool_input, cwd)
      when is_binary(actor_id) do
    GenServer.call(
      __MODULE__,
      {:authorize_tool, actor_id, session_id, tool_name, tool_input, cwd},
      30_000
    )
  catch
    :exit, _ -> {:error, :unauthorized, "Session registration authority unavailable"}
  end

  def authorize_tool(_actor_id, _session_id, _tool_name, _tool_input, _cwd),
    do: {:error, :unauthorized, "Authenticated registration principal required"}

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    {:ok, nil}
  end

  @impl true
  def handle_call(
        {:authorize_tool, actor_id, session_id, tool_name, tool_input, cwd},
        _from,
        state
      ) do
    result =
      with {:ok, proof} <-
             Arbor.Security.build_stored_signing_authority_acquisition_proof(
               actor_id,
               @purpose,
               self(),
               __MODULE__
             ),
           {:ok, authority} <- Arbor.Security.open_signing_authority(proof) do
        try do
          ClaudeSession.authorize_tool(session_id, tool_name, tool_input, cwd,
            actor_authority: authority
          )
        after
          _ = Arbor.Security.close_signing_authority(authority)
        end
      else
        _ -> {:error, :unauthorized, "Session registration authority denied"}
      end

    {:reply, result, state}
  end
end
