defmodule Arbor.Voice.ToolRouter.FrontDeskDispatchTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.ToolRouter.FrontDesk

  test "catalog is exactly consult_agent and dispatch_coding_task" do
    catalog = FrontDesk.catalog()
    assert length(catalog) == 2
    assert Enum.map(catalog, & &1["name"]) == ["consult_agent", "dispatch_coding_task"]

    dispatch = Enum.find(catalog, &(&1["name"] == "dispatch_coding_task"))
    params = dispatch["parameters"]
    assert params["required"] == ["task"]
    assert params["additionalProperties"] == false
    assert Map.keys(params["properties"]) == ["task"]
    assert params["properties"]["task"]["maxLength"] == 2048
  end

  test "dispatch_coding_task returns immediate task_id status shape" do
    authority = %{
      dispatch_coding_task: fn intent ->
        assert intent == "fix the bug"
        {:ok, "task_abc_1"}
      end
    }

    assert {:ok, %{"task_id" => "task_abc_1", "status" => "dispatched"}} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => "fix the bug"}},
               authority
             )
  end

  test "strict one-key task arguments; extras and malformed fail closed" do
    authority = %{
      dispatch_coding_task: fn _ -> flunk("must not call") end
    }

    assert {:error, :invalid_arguments} =
             FrontDesk.invoke(%{name: "dispatch_coding_task", arguments: %{}}, authority)

    assert {:error, :invalid_arguments} =
             FrontDesk.invoke(
               %{
                 name: "dispatch_coding_task",
                 arguments: %{"task" => "ok", "repo" => "/evil"}
               },
               authority
             )

    assert {:error, :invalid_arguments} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => ""}},
               authority
             )

    assert {:error, :invalid_arguments} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => "bad\nline"}},
               authority
             )

    assert {:error, :invalid_arguments} =
             FrontDesk.invoke(%{name: "dispatch_coding_task"}, authority)
  end

  test "dispatch failures and malformed returns normalize to tool_error" do
    assert {:error, :tool_error} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => "x"}},
               %{dispatch_coding_task: fn _ -> {:error, :unauthorized} end}
             )

    assert {:error, :tool_error} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => "x"}},
               %{dispatch_coding_task: fn _ -> {:ok, "bad id with spaces"} end}
             )

    assert {:error, :tool_error} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => "x"}},
               %{dispatch_coding_task: fn _ -> :not_a_tuple end}
             )

    assert {:error, :tool_error} =
             FrontDesk.invoke(
               %{name: "dispatch_coding_task", arguments: %{"task" => "x"}},
               %{}
             )
  end

  test "unknown tool name is unknown_tool" do
    assert {:error, :unknown_tool} =
             FrontDesk.invoke(%{name: "spawn_acp", arguments: %{}}, %{})
  end
end
