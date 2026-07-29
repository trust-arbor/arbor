defmodule Arbor.AI.AcpProviderUsageTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpManaged
  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.Config
  alias Arbor.AI.AcpSession.GrokSandbox
  alias Arbor.Common.SafePath
  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast

  defmodule FakeClient do
    @moduledoc false

    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def new_session(client, _cwd, opts) do
      state = Agent.get(client, & &1)

      if test_pid = Keyword.get(state, :test_pid) do
        send(test_pid, {:fake_new_session_opts, opts})
      end

      {:ok, %{"sessionId" => "fake-session"}}
    end

    def load_session(client, session_id, _cwd, opts) do
      state = Agent.get(client, & &1)

      if test_pid = Keyword.get(state, :test_pid) do
        send(test_pid, {:fake_load_session_opts, opts, session_id})
      end

      {:ok, %{"sessionId" => session_id}}
    end

    def set_config_option(_client, _session_id, _key, _value), do: :ok
    def cancel(_client, _session_id), do: :ok

    def disconnect(client) do
      Agent.stop(client, :normal)
      :ok
    end

    def prompt(client, _session_id, content, opts) do
      state = Agent.get(client, & &1)

      if test_pid = Keyword.get(state, :test_pid) do
        send(test_pid, {:fake_prompt_opts, opts, content})
        send(test_pid, {:prompt_started, self(), content})
      end

      result =
        if Keyword.get(state, :gated?, false) do
          receive do
            {:release, value} -> value
          after
            5_000 -> {:error, :fake_timeout}
          end
        else
          Agent.get_and_update(client, fn agent_state ->
            case Keyword.get(agent_state, :results, []) do
              [next | rest] -> {{:ok, next}, Keyword.put(agent_state, :results, rest)}
              [] -> {{:ok, %{"text" => "ok"}}, agent_state}
            end
          end)
        end

      case result do
        {:ok, map} when is_map(map) -> {:ok, map}
        {:error, reason} -> {:error, reason}
        map when is_map(map) -> {:ok, map}
        other -> other
      end
    end
  end

  defmodule CaptureSink do
    @moduledoc false
    @parent_key {__MODULE__, :parent}

    def set_parent(pid), do: :persistent_term.put(@parent_key, pid)
    def clear_parent, do: :persistent_term.erase(@parent_key)

    def append(mode, turn) do
      parent = :persistent_term.get(@parent_key)
      send(parent, {:transcript_sink_turn, self(), turn})

      case mode do
        :ok ->
          {:ok, descriptor(turn)}

        :fail ->
          {:error, :disk_unavailable}

        :gated ->
          receive do
            :ack_durable -> {:ok, descriptor(turn)}
          after
            5_000 -> {:error, :sink_timeout}
          end
      end
    end

    defp descriptor(turn) do
      seen = get_in(turn, ["execution", "capture_index"]) + 1

      %{
        "path" => "/tmp/acp-provider-usage-transcript.json",
        "sha256" => String.duplicate("a", 64),
        "byte_size" => 1_024,
        "turns_retained" => seen,
        "turns_seen" => seen,
        "turns_omitted" => 0,
        "turns_truncated" => false,
        "aggregate_truncated" => false,
        "schema_version" => 1,
        "task_id" => "task-owner"
      }
    end
  end

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"acp_provider_usage_#{:erlang.unique_integer([:positive])}"

    start_supervised!(
      {ETS, name: name, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: name
    )

    # Init-only target injection — never mutate Application ledger-target env.
    target = %{name: name, backend: ETS, opts: []}

    original_client = Application.get_env(:arbor_ai, :acp_client_module)
    Application.put_env(:arbor_ai, :acp_client_module, FakeClient)
    CaptureSink.set_parent(self())

    on_exit(fn ->
      restore_env(:acp_client_module, original_client)
      CaptureSink.clear_parent()
    end)

    {:ok, target: target}
  end

  test "ledger remains empty until transcript durability is acknowledged", %{target: target} do
    session =
      start_session(:claude,
        gated?: true,
        results: [],
        provider_usage_ledger_target: target
      )

    caller =
      Task.async(fn ->
        AcpSession.send_message(
          session,
          "hello",
          capture_opts(:gated,
            timeout: 5_000,
            usage_context: %{task_id: "task_owner", principal_id: "agent_owner"}
          )
        )
      end)

    assert_receive {:prompt_started, worker, "hello"}, 2_000

    send(
      worker,
      {:release,
       {:ok, %{"text" => "done", "usage" => %{"input_tokens" => 5, "output_tokens" => 2}}}}
    )

    assert_receive {:transcript_sink_turn, sink_worker, turn}, 2_000
    assert turn["execution"]["capture_index"] == 0
    assert stream_events(target) == []

    send(sink_worker, :ack_durable)
    assert {:ok, result} = Task.await(caller, 5_000)
    assert result["text"] == "done"

    events = stream_events(target)
    assert length(events) == 1
    assert hd(events).data["provider"] == "anthropic"
    assert hd(events).data["input_tokens"] == 5
    assert hd(events).data["task_id"] == "task_owner"
    assert hd(events).data["principal_id"] == "agent_owner"
    assert String.starts_with?(hd(events).id, "acp_")
  end

  test "queued follow-up inherits owner scope and emits after its own durable capture", %{
    target: target
  } do
    session = start_session(:gemini, gated?: true, provider_usage_ledger_target: target)

    caller =
      Task.async(fn ->
        AcpSession.send_message(
          session,
          "initial",
          capture_opts(:gated,
            timeout: 8_000,
            usage_context: %{task_id: "task_follow", principal_id: "agent_follow"}
          )
        )
      end)

    assert_receive {:prompt_started, initial_worker, "initial"}, 2_000

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, %{
               "control_id" => "ctrl-1",
               "message" => "follow-up",
               "task_id" => "task_follow"
             })

    send(
      initial_worker,
      {:release,
       {:ok, %{"text" => "initial", "usage" => %{"input_tokens" => 3, "output_tokens" => 1}}}}
    )

    assert_receive {:transcript_sink_turn, sink1, _}, 2_000
    assert stream_events(target) == []
    send(sink1, :ack_durable)

    assert_receive {:prompt_started, follow_worker, "follow-up"}, 2_000

    send(
      follow_worker,
      {:release,
       {:ok, %{"text" => "follow", "usage" => %{"input_tokens" => 7, "output_tokens" => 2}}}}
    )

    assert_receive {:transcript_sink_turn, sink2, follow_turn}, 2_000
    assert follow_turn["prompt"]["kind"] == "task_control"
    # Only the initial event is present until the follow-up sink acks.
    assert length(stream_events(target)) == 1
    send(sink2, :ack_durable)

    assert {:ok, _} = Task.await(caller, 5_000)

    events = stream_events(target)
    assert length(events) == 2
    assert Enum.map(events, & &1.data["input_tokens"]) == [3, 7]
    assert Enum.all?(events, &(&1.data["provider"] == "google"))
    assert Enum.all?(events, &(&1.data["task_id"] == "task_follow"))
    assert Enum.all?(events, &(&1.data["principal_id"] == "agent_follow"))
    assert Enum.at(events, 0).id != Enum.at(events, 1).id
  end

  test "transcript sink failure is not reported successful and admits no usage", %{target: target} do
    session =
      start_session(:claude,
        results: [
          %{"text" => "done", "usage" => %{"input_tokens" => 4, "output_tokens" => 1}}
        ],
        provider_usage_ledger_target: target
      )

    assert {:error, _reason} =
             AcpSession.send_message(session, "hello", capture_opts(:fail, timeout: 2_000))

    assert stream_events(target) == []
  end

  test "missing and malformed ACP usage invent no ledger facts", %{target: target} do
    session =
      start_session(:codex,
        results: [
          %{"text" => "no-usage"},
          %{"text" => "partial-usage", "usage" => %{"input_tokens" => 5}},
          %{
            "text" => "nested-invalid",
            "_meta" => %{
              "usage" => %{
                "input_tokens" => -1,
                "inputTokens" => 9,
                "output_tokens" => "bad",
                "outputTokens" => 3
              }
            }
          }
        ],
        provider_usage_ledger_target: target
      )

    assert {:ok, _} = AcpSession.send_message(session, "one", timeout: 1_000)
    assert {:ok, _} = AcpSession.send_message(session, "two", timeout: 1_000)
    assert {:ok, _} = AcpSession.send_message(session, "three", timeout: 1_000)
    assert stream_events(target) == []
  end

  test "oversized subscription_usage_units invent no ledger facts", %{
    target: target
  } do
    # Bignum-before-conversion / ceiling cases: must reject without raising and
    # without admitting a zero-token or invented subscription fact.
    over_int = 1_000_000_000_000_000_001
    over_float = 1.0e19

    session =
      start_session(:claude,
        results: [
          %{
            "text" => "over-int",
            "usage" => %{
              "input_tokens" => 2,
              "output_tokens" => 1,
              "subscription_usage_units" => over_int
            }
          },
          %{
            "text" => "over-float",
            "usage" => %{
              "input_tokens" => 2,
              "output_tokens" => 1,
              "subscription_usage_units" => over_float
            }
          }
        ],
        provider_usage_ledger_target: target
      )

    assert {:ok, _} = AcpSession.send_message(session, "one", timeout: 1_000)
    assert {:ok, _} = AcpSession.send_message(session, "two", timeout: 1_000)
    assert stream_events(target) == []
  end

  test "missing usage does not consult ledger or emit admission-failure observation" do
    # Explicit valid-shaped failing ETS target (backend GenServer absent).
    # If missing-usage short-circuit is wrong, admission would consult the
    # snapshotted failing ledger and log a closed admission-failure reason.
    # Never mutate global Application ledger target or Logger level.
    failing_target = %{
      name: :"missing_acp_missing_usage_#{:erlang.unique_integer([:positive])}",
      backend: ETS,
      opts: []
    }

    session =
      start_session(:claude,
        results: [%{"text" => "no-usage-at-all"}],
        provider_usage_ledger_target: failing_target
      )

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:ok, result} =
                 AcpSession.send_message(session, "hello", timeout: 1_000)

        assert result["text"] == "no-usage-at-all"
        Process.sleep(50)
      end)

    refute log =~ "acp provider usage admission failed"
    refute log =~ "provider_usage_ledger_target_unset"
    refute log =~ "invalid_provider_usage_ledger_target"
    refute log =~ "backend_unavailable"
  end

  test "managed send ignores conflicting caller task/principal and strips private context", %{
    target: target
  } do
    ensure_managed_registry()

    {:ok, session} =
      AcpSession.start_link(
        provider: :claude,
        provider_usage_ledger_target: target,
        client_opts: [
          test_pid: self(),
          results: [
            %{"text" => "done", "usage" => %{"input_tokens" => 8, "output_tokens" => 3}}
          ]
        ]
      )

    assert eventually(fn -> match?(%{status: :ready}, AcpSession.status(session)) end)

    assert {:ok, view} =
             SessionRegistry.register(%{
               session_pid: session,
               session_module: AcpSession,
               provider: :claude,
               model: nil,
               session_id: "fake-session",
               status: "ready",
               pooled: false,
               return_to_pool: false,
               task_id: "task_registry_owner",
               principal_id: "agent_registry_owner"
             })

    worker_id = view.worker_session_id

    assert {:ok, result} =
             AcpManaged.send_message(worker_id, "hello",
               timeout: 2_000,
               # Conflicting caller-supplied values must not become authority.
               task_id: "task_attacker",
               principal_id: "agent_attacker",
               goal_id: "goal_trusted",
               correlation_id: "corr_trusted"
             )

    assert result["text"] == "done"
    assert_receive {:fake_prompt_opts, opts, "hello"}
    refute Keyword.has_key?(opts, :usage_context)
    refute Keyword.has_key?(opts, :task_id)
    refute Keyword.has_key?(opts, :principal_id)
    refute Keyword.has_key?(opts, :goal_id)
    refute Keyword.has_key?(opts, :correlation_id)

    events = stream_events(target)
    assert length(events) == 1
    assert hd(events).data["task_id"] == "task_registry_owner"
    assert hd(events).data["principal_id"] == "agent_registry_owner"
    assert hd(events).data["goal_id"] == "goal_trusted"
    assert hd(events).data["correlation_id"] == "corr_trusted"
    refute hd(events).data["task_id"] == "task_attacker"
  end

  test "unmanaged sessions without usage_context omit owner attribution", %{target: target} do
    session =
      start_session(:claude,
        results: [
          %{"text" => "done", "usage" => %{"input_tokens" => 2, "output_tokens" => 1}}
        ],
        provider_usage_ledger_target: target
      )

    assert {:ok, _} = AcpSession.send_message(session, "hello", timeout: 1_000)
    [event] = stream_events(target)
    refute Map.has_key?(event.data, "task_id")
    refute Map.has_key?(event.data, "principal_id")
  end

  test "authoritative subscription units are preserved when provided", %{target: target} do
    session =
      start_session(:claude,
        results: [
          %{
            "text" => "done",
            "usage" => %{
              "input_tokens" => 2,
              "output_tokens" => 1,
              "subscription_usage_units" => 1.5
            }
          }
        ],
        provider_usage_ledger_target: target
      )

    assert {:ok, _} = AcpSession.send_message(session, "hello", timeout: 1_000)
    [event] = stream_events(target)
    assert event.data["subscription_usage_units"] == 1.5
    refute Map.has_key?(event.data, "marginal_api_cost_usd")
  end

  test "ACP CLI :grok prompt completion persists provider xai and projects BudgetTracker :grok",
       %{
         target: target
       } do
    previous_budget = Application.get_env(:arbor_ai, :enable_budget_tracking, true)
    Application.put_env(:arbor_ai, :enable_budget_tracking, true)
    ensure_budget_tracker()
    Arbor.AI.BudgetTracker.reset()
    isolate_grok_runtime_home!()

    on_exit(fn ->
      Application.put_env(:arbor_ai, :enable_budget_tracking, previous_budget)
      Arbor.AI.BudgetTracker.reset()
    end)

    {repository_root, worktree_root} = create_linked_grok_fixture!()
    assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

    assert {:ok, grok_client_opts} = Config.resolve(:grok, model: "grok-4.5")

    grok_client_opts =
      Keyword.merge(grok_client_opts,
        test_pid: self(),
        results: [
          %{"text" => "done", "usage" => %{"input_tokens" => 6, "output_tokens" => 2}}
        ]
      )

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :grok,
               model: "grok-4.5",
               workspace: {:directory, worktree_root},
               grok_sandbox_authority: authority,
               provider_usage_ledger_target: target,
               client_opts: grok_client_opts,
               timeout: 5_000
             )

    on_exit(fn ->
      if Process.alive?(session) do
        try do
          AcpSession.close(session)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert eventually(fn -> match?(%{status: :ready}, AcpSession.status(session)) end)
    assert {:ok, result} = AcpSession.send_message(session, "hello", timeout: 2_000)
    assert result["text"] == "done"

    assert eventually(fn -> length(stream_events(target)) == 1 end)
    [event] = stream_events(target)
    assert event.data["provider"] == "xai"
    assert event.data["source"] == "acp"
    assert event.data["runtime"] == "acp"
    assert event.data["input_tokens"] == 6
    assert event.data["output_tokens"] == 2

    assert eventually(fn ->
             match?(
               {:ok, %{backends: %{grok: %{requests: 1}}}},
               Arbor.AI.BudgetTracker.get_status()
             )
           end)

    assert {:ok, status} = Arbor.AI.BudgetTracker.get_status()
    assert status.backends.grok.requests == 1
    refute Map.has_key?(status.backends, :xai)
  end

  test "disabled budget projection still admits durable ACP events", %{target: target} do
    previous_budget = Application.get_env(:arbor_ai, :enable_budget_tracking, true)
    Application.put_env(:arbor_ai, :enable_budget_tracking, false)
    ensure_budget_tracker()
    Arbor.AI.BudgetTracker.reset()

    on_exit(fn ->
      Application.put_env(:arbor_ai, :enable_budget_tracking, previous_budget)
      Arbor.AI.BudgetTracker.reset()
    end)

    session =
      start_session(:claude,
        results: [
          %{"text" => "done", "usage" => %{"input_tokens" => 4, "output_tokens" => 1}}
        ],
        provider_usage_ledger_target: target
      )

    assert {:ok, _} = AcpSession.send_message(session, "hello", timeout: 1_000)
    [event] = stream_events(target)
    assert event.data["input_tokens"] == 4

    wait_briefly()
    assert {:ok, status} = Arbor.AI.BudgetTracker.get_status()
    assert status.backends == %{}
  end

  test "ledger failure is secret-safe and non-fatal to the ACP response", %{target: target} do
    # Missing backend GenServer → durable admit fails with closed reason.
    bad_target = %{name: :missing_acp_usage_backend, backend: ETS, opts: []}

    session =
      start_session(:claude,
        results: [
          %{"text" => "done", "usage" => %{"input_tokens" => 3, "output_tokens" => 1}}
        ],
        provider_usage_ledger_target: bad_target
      )

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:ok, result} =
                 AcpSession.send_message(session, "hello secret-sk-xyz", timeout: 1_000)

        assert result["text"] == "done"
        Process.sleep(50)
      end)

    assert stream_events(target) == []
    assert log =~ "acp provider usage admission failed"
    assert log =~ "append_indeterminate"
    refute log =~ "secret-sk-xyz"
    refute log =~ "sk-"
    refute log =~ "noproc"
    refute log =~ "GenServer"
    refute log =~ "missing_acp_usage_backend"
  end

  test "per-send ledger target opts are stripped and do not retarget admission", %{target: target} do
    session =
      start_session(:claude,
        results: [
          %{"text" => "done", "usage" => %{"input_tokens" => 2, "output_tokens" => 1}}
        ],
        provider_usage_ledger_target: target
      )

    private_keys = private_provider_facing_keys()

    assert {:ok, _} =
             AcpSession.send_message(
               session,
               "hello",
               Keyword.merge(private_keys, timeout: 1_000)
             )

    assert_receive {:fake_new_session_opts, ensure_opts}
    refute_private_provider_facing_keys(ensure_opts)

    assert_receive {:fake_prompt_opts, prompt_opts, "hello"}
    refute_private_provider_facing_keys(prompt_opts)

    [event] = stream_events(target)
    assert event.data["input_tokens"] == 2
  end

  @tag :security_regression
  test "security regression: explicit create_session strips private usage keys before new_session",
       %{target: target} do
    session = start_session(:claude, results: [], provider_usage_ledger_target: target)

    assert {:ok, %{"sessionId" => "fake-session"}} =
             AcpSession.create_session(
               session,
               Keyword.merge(private_provider_facing_keys(), timeout: 2_000)
             )

    assert_receive {:fake_new_session_opts, opts}, 1_000
    refute_private_provider_facing_keys(opts)
    assert timeout = Keyword.fetch!(opts, :timeout)
    assert is_integer(timeout) and timeout > 0 and timeout <= 2_000
    assert is_integer(Keyword.fetch!(opts, :deadline_ms))
  end

  @tag :security_regression
  test "security regression: explicit resume_session strips private usage keys before load_session",
       %{target: target} do
    session = start_session(:claude, results: [], provider_usage_ledger_target: target)

    assert {:ok, %{"sessionId" => "resume-session-1"}} =
             AcpSession.resume_session(
               session,
               "resume-session-1",
               Keyword.merge(private_provider_facing_keys(), timeout: 2_000)
             )

    assert_receive {:fake_load_session_opts, opts, "resume-session-1"}, 1_000
    refute_private_provider_facing_keys(opts)
    assert timeout = Keyword.fetch!(opts, :timeout)
    assert is_integer(timeout) and timeout > 0 and timeout <= 2_000
    assert is_integer(Keyword.fetch!(opts, :deadline_ms))
  end

  defp start_session(provider, results_or_opts) when is_list(results_or_opts) do
    {results, opts} =
      if Keyword.keyword?(results_or_opts) do
        {Keyword.get(results_or_opts, :results, []), results_or_opts}
      else
        {results_or_opts, []}
      end

    client_opts =
      opts
      |> Keyword.take([:gated?])
      |> Keyword.merge(test_pid: self(), results: results)

    start_opts =
      [
        provider: provider,
        client_opts: client_opts
      ]
      |> maybe_put_start_opt(
        :provider_usage_ledger_target,
        Keyword.get(opts, :provider_usage_ledger_target)
      )

    {:ok, session} = AcpSession.start_link(start_opts)

    assert eventually(fn -> match?(%{status: :ready}, AcpSession.status(session)) end)

    on_exit(fn ->
      if Process.alive?(session) do
        try do
          AcpSession.close(session)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    session
  end

  defp maybe_put_start_opt(opts, _key, nil), do: opts
  defp maybe_put_start_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp private_provider_facing_keys do
    attacker_target = %{name: :attacker_target, backend: ETS, opts: []}

    [
      usage_context: %{task_id: "task_leak", principal_id: "agent_leak"},
      provider_usage_context: %{
        task_id: "task_provider_leak",
        principal_id: "agent_provider_leak"
      },
      task_id: "task_leak",
      principal_id: "agent_leak",
      agent_id: "agent_leak",
      goal_id: "goal_leak",
      correlation_id: "corr_leak",
      provider_usage_ledger_target: attacker_target,
      usage_ledger_target: attacker_target,
      usage_ledger: :attacker,
      provider_usage_recorder: fn _ -> :ok end,
      transcript_sink: {CaptureSink, :append, [:ok]},
      transcript_execution_id: "private-transcript-execution",
      transcript_sink_timeout_ms: 123
    ]
  end

  defp refute_private_provider_facing_keys(opts) when is_list(opts) do
    for key <- [
          :usage_context,
          :provider_usage_context,
          :task_id,
          :principal_id,
          :agent_id,
          :goal_id,
          :correlation_id,
          :provider_usage_ledger_target,
          :usage_ledger_target,
          :usage_ledger,
          :provider_usage_recorder,
          :transcript_sink,
          :transcript_execution_id,
          :transcript_sink_timeout_ms
        ] do
      refute Keyword.has_key?(opts, key), "expected #{inspect(key)} stripped from provider opts"
    end
  end

  defp ensure_budget_tracker do
    case Process.whereis(Arbor.AI.BudgetTracker) do
      nil ->
        {:ok, _} = Arbor.AI.BudgetTracker.start_link([])

      _ ->
        :ok
    end
  end

  defp wait_briefly, do: Process.sleep(75)

  # GrokSandbox authority fixture (same shape as AcpSession.GrokSandboxTest).
  defp isolate_grok_runtime_home! do
    home =
      Path.join(System.tmp_dir!(), "acp-usage-grok-home-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    previous = System.get_env("GROK_HOME")
    System.put_env("GROK_HOME", Path.join(home, "grok"))

    on_exit(fn ->
      if previous do
        System.put_env("GROK_HOME", previous)
      else
        System.delete_env("GROK_HOME")
      end

      File.rm_rf!(home)
    end)

    :ok
  end

  defp create_linked_grok_fixture! do
    suffix = :erlang.unique_integer([:positive])
    repository = Path.join(System.tmp_dir!(), "acp-usage-grok-repo-#{suffix}")
    worktree = Path.join(System.tmp_dir!(), "acp-usage-grok-worktree-#{suffix}")
    branch = "usage-grok-#{suffix}"

    File.mkdir_p!(repository)
    git_cmd!(repository, ["init", "-b", "main"])
    git_cmd!(repository, ["config", "user.name", "Acp Usage Test"])
    git_cmd!(repository, ["config", "user.email", "acp-usage-test@example.com"])
    File.write!(Path.join(repository, "README.md"), "grok usage fixture\n")
    git_cmd!(repository, ["add", "README.md"])
    git_cmd!(repository, ["commit", "-q", "-m", "fixture", "--no-gpg-sign"])
    git_cmd!(repository, ["worktree", "add", "-b", branch, worktree])

    on_exit(fn ->
      File.rm_rf!(worktree)
      File.rm_rf!(repository)
    end)

    {canonical_path!(repository), canonical_path!(worktree)}
  end

  defp git_cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("git #{Enum.join(args, " ")} failed in #{cwd} (#{status}): #{output}")
    end
  end

  defp canonical_path!(path) do
    case SafePath.resolve_real(path) do
      {:ok, canonical} -> canonical
      {:error, reason} -> flunk("failed to canonicalize #{path}: #{inspect(reason)}")
    end
  end

  defp capture_opts(mode, extra) do
    Keyword.merge(
      [
        transcript_sink: {CaptureSink, :append, [mode]},
        transcript_execution_id: "exec_provider_usage_capture",
        transcript_sink_timeout_ms: 2_000
      ],
      extra
    )
  end

  defp stream_events(target) do
    day = Date.utc_today() |> Date.to_iso8601()
    stream_id = "provider_usage:v1:" <> day

    case Persistence.read_stream(target.name, target.backend, stream_id, from: 1, limit: 20) do
      {:ok, events} -> events
      _ -> []
    end
  end

  defp ensure_managed_registry do
    case Process.whereis(SessionRegistry) do
      nil ->
        start_supervised!(SessionRegistry)

      _pid ->
        :ok
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_ai, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_ai, key, value)
end
