defmodule Arbor.AI.AcpCliArgvInjectionSecurityRegressionTest do
  @moduledoc """
  Security regression for CVE-2026-96620 / GHSA-h4mw-j7qp-8mwm.

  An optional-value CLI flag does not bind a following token that starts with
  `-`, so a caller-supplied resume/session id such as `--mcp-config=/tmp/x.json`
  becomes a new CLI option. Arbor must reject that class of value before any
  ACP session or provider process is launched.
  """
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpManaged.Supervisor, as: ManagedSupervisor
  alias Arbor.AI.AcpSession

  @moduletag :fast
  @moduletag :security_regression

  @claude_uuid "a226df5e-bc82-412c-9870-1fc52d036763"
  @injected_mcp_config "--mcp-config=/tmp/x.json"
  @leading_dash_ids [@injected_mcp_config, "-x", " -x", "\t-x"]

  defmodule FakeSession do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def create_session(pid, opts \\ []), do: GenServer.call(pid, {:create_session, opts})

    def resume_session(pid, session_id, opts \\ []) do
      GenServer.call(pid, {:resume_session, session_id, opts})
    end

    def status(pid), do: GenServer.call(pid, :status)
    def close(pid), do: GenServer.call(pid, :close)

    @impl true
    def init(opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:fake_init, self(), Keyword.get(opts, :agent_id), opts})
      end

      {:ok, %{opts: opts, session_id: nil}}
    end

    @impl true
    def handle_call({:create_session, _opts}, _from, state) do
      {:reply, {:ok, %{"sessionId" => "created-session"}},
       %{state | session_id: "created-session"}}
    end

    def handle_call({:resume_session, session_id, _opts}, _from, state) do
      {:reply, {:ok, %{"sessionId" => session_id}}, %{state | session_id: session_id}}
    end

    def handle_call(:status, _from, state) do
      {:reply,
       %{
         status: :ready,
         session_id: state.session_id,
         model: Keyword.get(state.opts, :model),
         provider: Keyword.get(state.opts, :provider)
       }, state}
    end

    def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}
  end

  setup do
    registry_name = :"acp_cli_argv_reg_#{System.unique_integer([:positive])}"
    supervisor_name = :"acp_cli_argv_sup_#{System.unique_integer([:positive])}"

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

  describe "caller-requested resume session ids" do
    test "security regression: dash-leading session ids are rejected before any process starts",
         ctx do
      for session_id <- @leading_dash_ids do
        assert {:error, {:invalid_provider_session_id, :leading_dash}} =
                 AcpSession.validate_provider_session_id(session_id)

        assert {:error, {:invalid_provider_session_id, :leading_dash}} =
                 start_managed(:test, [session_id: session_id], ctx)

        refute_receive {:fake_init, _pid, _agent_id, _opts}, 50
        assert DynamicSupervisor.which_children(ctx.supervisor) == []
      end
    end

    test "security regression: Claude caller resume requires the provider UUID and still resumes",
         ctx do
      assert {:error, {:invalid_provider_session_id, :claude_session_uuid}} =
               start_managed(:claude, [session_id: "resume_abc"], ctx)

      refute_receive {:fake_init, _pid, _agent_id, _opts}, 50
      assert DynamicSupervisor.which_children(ctx.supervisor) == []

      assert {:ok, meta} = start_managed(:claude, [session_id: @claude_uuid], ctx)
      assert meta.session_id == @claude_uuid

      assert_receive {:fake_init, _pid, _agent_id, init_opts}, 1_000
      assert Keyword.get(init_opts, :adapter_opts)[:resume] == @claude_uuid

      assert {:ok, _closed} =
               AI.acp_managed_close_session(meta.worker_session_id, server: ctx.registry)
    end

    test "security regression: a non-Claude provider may still resume a non-UUID session id",
         ctx do
      assert {:ok, meta} = start_managed(:test, [session_id: "resume_abc"], ctx)
      assert meta.session_id == "resume_abc"
      assert_receive {:fake_init, _pid, _agent_id, _opts}, 1_000

      assert {:ok, _closed} =
               AI.acp_managed_close_session(meta.worker_session_id, server: ctx.registry)
    end
  end

  describe "other caller values that reach agent CLI argv" do
    test "security regression: dash-leading model/cwd/add-dir/resume-session-at fail before spawn",
         ctx do
      attacks = [
        [model: @injected_mcp_config],
        [cwd: @injected_mcp_config],
        [adapter_opts: [add_dir: @injected_mcp_config]],
        [adapter_opts: [add_dirs: ["/tmp/safe", @injected_mcp_config]]],
        [adapter_opts: [resume_session_at: @injected_mcp_config]],
        [adapter_opts: [resume: @injected_mcp_config]],
        [client_opts: [adapter_opts: [resume: " -x"]]]
      ]

      for opts <- attacks do
        assert {:error, {:invalid_cli_argv_value, :leading_dash}} =
                 start_managed(:test, opts, ctx)

        refute_receive {:fake_init, _pid, _agent_id, _opts}, 50
        assert DynamicSupervisor.which_children(ctx.supervisor) == []
      end
    end

    test "security regression: a safe model and cwd still start", ctx do
      assert {:ok, meta} =
               start_managed(:test, [model: "sonnet", cwd: "/tmp/workspace"], ctx)

      assert_receive {:fake_init, _pid, _agent_id, init_opts}, 1_000
      assert init_opts[:model] == "sonnet"
      assert init_opts[:cwd] == "/tmp/workspace"

      assert {:ok, _closed} =
               AI.acp_managed_close_session(meta.worker_session_id, server: ctx.registry)
    end
  end

  defp start_managed(provider, opts, ctx) do
    AI.acp_managed_start_session(provider, Keyword.merge(ctx.base_opts, opts))
  end
end
