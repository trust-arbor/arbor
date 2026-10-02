baseline = Path.expand("../../fixtures/measurements/pre-actionability-core.ex.txt", __DIR__)
source = File.read!(baseline)

Code.compile_string(
  String.replace(source, "defmodule ConversationKit do", "defmodule PreviousConversationKit do",
    global: false
  )
)

fixture =
  Path.expand("../../fixtures/v1/conversation.json", __DIR__) |> File.read!() |> JSON.decode!()

{:ok, before} =
  PreviousConversationKit.replay(fixture["events"], PreviousConversationKit.new(fixture["id"]))

{:ok, after_state} = ConversationKit.replay(fixture["events"], ConversationKit.new(fixture["id"]))

settled = %{
  "id" => "proof-12",
  "revision" => 12,
  "kind" => "settled",
  "data" => %{
    "command_id" => "research",
    "outcome" => %{
      "status" => "cancelled",
      "output" => nil,
      "error" => nil
    }
  }
}

{:ok, before} = PreviousConversationKit.apply(before, settled)
{:ok, after_state} = ConversationKit.apply(after_state, settled)
previous = PreviousConversationKit.project(before)
current = ConversationKit.project(after_state)

report = %{
  "scope" => "Projection correctness adjustment before notice extension, no authorization bypass",
  "before" => Map.take(previous, ["approvals", "tools", "speech"]),
  "after" => Map.take(current, ["approvals", "tools", "speech"]),
  "preserved_authoritative_approval" => after_state["approvals"],
  "preserved_authoritative_tool" => after_state["tools"]
}

true = hd(previous["approvals"])["status"] == "pending"
true = Enum.any?(previous["speech"], &(&1["type"] == "screen_required"))
true = hd(current["approvals"])["status"] == "unresolved"
false = Enum.any?(current["speech"], &(&1["type"] == "screen_required"))
out = Path.expand("../../fixtures/measurements/actionability-fix.json", __DIR__)
File.write!(out, JSON.encode!(report))

IO.puts(
  "Verified previous pending control/escalation becomes unresolved and silent after terminal cancellation."
)
