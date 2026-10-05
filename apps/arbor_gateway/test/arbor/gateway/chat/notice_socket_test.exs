defmodule Arbor.Gateway.Chat.NoticeSocketTest.Security do
  @moduledoc false

  def claim_terminal_session(credential) do
    with {:ok, binding} <- verify_terminal_session(credential) do
      {:ok, Map.delete(binding, :session_token)}
    end
  end

  def verify_terminal_session(credential) do
    if credential == String.duplicate("n", 43) and Process.get(:notice_lease_valid, true) do
      number = Process.get(:notice_proof_number, 0) + 1
      Process.put(:notice_proof_number, number)
      token = "server-only-notice-proof-#{number}"
      Process.put(:notice_latest_proof, token)

      {:ok,
       %{
         principal: "human_owner",
         target: "agent_a",
         owner: "human_owner",
         lifetime: :connection,
         session_token: token
       }}
    else
      {:error, :unauthorized}
    end
  end
end

defmodule Arbor.Gateway.Chat.NoticeSocketTest.Host do
  @moduledoc false
  # A frame-boundary collaborator with real Ed25519 proofs and one-use nonces.
  # It records the public facade call and issues deterministic pages. Real
  # Agent execution, linked-human resolution and notice authority are tested by
  # their own public-facade journeys; this fixture makes none of those claims.
  alias Arbor.Contracts.Security.SignedRequest

  @engagement "eng_11111111111111111111111111111111"

  def conversation_window(caller, target, opts) do
    with :ok <- authenticate(:window, caller, target, opts) do
      send(self(), {:notice_dispatch, :window, caller, target, opts})

      {:ok,
       %{
         engagement_id: @engagement,
         entries: [%{id: "owned", role: "user", content: "existing transcript", entry_ordinal: 1}],
         head: 1,
         first: 1,
         last: 1,
         has_older: false,
         has_newer: false
       }}
    end
  end

  def conversation_notices(caller, target, opts) do
    with :ok <- authenticate(:notices, caller, target, opts) do
      send(self(), {:notice_dispatch, :notices, caller, target, opts})
      if Process.get(:notice_lose_after_call, false), do: Process.put(:notice_lease_valid, false)
      Process.get(:notice_host_result, {:ok, page()})
    end
  end

  def page do
    %{
      owner_id: "human_owner",
      target_agent_id: "agent_a",
      engagement_id: @engagement,
      notices: [notice()],
      head: 1,
      through: 1,
      has_older: false,
      next_before: nil,
      complete: true
    }
  end

  defp notice do
    id = "notice_11111111111111111111111111111111"
    text = "Separate native notice"

    digest =
      [
        "arbor.notice.provenance.v1",
        "human_owner",
        "agent_a",
        @engagement,
        "human_owner",
        id,
        "notification",
        text
      ]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{
      notice_id: id,
      recipient_subject_id: "human_owner",
      kind: :notification,
      text: text,
      ordinal: 1,
      created_at: "2026-10-03T12:00:00.000000Z",
      provenance: %{
        origin: :native_action,
        taint: %{
          version: 1,
          payload_encoding: :canonical_json_v1,
          payload_sha256: digest,
          taint: %{
            level: :untrusted,
            sensitivity: :internal,
            sanitizations: 0,
            confidence: :unverified,
            source: :native_conversation_notice,
            chain: []
          }
        }
      }
    }
  end

  defp authenticate(operation, caller, target, opts) do
    clean = Keyword.drop(opts, [:signed_request, :session_token])

    expected =
      if operation == :notices,
        do: Arbor.Agent.conversation_notice_request_payload(caller, target, clean),
        else: Arbor.Agent.conversation_request_payload(:window, caller, target, nil, clean)

    with {:ok, payload} <- expected,
         false <- Process.get(:notice_revoked, false),
         true <- proof?(caller, payload, opts) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp proof?(caller, payload, opts) do
    case Keyword.fetch(opts, :signed_request) do
      {:ok, proof} ->
        public = Process.get({:notice_key, caller})

        valid =
          is_binary(public) and proof.agent_id == caller and proof.payload == payload and
            not Process.get({:notice_nonce, proof.nonce}, false) and
            :crypto.verify(:eddsa, :none, SignedRequest.signing_payload(proof), proof.signature, [
              public,
              :ed25519
            ])

        if valid, do: Process.put({:notice_nonce, proof.nonce}, true)
        valid

      :error ->
        Keyword.get(opts, :session_token) == Process.get(:notice_latest_proof)
    end
  end
