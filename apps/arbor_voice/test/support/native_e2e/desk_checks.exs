defmodule Arbor.Voice.NativeDeskE2E do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.{Comms, Multimedia, Security, Voice}
  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Multimedia.Fence
  alias Arbor.Security.{OIDCTestHelper, SessionToken}
  alias Arbor.Signals.Taint
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Test.SessionFakes.{FakeLedger, FakeSignals}
  @engagement "eng_0123456789abcdef0123456789abcdef"
  @output :binary.copy(<<7, 0>>, 513)
  @plain "The result is ready."
  @shaped "The result is ready.\n```elixir\nPRIVATE_RAW_REPLY_SENTINEL()\n```"

  defmodule OwnerResolver do
    def resolve(id), do: {:ok, id}
  end

  defmodule Store do
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{entries: [], appends: 0} end, name: __MODULE__)

    def resolve_or_create(agent, owner, opts) do
      {:ok,
       %Engagement{
         id: "eng_0123456789abcdef0123456789abcdef",
         agent_id: agent,
         owner_tenant: owner,
         scope: opts[:scope],
         visibility: opts[:visibility]
       }}
    end

    def ensure_session(session, agent, []) do
      Agent.update(__MODULE__, &Map.merge(&1, %{session: session, agent: agent}))
      {:ok, %{id: "canonical-session"}}
    end

    def append_session_entries("canonical-session", entries) do
      Agent.update(__MODULE__, fn state ->
        %{state | entries: state.entries ++ entries, appends: state.appends + 1}
      end)

      {:ok, length(entries)}
    end

    def load_recent_session_messages(session, opts) do
      Agent.get(__MODULE__, fn state ->
        if state[:session] == session,
          do: Enum.filter(state.entries, &(&1.metadata["engagement_id"] == opts[:engagement_id])),
          else: []
      end)
    end

    def snapshot, do: Agent.get(__MODULE__, & &1)
  end

  defmodule Provider do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none

    def open(opts) do
      state = Map.new(opts)
      send(state.parent, {:provider_opened, self()})
      {:ok, state}
    end

    def configure(state, config) do
      send(state.parent, {:provider_configured, config.audio_mode})
      {:ok, state}
    end

    def send_audio(state, bytes) do
      send(state.parent, {:provider_input, bytes})
      {:ok, state}
    end

    def send_text(state, text) do
      send(state.parent, {:unexpected_text_or_tts, text})
      {:ok, state}
    end

    def send_tool_result(state, _, _), do: {:ok, state}

    def recv(state, timeout) do
      case Agent.get_and_update(state.queue, fn
             [event | rest] -> {event, rest}
             [] -> {:timeout, []}
           end) do
        :timeout ->
          Process.sleep(min(timeout, 2))
          {:error, :timeout}

        {:wait_for_final, text} ->
          send(state.parent, {:provider_final_wait, self()})

          receive do
            :release_final -> {:ok, state, {:turn_done, %{text: text}}}
          end

        {:bounded_cancel_event, event} ->
          send(state.parent, {:provider_recv_wait, self(), timeout})

          receive do
            :release_recv -> {:ok, state, event}
          after
            timeout -> {:error, :timeout}
          end

        event ->
          {:ok, state, event}
      end
    end

    def close(state) do
      send(state.parent, :provider_closed)
      :ok
    end

    def meta(_),
      do: %{
        backend: :sealed_provider,
        mode: :local,
        input_format: PcmFormat.mono_s16le(16_000),
        output_format: PcmFormat.mono_s16le(24_000)
      }
  end

  defmodule NoTools do
    def tools, do: []
    def invoke(_, _), do: {:error, :unavailable}
  end

  setup do
    ArborNativeFake.configure(self())
    start_supervised!({Membrane.PortAudio.SyncExecutor, []})
    start_supervised!({Task.Supervisor, name: Arbor.Multimedia.NativeTaskSupervisor})

    start_supervised!(
      {DynamicSupervisor, name: Arbor.Multimedia.NativeSupervisor, strategy: :one_for_one},
      id: :native
    )

    start_supervised!(
      {DynamicSupervisor, name: Arbor.Multimedia.DriverSupervisor, strategy: :one_for_one},
      id: :driver
    )

    Application.put_env(:arbor_multimedia, :driver, Arbor.Multimedia.Driver.Native)
    Fence.release(Fence.current())
    start_supervised!({Arbor.Multimedia.DeviceOwner, []})
    start_supervised!(Store)
    {:ok, _} = FakeLedger.start()
    {:ok, _} = FakeSignals.start()
    queue = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :queue))

    overrides = [
      identity_alias_resolver: OwnerResolver,
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false,
      constraint_enforcement_enabled: true,
      session_token_secret: "sealed-e2e-session-secret"
    ]

    previous = for {key, _} <- overrides, do: {key, Application.fetch_env(:arbor_security, key)}
    for {key, value} <- overrides, do: Application.put_env(:arbor_security, key, value)

    suffix = System.unique_integer([:positive])
    oidc = OIDCTestHelper.issue_identity(subject: "native-e2e-#{suffix}")
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    user = oidc.identity.agent_id
    agent = "agent_native_e2e_#{suffix}"
    assert {:ok, cap} = Security.grant(principal: user, resource: "arbor://chat/agent/" <> agent)
    assert {:ok, payload} = Security.conversation_session_request_payload(user, agent)
    assert {:ok, signed} = SignedRequest.sign(payload, user, oidc.identity.private_key)
    assert {:ok, token} = Security.issue_signed_conversation_session(user, agent, signed)
    assert {:error, _} = SessionToken.verify(token)

    opts = [
      backend: Provider,
      backend_opts: [parent: self(), queue: queue],
      comms: Comms,
      engagement_store: Store,
      ledger: FakeLedger,
      signals: FakeSignals,
      transcript_opts: [persistence: Store],
      speakable: Arbor.Voice.Speakable,
      tool_router: NoTools,
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      resource_owner_opts: [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 100
      ]
    ]

    voice_env = [
      security_module: Security,
      desk_multimedia_module: Multimedia,
      desk_voice_module: Voice,
      desk_comms_module: Comms,
      desk_session_options: opts
    ]

    before_voice = for {key, _} <- voice_env, do: {key, Application.fetch_env(:arbor_voice, key)}
    for {key, value} <- voice_env, do: Application.put_env(:arbor_voice, key, value)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Arbor.Voice.DeskSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Arbor.Voice.DeskSupervisor, pid)

      _ = Security.revoke(cap.id)
      _ = Security.deregister_identity(user)
      oidc.cleanup.()

      for {app, entries} <- [{:arbor_security, previous}, {:arbor_voice, before_voice}],
          {key, old} <- entries do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      Application.delete_env(:arbor_multimedia, :driver)
      Fence.release(Fence.current())
    end)

    %{user: user, agent: agent, token: token, queue: queue, capability: cap}
  end

  test "real Desk, Native, Voice and canonical recorder complete one guarded audio turn", ctx do
    events(ctx, @plain)
    assert {:ok, id} = start(ctx)
    assert %{state: :complete, result: %{reply: @plain, disposition: :played}} = public = done(id)
    assert_receive {:provider_opened, _}
    assert_receive {:provider_configured, :pcm16}
    assert_receive {:provider_input, input}
    assert input == :binary.copy(<<12, 34>>, 1_600)
    assert_receive :provider_closed
    assert_receive {:effect, {:create, :sink, element, resource}}
    assert_receive {:effect, {:write, @output, ^resource}}
    assert_receive {:effect, {:start, :sink, ^resource}}
    assert_receive {:effect, {:destroy, ^resource}}
    refute Process.alive?(element)
    assert Multimedia.device_status() == :idle
    assert_canonical_turn(ctx, @plain)
    assert %{appends: 1} = Store.snapshot()
    refute inspect(public) =~ ctx.token
    refute Map.has_key?(public.result, :audio)
    refute_receive {:unexpected_text_or_tts, _}, 30
  end

  test "real Speakable shaping preserves raw canonical reply but never plays raw provider audio or sends raw TTS",
       ctx do
    events(ctx, @shaped)
    assert {:ok, id} = start(ctx)

    assert %{state: :complete, result: %{reply: @shaped, disposition: :screen_only}} =
             public = done(id)

    assert public.result.spoken_text != @shaped
    assert_canonical_turn(ctx, @shaped)
    assert_receive :provider_closed
    refute_receive {:effect, {:create, :sink, _, _}}, 50
    refute_receive {:effect, {:write, _, _}}, 30
    refute_receive {:unexpected_text_or_tts, _}, 30
    assert Multimedia.device_status() == :idle
  end

  test "cancelling Desk during real Native capture waits for positive close before retiring and never opens provider",
       ctx do
    ArborNativeFake.set(:hold, true)
    events(ctx, @plain)
    assert {:ok, id} = start(ctx)
    assert_receive {:effect, {:create, :source, element, resource}}
    assert_receive {:effect, {:held, executor}}
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    assert {:ok, %{terminal: false, state: :cleanup_pending}} = Voice.desk_turn_status(id)
    await_device_status(:cleanup_pending)
    assert {:error, :device_busy} = Multimedia.devices()
    send(executor, :release_native)
    assert %{terminal: true, state: :cancelled} = done(id)
    assert_receive {:effect, {:destroy, ^resource}}
    refute Process.alive?(element)
    assert Multimedia.device_status() == :idle
    assert Store.snapshot().entries == []
    refute_receive {:provider_opened, _}, 30
    refute_receive {:effect, {:start, _, _}}, 30
  end

  test "cancelling during actual Presentation native startup preserves the recorded turn and joins playback close",
       ctx do
    Agent.update(ctx.queue, fn _ ->
      [
        {:input_transcript, " Actual spoken input. "},
        {:output_audio, @output},
        {:wait_for_final, @plain}
      ]
    end)

    assert {:ok, id} = start(ctx)
    assert_receive {:provider_final_wait, provider}
    ArborNativeFake.set(:hold, true)
    send(provider, :release_final)
    assert_receive :provider_closed
    assert_receive {:effect, {:create, :sink, element, resource}}
    assert_receive {:effect, {:held, executor}}
    assert_canonical_turn(ctx, @plain)
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    assert {:ok, %{terminal: false, state: :cleanup_pending}} = Voice.desk_turn_status(id)
    send(executor, :release_native)
    assert %{terminal: true, state: :cancelled} = done(id)
    assert_receive {:effect, {:destroy, ^resource}}
    refute Process.alive?(element)
    refute_receive {:effect, {:start, :sink, _}}, 30
    refute_receive {:effect, {:write, _, _}}, 30
    assert Multimedia.device_status() == :idle
    assert %{appends: 1} = Store.snapshot()
  end

  test "revocation between native capture and fresh Voice admission prevents provider startup and recording",
       ctx do
    ArborNativeFake.set(:hold, true)
    events(ctx, @plain)
    assert {:ok, id} = start(ctx)
    assert_receive {:effect, {:create, :source, _, _}}
    assert_receive {:effect, {:held, executor}}
    assert :ok = Security.revoke(ctx.capability.id)
    send(executor, :release_native)
    assert %{terminal: true, state: :cancelled} = done(id)
    refute_receive {:provider_opened, _}, 30
    refute_receive {:effect, {:create, :sink, _, _}}, 30
    assert Store.snapshot().entries == []
    assert Multimedia.device_status() == :idle
  end

  test "cancelling a bounded provider receive discards late audio, positively closes, and permits an explicit fresh turn",
       ctx do
    Agent.update(ctx.queue, fn _ -> [{:bounded_cancel_event, {:output_audio, @output}}] end)
    assert {:ok, id} = start(ctx)
    assert_receive {:provider_recv_wait, provider, timeout}
    assert timeout in 1..100
    [{_, owner, _, _}] = DynamicSupervisor.which_children(Arbor.Voice.ResourceSupervisor)
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)

    # Synchronize only on redacted diagnostics; public results below prove the
    # behavior. If the predecessor kills the owner, continue to the missing
    # provider-close assertion rather than treating that death as cleanup proof.
    await_closing_or_down(owner)
    send(provider, :release_recv)
    assert_receive :provider_closed
    assert %{terminal: true, state: :cancelled, result: nil} = done(id)
    refute Process.alive?(provider)
    assert Multimedia.device_status() == :idle
    assert Store.snapshot().entries == []
    refute_receive {:effect, {:create, :sink, _, _}}, 30
    refute_receive {:unexpected_text_or_tts, _}, 30

    events(ctx, @plain)
    assert {:ok, retry} = start(ctx)
    refute retry == id
    assert %{state: :complete, result: %{reply: @plain, disposition: :played}} = done(retry)
    assert_canonical_turn(ctx, @plain)
    assert %{appends: 1} = Store.snapshot()
    assert Multimedia.device_status() == :idle
  end

  defp events(ctx, text),
    do:
      Agent.update(ctx.queue, fn _ ->
        [
          {:input_transcript, " Actual spoken input. "},
          {:output_audio, @output},
          {:turn_done, %{text: text}}
        ]
      end)

  defp start(ctx),
    do:
      Voice.start_desk_turn(ctx.user, ctx.agent,
        session_token: ctx.token,
        expected_engagement_id: @engagement,
        duration_ms: 100
      )

  defp assert_canonical_turn(ctx, raw) do
    assert [user, assistant] =
             Comms.load_engagement_transcript(ctx.agent, @engagement, persistence: Store)

    assert user.role == "user"
    assert assistant.role == "assistant"
    assert user.content == [%{"type" => "text", "text" => " Actual spoken input. "}]
    assert assistant.content == [%{"type" => "text", "text" => raw}]
    assert user.metadata["transport"] == "voice"
    assert user.metadata["engagement_id"] == @engagement
    assert assistant.metadata["engagement_id"] == @engagement

    assert {:ok, _} =
             Taint.verify_durable_provenance(user.metadata["taint"], user.content)

    assert {:ok, _} =
             Taint.verify_durable_provenance(
               assistant.metadata["taint"],
               assistant.content
             )

    assert user.metadata["utterance_end_at"] == DateTime.to_iso8601(user.timestamp)
    assert DateTime.compare(user.timestamp, assistant.timestamp) in [:lt, :eq]
  end

  defp done(id, n \\ 400)
  defp done(_, 0), do: flunk("integrated desk operation did not settle")

  defp done(id, n) do
    assert {:ok, state} = Voice.desk_turn_status(id)

    if state.terminal,
      do: state,
      else:
        (
          Process.sleep(10)
          done(id, n - 1)
        )
  end

  defp await_closing_or_down(owner, attempts \\ 40)
  defp await_closing_or_down(_, 0), do: :ok

  defp await_closing_or_down(owner, attempts) do
    if inspect(:sys.get_status(owner, 100)) =~ "phase: :closing" do
      :ok
    else
      Process.sleep(1)
      await_closing_or_down(owner, attempts - 1)
    end
  catch
    :exit, _ -> :ok
  end

  defp await_device_status(expected, attempts \\ 40)
  defp await_device_status(expected, 0), do: assert(Multimedia.device_status() == expected)

  defp await_device_status(expected, attempts) do
    if Multimedia.device_status() == expected do
      :ok
    else
      Process.sleep(5)
      await_device_status(expected, attempts - 1)
    end
  end
end
