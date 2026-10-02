baseline_source =
  Path.expand("../../fixtures/measurements/baseline-core.ex.txt", __DIR__) |> File.read!()

Code.compile_string(
  String.replace(
    baseline_source,
    "defmodule ConversationKit do",
    "defmodule BaselineConversationKit do",
    global: false
  )
)

defmodule ConversationKit.ExtensionTest do
  use ExUnit.Case, async: true

  test "frozen old core rejects the new event; upgraded core projects a passive text fallback" do
    fixture =
      Path.expand("../../fixtures/v1/notice.json", __DIR__) |> File.read!() |> JSON.decode!()

    {baseline, [notice]} = Enum.split(fixture["events"], 11)

    {:ok, before} =
      BaselineConversationKit.replay(baseline, BaselineConversationKit.new(fixture["id"]))

    assert {:error, :invalid_event} = BaselineConversationKit.apply(before, notice)
    assert {:ok, after_state} = ConversationKit.apply(before, notice)
    projection = ConversationKit.project(after_state)

    assert List.last(projection["blocks"]) == %{
             "id" => "host-advisory",
             "type" => "notice",
             "status" => "info",
             "severity" => "info",
             "text" => "This conversation is available on another device."
           }

    assert projection["speech"] == BaselineConversationKit.project(before)["speech"]
    assert after_state["revision"] == 12
    assert {:ok, ^after_state} = ConversationKit.apply(after_state, notice)

    assert {:error, :notice_already_exists} =
             ConversationKit.apply(after_state, %{
               notice
               | "id" => "another-event",
                 "revision" => 13
             })

    assert {:error, :invalid_event} =
             ConversationKit.apply(after_state, put_in(notice, ["data", "severity"], "execute"))
  end
end
