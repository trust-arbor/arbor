defmodule Mix.Tasks.Arbor.EvalOAuthPreflightTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Mix.Tasks.Arbor.Eval, as: EvalTask

  setup do
    previous = Application.fetch_env(:arbor_llm, :oauth_store_dir)

    store_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor-eval-task-oauth-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :oauth_store_dir, value)
        :error -> Application.delete_env(:arbor_llm, :oauth_store_dir)
      end

      File.rm_rf!(store_dir)
    end)

    :ok
  end

  test "security regression: the CLI refuses non-ready OAuth before creating an EvalRun" do
    assert {:error, message} = EvalTask.preflight_provider("xai_oauth")
    assert message =~ "not ready"
    assert message =~ "no EvalRun was created"

    assert_raise Mix.Error, ~r/OAuth provider "xai_oauth" is not ready/, fn ->
      EvalTask.run([
        "--domain",
        "chat",
        "--model",
        "grok-4.5",
        "--provider",
        "xai_oauth",
        "--limit",
        "1"
      ])
    end
  end

  test "infrastructure failures are terminal evidence, not zero-score model results" do
    results = [
      %{passed: true, infrastructure_error: nil},
      %{passed: false, infrastructure_error: "protocol: invalid_stream"}
    ]

    assert EvalTask.infrastructure_failure(results) == "protocol: invalid_stream"
    assert EvalTask.infrastructure_failure([%{passed: false, infrastructure_error: nil}]) == nil
  end
end
