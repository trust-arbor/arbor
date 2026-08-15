defmodule Arbor.AI.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  test "propagates the Arbor coding-plan key alias to ReqLLM" do
    env_key = "ZAI_CODING_PLAN_API_KEY"
    config_key = :zai_coding_plan_api_key
    previous_env = System.get_env(env_key)
    previous_config = Application.fetch_env(:req_llm, config_key)

    on_exit(fn ->
      if previous_env, do: System.put_env(env_key, previous_env), else: System.delete_env(env_key)

      case previous_config do
        {:ok, value} -> Application.put_env(:req_llm, config_key, value)
        :error -> Application.delete_env(:req_llm, config_key)
      end
    end)

    System.put_env(env_key, "test-coding-plan-key")
    Application.delete_env(:req_llm, config_key)

    Arbor.AI.Application.propagate_api_keys()

    assert ReqLLM.get_key(config_key) == "test-coding-plan-key"
  end
end
