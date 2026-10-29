defmodule Arbor.Common.AuthenticatedCall do
  @moduledoc """
  Compatibility entry points for authenticated same-node custody calls.

  New consumers use `Arbor.Custody`. Existing callers retain their function
  signatures, wire protocol, sealed custody and call error identities.
  """

  @typedoc "Opaque reply target returned only after a challenge is consumed."
  @type reply_to :: Arbor.Custody.authenticated_call_reply_to()

  @type handle_result :: Arbor.Custody.authenticated_call_handle_result()

  @doc "Creates the private pending-challenge table owned by the calling server."
  @spec new_custody() :: :ets.tid()
  def new_custody, do: Arbor.Custody.new_authenticated_call_custody()

  @doc "Performs an authenticated call to an exact, already-verified local server PID."
  @spec call(pid(), term(), timeout()) :: term()
  def call(server_pid, request, timeout \\ 5_000),
    do: Arbor.Custody.authenticated_call(server_pid, request, timeout)

  @doc "Handles one protocol message inside the server's handle_info/2."
  @spec handle(term(), :ets.tid()) :: handle_result()
  def handle(message, custody), do: Arbor.Custody.handle_authenticated_call(message, custody)

  @doc "Replies to the authenticated caller returned by handle/2."
  @spec reply(reply_to(), term()) :: :ok
  def reply(reply_to, result), do: Arbor.Custody.reply_authenticated_call(reply_to, result)

  @doc "Clears outstanding challenges while retaining the private table."
  @spec clear(:ets.tid()) :: :ok
  def clear(custody), do: Arbor.Custody.clear_authenticated_call_custody(custody)
end
