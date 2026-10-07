defmodule Arbor.Common do
  @moduledoc """
  Common utilities shared across Arbor applications.

  This library provides reusable utilities for:
  - **Time formatting** - Relative time ("2h ago"), datetime, time-only formats
  - **Pagination** - Cursor-based pagination with timestamp:id cursors
  - **SafeAtom** - DoS-resistant string-to-atom conversion

  ## Usage

      # Time formatting
      Arbor.Common.Time.relative(datetime)  # => "2h ago"
      Arbor.Common.Time.datetime(datetime)  # => "2026-01-26 17:00:00"

      # Pagination
      cursor = Arbor.Common.Pagination.generate_cursor(record)
      {:ok, {timestamp, id}} = Arbor.Common.Pagination.parse_cursor(cursor)

      # Safe atom conversion (DoS prevention)
      Arbor.Common.SafeAtom.to_existing("ok")           # => {:ok, :ok}
      Arbor.Common.SafeAtom.to_allowed("read", [:read]) # => {:ok, :read}
      Arbor.Common.SafeAtom.atomize_keys(map, [:name])  # => %{name: "value"}
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Contracts, Finch, Jason, Logger, Req, Zoi],
    exports: :all

  @typedoc "Opaque reply target returned after an authenticated same-node call."
  @type authenticated_call_reply_to :: Arbor.Common.AuthenticatedCall.reply_to()

  @typedoc "Result of admitting one authenticated-call protocol message."
  @type authenticated_call_handle_result ::
          :pending
          | :expired
          | :rejected
          | :unrecognized
          | {:authenticated, pid(), term(), authenticated_call_reply_to()}

  @doc "Creates private ETS custody for an authenticated-call server."
  @spec new_authenticated_call_custody() :: :ets.tid()
  def new_authenticated_call_custody,
    do: Arbor.Common.AuthenticatedCall.new_custody()

  @doc "Calls an already-verified local server PID with caller authentication."
  @spec authenticated_call(pid(), term(), timeout()) :: term()
  def authenticated_call(server_pid, request, timeout \\ 5_000),
    do: Arbor.Common.AuthenticatedCall.call(server_pid, request, timeout)

  @doc "Admits one authenticated-call protocol message in a server callback."
  @spec handle_authenticated_call(term(), :ets.tid()) :: authenticated_call_handle_result()
  def handle_authenticated_call(message, custody),
    do: Arbor.Common.AuthenticatedCall.handle(message, custody)

  @doc "Replies through an authenticated-call reply target."
  @spec reply_authenticated_call(authenticated_call_reply_to(), term()) :: :ok
  def reply_authenticated_call(reply_to, result),
    do: Arbor.Common.AuthenticatedCall.reply(reply_to, result)

  @doc "Clears all pending calls from authenticated-call custody."
  @spec clear_authenticated_call_custody(:ets.tid()) :: :ok
  def clear_authenticated_call_custody(custody),
    do: Arbor.Common.AuthenticatedCall.clear(custody)

  @doc "Whether the system tool catalog is enabled (default false)."
  @spec tool_catalog_enabled?() :: term()
  def tool_catalog_enabled?, do: Arbor.Common.Config.tool_catalog_enabled?()

  @doc "Whether the system skill catalog is enabled (default false)."
  @spec skill_catalog_enabled?() :: term()
  def skill_catalog_enabled?, do: Arbor.Common.Config.skill_catalog_enabled?()

  @doc "Whether project-context auto-load is enabled (default false)."
  @spec project_context_enabled?() :: term()
  def project_context_enabled?, do: Arbor.Common.Config.project_context_enabled?()

  @doc "Returns the SHA-256 identity of the BEAM code currently loaded for a module."
  @spec loaded_module_sha256(module()) :: {:ok, String.t()} | {:error, atom()}
  def loaded_module_sha256(module), do: Arbor.Common.LoadedModuleIdentity.sha256(module)

  @doc "Returns the registered PID only when it is the exact child in an application's supervision tree."
  @spec supervised_registered_child_pid(atom(), [term()], atom(), timeout()) ::
          {:ok, pid()} | {:error, :not_supervised_owner}
  def supervised_registered_child_pid(application, child_path, registered_name, timeout \\ 1_000) do
    Arbor.Common.SupervisedOwner.registered_child_pid(
      application,
      child_path,
      registered_name,
      timeout
    )
  end

  @doc "Creates the shared handler-registry child spec for an owning supervisor."
  @spec handler_registry_child_spec(keyword()) :: Supervisor.child_spec()
  def handler_registry_child_spec(opts \\ []), do: Arbor.Common.HandlerRegistry.child_spec(opts)

  @doc "Returns the live shared handler-registry PID, if registered."
  @spec handler_registry_pid() :: pid() | nil
  def handler_registry_pid, do: Process.whereis(Arbor.Common.HandlerRegistry)

  @doc "Returns the stable supervisor child ID for the shared handler registry."
  @spec handler_registry_child_id() :: module()
  def handler_registry_child_id, do: Arbor.Common.HandlerRegistry

  @doc "Resolves one registered handler type."
  @spec resolve_handler(String.t()) :: {:ok, module()} | {:error, term()}
  def resolve_handler(type), do: Arbor.Common.HandlerRegistry.resolve(type)

  @doc false
  @spec register_core_handler(String.t(), module(), map(), binary()) :: :ok | {:error, term()}
  def register_core_handler(type, module, metadata, custody),
    do: Arbor.Common.HandlerRegistry.register_core(type, module, metadata, custody)

  @doc false
  @spec lock_core_handlers() :: :ok | {:error, term()}
  def lock_core_handlers, do: Arbor.Common.HandlerRegistry.lock_core()

  @doc false
  @spec lock_core_handlers(binary(), timeout()) :: :ok | {:error, term()}
  def lock_core_handlers(custody, timeout),
    do: Arbor.Common.HandlerRegistry.lock_core(custody, timeout)

  @doc "Whether the shared handler registry has locked its core namespace."
  @spec core_handlers_locked?() :: boolean()
  def core_handlers_locked?, do: Arbor.Common.HandlerRegistry.core_locked?()

  @doc "Opens a process-owned private state slot."
  @spec open_process_private_state(term(), atom(), term(), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def open_process_private_state(anchor, schema, value, validator),
    do: Arbor.Common.ProcessPrivateState.open(anchor, schema, value, validator)

  @doc "Reads a process-owned private state slot."
  @spec fetch_process_private_state(term(), atom(), (term() -> boolean())) ::
          {:ok, term()} | {:error, :invalid_private_state}
  def fetch_process_private_state(anchor, schema, validator),
    do: Arbor.Common.ProcessPrivateState.fetch(anchor, schema, validator)

  @doc "Replaces a process-owned private state slot."
  @spec replace_process_private_state(term(), atom(), term(), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def replace_process_private_state(anchor, schema, value, validator),
    do: Arbor.Common.ProcessPrivateState.replace(anchor, schema, value, validator)

  @doc "Updates a process-owned private state slot."
  @spec update_process_private_state(term(), atom(), (term() -> term()), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def update_process_private_state(anchor, schema, update_fun, validator),
    do: Arbor.Common.ProcessPrivateState.update(anchor, schema, update_fun, validator)

  @doc "Closes a process-owned private state slot."
  @spec close_process_private_state(term()) :: :ok
  def close_process_private_state(anchor), do: Arbor.Common.ProcessPrivateState.close(anchor)
end
