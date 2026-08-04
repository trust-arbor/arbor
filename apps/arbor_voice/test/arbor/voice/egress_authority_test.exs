defmodule Arbor.Voice.EgressAuthorityTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.EgressAuthority

  @route %{
    destination: "api.x.ai",
    provider: "xai",
    runtime: "arbor",
    model: "grok-voice-latest"
  }
  @session_id "session_0123456789abcdef0123456789abcdef"
  @turn_id "turn_0123456789abcdef0123456789abcdef"
  @malformed_capability_id "cap_gggggggggggggggggggggggggggggggg"

  defmodule MalformedCapabilitySecurity do
    @moduledoc false

    def uri_registered?(_resource), do: true

    def grant_capability_id(_opts) do
      {:ok, "cap_gggggggggggggggggggggggggggggggg"}
    end

    def issue_disclosure_capability_id(_opts) do
      {:ok, "cap_gggggggggggggggggggggggggggggggg"}
    end

    def revoke(_capability_id), do: :ok
  end

  test "correct-length non-hex authority identifiers fail closed before retention" do
    refute EgressAuthority.canonical_session_id?("session_gggggggggggggggggggggggggggggggg")
    refute EgressAuthority.canonical_capability_id?(@malformed_capability_id)

    config = %{
      agent_id: "agent_0123456789abcdef0123456789abcdef",
      user_id: "human-1",
      security_module: MalformedCapabilitySecurity,
      trust_module: __MODULE__,
      wall_clock: fn -> DateTime.from_unix!(0) end
    }

    assert {:error, :start_failed} =
             EgressAuthority.prepare_session_authority(
               %{kind: :external, route: @route, tier: :external_provider},
               config,
               @session_id,
               1_000
             )

    authority = %{
      kind: :external,
      route: @route,
      tier: :external_provider,
      agent_id: config.agent_id,
      human_id: config.user_id,
      session_id: @session_id,
      resource_uri: "arbor://voice/realtime/xai/#{@session_id}",
      route_capability_id: "cap_0123456789abcdef0123456789abcdef",
      security_module: MalformedCapabilitySecurity,
      trust_module: __MODULE__
    }

    assert {:error, :turn_failed} = EgressAuthority.issue_turn(authority, @turn_id)
  end

  test "canonical identifiers require exact prefixes and lowercase hex" do
    assert EgressAuthority.canonical_session_id?(@session_id)
    assert EgressAuthority.canonical_capability_id?("cap_0123456789abcdef0123456789abcdef")

    refute EgressAuthority.canonical_session_id?(String.upcase(@session_id))
    refute EgressAuthority.canonical_capability_id?("cap_0123456789abcdef0123456789abcde")
  end
end
