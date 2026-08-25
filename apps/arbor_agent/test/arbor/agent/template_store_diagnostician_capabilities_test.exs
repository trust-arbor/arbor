defmodule Arbor.Agent.TemplateStoreDiagnosticianCapabilitiesTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.TemplateStore

  # The shipped priv/templates/*.md wins over the legacy .arbor/templates/*.json.
  # The diagnostician .md declared only self-code + memory + orchestrator caps
  # while the (never used) .json carried the diagnostic set, so live
  # diagnosticians held no monitor/historian/fs authority at all (2026-08-25).
  # This pins the resolved template, whichever file wins.
  test "the resolved diagnostician template grants its diagnostic toolkit" do
    assert {:ok, data} = TemplateStore.get("diagnostician")

    resources =
      data
      |> Map.get("required_capabilities", [])
      |> Enum.map(&(&1["resource"] || &1[:resource]))

    for uri <- ~w(arbor://monitor/read arbor://monitor/remediate arbor://historian/query
                  arbor://fs/read arbor://fs/list arbor://consensus/propose
                  arbor://memory/write arbor://orchestrator/execute) do
      assert uri in resources, "diagnostician template is missing #{uri}"
    end
  end
end
