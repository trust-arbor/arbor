defmodule Arbor.Voice.ToolRouter.FrontDeskTest do
  @moduledoc "FrontDesk static catalog and consult_agent failure table (VP-05B / VOICE-9)."
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.Session.ToolTaskCore
  alias Arbor.Voice.ToolRouter.EmptyCatalog
  alias Arbor.Voice.ToolRouter.FrontDesk

  @tag spec: "VOICE-9"
  test "catalog includes consult_agent function schema with min/maxLength" do
    tools = FrontDesk.tools()
    assert tools == FrontDesk.catalog()
    assert Enum.map(tools, & &1["name"]) == ["consult_agent", "dispatch_coding_task"]

    decl = Enum.find(tools, &(&1["name"] == "consult_agent"))
    assert decl["type"] == "function"
    assert is_binary(decl["description"]) and String.trim(decl["description"]) != ""

    params = decl["parameters"]
    assert params["type"] == "object"
    assert params["required"] == ["message"]
    assert params["additionalProperties"] == false

    message = params["properties"]["message"]
    assert message["type"] == "string"
    assert message["minLength"] == 1
    assert message["maxLength"] == 8192
  end

  @tag spec: "VOICE-9"
  test "EmptyCatalog remains empty with no_tools_installed" do
    assert EmptyCatalog.tools() == []
    assert EmptyCatalog.invoke(%{name: "consult_agent"}, %{}) == {:error, :no_tools_installed}
  end

  @tag spec: "VOICE-9"
  test "happy path returns structured reply for authority call" do
    authority = %{
      consult_agent: fn msg ->
        assert msg == "hello agent"
        {:ok, "grounded answer"}
      end
    }

    assert {:ok, %{"reply" => "grounded answer"}} =
             FrontDesk.invoke(
               %{name: "consult_agent", arguments: %{"message" => "hello agent"}},
               authority
             )

    encoded =
      ToolTaskCore.normalize(
        FrontDesk.invoke(
          %{name: "consult_agent", arguments: %{"message" => "hello agent"}},
          authority
        )
      )

    assert Jason.decode!(encoded) == %{
             "success" => true,
             "result" => %{"reply" => "grounded answer"}
           }
  end

  @tag spec: "VOICE-9"
  test "argument failure table rejects before authority call" do
    called = :atomics.new(1, signed: true)
    :atomics.put(called, 1, 0)

    authority = %{
      consult_agent: fn _ ->
        :atomics.add(called, 1, 1)
        {:ok, "nope"}
      end
    }

    # Wrong name → unknown_tool
    assert {:error, :unknown_tool} =
             FrontDesk.invoke(%{name: "other_tool", arguments: %{"message" => "x"}}, authority)

    assert Jason.decode!(
             ToolTaskCore.normalize(
               FrontDesk.invoke(%{name: "other_tool", arguments: %{"message" => "x"}}, authority)
             )
           ) == %{"code" => "unknown_tool"}

    # Correct consult_agent name with missing/malformed args → invalid_arguments
    # (tool_error after normalize), never unknown_tool.
    bad_consult_args = [
      %{name: "consult_agent", arguments: %{}},
      %{name: "consult_agent", arguments: %{"message" => "x", "extra" => "y"}},
      %{name: "consult_agent", arguments: %{"message" => ""}},
      %{name: "consult_agent", arguments: %{"message" => "   "}},
      %{name: "consult_agent", arguments: %{"message" => <<0xFF, 0xFE>>}},
      %{name: "consult_agent", arguments: %{"message" => String.duplicate("a", 8193)}},
      %{name: "consult_agent", arguments: %{"message" => 123}},
      %{name: "consult_agent"},
      %{name: "consult_agent", arguments: "not-a-map"}
    ]

    for ctx <- bad_consult_args do
      result = FrontDesk.invoke(ctx, authority)
      assert result == {:error, :invalid_arguments}, "unexpected #{inspect(result)} for #{inspect(ctx)}"
      assert Jason.decode!(ToolTaskCore.normalize(result)) == %{"code" => "tool_error"}
    end

    assert :atomics.get(called, 1) == 0
  end

  @tag spec: "VOICE-9"
  test "Agent denial, blank reply, and malformed returns collapse without leak" do
    cases = [
      {fn _ -> {:error, :unauthorized} end, "tool_error"},
      {fn _ -> {:error, :delivery_failed} end, "tool_error"},
      {fn _ -> {:ok, ""} end, "tool_error"},
      {fn _ -> {:ok, "   "} end, "tool_error"},
      {fn _ -> {:ok, 123} end, "tool_error"},
      {fn _ -> :not_a_result end, "tool_error"},
      {fn _ -> raise "boom" end, :raise},
      {fn _ -> throw(:x) end, :throw}
    ]

    for {fun, expected} <- cases do
      authority = %{consult_agent: fun}

      result =
        try do
          FrontDesk.invoke(
            %{name: "consult_agent", arguments: %{"message" => "hi"}},
            authority
          )
        rescue
          _ -> :raised
        catch
          :throw, _ -> :thrown
          :exit, _ -> :exited
        end

      case expected do
        :raise ->
          assert result == :raised

        :throw ->
          assert result == :thrown

        code when is_binary(code) ->
          assert {:error, :tool_error} = result
          assert Jason.decode!(ToolTaskCore.normalize(result)) == %{"code" => code}
          refute inspect(result) =~ "unauthorized"
          refute inspect(result) =~ "delivery_failed"
      end
    end
  end

  @tag spec: "VOICE-9"
  test "missing authority callable is tool_error without calling Agent" do
    assert {:error, :tool_error} =
             FrontDesk.invoke(
               %{name: "consult_agent", arguments: %{"message" => "hi"}},
               %{}
             )
  end

  @tag spec: "VOICE-9"
  test "final envelope overflow is invalid_output via ToolTaskCore sole encoder" do
    # Reply fits JsonTerm alone inside %{"reply" => reply} (<=8192), but the
    # outer {"success":true,"result":...} envelope exceeds the encode ceiling.
    # 8180 leaves room for {"reply":"..."} while outer wrapper overflows.
    huge = String.duplicate("x", 8_180)

    authority = %{
      consult_agent: fn _ -> {:ok, huge} end
    }

    assert {:ok, %{"reply" => ^huge}} =
             FrontDesk.invoke(
               %{name: "consult_agent", arguments: %{"message" => "ask"}},
               authority
             )

    # Prove result term alone is valid JSON under the bound.
    assert :ok = Arbor.Voice.Session.JsonTerm.validate(%{"reply" => huge})

    encoded =
      ToolTaskCore.normalize(
        FrontDesk.invoke(
          %{name: "consult_agent", arguments: %{"message" => "ask"}},
          authority
        )
      )

    assert Jason.decode!(encoded) == %{"code" => "invalid_output"}
  end
end
