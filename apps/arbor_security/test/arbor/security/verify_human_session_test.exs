defmodule Arbor.Security.VerifyHumanSessionTest do
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.SessionToken

  @moduletag :fast

  setup do
    keys = [:session_token_secret, :session_token_module]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_security, &1)})
    Application.put_env(:arbor_security, :session_token_secret, "isolated-login-proof-test")
    Application.put_env(:arbor_security, :session_token_module, SessionToken)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    :ok
  end

  test "valid exact human subject authenticates without resource authority" do
    {:ok, token} = SessionToken.generate("human_session_owner")
    assert :ok = Security.verify_human_session("human_session_owner", token)
    assert {:error, :unauthorized} = Security.verify_human_session("human_other", token)
  end

  test "security regression: expired or malformed session proof is rejected" do
    {:ok, expired} = SessionToken.generate("human_session_owner", ttl: -1)

    for token <- [expired, "malformed", "", nil, String.duplicate("a", 4097)],
        do:
          assert(
            {:error, :unauthorized} = Security.verify_human_session("human_session_owner", token)
          )
  end

  test "security regression: scoped conversation proof cannot become general dashboard login" do
    {:ok, token} = SessionToken.generate_conversation("human_session_owner", "agent_target")
    assert {:error, :unauthorized} = Security.verify_human_session("human_session_owner", token)
  end

  test "nonhuman token cannot authenticate a human dashboard session" do
    {:ok, token} = SessionToken.generate("agent_caller")
    assert {:error, :unauthorized} = Security.verify_human_session("agent_caller", token)
  end
end
