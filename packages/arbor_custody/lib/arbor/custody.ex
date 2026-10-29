defmodule Arbor.Custody do
  @moduledoc """
  Caller-owned custody and supervised-process provenance for OTP applications.

  Authenticated calls bind messages to the actual local caller through private
  ETS ownership and a one-shot challenge exchange. Private state stays outside
  replaceable GenServer callback state. Supervision helpers bind registered
  names and startup candidates to exact application descendants.

  All custody operations execute in the calling process. Pass an independently
  verified local server PID to `authenticated_call/3`; a registered name alone
  is not server authentication. Long-lived principals must mark themselves
  sensitive from startup when their authority extends beyond one call.

  Callers own all tables and process lifetimes. Starting this package creates
  no supervisor, registry, broker or store. It grants no signing authority and
  implements no application-specific authorization policy.
  """

  alias Arbor.Custody.AuthenticatedCall
  alias Arbor.Custody.ProcessPrivateState
  alias Arbor.Custody.SupervisedOwner

  @typedoc "Opaque reply target returned after an authenticated same-node call."
  @type authenticated_call_reply_to :: AuthenticatedCall.reply_to()

  @typedoc "Result of admitting one authenticated-call protocol message."
  @type authenticated_call_handle_result ::
          :pending
          | :expired
          | :rejected
          | :unrecognized
          | {:authenticated, pid(), term(), authenticated_call_reply_to()}

  @doc "Creates private ETS custody for an authenticated-call server."
  @spec new_authenticated_call_custody() :: :ets.tid()
  def new_authenticated_call_custody, do: AuthenticatedCall.new_custody()

  @doc "Calls an already-verified local server PID with caller authentication."
  @spec authenticated_call(pid(), term(), timeout()) :: term()
  def authenticated_call(server_pid, request, timeout \\ 5_000),
    do: AuthenticatedCall.call(server_pid, request, timeout)

  @doc "Admits one authenticated-call protocol message in a server callback."
  @spec handle_authenticated_call(term(), :ets.tid()) :: authenticated_call_handle_result()
  def handle_authenticated_call(message, custody), do: AuthenticatedCall.handle(message, custody)

  @doc "Replies through an authenticated-call reply target."
  @spec reply_authenticated_call(authenticated_call_reply_to(), term()) :: :ok
  def reply_authenticated_call(reply_to, result), do: AuthenticatedCall.reply(reply_to, result)

  @doc "Clears all pending calls from authenticated-call custody."
  @spec clear_authenticated_call_custody(:ets.tid()) :: :ok
  def clear_authenticated_call_custody(custody), do: AuthenticatedCall.clear(custody)

  @doc "Returns the registered PID only when it is the exact child in an application's supervision tree."
  @spec supervised_registered_child_pid(atom(), [term()], atom(), timeout()) ::
          {:ok, pid()} | {:error, :not_supervised_owner}
  def supervised_registered_child_pid(application, child_path, registered_name, timeout \\ 1_000),
    do: SupervisedOwner.registered_child_pid(application, child_path, registered_name, timeout)

  @doc """
  Binds a candidate to the root of an application still inside `start/2`.

  Uses VM-maintained spawn parents without asking a starting application
  master for its child. Callers must still confirm the exact child path.
  """
  @spec starting_application_root(atom(), pid(), pos_integer()) :: {:ok, pid()} | :error
  def starting_application_root(application, candidate, depth),
    do: SupervisedOwner.starting_application_root(application, candidate, depth)

  @doc "Opens a process-owned private state slot."
  @spec open_process_private_state(term(), atom(), term(), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def open_process_private_state(anchor, schema, value, validator),
    do: ProcessPrivateState.open(anchor, schema, value, validator)

  @doc "Reads a process-owned private state slot."
  @spec fetch_process_private_state(term(), atom(), (term() -> boolean())) ::
          {:ok, term()} | {:error, :invalid_private_state}
  def fetch_process_private_state(anchor, schema, validator),
    do: ProcessPrivateState.fetch(anchor, schema, validator)

  @doc "Replaces a process-owned private state slot."
  @spec replace_process_private_state(term(), atom(), term(), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def replace_process_private_state(anchor, schema, value, validator),
    do: ProcessPrivateState.replace(anchor, schema, value, validator)

  @doc "Updates a process-owned private state slot."
  @spec update_process_private_state(term(), atom(), (term() -> term()), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def update_process_private_state(anchor, schema, update_fun, validator),
    do: ProcessPrivateState.update(anchor, schema, update_fun, validator)

  @doc "Closes a process-owned private state slot."
  @spec close_process_private_state(term()) :: :ok
  def close_process_private_state(anchor), do: ProcessPrivateState.close(anchor)
end
