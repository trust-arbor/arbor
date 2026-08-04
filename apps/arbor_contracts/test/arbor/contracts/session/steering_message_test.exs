defmodule Arbor.Contracts.Session.SteeringMessageTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.SteeringMessage

  @message_id "steer_0123456789abcdef0123456789abcdef"
  @engagement_id "eng_0123456789abcdef0123456789abcdef"

  defp taint(overrides \\ %{}) do
    struct(
      Taint,
      Map.merge(
        %{
          level: :untrusted,
          sensitivity: :internal,
          sanitizations: 0,
          confidence: :verified,
          source: "authenticated_user",
          chain: ["agent_ingress"]
        },
        overrides
      )
    )
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        message_id: @message_id,
        engagement_id: @engagement_id,
        content: "Please include this correction.",
        taint: taint()
      },
      overrides
    )
  end

  test "constructs only the exact four-field envelope" do
    assert {:ok, message} = SteeringMessage.new(attrs())

    assert Map.from_struct(message) == attrs()

    assert Enum.sort(Map.keys(Map.from_struct(message))) ==
             Enum.sort([:message_id, :engagement_id, :content, :taint])

    assert {:ok, nil_engagement} =
             attrs(%{engagement_id: nil}) |> SteeringMessage.new()

    assert nil_engagement.engagement_id == nil
  end

  test "exposes the named boundary policy constants" do
    assert SteeringMessage.max_content_bytes() == 32_768
    assert SteeringMessage.max_engagement_id_bytes() == 256
    assert SteeringMessage.max_taint_source_bytes() == 128
    assert SteeringMessage.max_taint_chain_entries() == 16
    assert SteeringMessage.max_taint_chain_entry_bytes() == 128
  end

  test "rejects missing, extra, duplicate, string-keyed, struct, and improper attributes" do
    assert {:error, :invalid_attributes} =
             attrs() |> Map.delete(:content) |> SteeringMessage.new()

    assert {:error, :invalid_attributes} =
             attrs(%{authority: :forged}) |> SteeringMessage.new()

    assert {:error, :invalid_attributes} =
             SteeringMessage.new(
               message_id: @message_id,
               engagement_id: @engagement_id,
               content: "one",
               content: "two",
               taint: taint()
             )

    assert {:error, :invalid_attributes} =
             SteeringMessage.new(%{
               "message_id" => @message_id,
               "engagement_id" => @engagement_id,
               "content" => "content",
               "taint" => taint()
             })

    assert {:error, :invalid_attributes} =
             attrs() |> then(&struct!(SteeringMessage, &1)) |> SteeringMessage.new()

    improper = [{:message_id, @message_id} | :not_a_list]
    assert {:error, :invalid_attributes} = SteeringMessage.new(improper)
  end

  test "enforces source-owned canonical identifiers" do
    for invalid <- [
          "steer_ABCDEF0123456789abcdef0123456789",
          "steer_" <> String.duplicate("a", 31),
          "msg_" <> String.duplicate("a", 32),
          123
        ] do
      assert {:error, :invalid_message_id} =
               attrs(%{message_id: invalid}) |> SteeringMessage.new()
    end

    for invalid <- [
          "eng_ABCDEF0123456789abcdef0123456789",
          "eng_" <> String.duplicate("a", 31),
          "other_" <> String.duplicate("a", 32),
          String.duplicate("x", 257),
          123
        ] do
      assert {:error, :invalid_engagement_id} =
               attrs(%{engagement_id: invalid}) |> SteeringMessage.new()
    end
  end

  test "enforces valid nonblank UTF-8 content at the Agent ingress ceiling" do
    max = SteeringMessage.max_content_bytes()
    assert {:ok, _} = attrs(%{content: String.duplicate("x", max)}) |> SteeringMessage.new()

    for invalid <- ["", " \n\t", <<255>>, String.duplicate("x", max + 1), nil] do
      assert {:error, :invalid_content} =
               attrs(%{content: invalid}) |> SteeringMessage.new()
    end
  end

  test "accepts an exact bounded taint and rejects malformed dimensions" do
    assert {:ok, _} = attrs(%{taint: taint(%{source: nil, chain: []})}) |> SteeringMessage.new()

    invalid_taints = [
      taint(%{level: :unknown}),
      taint(%{sensitivity: :secret}),
      taint(%{confidence: :certain}),
      taint(%{sanitizations: -1}),
      taint(%{sanitizations: 256}),
      taint(%{source: ""}),
      taint(%{source: <<255>>}),
      taint(%{source: String.duplicate("s", 129)}),
      taint(%{chain: String.duplicate("not-a-list", 2)}),
      taint(%{chain: List.duplicate("entry", 17)}),
      taint(%{chain: [nil]}),
      taint(%{chain: [""]}),
      taint(%{chain: [<<255>>]}),
      taint(%{chain: [String.duplicate("c", 129)]}),
      %{level: :untrusted}
    ]

    for invalid <- invalid_taints do
      assert {:error, :invalid_taint} =
               attrs(%{taint: invalid}) |> SteeringMessage.new()
    end
  end

  test "rejects extended taint structs and malformed steering structs" do
    extended_taint = Map.put(taint(), :authority, :forged)

    assert {:error, :invalid_taint} =
             attrs(%{taint: extended_taint}) |> SteeringMessage.new()

    assert {:ok, message} = SteeringMessage.new(attrs())
    assert {:ok, ^message} = SteeringMessage.canonicalize(message)

    assert {:error, :invalid_message_shape} =
             message |> Map.put(:turn_token, "forged") |> SteeringMessage.canonicalize()

    malformed = %{__struct__: SteeringMessage, message_id: @message_id}
    assert {:error, :invalid_message_shape} = SteeringMessage.canonicalize(malformed)
  end

  test "canonicalize revalidates exact atom-keyed maps and rejects unrelated terms" do
    assert {:ok, message} = SteeringMessage.canonicalize(attrs())
    assert message.message_id == @message_id

    assert {:error, :invalid_attributes} =
             attrs(%{timestamp: DateTime.utc_now()}) |> SteeringMessage.canonicalize()

    assert {:error, :invalid_steering_message} = SteeringMessage.canonicalize(:invalid)
  end
end