end

defmodule Arbor.Gateway.Chat.NoticeSocketTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.Socket

  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"

  setup do
    previous =
      Map.new(
        [:chat_agent_facade, :terminal_login_security],
        &{&1, Application.fetch_env(:arbor_gateway, &1)}
      )

    Application.put_env(:arbor_gateway, :chat_agent_facade, __MODULE__.Host)
    Application.put_env(:arbor_gateway, :terminal_login_security, __MODULE__.Security)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arbor_gateway, key, value)
          :error -> Application.delete_env(:arbor_gateway, key)
        end
      end
    end)

    {public, key} = :crypto.generate_key(:eddsa, :ed25519)
    Process.put({:notice_key, "human_owner"}, public)
    {:ok, state} = Socket.init(%{principal: "human_owner"})
    %{state: state, key: key}
  end

  test "security regression supported signed window attaches before the separate notice page succeeds",
       %{state: state, key: key} do
    attached = attach_signed(state, key)
    assert attached.agent_id == "agent_a"
    assert attached.engagement_id == @engagement

    {reply, latest} =
      drive(signed_frame(:notices, key, before: 2, through: 1, limit: 1), attached)

    assert reply["type"] == "conversation_notices"
    assert reply["data"] == Jason.decode!(Jason.encode!(__MODULE__.Host.page()))

    assert Enum.sort(Map.keys(reply["data"])) ==
             ~w(complete engagement_id has_older head next_before notices owner_id target_agent_id through)

    assert latest.agent_id == attached.agent_id
    assert latest.engagement_id == attached.engagement_id
    assert_receive {:notice_dispatch, :notices, "human_owner", "agent_a", opts}
    assert %SignedRequest{} = opts[:signed_request]
    assert opts[:before] == 2
    assert opts[:through] == 1
    assert opts[:limit] == 1
    assert opts[:expected_engagement_id] == @engagement
    refute Keyword.has_key?(opts, :session_token)
  end

  test "security regression signed notice replay forged signature changed selector and revocation withhold data",
       %{state: state, key: key} do
    attached = attach_signed(state, key)
    original = signed_frame(:notices, key, limit: 1)
    assert {%{"type" => "conversation_notices"}, _} = drive(original, attached)
    assert_receive {:notice_dispatch, :notices, _, _, _}
    assert {%{"reason" => "unauthorized"}, _} = drive(original, attached)

    wire = Jason.decode!(signed_frame(:notices, key, limit: 1))

    altered =
      wire["payload"] |> Jason.decode!() |> List.replace_at(3, [nil, nil, 2]) |> Jason.encode!()

    assert {%{"reason" => "unauthorized"}, _} =
             drive(Jason.encode!(Map.put(wire, "payload", altered)), attached)

    {_, foreign_key} = :crypto.generate_key(:eddsa, :ed25519)

    assert {%{"reason" => "unauthorized"}, _} =
             drive(signed_frame(:notices, foreign_key), attached)

    Process.put(:notice_revoked, true)
    assert {%{"reason" => "unauthorized"}, _} = drive(signed_frame(:notices, key), attached)
    refute_receive {:notice_dispatch, :notices, _, _, _}
  end

  test "security regression notices require attachment and cannot replace the pinned target or fence",
       %{state: state, key: key} do
    assert {%{"reason" => "not_attached"}, _} = drive(signed_frame(:notices, key), state)
    refute_receive {:notice_dispatch, :notices, _, _, _}
    attached = attach_signed(state, key)

    for opts <- [
          [target: "agent_b"],
          [expected_engagement_id: "eng_22222222222222222222222222222222"]
        ] do
      {reply, invalidated} = drive(signed_frame(:notices, key, opts), attached)
      assert reply == %{"type" => "error", "reason" => "conversation_scope_changed"}
      assert invalidated.invalidated?
      assert invalidated.agent_id == nil
      assert invalidated.engagement_id == nil
    end

    refute_receive {:notice_dispatch, :notices, _, _, _}
  end

  test "security regression signed notice subject must match the authenticated socket principal",
       %{state: state, key: key} do
    attached = attach_signed(state, key)

    assert {%{"reason" => "unauthorized"}, _} =
             drive(signed_frame(:notices, key, caller: "human_foreign"), attached)

    refute_receive {:notice_dispatch, :notices, _, _, _}
  end

  test "notice subject required is a narrow refusal and preserves the successful window attachment",
       _context do
    {public, key} = :crypto.generate_key(:eddsa, :ed25519)
    Process.put({:notice_key, "agent_reader"}, public)
    {:ok, state} = Socket.init(%{principal: "agent_reader"})
    attached = attach_signed(state, key, caller: "agent_reader")
    Process.put(:notice_host_result, {:error, :notice_subject_required})
    {reply, latest} = drive(signed_frame(:notices, key, caller: "agent_reader"), attached)
    assert reply == %{"type" => "error", "reason" => "notice_subject_required"}
    assert latest.agent_id == "agent_a"
    assert latest.engagement_id == @engagement
    refute latest.invalidated?
    refute Map.has_key?(reply, "data")
    assert_receive {:notice_dispatch, :notices, _, _, _}

    Process.delete(:notice_host_result)

    assert {%{"type" => "conversation_window"}, _} =
             drive(signed_frame(:window, key, caller: "agent_reader"), latest)

    assert_receive {:notice_dispatch, :window, _, _, _}
  end

  test "security regression foreign host scope private fields missing keys extras and oversized replies are withheld",
       %{state: state, key: key} do
    attached = attach_signed(state, key)
    page = __MODULE__.Host.page()

    for {malformed, reason} <- [
          {%{page | target_agent_id: "agent_b"}, "conversation_scope_changed"},
          {%{page | engagement_id: "eng_22222222222222222222222222222222"},
           "conversation_scope_changed"},
          {Map.delete(page, :owner_id), "conversation_unavailable"},
          {Map.put(page, :extra, "unexpected page field"), "conversation_unavailable"},
          {Map.put(page, :session_token, "private"), "conversation_unavailable"},
          {Map.put(page, :proof, "private"), "conversation_unavailable"},
          {%{page | notices: [Map.put(hd(page.notices), :session_token, "nested private")]},
           "conversation_unavailable"},
          {%{page | notices: [%{hd(page.notices) | text: String.duplicate("x", 131_073)}]},
           "page_too_large"}
        ] do
      Process.put(:notice_host_result, {:ok, malformed})
      assert {%{"reason" => ^reason}, _} = drive(signed_frame(:notices, key), attached)
      assert_receive {:notice_dispatch, :notices, _, _, _}
    end
  end

  test "terminal notice reads carry fresh server-held proofs and preserve the exact page" do
    state = terminal_state()
    attached = attach_terminal(state)

    tokens =
      for _ <- 1..2 do
        {reply, _} = drive(session_frame(:notices, limit: 1), attached)
        assert reply["type"] == "conversation_notices"
        assert reply["data"] == Jason.decode!(Jason.encode!(__MODULE__.Host.page()))
        assert_receive {:notice_dispatch, :notices, "human_owner", "agent_a", opts}
        refute Keyword.has_key?(opts, :signed_request)
        opts[:session_token]
      end

    assert Enum.all?(tokens, &is_binary/1)
    assert length(Enum.uniq(tokens)) == 2
    Socket.terminate(:normal, attached)
  end

  test "security regression terminal binding revocation before notices prevents host dispatch" do
    attached = attach_terminal(terminal_state())
    Process.put(:notice_lease_valid, false)
    {reply, closed} = drive(session_frame(:notices), attached)
    assert reply == %{"type" => "error", "reason" => "unauthorized"}
    assert closed.invalidated?
    assert closed.agent_id == nil
    assert closed.engagement_id == nil
    refute_receive {:notice_dispatch, :notices, _, _, _}
  end

  test "security regression terminal authority loss after notice admission withholds success and refusal" do
    for result <- [{:ok, __MODULE__.Host.page()}, {:error, :notice_subject_required}] do
      Process.put(:notice_lease_valid, true)
      Process.delete(:notice_lose_after_call)
      attached = attach_terminal(terminal_state())
      Process.put(:notice_host_result, result)
      Process.put(:notice_lose_after_call, true)
      {reply, closed} = drive(session_frame(:notices), attached)
      assert reply == %{"type" => "error", "reason" => "unauthorized"}
      assert closed.invalidated?
      assert closed.credential_table == nil
      assert closed.agent_id == nil
      assert closed.engagement_id == nil
      assert_receive {:notice_dispatch, :notices, _, _, _}
      refute Map.has_key?(reply, "data")
    end
  end

  test "security regression terminal notice caller and target cannot replace the server binding" do
    attached = attach_terminal(terminal_state())

    for opts <- [[caller: "human_foreign"], [target: "agent_b"]] do
      assert {%{"reason" => "unauthorized"}, _} = drive(session_frame(:notices, opts), attached)
    end

    refute_receive {:notice_dispatch, :notices, _, _, _}
    Socket.terminate(:normal, attached)
  end

  defp attach_signed(state, key, opts \\ []) do
    {reply, attached} = drive(signed_frame(:window, key, opts), state)
    assert reply["type"] == "conversation_window"
    assert reply["data"]["entries"] |> hd() |> Map.fetch!("content") == "existing transcript"
    assert_receive {:notice_dispatch, :window, _, _, _}
    attached
  end

  defp attach_terminal(state) do
    {reply, attached} = drive(session_frame(:window), state)
    assert reply["type"] == "conversation_window"
    assert_receive {:notice_dispatch, :window, _, _, _}
    attached
  end

  defp terminal_state do
    {:ok, state} =
      Socket.init(%{
        auth_mode: :conversation_session,
        credential: String.duplicate("n", 43),
        principal: "human_owner",
        target: "agent_a",
        owner: "human_owner",
        lifetime: :connection
      })

    state
  end

  defp payload(operation, opts) do
    {caller, opts} = Keyword.pop(opts, :caller, "human_owner")
    {target, opts} = Keyword.pop(opts, :target, "agent_a")
    opts = Keyword.put_new(opts, :expected_engagement_id, @engagement)

    result =
      if operation == :notices,
        do: Arbor.Agent.conversation_notice_request_payload(caller, target, opts),
        else: Arbor.Agent.conversation_request_payload(:window, caller, target, nil, opts)

    {:ok, payload} = result
    {caller, payload}
  end

  defp session_frame(operation, opts \\ []) do
    {_, payload} = payload(operation, opts)
    Jason.encode!(%{payload: payload, authentication: "conversation_session"})
  end

  defp signed_frame(operation, key, opts \\ []) do
    {caller, payload} = payload(operation, opts)
    {:ok, proof} = SignedRequest.sign(payload, caller, key)

    auth = %{
      agent_id: proof.agent_id,
      timestamp: DateTime.to_iso8601(proof.timestamp),
      nonce: Base.encode64(proof.nonce),
      signature: Base.encode64(proof.signature)
    }

    Jason.encode!(%{
      payload: payload,
      authorization: "Signature " <> Base.encode64(Jason.encode!(auth), padding: false)
    })
  end

  defp drive(frame, state) do
    case Socket.handle_in({frame, [opcode: :text]}, state) do
      {:push, [{:text, json}], state} -> {Jason.decode!(json), state}
      {:stop, :normal, 1008, [{:text, json}], state} -> {Jason.decode!(json), state}
    end
  end
end
