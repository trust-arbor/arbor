defmodule Arbor.AI.AcpManagedSessionRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpManaged.Supervisor, as: ManagedSupervisor
  alias Arbor.AI.Application, as: AIApplication

  @moduletag :fast

  # -- Fakes ----------------------------------------------------------------

  defmodule FakeSession do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      if delay = Keyword.get(opts, :start_delay_ms) do
        if test_pid = Keyword.get(opts, :test_pid),
          do: send(test_pid, {:fake_start_stalled, self(), delay})

        Process.sleep(delay)
      end

      GenServer.start_link(__MODULE__, opts)
    end

    def create_session(pid, opts \\ []) do
      GenServer.call(pid, {:create_session, opts})
    end

    def resume_session(pid, session_id, opts \\ []) do
      GenServer.call(pid, {:resume_session, session_id, opts})
    end

    def send_message(pid, content, opts \\ []) do
      GenServer.call(pid, {:send_message, content, opts}, :infinity)
    end

    def status(pid) do
      # Failures are simulated on the client side so the session process stays
      # alive (mirrors a busy-prompt status timeout / transient call failure).
      case GenServer.call(pid, :status) do
        {:__status_fail__, :raise} -> raise "fake status boom"
        {:__status_fail__, :exit} -> exit(:fake_status_exit)
        {:__status_fail__, :error} -> exit(:status_call_failed)
        other -> other
      end
    end

    # Mirrors AcpSession.context_pressure?/1 for managed status fallback.
    def context_pressure?(pid) do
      GenServer.call(pid, :context_pressure?)
    end

    def close(pid) do
      GenServer.call(pid, :close)
    end

    @impl true
    def init(opts) do
      if delay = Keyword.get(opts, :init_delay_ms) do
        if test_pid = Keyword.get(opts, :test_pid),
          do: send(test_pid, {:fake_init_stalled, self(), delay})

        Process.sleep(delay)
      end

      # Mirror AcpSession: honor explicit owner (registry/facade sets it).
      owner = Keyword.get(opts, :owner, self())
      owner_ref = if is_pid(owner), do: Process.monitor(owner), else: nil
      test_pid = Keyword.get(opts, :test_pid)
      agent_id = Keyword.get(opts, :agent_id)

      if test_pid do
        send(test_pid, {:fake_init, self(), agent_id, opts})
      end

      {:ok,
       %{
         owner: owner,
         owner_ref: owner_ref,
         test_pid: test_pid,
         agent_id: agent_id,
         create_mode: Keyword.get(opts, :create_mode, :ok),
         create_delay_ms: Keyword.get(opts, :create_delay_ms, 0),
         resume_mode: Keyword.get(opts, :resume_mode, :ok),
         status_mode: Keyword.get(opts, :status_mode, :ok),
         close_mode: Keyword.get(opts, :close_mode, :ok),
         # Backward-compatible flag used by older tests
         fail_create?: Keyword.get(opts, :fail_create, false),
         provider: Keyword.get(opts, :provider, :test),
         model: Keyword.get(opts, :model),
         session_id: nil,
         status: :ready,
         closed: false,
         context_tokens: Keyword.get(opts, :context_tokens, 0),
         usage: Keyword.get(opts, :usage, %{}),
         # :unset means omit from status map so managed status uses context_pressure?/1
         status_context_pressure: Keyword.get(opts, :status_context_pressure, :unset),
         pressure?: Keyword.get(opts, :pressure?, false)
       }}
    end

    @impl true
    def handle_call({:create_session, opts}, _from, state) do
      if state.test_pid, do: send(state.test_pid, {:fake_create_opts, self(), opts})
      if state.create_delay_ms > 0, do: Process.sleep(state.create_delay_ms)

      mode =
        cond do
          state.fail_create? -> :error
          true -> state.create_mode
        end

      case mode do
        :ok ->
          sid = "prov_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
          state = %{state | session_id: sid, status: :ready}
          {:reply, {:ok, %{"sessionId" => sid}}, state}

        :error ->
          {:reply, {:error, :create_failed}, %{state | status: :error}}

        :raise ->
          raise "fake create boom"

        :unexpected ->
          {:reply, :not_a_result_tuple, state}

        :exit ->
          exit(:fake_create_exit)
      end
    end

    def handle_call({:resume_session, session_id, _opts}, _from, state) do
      case state.resume_mode do
        :ok ->
          state = %{state | session_id: session_id, status: :ready}
          {:reply, {:ok, %{"sessionId" => session_id}}, state}

        :error ->
          {:reply, {:error, :resume_failed}, %{state | status: :error}}

        :raise ->
          raise "fake resume boom"

        :unexpected ->
          {:reply, :not_a_result_tuple, state}

        :exit ->
          exit(:fake_resume_exit)
      end
    end

    def handle_call({:send_message, content, opts}, {from_pid, _tag}, state) do
      if state.test_pid do
        send(state.test_pid, {:fake_send, from_pid, content, self(), opts, state.agent_id})
      end

      {:reply,
       {:ok,
        %{
          "text" => "echo:#{content}",
          "from_pid" => inspect(from_pid),
          "agent_id" => state.agent_id
        }}, state}
    end

    def handle_call(:status, _from, state) do
      case state.status_mode do
        :ok ->
          info = %{
            provider: state.provider,
            model: state.model,
            session_id: state.session_id,
            status: state.status,
            context_tokens: state.context_tokens,
            usage: state.usage
          }

          info =
            case state.status_context_pressure do
              :unset -> info
              pressure -> Map.put(info, :context_pressure, pressure)
            end

          {:reply, info, state}

        mode when mode in [:error, :raise, :exit] ->
          # Keep the GenServer alive; client-side status/1 will fail.
          {:reply, {:__status_fail__, mode}, state}
      end
    end

    def handle_call(:context_pressure?, _from, state) do
      {:reply, state.pressure? == true, state}
    end

    def handle_call(:close, _from, state) do
      if state.test_pid, do: send(state.test_pid, {:fake_close, self()})

      case state.close_mode do
        :stall ->
          if state.test_pid, do: send(state.test_pid, {:fake_close_stalled, self()})
          Process.sleep(:infinity)

        _other ->
          {:stop, :normal, :ok, %{state | status: :closed, closed: true}}
      end
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
      if state.test_pid, do: send(state.test_pid, {:fake_owner_down, self()})
      {:stop, :normal, %{state | status: :closed}}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  defmodule SlowRegistry do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:register, attrs}, _from, opts), do: delayed_register(attrs, opts)
    def handle_call({:register, attrs, _deadline}, _from, opts), do: delayed_register(attrs, opts)

    defp delayed_register(attrs, opts) do
      Process.sleep(Keyword.fetch!(opts, :delay_ms))
      send(Keyword.fetch!(opts, :test_pid), {:slow_registry_register, attrs})

      view = %{
        worker_session_id: "acp_worker_slow",
        session_id: attrs.session_id,
        provider: to_string(attrs.provider),
        model: attrs.model,
        status: "ready",
        pooled: attrs.pooled == true
      }

      {:reply, {:ok, view}, opts}
    end
  end

  # Session module without context_pressure?/1 so managed status fails closed.
  defmodule FakeSessionNoPressure do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def create_session(pid, opts \\ []), do: GenServer.call(pid, {:create_session, opts})

    def resume_session(pid, sid, opts \\ []),
      do: GenServer.call(pid, {:resume_session, sid, opts})

    def send_message(pid, content, opts \\ []),
      do: GenServer.call(pid, {:send_message, content, opts})

    def status(pid), do: GenServer.call(pid, :status)
    def close(pid), do: GenServer.call(pid, :close)

    @impl true
    def init(opts) do
      {:ok,
       %{
         owner: Keyword.get(opts, :owner, self()),
         provider: Keyword.get(opts, :provider, :test),
         model: Keyword.get(opts, :model),
         session_id: nil,
         status: :ready,
         context_tokens: Keyword.get(opts, :context_tokens, 42),
         usage: Keyword.get(opts, :usage, %{"input" => 1})
       }}
    end

    @impl true
    def handle_call({:create_session, _opts}, _from, state) do
      sid = "prov_np_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
      {:reply, {:ok, %{"sessionId" => sid}}, %{state | session_id: sid}}
    end

    def handle_call({:resume_session, session_id, _opts}, _from, state) do
      {:reply, {:ok, %{"sessionId" => session_id}}, %{state | session_id: session_id}}
    end

    def handle_call({:send_message, content, _opts}, _from, state) do
      {:reply, {:ok, %{"text" => content}}, state}
    end

    def handle_call(:status, _from, state) do
      {:reply,
       %{
         provider: state.provider,
         model: state.model,
         session_id: state.session_id,
         status: state.status,
         context_tokens: state.context_tokens,
         usage: state.usage
       }, state}
    end

    def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}
  end

  defmodule FakePool do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def checkout(provider, opts \\ []) do
      server = Keyword.get(opts, :pool_server, __MODULE__)
      GenServer.call(server, {:checkout, provider, opts})
    end

    def checkin(session_pid) do
      GenServer.call(__MODULE__, {:checkin, session_pid})
    end

    def close_session(session_pid) do
      GenServer.call(__MODULE__, {:close_session, session_pid})
    end

    def status do
      GenServer.call(__MODULE__, :status)
    end

    @impl true
    def init(opts) do
      # Sessions are started with start_link; trap exits so a crashing session
      # during create/resume failure cleanup does not take the pool down.
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         sessions: %{},
         checked_out: MapSet.new(),
         test_pid: Keyword.get(opts, :test_pid),
         session_module: Keyword.get(opts, :session_module, FakeSession),
         # Optional defaults for sessions started by the pool
         session_opts: Keyword.get(opts, :session_opts, [])
       }}
    end

    # Mirror real AcpPool: pool-only opts scope checkout but must not reach AcpSession.
    @pool_only_opts [
      :tool_modules,
      :trust_domain,
      :affinity_key,
      :name,
      :tags,
      :task_id,
      :principal_id,
      :use_pool,
      :pooled,
      :return_to_pool,
      :pool_module,
      :session_module,
      :create_session,
      :session_id,
      :server,
      :pool_server
    ]

    @impl true
    def handle_call({:checkout, provider, opts}, {caller, _}, state) do
      session_mod = state.session_module

      if state.test_pid, do: send(state.test_pid, {:pool_checkout_opts, provider, opts, caller})

      session_opts =
        state.session_opts
        |> Keyword.merge(opts)
        |> Keyword.put(:provider, provider)
        |> Keyword.put_new(:owner, caller)
        |> Keyword.put_new(:test_pid, state.test_pid)
        |> Keyword.drop(@pool_only_opts)

      case session_mod.start_link(session_opts) do
        {:ok, pid} ->
          # Pooled sessions are typically pre-created (unless tests override create_mode)
          unless Keyword.get(session_opts, :skip_pool_precreate, false) do
            _ = safe_precreate(session_mod, pid)
          end

          owner_ref = Process.monitor(caller)
          session_ref = Process.monitor(pid)

          state = %{
            state
            | sessions:
                Map.put(state.sessions, pid, %{
                  owner: caller,
                  owner_ref: owner_ref,
                  session_ref: session_ref,
                  checkout_opts: opts
                }),
              checked_out: MapSet.put(state.checked_out, pid)
          }

          if state.test_pid, do: send(state.test_pid, {:pool_checkout, pid, caller})
          {:reply, {:ok, pid}, state}

        error ->
          {:reply, error, state}
      end
    end

    def handle_call({:checkin, session_pid}, _from, state) do
      if state.test_pid, do: send(state.test_pid, {:pool_checkin, session_pid})

      case Map.pop(state.sessions, session_pid) do
        {nil, _} ->
          {:reply, {:error, :not_found}, state}

        {%{owner_ref: owner_ref, session_ref: session_ref}, sessions} ->
          Process.demonitor(owner_ref, [:flush])
          Process.demonitor(session_ref, [:flush])

          state = %{
            state
            | sessions: sessions,
              checked_out: MapSet.delete(state.checked_out, session_pid)
          }

          {:reply, :ok, state}
      end
    end

    def handle_call({:close_session, session_pid}, _from, state) do
      if state.test_pid, do: send(state.test_pid, {:pool_close_session, session_pid})

      case Map.pop(state.sessions, session_pid) do
        {nil, _} ->
          # Still try to stop the process if alive
          if is_pid(session_pid) and Process.alive?(session_pid) do
            safe_close_session(state.session_module, session_pid)
          end

          {:reply, :ok, state}

        {%{owner_ref: owner_ref, session_ref: session_ref}, sessions} ->
          Process.demonitor(owner_ref, [:flush])
          Process.demonitor(session_ref, [:flush])
          safe_close_session(state.session_module, session_pid)

          state = %{
            state
            | sessions: sessions,
              checked_out: MapSet.delete(state.checked_out, session_pid)
          }

          {:reply, :ok, state}
      end
    end

    def handle_call(:status, _from, state) do
      {:reply,
       %{
         checked_out: MapSet.size(state.checked_out),
         total: map_size(state.sessions)
       }, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
      case Enum.find(state.sessions, fn {_spid, meta} ->
             meta.owner_ref == ref or meta.session_ref == ref
           end) do
        {session_pid, meta} ->
          kind = if meta.owner_ref == ref, do: :owner, else: :session

          if state.test_pid do
            case kind do
              :owner -> send(state.test_pid, {:pool_auto_checkin, session_pid})
              :session -> send(state.test_pid, {:pool_session_died, session_pid, pid})
            end
          end

          Process.demonitor(meta.owner_ref, [:flush])
          Process.demonitor(meta.session_ref, [:flush])

          state = %{
            state
            | sessions: Map.delete(state.sessions, session_pid),
              checked_out: MapSet.delete(state.checked_out, session_pid)
          }

          {:noreply, state}

        nil ->
          {:noreply, state}
      end
    end

    def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

    def handle_info(_msg, state), do: {:noreply, state}

    defp safe_precreate(session_mod, pid) do
      try do
        session_mod.create_session(pid)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    defp safe_close_session(session_mod, pid) do
      try do
        if function_exported?(session_mod, :close, 1) and Process.alive?(pid) do
          session_mod.close(pid)
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # -- Setup ----------------------------------------------------------------

  setup do
    registry_name = :"acp_managed_reg_#{System.unique_integer([:positive])}"
    supervisor_name = :"acp_managed_sup_#{System.unique_integer([:positive])}"

    start_supervised!({ManagedSupervisor, name: supervisor_name})
    start_supervised!({SessionRegistry, name: registry_name})

    {:ok,
     registry: registry_name,
     supervisor: supervisor_name,
     base_opts: [
       session_module: FakeSession,
       supervisor: supervisor_name,
       server: registry_name,
       test_pid: self()
     ]}
  end

  # -- Helpers --------------------------------------------------------------

  defp start_managed(provider \\ :test, opts, ctx) do
    AI.acp_managed_start_session(provider, Keyword.merge(ctx.base_opts, opts))
  end

  defp json_clean?(term) do
    case Jason.encode(term) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp refute_pid_like(term) do
    refute contains_pid_or_ref?(term)
  end

  defp contains_pid_or_ref?(term) when is_pid(term) or is_reference(term) or is_function(term),
    do: true

  defp contains_pid_or_ref?(%_{} = struct), do: contains_pid_or_ref?(Map.from_struct(struct))

  defp contains_pid_or_ref?(map) when is_map(map),
    do:
      Enum.any?(map, fn {k, v} ->
        contains_pid_or_ref?(k) or contains_pid_or_ref?(v)
      end)

  defp contains_pid_or_ref?(list) when is_list(list), do: Enum.any?(list, &contains_pid_or_ref?/1)

  defp contains_pid_or_ref?(tuple) when is_tuple(tuple),
    do: contains_pid_or_ref?(Tuple.to_list(tuple))

  defp contains_pid_or_ref?(_), do: false

  defp assert_eventually(fun, attempts \\ 50) do
    fun.()
  rescue
    e in [ExUnit.AssertionError, MatchError] ->
      if attempts <= 1 do
        reraise e, __STACKTRACE__
      else
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
      end
  end

  defp assert_supervisor_empty(supervisor) do
    assert_eventually(fn ->
      assert DynamicSupervisor.which_children(supervisor) == []
    end)
  end

  defp start_fake_pool(opts \\ []) do
    start_supervised!(
      {FakePool,
       Keyword.merge(
         [name: FakePool, test_pid: self(), session_module: FakeSession],
         opts
       )}
    )
  end

  defp managed_close_owner_loop(parent, worker_session_id, registry) do
    receive do
      {:close, timeout} ->
        result =
          AI.acp_managed_close_session(worker_session_id,
            server: registry,
            timeout: timeout
          )

        send(parent, {:managed_owner_close, result})
        managed_close_owner_loop(parent, worker_session_id, registry)

      :resolve ->
        send(
          parent,
          {:managed_owner_resolve, SessionRegistry.resolve(worker_session_id, server: registry)}
        )

        managed_close_owner_loop(parent, worker_session_id, registry)

      :stop ->
        :ok
    end
  end

  # -- Tests ----------------------------------------------------------------

  describe "public handle metadata" do
    test "JSON encodable and contains no PID/ref/function/struct", ctx do
      assert {:ok, meta} = start_managed([], ctx)

      assert is_binary(meta.worker_session_id)
      assert String.starts_with?(meta.worker_session_id, "acp_worker_")
      assert is_binary(meta.session_id)
      assert meta.provider == "test"
      assert meta.status == "ready"
      assert meta.pooled == false

      assert json_clean?(meta)
      refute_pid_like(meta)
    end

    test "strips caller-supplied owner option", ctx do
      decoy = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, meta} =
               start_managed([owner: decoy, owner_pid: decoy, model: "m1"], ctx)

      assert meta.model == "m1"
      # Owner is the test process (facade caller), so same-owner status works.
      assert {:ok, status} =
               AI.acp_managed_session_status(meta.worker_session_id, server: ctx.registry)

      assert status.worker_session_id == meta.worker_session_id
      Process.exit(decoy, :kill)
    end
  end

  describe "same-owner operations" do
    test "owner can send, status, and close", ctx do
      assert {:ok, meta} = start_managed([model: "opus"], ctx)
      id = meta.worker_session_id

      assert {:ok, result} =
               AI.acp_managed_send_message(id, "hello", server: ctx.registry)

      assert result["text"] == "echo:hello"

      assert {:ok, status} = AI.acp_managed_session_status(id, server: ctx.registry)
      assert status.model == "opus"
      assert status.status == "ready"
      assert json_clean?(status)
      refute_pid_like(status)

      assert {:ok, closed} = AI.acp_managed_close_session(id, server: ctx.registry)
      assert closed.status == "closed"
      assert closed.active == false
    end
  end

  describe "status fields for action migration compatibility" do
    test "returns worker_session_id, provider session_id, provider, model, status, pooled, context fields",
         ctx do
      usage = %{"input_tokens" => 120, "output_tokens" => 30}

      assert {:ok, meta} =
               start_managed(
                 [
                   model: "sonnet",
                   context_tokens: 12_345,
                   usage: usage,
                   status_context_pressure: true
                 ],
                 ctx
               )

      id = meta.worker_session_id

      assert {:ok, status} = AI.acp_managed_session_status(id, server: ctx.registry)

      assert status.worker_session_id == id
      assert is_binary(status.session_id)
      assert status.session_id == meta.session_id
      assert status.provider == "test"
      assert status.model == "sonnet"
      assert status.status == "ready"
      assert status.pooled == false
      assert status.context_pressure == true
      assert status.context_tokens == 12_345
      assert status.usage == usage

      assert json_clean?(status)
      refute_pid_like(status)

      # Required keys for Arbor.Actions.Acp.SessionStatus migration consumers.
      for key <- [
            :worker_session_id,
            :session_id,
            :provider,
            :model,
            :status,
            :pooled,
            :context_pressure,
            :context_tokens,
            :usage
          ] do
        assert Map.has_key?(status, key), "missing status key #{inspect(key)}"
      end
    end

    test "context_pressure falls back to session_module.context_pressure?/1 when not in live status",
         ctx do
      assert {:ok, meta} =
               start_managed(
                 [
                   pressure?: true,
                   context_tokens: 99,
                   usage: %{"input" => 99}
                 ],
                 ctx
               )

      assert {:ok, status} =
               AI.acp_managed_session_status(meta.worker_session_id, server: ctx.registry)

      assert status.context_pressure == true
      assert status.context_tokens == 99
      assert status.usage == %{"input" => 99}
      assert json_clean?(status)
    end

    test "context_pressure fails safely to false when pressure helper is not exported", ctx do
      assert {:ok, meta} =
               start_managed(
                 [
                   session_module: FakeSessionNoPressure,
                   context_tokens: 42,
                   usage: %{"input" => 1}
                 ],
                 ctx
               )

      assert {:ok, status} =
               AI.acp_managed_session_status(meta.worker_session_id, server: ctx.registry)

      assert status.context_pressure == false
      assert status.context_tokens == 42
      assert status.usage == %{"input" => 1}
      assert json_clean?(status)
    end
  end

  describe "security regression: cross-process authority" do
    test "task_id alone and wrong principal cannot resolve; matching task+principal can",
         ctx do
      parent = self()
      task_id = "task_#{System.unique_integer([:positive])}"
      principal_id = "agent_#{System.unique_integer([:positive])}"

      owner =
        spawn(fn ->
          {:ok, meta} =
            start_managed(
              [task_id: task_id, principal_id: principal_id, model: "secure"],
              ctx
            )

          send(parent, {:started, meta})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:started, meta}, 2_000
      id = meta.worker_session_id

      # Different process, no credentials
      assert {:error, :not_authorized} =
               AI.acp_managed_session_status(id, server: ctx.registry)

      # task_id alone is not authority
      assert {:error, :not_authorized} =
               AI.acp_managed_session_status(id, server: ctx.registry, task_id: task_id)

      # wrong principal
      assert {:error, :not_authorized} =
               AI.acp_managed_session_status(id,
                 server: ctx.registry,
                 task_id: task_id,
                 principal_id: "agent_other"
               )

      # matching task + principal from another process
      assert {:ok, status} =
               AI.acp_managed_session_status(id,
                 server: ctx.registry,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert status.worker_session_id == id

      assert {:ok, _result} =
               AI.acp_managed_send_message(id, "cross",
                 server: ctx.registry,
                 task_id: task_id,
                 principal_id: principal_id
               )

      send(owner, :hold)
    end
  end

  describe "security regression: ACP callback identity preserves agent_id" do
    test "public managed start forwards agent_id into the non-pooled session", ctx do
      agent_id = "agent_callback_#{System.unique_integer([:positive])}"

      assert {:ok, meta} =
               AI.acp_managed_start_session(
                 :test,
                 Keyword.merge(ctx.base_opts,
                   agent_id: agent_id,
                   model: "secure-model",
                   test_pid: self()
                 )
               )

      assert_receive {:fake_init, session_pid, ^agent_id, init_opts}, 1_000
      assert is_pid(session_pid)
      assert Keyword.get(init_opts, :agent_id) == agent_id

      # Exercise through the public managed API (not a private option builder).
      assert {:ok, result} =
               AI.acp_managed_send_message(meta.worker_session_id, "who-am-i",
                 server: ctx.registry
               )

      assert result["agent_id"] == agent_id
      assert_receive {:fake_send, _from, "who-am-i", ^session_pid, _opts, ^agent_id}, 1_000

      # agent_id also remains principal fallback for cross-process authority.
      task_id = "task_#{System.unique_integer([:positive])}"

      parent = self()

      owner =
        spawn(fn ->
          {:ok, owned} =
            AI.acp_managed_start_session(
              :test,
              Keyword.merge(ctx.base_opts,
                agent_id: agent_id,
                task_id: task_id,
                model: "secure-model"
              )
            )

          send(parent, {:owned, owned})
          Process.sleep(:infinity)
        end)

      assert_receive {:owned, owned}, 2_000

      assert {:ok, status} =
               AI.acp_managed_session_status(owned.worker_session_id,
                 server: ctx.registry,
                 task_id: task_id,
                 agent_id: agent_id
               )

      assert status.worker_session_id == owned.worker_session_id
      Process.exit(owner, :kill)
    end

    test "public managed start forwards agent_id on pooled checkout", ctx do
      start_fake_pool()
      agent_id = "agent_pool_#{System.unique_integer([:positive])}"

      assert {:ok, meta} =
               AI.acp_managed_start_session(
                 :test,
                 Keyword.merge(ctx.base_opts,
                   use_pool: true,
                   pool_module: FakePool,
                   agent_id: agent_id,
                   test_pid: self()
                 )
               )

      assert meta.pooled == true
      assert_receive {:fake_init, session_pid, ^agent_id, init_opts}, 1_000
      assert Keyword.get(init_opts, :agent_id) == agent_id

      assert {:ok, result} =
               AI.acp_managed_send_message(meta.worker_session_id, "pool-who",
                 server: ctx.registry
               )

      assert result["agent_id"] == agent_id
      assert_receive {:fake_send, _from, "pool-who", ^session_pid, _opts, ^agent_id}, 1_000
    end

    test "security regression: managed pool checkout gets task scope and strips child-unsupported opts",
         ctx do
      start_fake_pool()
      task_id = "task_scope_#{System.unique_integer([:positive])}"
      agent_id = "agent_scope_#{System.unique_integer([:positive])}"
      cwd = "/tmp/managed_scope_#{System.unique_integer([:positive])}"

      assert {:ok, meta} =
               AI.acp_managed_start_session(
                 :test,
                 Keyword.merge(ctx.base_opts,
                   use_pool: true,
                   pool_module: FakePool,
                   agent_id: agent_id,
                   task_id: task_id,
                   principal_id: agent_id,
                   cwd: cwd,
                   model: "scope-model",
                   session_id: "provider_resume_should_not_reach_pool",
                   create_session: true,
                   test_pid: self()
                 )
               )

      assert meta.pooled == true

      assert_receive {:pool_checkout_opts, :test, checkout_opts, _caller}, 1_000
      # Task scope must reach the pool for SessionProfile matching
      assert Keyword.get(checkout_opts, :task_id) == task_id
      assert Keyword.get(checkout_opts, :agent_id) == agent_id
      assert Keyword.get(checkout_opts, :cwd) == cwd
      assert Keyword.get(checkout_opts, :model) == "scope-model"
      # Child-unsupported / post-checkout opts must not be pool start payload
      refute Keyword.has_key?(checkout_opts, :session_id)
      refute Keyword.has_key?(checkout_opts, :create_session)
      refute Keyword.has_key?(checkout_opts, :principal_id)
      refute Keyword.has_key?(checkout_opts, :use_pool)

      assert_receive {:fake_init, session_pid, ^agent_id, init_opts}, 1_000
      # Pool strips task_id before starting the child session process
      refute Keyword.has_key?(init_opts, :task_id)
      refute Keyword.has_key?(init_opts, :principal_id)
      assert Keyword.get(init_opts, :agent_id) == agent_id
      assert Keyword.get(init_opts, :cwd) == cwd
      assert Process.alive?(session_pid)

      assert {:ok, _} =
               AI.acp_managed_close_session(meta.worker_session_id, server: ctx.registry)
    end
  end

  describe "owner death cleanup" do
    test "non-pooled session is closed on owner death", ctx do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, meta} = start_managed([test_pid: parent], ctx)
          {:ok, resolved} = SessionRegistry.resolve(meta.worker_session_id, server: ctx.registry)
          send(parent, {:started, meta.worker_session_id, resolved.session_pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, id, session_pid}, 2_000
      assert Process.alive?(session_pid)

      Process.exit(owner, :kill)

      assert_eventually(fn ->
        assert {:error, :not_found} =
                 SessionRegistry.resolve(id,
                   server: ctx.registry,
                   task_id: "x",
                   principal_id: "y"
                 )
      end)

      assert_eventually(fn ->
        refute Process.alive?(session_pid)
      end)
    end

    test "pooled session is checked in on owner death", ctx do
      start_fake_pool()
      parent = self()

      owner =
        spawn(fn ->
          {:ok, meta} =
            start_managed(
              [
                use_pool: true,
                pool_module: FakePool,
                return_to_pool: true
              ],
              ctx
            )

          send(parent, {:started, meta})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, meta}, 2_000
      assert meta.pooled == true
      assert_receive {:pool_checkout, session_pid, ^owner}, 1_000

      Process.exit(owner, :kill)

      # Pool auto-checkin and/or registry checkin must not leak the checkout
      assert_receive {:pool_auto_checkin, ^session_pid}, 1_000

      assert_eventually(fn ->
        assert {:error, :not_found} =
                 SessionRegistry.resolve(meta.worker_session_id, server: ctx.registry)
      end)
    end
  end

  describe "session death" do
    test "invalidates the managed handle", ctx do
      assert {:ok, meta} = start_managed([], ctx)
      id = meta.worker_session_id

      {:ok, resolved} = SessionRegistry.resolve(id, server: ctx.registry)
      Process.exit(resolved.session_pid, :kill)

      assert_eventually(fn ->
        assert {:error, :not_found} = SessionRegistry.resolve(id, server: ctx.registry)
      end)
    end
  end

  describe "idempotent close" do
    @tag timeout: 2_000
    test "security regression: expired queued close cannot orphan a managed session", ctx do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, meta} = start_managed([], ctx)
          {:ok, resolved} = SessionRegistry.resolve(meta.worker_session_id, server: ctx.registry)
          send(parent, {:managed_owner_ready, meta, resolved.session_pid})
          managed_close_owner_loop(parent, meta.worker_session_id, ctx.registry)
        end)

      on_exit(fn ->
        if Process.alive?(owner), do: Process.exit(owner, :kill)
      end)

      assert_receive {:managed_owner_ready, _meta, session_pid}, 1_000

      :ok = :sys.suspend(ctx.registry)

      try do
        send(owner, {:close, 25})

        assert_eventually(fn ->
          registry_pid = Process.whereis(ctx.registry)
          assert {:message_queue_len, queued} = Process.info(registry_pid, :message_queue_len)
          assert queued > 0
        end)

        assert_receive {:managed_owner_close, {:error, :timeout}}, 250
      after
        :ok = :sys.resume(ctx.registry)
      end

      send(owner, :resolve)
      assert_receive {:managed_owner_resolve, {:ok, after_close}}, 500

      assert after_close.session_pid == session_pid
      assert Process.alive?(session_pid)

      send(owner, {:close, 500})
      assert_receive {:managed_owner_close, {:ok, %{status: "closed"}}}, 1_000
      send(owner, :stop)
    end

    @tag timeout: 2_000
    test "security regression: managed close kills a non-returning close operation", ctx do
      task_id = "task_stalled_close_#{System.unique_integer([:positive])}"
      principal_id = "agent_stalled_close_#{System.unique_integer([:positive])}"

      assert {:ok, meta} =
               start_managed(
                 [close_mode: :stall, task_id: task_id, principal_id: principal_id],
                 ctx
               )

      {:ok, resolved} = SessionRegistry.resolve(meta.worker_session_id, server: ctx.registry)
      session_pid = resolved.session_pid
      session_ref = Process.monitor(session_pid)

      credentials = [
        server: ctx.registry,
        task_id: task_id,
        principal_id: principal_id
      ]

      close_task =
        Task.async(fn ->
          AI.acp_managed_close_session(
            meta.worker_session_id,
            Keyword.put(credentials, :timeout, 80)
          )
        end)

      assert_receive {:fake_close_stalled, ^session_pid}, 200

      assert {:ok, reconciling} =
               AI.acp_managed_close_session(
                 meta.worker_session_id,
                 Keyword.put(credentials, :timeout, 20)
               )

      assert reconciling.status == "closing"
      assert {:error, :timeout} = Task.await(close_task, 300)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}, 300

      assert_eventually(fn ->
        assert {:ok, terminal} =
                 AI.acp_managed_close_session(meta.worker_session_id, credentials)

        assert terminal.status == "already_closed"
      end)
    end

    test "second close returns already_closed", ctx do
      assert {:ok, meta} = start_managed([], ctx)
      id = meta.worker_session_id

      assert {:ok, first} = AI.acp_managed_close_session(id, server: ctx.registry)
      assert first.status == "closed"

      assert {:ok, second} = AI.acp_managed_close_session(id, server: ctx.registry)
      assert second.status == "already_closed"

      assert {:error, :not_found} =
               AI.acp_managed_session_status(id, server: ctx.registry)
    end
  end

  describe "partial start / create failure cleanup" do
    @tag timeout: 2_000
    test "security regression: never-returning child startup leaves supervisor responsive", ctx do
      assert {:error, :timeout} =
               start_managed([start_delay_ms: :infinity, timeout: 40], ctx)

      assert_receive {:fake_start_stalled, startup_worker, :infinity}, 200
      refute Process.alive?(startup_worker)

      assert {:ok, %{active: 0}} =
               Task.async(fn -> DynamicSupervisor.count_children(ctx.supervisor) end)
               |> Task.yield(200)

      assert {:ok, healthy} = start_managed([], ctx)

      assert {:ok, _closed} =
               AI.acp_managed_close_session(healthy.worker_session_id, server: ctx.registry)
    end

    @tag timeout: 2_000
    test "security regression: never-returning child init cannot wedge the supervisor", ctx do
      assert {:error, :timeout} =
               start_managed([init_delay_ms: :infinity, timeout: 40], ctx)

      assert_receive {:fake_init_stalled, child, :infinity}, 200
      refute Process.alive?(child)

      assert {:ok, %{active: 0}} =
               Task.async(fn -> DynamicSupervisor.count_children(ctx.supervisor) end)
               |> Task.yield(200)

      assert {:ok, healthy} = start_managed([], ctx)

      assert {:ok, _closed} =
               AI.acp_managed_close_session(healthy.worker_session_id, server: ctx.registry)
    end

    test "security regression: managed child startup consumes the operation deadline", ctx do
      started_at = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               start_managed([start_delay_ms: 60, timeout: 20], ctx)

      assert System.monotonic_time(:millisecond) - started_at < 50
      Process.sleep(80)
      assert_supervisor_empty(ctx.supervisor)
    end

    test "security regression: managed start shares one deadline through create and registry",
         ctx do
      slow_registry = start_supervised!({SlowRegistry, delay_ms: 25, test_pid: self()})
      started_at = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               start_managed(
                 [server: slow_registry, create_delay_ms: 25, timeout: 40],
                 ctx
               )

      assert System.monotonic_time(:millisecond) - started_at < 100
      assert_receive {:fake_create_opts, _session_pid, create_opts}
      assert is_integer(create_opts[:deadline_ms])
      assert create_opts[:timeout] in 1..40
      assert_supervisor_empty(ctx.supervisor)
    end

    test "create failure terminates the temporary session and does not register", ctx do
      assert {:error, :create_failed} =
               start_managed([fail_create: true], ctx)

      assert {:error, :not_found} =
               SessionRegistry.resolve("acp_worker_missing", server: ctx.registry)

      assert_supervisor_empty(ctx.supervisor)
    end

    test "create raise cleans temporary child and returns error", ctx do
      # GenServer.call converts handle_call raises into caller exits.
      assert {:error, {:managed_start_exit, _}} =
               start_managed([create_mode: :raise], ctx)

      assert_supervisor_empty(ctx.supervisor)
    end

    test "create unexpected result cleans temporary child and returns error", ctx do
      assert {:error, {:unexpected_result, :not_a_result_tuple}} =
               start_managed([create_mode: :unexpected], ctx)

      assert_supervisor_empty(ctx.supervisor)
    end

    test "create exit cleans temporary child and returns error", ctx do
      assert {:error, {:managed_start_exit, _}} =
               start_managed([create_mode: :exit], ctx)

      assert_supervisor_empty(ctx.supervisor)
    end

    test "resume raise cleans temporary child", ctx do
      assert {:error, {:managed_start_exit, _}} =
               start_managed([session_id: "r1", resume_mode: :raise], ctx)

      assert_supervisor_empty(ctx.supervisor)
    end
  end

  describe "pooled init failure cleanup" do
    test "pooled resume failure does not register and checks in the checkout", ctx do
      start_fake_pool(session_opts: [resume_mode: :error])

      assert {:error, :resume_failed} =
               start_managed(
                 [
                   use_pool: true,
                   pool_module: FakePool,
                   return_to_pool: true,
                   session_id: "resume_me"
                 ],
                 ctx
               )

      assert_receive {:pool_checkout, session_pid, _}, 1_000
      assert_receive {:pool_checkin, ^session_pid}, 1_000

      assert FakePool.status().checked_out == 0
      assert FakePool.status().total == 0

      assert {:error, :not_found} =
               SessionRegistry.resolve("acp_worker_missing", server: ctx.registry)
    end

    test "pooled explicit create failure does not register and checks in", ctx do
      # Skip pool precreate so the explicit create_session is the one that fails.
      start_fake_pool(
        session_opts: [create_mode: :error, skip_pool_precreate: true, fail_create: true]
      )

      assert {:error, :create_failed} =
               start_managed(
                 [
                   use_pool: true,
                   pool_module: FakePool,
                   return_to_pool: true,
                   create_session: true,
                   create_mode: :error,
                   fail_create: true
                 ],
                 ctx
               )

      assert_receive {:pool_checkout, session_pid, _}, 1_000
      assert_receive {:pool_checkin, ^session_pid}, 1_000

      assert FakePool.status().checked_out == 0
      assert FakePool.status().total == 0
    end

    test "pooled resume raise cleans checkout without publishing handle", ctx do
      start_fake_pool(session_opts: [resume_mode: :raise])

      assert {:error, {:managed_start_exit, _}} =
               start_managed(
                 [
                   use_pool: true,
                   pool_module: FakePool,
                   return_to_pool: true,
                   session_id: "resume_raise"
                 ],
                 ctx
               )

      assert_receive {:pool_checkout, session_pid, _}, 1_000

      # Cleanup checkin runs after the raise; session death may also fire.
      receive do
        {:pool_checkin, ^session_pid} -> :ok
        {:pool_session_died, ^session_pid, _} -> :ok
      after
        1_000 ->
          flunk("expected pool checkin or session-death cleanup for #{inspect(session_pid)}")
      end

      assert_eventually(fn ->
        assert FakePool.status().checked_out == 0
        assert FakePool.status().total == 0
      end)
    end
  end

  describe "live status failure" do
    test "status failure returns session_unavailable and keeps the handle live", ctx do
      assert {:ok, meta} = start_managed([status_mode: :exit], ctx)
      id = meta.worker_session_id

      assert {:error, :session_unavailable} =
               AI.acp_managed_session_status(id, server: ctx.registry)

      # Handle must still resolve (busy-prompt timeout must not invalidate).
      assert {:ok, resolved} = SessionRegistry.resolve(id, server: ctx.registry)
      assert is_pid(resolved.session_pid)
      assert Process.alive?(resolved.session_pid)

      # Send still works on the same handle
      assert {:ok, result} =
               AI.acp_managed_send_message(id, "still-here", server: ctx.registry)

      assert result["text"] == "echo:still-here"
    end

    test "status raise returns session_unavailable", ctx do
      assert {:ok, meta} = start_managed([status_mode: :raise], ctx)

      assert {:error, :session_unavailable} =
               AI.acp_managed_session_status(meta.worker_session_id, server: ctx.registry)
    end
  end

  describe "pooled explicit close return_to_pool override" do
    test "return_to_pool true checks in without hard-close", ctx do
      start_fake_pool()

      assert {:ok, meta} =
               start_managed(
                 [
                   use_pool: true,
                   pool_module: FakePool,
                   return_to_pool: false
                 ],
                 ctx
               )

      assert_receive {:pool_checkout, session_pid, _}, 1_000
      assert Process.alive?(session_pid)

      assert {:ok, closed} =
               AI.acp_managed_close_session(meta.worker_session_id,
                 server: ctx.registry,
                 return_to_pool: true
               )

      assert closed.status == "closed"
      assert_receive {:pool_checkin, ^session_pid}, 1_000
      refute_receive {:pool_close_session, _}, 100

      # Session process remains alive after checkin (pool reuses it).
      assert Process.alive?(session_pid)
      assert FakePool.status().checked_out == 0
    end

    test "return_to_pool false hard-closes and removes pool entry", ctx do
      start_fake_pool()

      assert {:ok, meta} =
               start_managed(
                 [
                   use_pool: true,
                   pool_module: FakePool,
                   return_to_pool: true
                 ],
                 ctx
               )

      assert_receive {:pool_checkout, session_pid, _}, 1_000

      assert {:ok, closed} =
               AI.acp_managed_close_session(meta.worker_session_id,
                 server: ctx.registry,
                 return_to_pool: false
               )

      assert closed.status == "closed"
      assert_receive {:pool_close_session, ^session_pid}, 1_000

      assert_eventually(fn ->
        refute Process.alive?(session_pid)
      end)

      assert FakePool.status().checked_out == 0
      assert FakePool.status().total == 0

      assert {:error, :not_found} =
               SessionRegistry.resolve(meta.worker_session_id, server: ctx.registry)
    end
  end

  describe "temporary child does not restart after close" do
    test "closed non-pooled session stays dead", ctx do
      assert {:ok, meta} = start_managed([], ctx)
      {:ok, resolved} = SessionRegistry.resolve(meta.worker_session_id, server: ctx.registry)
      session_pid = resolved.session_pid

      assert {:ok, _} =
               AI.acp_managed_close_session(meta.worker_session_id, server: ctx.registry)

      assert_eventually(fn ->
        refute Process.alive?(session_pid)
      end)

      # Give the DynamicSupervisor a beat to restart if it wrongly would
      Process.sleep(50)
      refute Process.alive?(session_pid)
      assert DynamicSupervisor.which_children(ctx.supervisor) == []
    end
  end

  describe "managed send caller ownership" do
    test "send_message runs in the original facade caller process, not the registry", ctx do
      assert {:ok, meta} = start_managed([test_pid: self()], ctx)
      id = meta.worker_session_id
      caller = self()

      assert {:ok, _} = AI.acp_managed_send_message(id, "cancel-me", server: ctx.registry)

      assert_receive {:fake_send, ^caller, "cancel-me", _session_pid, opts, _agent_id}, 1_000
      # Registry/authority-only opts must not be forwarded to the session module.
      refute Keyword.has_key?(opts, :server)
      refute Keyword.has_key?(opts, :task_id)
      refute Keyword.has_key?(opts, :principal_id)
    end
  end

  describe "application supervision" do
    test "managed registry/supervisor children are independent of optional AcpPool", ctx do
      children = AIApplication.managed_acp_children()
      assert ManagedSupervisor in children
      assert SessionRegistry in children
      refute Arbor.AI.AcpPool in children
      refute Arbor.AI.AcpPool.Supervisor in children

      # Operational independence: non-pooled start works with only the managed
      # supervisor/registry from setup (no AcpPool required).
      assert {:ok, meta} = start_managed([], ctx)
      assert meta.pooled == false
      assert String.starts_with?(meta.worker_session_id, "acp_worker_")
    end
  end

  describe "resume path" do
    test "resume populates provider session_id on the public view", ctx do
      assert {:ok, meta} =
               start_managed([session_id: "resume_abc"], ctx)

      assert meta.session_id == "resume_abc"
      assert json_clean?(meta)
    end
  end
end
