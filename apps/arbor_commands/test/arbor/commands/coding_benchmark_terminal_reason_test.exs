defmodule Arbor.Commands.CodingBenchmark.TerminalReasonTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingBenchmark.TerminalReason

  @moduletag :fast

  test "success terminals keep a nil reason" do
    assert TerminalReason.from_result(%{"error" => "ignored"}, "change_committed") == nil
    assert TerminalReason.from_result(%{"error" => "ignored"}, "no_changes") == nil
    assert TerminalReason.from_result(%{"error" => "ignored"}, "pr_created") == nil
  end

  test "explicit error remains the terminal reason" do
    result = %{
      "payload" => %{
        "error" => "pipeline_error:handler_binding_mismatch",
        "validation" => [
          %{"command" => "mix test", "passed" => false, "exit_code" => 1, "stderr" => "no"}
        ]
      }
    }

    assert TerminalReason.from_result(result, "pipeline_error") ==
             "pipeline_error:handler_binding_mismatch"
  end

  test "derives a non-null bounded reason from the first failed validation entry" do
    result = %{
      "result_type" => "coding_change",
      "payload" => %{
        "status" => "validation_failed",
        "validation" => [
          %{
            "command" => "mix test",
            "passed" => true,
            "exit_code" => 0,
            "stdout" => "secret-ok"
          },
          %{
            "command" => "./bin/mix compile --warnings-as-errors",
            "passed" => false,
            "exit_code" => 1,
            "timed_out" => false,
            "killed" => false,
            "stderr" => "undefined function Foo.bar/0",
            "stdout" => String.duplicate("SECRET", 200)
          }
        ]
      }
    }

    reason = TerminalReason.from_result(result, "validation_failed")

    assert is_binary(reason)
    assert reason =~ "command=./bin/mix compile --warnings-as-errors"
    assert reason =~ "exit_code=1"
    assert reason =~ "stderr=undefined function Foo.bar/0"
    refute reason =~ "SECRET"
    refute reason =~ "secret-ok"
  end

  test "includes timed_out and killed flags when present" do
    result = %{
      "payload" => %{
        "validation" => [
          %{
            "command" => "mix test",
            "passed" => false,
            "exit_code" => 137,
            "timed_out" => true,
            "killed" => true,
            "stderr" => "command timed out"
          }
        ]
      }
    }

    reason = TerminalReason.from_result(result, "validation_failed")
    assert reason =~ "timed_out=true"
    assert reason =~ "killed=true"
    assert reason =~ "exit_code=137"
  end

  test "returns nil when no explicit reason and no failed validation is present" do
    assert TerminalReason.from_result(%{"payload" => %{"status" => "declined"}}, "declined") ==
             nil
  end

  test "redacts API-key patterns from explicit errors and validation stderr" do
    # Matches Arbor.Common.SensitiveData Anthropic API key pattern.
    api_key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"

    explicit = %{
      "payload" => %{
        "error" => "pipeline failed with key=#{api_key} during handler binding"
      }
    }

    explicit_reason = TerminalReason.from_result(explicit, "pipeline_error")
    assert is_binary(explicit_reason)
    refute explicit_reason =~ api_key
    assert explicit_reason =~ "[REDACTED]"
    assert byte_size(explicit_reason) <= 1_000

    validation = %{
      "payload" => %{
        "status" => "validation_failed",
        "validation" => [
          %{
            "command" => "mix test",
            "passed" => false,
            "exit_code" => 1,
            "stderr" => "export ANTHROPIC_API_KEY=#{api_key}\nCompilation failed"
          }
        ]
      }
    }

    validation_reason = TerminalReason.from_result(validation, "validation_failed")
    assert is_binary(validation_reason)
    refute validation_reason =~ api_key
    assert validation_reason =~ "[REDACTED]"
    assert validation_reason =~ "exit_code=1"
    assert byte_size(validation_reason) <= 1_000
  end
end
