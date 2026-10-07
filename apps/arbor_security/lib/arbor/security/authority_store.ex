defmodule Arbor.Security.AuthorityStore do
  @moduledoc """
  Security-owned authority storage with a frozen backend configuration.

  The default backend is `Arbor.Security.Store.JSONFile`, whose durability is
  `:node_restart`. Passing `backend: nil` selects owner-private in-memory state
  with `:process_lifetime` durability. The in-memory mode makes no restart or
  distributed consistency claim.

  This process serializes access and bounds authoritative snapshots. Startup
  handoff is coherent when it is the exclusive owner of backend mutations.
  Writers bypassing this process may race inventory hydration; snapshot isolation
  against such writers is not claimed. Durable generation and revision semantics
  remain owned by the configured Store backend; ephemeral mode delegates those
  transitions to `Revision`.
  """

  use GenServer

  alias Arbor.Contracts.Persistence.{Record, Revision}
  alias Arbor.Security.Config
  alias Arbor.Security.PrivateState
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.SupervisedOwner

  @default_hydration_limit 10_000
  @test_env Mix.env() == :test
  @required_callbacks [put: 3, get: 2, delete: 2, list: 1]
  @durability_classes [:volatile, :process_lifetime, :application_restart, :node_restart]
  @backend_custody_anchor {__MODULE__, :backend_custody}
  @backend_custody_schema :authority_store_backend_v1
  if Mix.env() == :test do
    @test_fixture_anchor {__MODULE__, :test_isolated_fixture}
  end

  @supervised_mutation_owners [
    Arbor.Security.CapabilityStore,
    Arbor.Security.Identity.Registry,
    Arbor.Security.IssuerRegistry
  ]
  @recognized_mutation_owners [
    Arbor.Security.CapabilityStore,
    Arbor.Security.Identity.Registry,
    Arbor.Security.IssuerRegistry,
    Arbor.Security.SigningKeyStore.Owner
  ]
  @storage_integrity_errors [
    :offline_migration_required,
    :record_authentication_failed,
    :record_authentication_unavailable,
    :revocation_ledger_missing,
    :revocation_ledger_malformed,
    :revocation_ledger_insecure_mode,
    :revocation_ledger_symlink_rejected,
    :revocation_ledger_hardlink_rejected,
    :revocation_ledger_not_regular,
    :revocation_ledger_marker_malformed,
    :revocation_ledger_marker_insecure_mode,
    :revocation_ledger_marker_symlink_rejected,
    :revocation_ledger_marker_hardlink_rejected,
    :revocation_ledger_marker_not_regular,
    :revocation_ledger_parent_unavailable
  ]

  @type expected :: :not_found | {:value, Record.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, name} <- fetch_name(opts) do
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @doc false
  @spec complete_startup(pid(), atom()) :: :ok | {:error, term()}
  def complete_startup(supervisor, name) do
    with {:ok, timeout} <- Config.startup_timeout_ms() do
      complete_startup(supervisor, name, timeout)
    end
  end

  @spec complete_startup(pid(), atom(), timeout()) :: :ok | {:error, term()}

  def complete_startup(supervisor, name, timeout)
      when is_pid(supervisor) and is_atom(name) and is_integer(timeout) and timeout > 0 do
    startup_call(supervisor, name, :complete_startup, timeout)
  end

  def complete_startup(_supervisor, _name, _timeout),
    do: {:error, :invalid_authority_store_startup}

  @doc false
  def authoritative_get_from_supervisor(supervisor, key, opts),
    do: startup_authoritative_call(supervisor, opts, {:authoritative_get, key})

  @doc false
  def authoritative_entry_from_supervisor(supervisor, key, opts),
    do: startup_authoritative_call(supervisor, opts, {:authoritative_entry, key})

  @doc false
  def take_hydrated_entries_from_supervisor(supervisor, opts),
    do: startup_authoritative_call(supervisor, opts, :take_hydrated_entries)

  @doc false
  def durability_class_from_supervisor(supervisor, opts),
    do: startup_authoritative_call(supervisor, opts, :durability_class)

  @doc false
  def acknowledged_put_from_supervisor(supervisor, key, value, opts),
    do: startup_mutation_call(supervisor, opts, {:acknowledged_put, key, value})

  @doc false
  def acknowledged_delete_from_supervisor(supervisor, key, opts),
    do: startup_mutation_call(supervisor, opts, {:acknowledged_delete, key})

  @doc false
  def acknowledged_compare_and_swap_from_supervisor(
        supervisor,
        key,
        expected,
        replacement,
        opts
      ),
      do:
        startup_mutation_call(
          supervisor,
          opts,
          {:acknowledged_compare_and_swap, key, expected, replacement}
        )

  @doc false
  def acknowledged_compare_and_delete_from_supervisor(supervisor, key, expected, opts),
    do:
      startup_mutation_call(
        supervisor,
        opts,
        {:acknowledged_compare_and_delete, key, expected}
      )

  if Mix.env() == :test do
    @doc false
    @spec start_test_fixture(keyword()) :: GenServer.on_start()
    def start_test_fixture(opts) when is_list(opts) do
      start_link(Keyword.put(opts, :test_isolated_owner, true))
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    # ExUnit starts isolated AuthorityStore fixtures through this child spec.
    # Mark that path explicitly so test stores can be resolved without the old
    # registered-name fallback. Production builds never add the marker.
    opts = test_fixture_child_opts(opts)

    # Child id is the registered name, not the module. Several stores run under
    # one supervisor; a module id would collide. Ownership proofs equate
    # Process.whereis(name) with the child pid listed under that same id.
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec authoritative_get(String.t(), keyword()) ::
          {:ok, Record.t()} | {:error, :not_found | atom()}
  def authoritative_get(key, opts),
    do: authoritative_call(opts, {:authoritative_get, key})

  @doc false
  def authoritative_entry(key, opts),
    do: authoritative_call(opts, {:authoritative_entry, key})

  @doc false
  def acknowledged_compare_and_create(key, expected, replacement, opts),
    do:
      authenticated_mutation_call(
        opts,
        {:acknowledged_compare_and_create, key, expected, replacement}
      )

  @spec authoritative_list(keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def authoritative_list(opts),
    do: authoritative_call(opts, {:authoritative_list, nil})

  @spec authoritative_entries(keyword()) ::
          {:ok, [{String.t(), Record.t()}]} | {:error, atom()}
  def authoritative_entries(opts), do: authoritative_call(opts, :authoritative_entries)

  @doc """
  Takes the validated startup entries, or a fresh complete bounded inventory.

  The startup set is handed off at most once. Later calls always perform a fresh
  complete read, as do first calls after any attempted owner mutation.
  """
  @spec take_hydrated_entries(keyword()) ::
          {:ok, [{String.t(), Record.t()}]} | {:error, atom()}
  def take_hydrated_entries(opts), do: authoritative_call(opts, :take_hydrated_entries)

  @spec put(String.t(), Record.t(), keyword()) :: :ok | {:error, atom()}
  def put(key, value, opts), do: authenticated_mutation_call(opts, {:put, key, value})

  @spec delete(String.t(), keyword()) :: :ok | {:error, atom()}
  def delete(key, opts), do: authenticated_mutation_call(opts, {:delete, key})

  @spec acknowledged_put(String.t(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, atom()}
  def acknowledged_put(key, value, opts),
    do: authenticated_mutation_call(opts, {:acknowledged_put, key, value})

  @spec acknowledged_delete(String.t(), keyword()) :: :ok | {:error, atom()}
  def acknowledged_delete(key, opts),
    do: authenticated_mutation_call(opts, {:acknowledged_delete, key})

  @spec acknowledged_compare_and_swap(String.t(), expected(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, atom()}
  def acknowledged_compare_and_swap(key, expected, replacement, opts),
    do:
      authenticated_mutation_call(
        opts,
        {:acknowledged_compare_and_swap, key, expected, replacement}
      )

  @spec acknowledged_compare_and_delete(String.t(), Record.t(), keyword()) ::
          :ok | {:error, atom()}
  def acknowledged_compare_and_delete(key, expected, opts),
    do: authenticated_mutation_call(opts, {:acknowledged_compare_and_delete, key, expected})

  @spec hydration_status(keyword()) :: {:ok, map()} | {:error, :store_unavailable}
  def hydration_status(opts), do: authoritative_call(opts, :hydration_status)

  @spec durability_class(keyword()) ::
          :volatile | :process_lifetime | :application_restart | :node_restart | :unknown
  def durability_class(opts) do
    case authoritative_call(opts, :durability_class) do
      class when class in @durability_classes -> class
      _ -> :unknown
    end
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, defer_hydration?} <- defer_hydration(opts),
         {:ok, supervisor_pid} <- maybe_startup_supervisor_pid(defer_hydration?),
         {:ok, state} <- build_state(opts, supervisor_pid) do
      :ok = maybe_register_test_fixture(state)

      cond do
        defer_hydration? and not SupervisedOwner.application_started?(:arbor_security) ->
          {:ok, %{state | initialization: :pending}}

        defer_hydration? ->
          {:ok, %{state | initialization: :pending}, {:continue, :hydrate}}

        true ->
          {:ok, state |> hydrate() |> Map.put(:initialization, :ready)}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:hydrate, state) do
    case finish_hydration(state) do
      {:ok, hydrated} -> {:noreply, hydrated}
      {:error, reason, failed} -> {:stop, reason, failed}
    end
  end

  @impl GenServer
  def handle_call({:startup_call, supervisor, :complete_startup}, _from, state) do
    case {startup_store?(state, supervisor), state.initialization} do
      {true, :pending} ->
        case finish_hydration(state) do
          {:ok, hydrated} -> {:reply, :ok, hydrated}
          {:error, reason, failed} -> {:stop, reason, {:error, reason}, failed}
        end

      {true, :ready} ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :invalid_authority_store_startup}, state}
    end
  end

  def handle_call({:startup_call, supervisor, request}, from, state) do
    if startup_store?(state, supervisor) and state.initialization == :ready and
         not mutation_request?(request) do
      handle_authoritative_call(request, from, state)
    else
      {:reply, {:error, :store_unavailable}, state}
    end
  end

  @impl GenServer
  def handle_call(:hydration_status, _from, state) do
    {:reply, {:ok, state.hydration_status}, state}
  end

  def handle_call(:durability_class, _from, state) do
    {:reply, state.durability_class, state}
  end

  # Hydration diagnostics remain readable after failure, but every authoritative
  # read and mutation below is poison-gated so partial inventory cannot escape.
  def handle_call(request, from, state) do
    cond do
      state.initialization != :ready ->
        {:reply, {:error, :store_unavailable}, state}

      poisoned?(state) ->
        {:reply, {:error, :hydration_unavailable}, state}

      mutation_request?(request) ->
        {:reply, {:error, :store_mutation_unauthorized}, state}

      true ->
        handle_authoritative_call(request, from, state)
    end
  end

  @impl GenServer
  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        {reply, state} =
          case request do
            {:startup_mutation, supervisor, mutation} ->
              dispatch_startup_mutation(supervisor, mutation, caller, state)

            _other ->
              dispatch_authenticated_mutation(request, caller, state)
          end

        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        {:noreply, state}
    end
  end

  defp handle_authoritative_call({:authoritative_get, key}, _from, state) do
    {:reply, get_record(state, key), state}
  end

  defp handle_authoritative_call(:durability_class, _from, state) do
    {:reply, state.durability_class, state}
  end

  defp handle_authoritative_call({:authoritative_entry, key}, _from, state) do
    {:reply, get_entry(state, key), state}
  end

  defp handle_authoritative_call(
         {:acknowledged_compare_and_create, key, expected, replacement},
         _from,
         state
       ) do
    state = invalidate_startup_entries(state)
    {reply, state} = compare_and_create(state, key, expected, replacement)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:authoritative_list, nil}, _from, state) do
    {:reply, list_records(state), state}
  end

  defp handle_authoritative_call(:authoritative_entries, _from, state) do
    {:reply, list_entries(state), state}
  end

  defp handle_authoritative_call(:take_hydrated_entries, _from, state) do
    case state.startup_entries do
      {:ready, entries} ->
        {:reply, {:ok, entries}, %{state | startup_entries: :refresh_required}}

      {:failed, reason} ->
        {:reply, {:error, reason}, state}

      :refresh_required ->
        {:reply, list_entries(state), state}
    end
  end

  defp handle_authoritative_call({:put, key, value}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_put(state, key, value, false)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:delete, key}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_delete(state, key, false)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:acknowledged_put, key, value}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_put(state, key, value, true)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:acknowledged_delete, key}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_delete(state, key, true)
    {:reply, reply, state}
  end

  defp handle_authoritative_call(
         {:acknowledged_compare_and_swap, key, expected, replacement},
         _from,
         state
       ) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_compare_and_swap(state, key, expected, replacement)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:acknowledged_compare_and_delete, key, expected}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_compare_and_delete(state, key, expected)
    {:reply, reply, state}
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) -> {:ok, name}
      {:ok, _invalid} -> {:error, :invalid_name}
      :error -> {:error, :name_required}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp store_name!(opts) do
    case fetch_name(opts) do
      {:ok, name} -> name
      {:error, reason} -> raise ArgumentError, "invalid AuthorityStore options: #{reason}"
    end
  end

  defp build_state(opts, supervisor_pid) do
    with {:ok, name} <- fetch_name(opts),
         {:ok, namespace} <- fetch_namespace(opts, name),
         {:ok, backend} <- fetch_backend(opts),
         :ok <- validate_backend(backend),
         {:ok, backend_opts} <- fetch_backend_opts(opts),
         {:ok, backend_opts} <- inject_jsonfile_root(backend, backend_opts),
         backend_opts <- put_startup_supervisor(backend_opts, supervisor_pid),
         {:ok, hydration_limit} <- fetch_hydration_limit(opts),
         {:ok, mutation_owners} <- fetch_mutation_owners(opts),
         {:ok, durability_class} <- resolve_durability(backend, backend_opts, namespace) do
      backend_custody =
        PrivateState.new(
          @backend_custody_anchor,
          @backend_custody_schema,
          Keyword.put(backend_opts, :name, namespace)
        )

      {:ok,
       %{
         name: name,
         namespace: namespace,
         backend: backend,
         backend_custody: backend_custody,
         hydration_limit: hydration_limit,
         mutation_owners: mutation_owners,
         test_isolated_owner: test_isolated_owner?(opts),
         security_supervisor_pid: supervisor_pid,
         authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
         initialization: :pending,
         persistence_mode: if(is_nil(backend), do: :ephemeral, else: :durable),
         durability_class: durability_class,
         entries: %{},
         startup_entries: {:failed, :not_hydrated},
         hydration_status: hydration_status(:unavailable, 0, hydration_limit, :not_hydrated)
       }}
    end
  end

  defp fetch_namespace(opts, name) do
    namespace =
      Keyword.get(opts, :namespace, Keyword.get(opts, :collection, Atom.to_string(name)))

    if (is_binary(namespace) and byte_size(namespace) > 0) or
         (is_atom(namespace) and not is_nil(namespace)) do
      {:ok, namespace}
    else
      {:error, :invalid_namespace}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp fetch_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      :error -> {:ok, JSONFile}
      {:ok, nil} -> {:ok, nil}
      {:ok, backend} when is_atom(backend) -> {:ok, backend}
      {:ok, _invalid} -> {:error, :invalid_backend}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp fetch_backend_opts(opts) do
    backend_opts = Keyword.get(opts, :backend_opts, [])

    if Keyword.keyword?(backend_opts),
      do: {:ok, backend_opts},
      else: {:error, :invalid_backend_opts}
  rescue
    _ -> {:error, :invalid_backend_opts}
  end

  defp fetch_mutation_owners(opts) do
    case Keyword.fetch(opts, :mutation_owners) do
      :error ->
        if @test_env, do: {:ok, :test_any}, else: {:error, :mutation_owners_required}

      {:ok, :any} ->
        if @test_env, do: {:ok, :test_any}, else: {:error, :invalid_mutation_owners}

      {:ok, owners} when is_list(owners) and owners != [] ->
        if Enum.all?(owners, &(&1 in @recognized_mutation_owners)),
          do: {:ok, MapSet.new(owners)},
          else: {:error, :invalid_mutation_owners}

      _invalid ->
        {:error, :invalid_mutation_owners}
    end
  rescue
    _ -> {:error, :invalid_mutation_owners}
  end

  defp defer_hydration(opts) when is_list(opts) do
    case Keyword.get(opts, :defer_hydration, false) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, :invalid_defer_hydration}
    end
  rescue
    _ -> {:error, :invalid_defer_hydration}
  end

  defp defer_hydration(_opts), do: {:error, :invalid_defer_hydration}

  defp maybe_startup_supervisor_pid(false), do: {:ok, nil}
  defp maybe_startup_supervisor_pid(true), do: startup_supervisor_pid()

  defp startup_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> linked_supervisor(pid)
      [name | _] when is_atom(name) -> name |> Process.whereis() |> linked_supervisor()
      _other -> {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(pid) when is_pid(pid) do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if pid in links, do: {:ok, pid}, else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  defp put_startup_supervisor(backend_opts, supervisor) when is_pid(supervisor),
    do: Keyword.put(backend_opts, :security_supervisor_pid, supervisor)

  defp put_startup_supervisor(backend_opts, _supervisor), do: backend_opts

  defp inject_jsonfile_root(nil, backend_opts), do: {:ok, backend_opts}

  defp inject_jsonfile_root(backend, backend_opts) when backend != JSONFile,
    do: {:ok, backend_opts}

  defp inject_jsonfile_root(JSONFile, backend_opts) do
    case Keyword.get(backend_opts, :base_dir) do
      dir when is_binary(dir) and byte_size(dir) > 0 ->
        if Path.type(dir) == :absolute do
          {:ok, backend_opts}
        else
          # Relative legacy values are config aliases, not per-store roots.
          put_frozen_jsonfile_root(backend_opts)
        end

      _missing ->
        put_frozen_jsonfile_root(backend_opts)
    end
  end

  defp put_frozen_jsonfile_root(backend_opts) do
    case Config.authority_root() do
      {:ok, root} -> {:ok, Keyword.put(backend_opts, :base_dir, root)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp poisoned?(%{persistence_mode: :durable, hydration_status: %{status: :failed}}), do: true
  defp poisoned?(_state), do: false

  defp mutation_request?({operation, _key, _value})
       when operation in [:put, :acknowledged_put],
       do: true

  defp mutation_request?({operation, _key}) when operation in [:delete, :acknowledged_delete],
    do: true

  defp mutation_request?({:acknowledged_compare_and_create, _key, _expected, _replacement}),
    do: true

  defp mutation_request?({:acknowledged_compare_and_swap, _key, _expected, _replacement}),
    do: true

  defp mutation_request?({:acknowledged_compare_and_delete, _key, _expected}), do: true
  defp mutation_request?(_request), do: false

  defp dispatch_authenticated_mutation(request, caller, state) do
    cond do
      state.initialization != :ready ->
        {{:error, :store_mutation_unauthorized}, state}

      poisoned?(state) ->
        {{:error, :hydration_unavailable}, state}

      not mutation_request?(request) ->
        {{:error, :store_mutation_unauthorized}, state}

      not mutation_authorized?(state, caller) ->
        {{:error, :store_mutation_unauthorized}, state}

      true ->
        case handle_authoritative_call(request, {caller, :authenticated}, state) do
          {:reply, reply, state} -> {reply, state}
        end
    end
  end

  defp dispatch_startup_mutation(supervisor, request, caller, state) do
    cond do
      not startup_store?(state, supervisor) or state.initialization != :ready ->
        {{:error, :store_mutation_unauthorized}, state}

      poisoned?(state) ->
        {{:error, :hydration_unavailable}, state}

      not mutation_request?(request) ->
        {{:error, :store_mutation_unauthorized}, state}

      not startup_mutation_authorized?(state, caller, supervisor) ->
        {{:error, :store_mutation_unauthorized}, state}

      true ->
        case handle_authoritative_call(request, {caller, :startup_authenticated}, state) do
          {:reply, reply, state} -> {reply, state}
        end
    end
  end

  if Mix.env() == :test do
    defp mutation_authorized?(%{mutation_owners: :test_any}, _caller), do: true
  end

  defp mutation_authorized?(%{mutation_owners: owners}, caller) when is_pid(caller) do
    Enum.any?(owners, fn
      Arbor.Security.SigningKeyStore.Owner ->
        Arbor.Security.SigningKeyStore.Owner.authorized_pid?(caller)

      owner when owner in @supervised_mutation_owners ->
        SupervisedOwner.authorized?(caller, :arbor_security, [owner])

      _unknown_owner ->
        false
    end)
  end

  defp mutation_authorized?(_state, _caller), do: false

  defp authenticated_mutation_call(opts, request) do
    Arbor.Common.authenticated_call(authoritative_store_pid(opts), request)
  end

  defp authoritative_call(opts, request) do
    case authoritative_store_pid(opts) do
      pid when is_pid(pid) -> GenServer.call(pid, request)
      nil -> {:error, :store_unavailable}
    end
  end

  defp authoritative_store_pid(opts) do
    name = store_name!(opts)

    SupervisedOwner.registered_child(name, :arbor_security, [name]) ||
      test_isolated_store_pid(name)
  end

  defp startup_authoritative_call(supervisor, opts, request) do
    with {:ok, timeout} <- Config.startup_timeout_ms() do
      startup_call(supervisor, store_name!(opts), request, timeout)
    end
  end

  defp startup_mutation_call(supervisor, opts, request) do
    name = store_name!(opts)

    with {:ok, timeout} <- Config.startup_timeout_ms() do
      case startup_store_pid(supervisor, name) do
        pid when is_pid(pid) ->
          Arbor.Common.authenticated_call(
            pid,
            {:startup_mutation, supervisor, request},
            timeout
          )

        nil ->
          {:error, :store_unavailable}
      end
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  defp startup_call(supervisor, name, request, timeout) do
    case startup_store_pid(supervisor, name) do
      pid when is_pid(pid) -> GenServer.call(pid, {:startup_call, supervisor, request}, timeout)
      nil -> {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :authority_store_startup_timeout}
    :exit, _ -> {:error, :store_unavailable}
  end

  defp startup_store_pid(supervisor, name) when is_pid(supervisor) and is_atom(name),
    do: SupervisedOwner.child_pid(supervisor, name)

  defp startup_store_pid(_supervisor, _name), do: nil

  defp startup_store?(state, supervisor) do
    is_pid(supervisor) and supervisor === state.security_supervisor_pid and
      SupervisedOwner.child_pid(supervisor, state.name) == self()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  if Mix.env() == :test do
    defp startup_mutation_authorized?(%{mutation_owners: :test_any}, _caller, _supervisor),
      do: true
  end

  defp startup_mutation_authorized?(%{mutation_owners: %MapSet{} = owners}, caller, supervisor)
       when is_pid(caller) do
    Enum.any?(owners, fn owner ->
      SupervisedOwner.child_pid(supervisor, owner) == caller
    end)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp startup_mutation_authorized?(_state, _caller, _supervisor), do: false

  if Mix.env() == :test do
    defp test_fixture_child_opts(opts), do: Keyword.put(opts, :test_isolated_owner, true)
    defp test_isolated_owner?(opts), do: Keyword.get(opts, :test_isolated_owner, false) == true

    defp maybe_register_test_fixture(%{name: name, test_isolated_owner: true}) do
      :persistent_term.put({@test_fixture_anchor, name}, self())
      :ok
    end

    defp maybe_register_test_fixture(_state), do: :ok

    defp test_isolated_store_pid(name) do
      case :persistent_term.get({@test_fixture_anchor, name}, nil) do
        pid when is_pid(pid) ->
          if Process.alive?(pid) and Process.whereis(name) == pid, do: pid, else: nil

        _ ->
          nil
      end
    end

    defp clear_test_fixture(%{name: name, test_isolated_owner: true}) do
      key = {@test_fixture_anchor, name}

      if :persistent_term.get(key, nil) == self(), do: :persistent_term.erase(key)
      :ok
    end

    defp clear_test_fixture(_state), do: :ok
  else
    defp test_fixture_child_opts(opts), do: opts
    defp test_isolated_owner?(_opts), do: false
    defp maybe_register_test_fixture(_state), do: :ok
    defp test_isolated_store_pid(_name), do: nil
    defp clear_test_fixture(_state), do: :ok
  end

  defp fetch_hydration_limit(opts) do
    case Keyword.get(opts, :hydration_limit, @default_hydration_limit) do
      limit when is_integer(limit) and limit > 0 ->
        {:ok, limit}

      _invalid ->
        {:error, :invalid_hydration_limit}
    end
  rescue
    _ -> {:error, :invalid_hydration_limit}
  end

  defp validate_backend(nil), do: :ok

  defp validate_backend(backend) do
    if Code.ensure_loaded?(backend) do
      case Enum.find(@required_callbacks, fn {fun, arity} ->
             not function_exported?(backend, fun, arity)
           end) do
        nil -> :ok
        {fun, arity} -> {:error, {:missing_backend_callback, fun, arity}}
      end
    else
      {:error, :backend_unavailable}
    end
  end

  defp resolve_durability(nil, _backend_opts, _namespace), do: {:ok, :process_lifetime}

  defp resolve_durability(backend, backend_opts, namespace) do
    if function_exported?(backend, :durability_class, 1) do
      case guarded_backend(fn ->
             backend.durability_class(Keyword.put(backend_opts, :name, namespace))
           end) do
        {:returned, class} when class in @durability_classes -> {:ok, class}
        {:returned, _malformed} -> {:error, :invalid_backend_response}
        :aborted -> {:error, :backend_unavailable}
      end
    else
      {:ok, :unknown}
    end
  end

  defp hydrate(%{backend: nil, hydration_limit: limit} = state) do
    %{
      state
      | startup_entries: {:ready, []},
        hydration_status: hydration_status(:ready, 0, limit, :ok)
    }
  end

  defp hydrate(state) do
    case list_entries(state) do
      {:ok, entries} ->
        %{
          state
          | startup_entries: {:ready, entries},
            hydration_status:
              hydration_status(:ready, length(entries), state.hydration_limit, :ok)
        }

      {:error, reason} ->
        %{
          state
          | startup_entries: {:failed, reason},
            hydration_status: hydration_status(:failed, 0, state.hydration_limit, reason)
        }
    end
  end

  defp finish_hydration(state) do
    hydrated = state |> hydrate() |> Map.put(:initialization, :ready)

    case hydrated.hydration_status do
      %{status: :ready} -> {:ok, hydrated}
      %{reason: reason} -> {:error, {:authority_store_hydration_failed, reason}, hydrated}
      _other -> {:error, {:authority_store_hydration_failed, :unknown}, hydrated}
    end
  end

  defp invalidate_startup_entries(state), do: %{state | startup_entries: :refresh_required}

  defp hydration_status(status, loaded_count, limit, reason) do
    %{
      status: status,
      loaded_count: loaded_count,
      configured_limit: limit,
      reason: reason
    }
  end

  defp get_record(_state, key) when not is_binary(key), do: {:error, :invalid_key}

  defp get_record(%{backend: nil, entries: entries}, key) do
    entries
    |> Map.get(key, :absent)
    |> Revision.live_value()
    |> normalize_live_value(key)
  end

  defp get_record(state, key) do
    case guarded_backend(fn -> state.backend.get(key, backend_opts!(state)) end) do
      {:returned, {:ok, %Record{} = record}} -> validate_record(key, record)
      {:returned, {:ok, _malformed}} -> {:error, :invalid_backend_response}
      {:returned, {:error, :not_found}} -> {:error, :not_found}
      {:returned, {:error, reason}} when reason in @storage_integrity_errors -> {:error, reason}
      {:returned, {:error, _reason}} -> {:error, :backend_unavailable}
      {:returned, _malformed} -> {:error, :invalid_backend_response}
      :aborted -> {:error, :backend_unavailable}
    end
  end

  defp normalize_live_value({:ok, %Record{} = record}, key), do: validate_record(key, record)
  defp normalize_live_value({:ok, _malformed}, _key), do: {:error, :invalid_backend_response}
  defp normalize_live_value(:not_found, _key), do: {:error, :not_found}

  defp get_entry(_state, key) when not is_binary(key), do: {:error, :invalid_key}

  defp get_entry(%{backend: nil, entries: entries}, key),
    do: {:ok, Map.get(entries, key, :absent)}

  defp get_entry(state, key) do
    if function_exported?(state.backend, :authoritative_entry, 2) do
      case guarded_backend(fn -> state.backend.authoritative_entry(key, backend_opts!(state)) end) do
        {:returned, {:ok, entry}} -> validate_entry(key, entry)
        {:returned, {:error, reason}} when reason in @storage_integrity_errors -> {:error, reason}
        _ -> {:error, :backend_unavailable}
      end
    else
      {:error, :unsupported}
    end
  end

  defp validate_entry(_key, :absent), do: {:ok, :absent}

  defp validate_entry(_key, {:tombstone, generation} = entry)
       when is_integer(generation) and generation > 0 and generation < 9_007_199_254_740_991,
       do: {:ok, entry}

  defp validate_entry(key, %Record{} = record), do: validate_record(key, record)
  defp validate_entry(_key, _entry), do: {:error, :invalid_backend_response}

  defp validate_record(key, %Record{} = record) do
    if Revision.key_mismatch?(key, record),
      do: {:error, :key_mismatch},
      else: {:ok, record}
  end

  defp list_records(%{backend: nil, entries: entries, hydration_limit: limit}) do
    entries
    |> Enum.reduce([], fn {key, entry}, acc ->
      if match?({:ok, %Record{}}, Revision.live_value(entry)), do: [key | acc], else: acc
    end)
    |> validate_keys(limit)
  end

  defp list_records(state), do: backend_list(state)

  defp list_entries(state) do
    with {:ok, keys} <- list_records(state),
         {:ok, entries} <- fetch_entries(state, keys) do
      {:ok, entries}
    end
  end

  defp backend_list(state) do
    case guarded_backend(fn -> call_bounded_list(state) end) do
      {:returned, {:ok, keys}} ->
        validate_keys(keys, state.hydration_limit)

      {:returned, {:error, :inventory_limit_exceeded}} ->
        {:error, :hydration_limit_exceeded}

      {:returned, {:error, :bounded_inventory_unsupported}} ->
        {:error, :bounded_inventory_unsupported}

      {:returned, {:error, reason}} when reason in @storage_integrity_errors ->
        {:error, reason}

      {:returned, {:error, _reason}} ->
        {:error, :backend_unavailable}

      {:returned, _malformed} ->
        {:error, :invalid_backend_response}

      :aborted ->
        {:error, :backend_unavailable}
    end
  end

  defp call_bounded_list(state) do
    cond do
      function_exported?(state.backend, :bounded_list, 2) ->
        state.backend.bounded_list(state.hydration_limit, backend_opts!(state))

      state.hydration_limit <= @default_hydration_limit ->
        state.backend.list(
          Keyword.put(backend_opts!(state), :authoritative_limit, state.hydration_limit)
        )

      true ->
        {:error, :bounded_inventory_unsupported}
    end
  end

  defp validate_keys(keys, limit), do: validate_keys(keys, limit, MapSet.new(), [], 0)

  defp validate_keys([], _limit, _seen, acc, _count), do: {:ok, Enum.sort(acc)}

  defp validate_keys([key | rest], limit, seen, acc, count) when is_binary(key) do
    cond do
      count >= limit ->
        {:error, :hydration_limit_exceeded}

      MapSet.member?(seen, key) ->
        {:error, :invalid_backend_response}

      true ->
        validate_keys(rest, limit, MapSet.put(seen, key), [key | acc], count + 1)
    end
  end

  defp validate_keys([_malformed | _rest], _limit, _seen, _acc, _count),
    do: {:error, :invalid_backend_response}

  defp validate_keys(_improper, _limit, _seen, _acc, _count),
    do: {:error, :invalid_backend_response}

  defp fetch_entries(state, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case get_record(state, key) do
        {:ok, record} -> {:cont, {:ok, [{key, record} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp do_put(state, key, value, acknowledged?) do
    with :ok <- validate_mutation(key, value) do
      case state.persistence_mode do
        :ephemeral -> ephemeral_put(state, key, value, acknowledged?)
        :durable -> durable_put(state, key, value, acknowledged?)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_put(state, key, value, acknowledged?) do
    with :ok <- ensure_ephemeral_capacity(state, key),
         {:ok, stored} <- apply_ephemeral_put(state.entries, key, value) do
      state = %{state | entries: Map.put(state.entries, key, stored)}
      reply = if acknowledged?, do: {:ok, stored}, else: :ok
      {reply, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_ephemeral_put(entries, key, replacement) do
    case Map.fetch(entries, key) do
      {:ok, %Record{} = current} ->
        Revision.advance_cas_update(current, replacement)

      {:ok, {:tombstone, generation}} ->
        {:ok, Revision.advance_cas_insert_from_tombstone(generation, replacement)}

      :error ->
        {:ok, Revision.advance_ephemeral_insert(replacement)}
    end
  end

  defp durable_put(state, key, value, acknowledged?) do
    case guarded_backend(fn -> state.backend.put(key, value, backend_opts!(state)) end) do
      {:returned, :ok} when acknowledged? ->
        case get_record(state, key) do
          {:ok, stored} -> {{:ok, stored}, state}
          {:error, _reason} -> {{:error, :outcome_unknown}, state}
        end

      {:returned, :ok} ->
        {:ok, state}

      {:returned, {:error, :key_mismatch}} ->
        {{:error, :key_mismatch}, state}

      {:returned, {:error, _reason}} when acknowledged? ->
        {{:error, :outcome_unknown}, state}

      {:returned, {:error, _reason}} ->
        {{:error, :backend_unavailable}, state}

      {:returned, _malformed} when acknowledged? ->
        {{:error, :outcome_unknown}, state}

      {:returned, _malformed} ->
        {{:error, :invalid_backend_response}, state}

      :aborted when acknowledged? ->
        {{:error, :outcome_unknown}, state}

      :aborted ->
        {{:error, :backend_unavailable}, state}
    end
  end

  defp do_delete(state, key, _acknowledged?) when not is_binary(key),
    do: {{:error, :invalid_key}, state}

  defp do_delete(%{persistence_mode: :ephemeral} = state, key, _acknowledged?) do
    {:ok, retain_ephemeral_tombstone(state, key)}
  end

  defp do_delete(state, key, acknowledged?) do
    case guarded_backend(fn -> state.backend.delete(key, backend_opts!(state)) end) do
      {:returned, :ok} -> {:ok, state}
      {:returned, _other} when acknowledged? -> {{:error, :outcome_unknown}, state}
      {:returned, {:error, _reason}} -> {{:error, :backend_unavailable}, state}
      {:returned, _malformed} -> {{:error, :invalid_backend_response}, state}
      :aborted when acknowledged? -> {{:error, :outcome_unknown}, state}
      :aborted -> {{:error, :backend_unavailable}, state}
    end
  end

  defp do_compare_and_swap(state, key, expected, replacement) do
    with :ok <- validate_mutation(key, replacement),
         :ok <- validate_expected(key, expected) do
      case state.persistence_mode do
        :ephemeral -> ephemeral_compare_and_swap(state, key, expected, replacement)
        :durable -> durable_compare_and_swap(state, key, expected, replacement)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_compare_and_swap(state, key, expected, replacement) do
    current = Map.get(state.entries, key, :absent)

    with :ok <- ensure_ephemeral_capacity(state, key),
         {:ok, stored} <- ephemeral_cas(current, expected, replacement) do
      {{:ok, stored}, %{state | entries: Map.put(state.entries, key, stored)}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_cas(:absent, :not_found, replacement),
    do: {:ok, Revision.advance_ephemeral_insert(replacement)}

  defp ephemeral_cas({:tombstone, generation}, :not_found, replacement),
    do: {:ok, Revision.advance_cas_insert_from_tombstone(generation, replacement)}

  defp ephemeral_cas(%Record{} = current, {:value, expected}, replacement) do
    if Revision.cas_matches?(current, expected),
      do: Revision.advance_cas_update(current, replacement),
      else: {:error, :conflict}
  end

  defp ephemeral_cas(_current, {:value, _expected}, _replacement), do: {:error, :conflict}
  defp ephemeral_cas(_current, :not_found, _replacement), do: {:error, :conflict}

  defp ensure_ephemeral_capacity(state, key) do
    if Map.has_key?(state.entries, key) or map_size(state.entries) < state.hydration_limit do
      :ok
    else
      {:error, :inventory_limit_exceeded}
    end
  end

  defp durable_compare_and_swap(state, key, expected, replacement) do
    if function_exported?(state.backend, :compare_and_swap, 4) do
      case guarded_backend(fn ->
             state.backend.compare_and_swap(key, expected, replacement, backend_opts!(state))
           end) do
        {:returned, {:ok, %Record{} = stored}} ->
          case validate_record(key, stored) do
            {:ok, valid} -> {{:ok, valid}, state}
            {:error, _reason} -> {{:error, :outcome_unknown}, state}
          end

        {:returned, {:ok, _malformed}} ->
          {{:error, :outcome_unknown}, state}

        {:returned, {:error, :conflict}} ->
          {{:error, :conflict}, state}

        {:returned, {:error, :key_mismatch}} ->
          {{:error, :key_mismatch}, state}

        {:returned, _other} ->
          {{:error, :outcome_unknown}, state}

        :aborted ->
          {{:error, :outcome_unknown}, state}
      end
    else
      {{:error, :unsupported}, state}
    end
  end

  defp compare_and_create(state, key, expected, replacement) do
    with :ok <- validate_mutation(key, replacement),
         :ok <- validate_creation_fence(expected) do
      create_for_mode(state, key, expected, replacement)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp validate_creation_fence(:absent), do: :ok

  defp validate_creation_fence({:tombstone, generation})
       when is_integer(generation) and generation > 0 and generation < 9_007_199_254_740_991,
       do: :ok

  defp validate_creation_fence(_), do: {:error, :invalid_expected}

  defp create_for_mode(%{backend: nil} = state, key, expected, replacement) do
    with :ok <- ensure_ephemeral_capacity(state, key),
         true <- Map.get(state.entries, key, :absent) == expected do
      stored =
        case expected do
          :absent ->
            Revision.advance_cas_insert(replacement)

          {:tombstone, generation} ->
            Revision.advance_cas_insert_from_tombstone(generation, replacement)
        end

      {{:ok, stored}, %{state | entries: Map.put(state.entries, key, stored)}}
    else
      false -> {{:error, :conflict}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp create_for_mode(state, key, expected, replacement) do
    if function_exported?(state.backend, :compare_and_create, 4) do
      reply =
        case guarded_backend(fn ->
               state.backend.compare_and_create(key, expected, replacement, backend_opts!(state))
             end) do
          {:returned, {:ok, %Record{} = stored}} -> validate_record(key, stored)
          {:returned, {:error, :conflict}} -> {:error, :conflict}
          _ -> {:error, :outcome_unknown}
        end

      {reply, state}
    else
      {{:error, :unsupported}, state}
    end
  end

  defp do_compare_and_delete(state, key, expected) do
    with :ok <- validate_expected_record(key, expected) do
      case state.persistence_mode do
        :ephemeral -> ephemeral_compare_and_delete(state, key, expected)
        :durable -> durable_compare_and_delete(state, key, expected)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_compare_and_delete(state, key, expected) do
    case Map.get(state.entries, key, :absent) do
      %Record{} = current ->
        if Revision.cas_matches?(current, expected) do
          {:ok, retain_ephemeral_tombstone(state, key)}
        else
          {{:error, :conflict}, state}
        end

      _other ->
        {{:error, :conflict}, state}
    end
  end

  defp retain_ephemeral_tombstone(state, key) do
    case Revision.to_tombstone(Map.get(state.entries, key, :absent)) do
      :absent -> state
      tombstone -> %{state | entries: Map.put(state.entries, key, tombstone)}
    end
  end

  defp durable_compare_and_delete(state, key, expected) do
    if function_exported?(state.backend, :compare_and_delete, 3) do
      case guarded_backend(fn ->
             state.backend.compare_and_delete(key, expected, backend_opts!(state))
           end) do
        {:returned, :ok} -> {:ok, state}
        {:returned, {:error, :conflict}} -> {{:error, :conflict}, state}
        {:returned, {:error, :key_mismatch}} -> {{:error, :key_mismatch}, state}
        {:returned, _other} -> {{:error, :outcome_unknown}, state}
        :aborted -> {{:error, :outcome_unknown}, state}
      end
    else
      {{:error, :unsupported}, state}
    end
  end

  defp validate_mutation(key, %Record{} = record) when is_binary(key) do
    if Revision.key_mismatch?(key, record), do: {:error, :key_mismatch}, else: :ok
  end

  defp validate_mutation(key, _record) when not is_binary(key), do: {:error, :invalid_key}
  defp validate_mutation(_key, _record), do: {:error, :unsupported_value}

  defp validate_expected(_key, :not_found), do: :ok

  defp validate_expected(key, {:value, %Record{} = record}),
    do: validate_expected_record(key, record)

  defp validate_expected(_key, _expected), do: {:error, :invalid_expected}

  defp validate_expected_record(key, %Record{} = record) when is_binary(key) do
    if Revision.key_mismatch?(key, record), do: {:error, :key_mismatch}, else: :ok
  end

  defp validate_expected_record(key, _record) when not is_binary(key), do: {:error, :invalid_key}
  defp validate_expected_record(_key, _record), do: {:error, :invalid_expected}

  @impl true
  def terminate(_reason, state) do
    clear_test_fixture(state)
    PrivateState.delete(Map.get(state, :backend_custody), @backend_custody_anchor)
    :ok
  end

  defp backend_opts!(%{backend_custody: custody}) do
    case PrivateState.fetch(
           custody,
           @backend_custody_anchor,
           @backend_custody_schema,
           &valid_backend_custody?/1
         ) do
      {:ok, opts} -> opts
      {:error, _reason} -> raise "invalid authority store backend custody"
    end
  end

  defp backend_opts!(_state), do: raise("invalid authority store backend custody")

  defp valid_backend_custody?(opts) when is_list(opts), do: Keyword.keyword?(opts)
  defp valid_backend_custody?(_opts), do: false

  defp guarded_backend(fun) do
    {:returned, fun.()}
  rescue
    _ -> :aborted
  catch
    _, _ -> :aborted
  end
end
