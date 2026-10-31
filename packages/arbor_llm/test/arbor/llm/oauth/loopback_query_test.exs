defmodule Arbor.LLM.OAuth.Login.LoopbackQueryTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.OAuth.Login.LoopbackQuery

  test "accepts the closed success and provider-error shapes" do
    assert {:ok, {:success, "code", "state"}} = LoopbackQuery.parse("code=code&state=state")

    assert {:ok, {:success, "code", "state"}} =
             LoopbackQuery.parse("scope=openid+profile&state=state&code=code")

    assert {:ok, {:provider_error, :access_denied, "state"}} =
             LoopbackQuery.parse(
               "error=access_denied&state=state&error_description=denied&error_uri=https%3A%2F%2Fauth.openai.com%2Ferror"
             )
  end

  test "rejects duplicate, unknown, nested, malformed, blank, and mixed shapes" do
    invalid = [
      "code=a&code=b&state=s",
      "code=a&state=s&unknown=x",
      "code%5Bvalue%5D=a&state=s",
      "code=%ZZ&state=s",
      "code=&state=s",
      "code=a&state=",
      "code=a&state=s&error=access_denied",
      "error=made_up&state=s",
      "error=access_denied&state=s&scope=openid",
      "error=access_denied&state=s&error_uri=javascript%3Aalert(1)",
      "code=a&state=s&state=t",
      "code",
      ""
    ]

    for query <- invalid do
      assert {:error, :invalid_callback} = LoopbackQuery.parse(query)
    end
  end

  test "rejects oversized query, values, pair count, invalid UTF-8, and controls" do
    assert {:error, :invalid_callback} =
             LoopbackQuery.parse("code=#{String.duplicate("a", 1_025)}&state=s")

    assert {:error, :invalid_callback} = LoopbackQuery.parse(String.duplicate("a", 4_097))

    assert {:error, :invalid_callback} =
             LoopbackQuery.parse("code=a&state=s&" <> Enum.map_join(1..7, "&", &"x#{&1}=y"))

    assert {:error, :invalid_callback} = LoopbackQuery.parse("code=%FF&state=s")
    assert {:error, :invalid_callback} = LoopbackQuery.parse("code=a%0Ab&state=s")
  end
end
