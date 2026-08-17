defmodule Arbor.Common.Extension.FakeTransportTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Extension.FakeTransport
  alias Arbor.Contracts.Extension.Envelope

  @fixture_dir Path.expand(
                 "../../../../../arbor_kernel/test/fixtures/extension_envelopes/v1",
                 __DIR__
               )

  test "local and external fakes consume the same committed request fixture" do
    request = load_fixture("invocation_request.json")
    authorization = load_fixture("invocation_authorization.json")
    handle = load_fixture("provider_handle.json")

    input = %{handle: handle, authorization: authorization, request: request}

    assert {:ok, local, [{:consume_nonce, nonce}]} =
             FakeTransport.invoke("local_module", input,
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z"
             )

    external_handle = %{handle | "transport_class" => "external"}

    assert {:ok, external, [{:consume_nonce, ^nonce}]} =
             FakeTransport.invoke(
               "external",
               %{input | handle: external_handle},
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:ok, _} = Envelope.validate(:invocation_result, local)
    assert {:ok, _} = Envelope.validate(:invocation_result, external)
    assert local["request_sha256"] == request["request_sha256"]
    assert external["request_sha256"] == request["request_sha256"]
    assert local["effect_disposition"] == "applied"
    assert external["effect_disposition"] == "applied"
  end

  test "external transport loss is unknown and blocks non-idempotent retry" do
    request = Envelope.fixture(:invocation_request)
    authorization = Envelope.fixture(:invocation_authorization)
    handle = %{Envelope.fixture(:provider_handle) | "transport_class" => "external"}
    input = %{handle: handle, authorization: authorization, request: request}

    assert {:pending, lost, [{:consume_nonce, nonce}]} =
             FakeTransport.invoke("external", input,
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z",
               loss: true
             )

    assert lost["effect_disposition"] == "unknown"
    assert lost["error_code"] == "provider_unavailable"

    assert {:error, "replayed"} =
             FakeTransport.invoke("external", input,
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z",
               consumed_nonces: MapSet.new([nonce]),
               pending_unknown: true
             )

    assert {:error, "effect_disposition_unknown"} =
             FakeTransport.invoke("external", input,
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z",
               pending_unknown: true,
               idempotent: false
             )

    assert {:ok, _retried, _effects} =
             FakeTransport.invoke("external", input,
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z",
               pending_unknown: true,
               idempotent: true
             )
  end

  test "stale generation, expired lease, and digest mismatch fail closed" do
    request = Envelope.fixture(:invocation_request)
    authorization = Envelope.fixture(:invocation_authorization)
    handle = Envelope.fixture(:provider_handle)
    input = %{handle: handle, authorization: authorization, request: request}

    stale = %{handle | "generation" => 2}

    assert {:error, "denied"} =
             FakeTransport.invoke("local_module", %{input | handle: stale},
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "expired"} =
             FakeTransport.invoke("local_module", input,
               allow_unsigned: true,
               now: "2026-08-18T00:00:00Z"
             )

    mismatched = %{authorization | "request_sha256" => String.duplicate("00", 32)}

    assert {:error, "digest_mismatch"} =
             FakeTransport.invoke("local_module", %{input | authorization: mismatched},
               allow_unsigned: true,
               now: "2026-08-16T00:00:00Z"
             )
  end

  defp load_fixture(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
