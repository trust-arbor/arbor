defmodule Arbor.Contracts.Pipeline.ResponseTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Arbor.Contracts.Pipeline.Response
  alias Arbor.Contracts.Security.Taint

  @moduletag :fast

  test "normalize accepts an exact valid process-local taint struct" do
    taint = valid_taint()

    assert %Response{taint: ^taint} = Response.normalize(%{content: "ok", taint: taint})
    assert %Response{taint: ^taint} = Response.normalize(%{"content" => "ok", "taint" => taint})
    assert %Response{taint: ^taint} = Response.normalize(%Response{content: "ok", taint: taint})
  end

  test "security regression: malformed caller maps cannot inject response taint" do
    taint = valid_taint()

    malformed = [
      Map.from_struct(taint),
      %{Map.from_struct(taint) | level: :unknown},
      Map.put(taint, :unexpected, true),
      %Taint{taint | sensitivity: :unknown},
      %{
        "level" => "hostile",
        "sensitivity" => "restricted",
        "sanitizations" => 0,
        "confidence" => "unverified",
        "source" => "caller",
        "chain" => []
      }
    ]

    Enum.each(malformed, fn injected ->
      assert %Response{taint: nil} = Response.normalize(%{content: "ok", taint: injected})
      assert %Response{taint: nil} = Response.normalize(%Response{content: "ok", taint: injected})
    end)

    assert %Response{taint: nil} =
             Response.normalize(%{
               "taint" => taint,
               content: "ok",
               taint: nil
             })
  end

  defp valid_taint do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: "steering",
      chain: ["initial", "steering"]
    }
  end
end
