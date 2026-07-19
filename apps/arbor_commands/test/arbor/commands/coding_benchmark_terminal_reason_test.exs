defmodule Arbor.Commands.CodingBenchmark.TerminalReasonTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingBenchmark.TerminalReason
  alias Arbor.Commands.CodingBenchmarkHostileInspect

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

  test "UTF-8-safe byte ceilings hold for multibyte explicit errors and stderr" do
    # Each "é" is 2 bytes; grapheme-bounded slice would undercount bytes.
    multibyte = String.duplicate("é", 800)

    explicit = %{"payload" => %{"error" => multibyte}}
    explicit_reason = TerminalReason.from_result(explicit, "pipeline_error")
    assert is_binary(explicit_reason)
    assert String.valid?(explicit_reason)
    assert byte_size(explicit_reason) <= 1_000

    validation = %{
      "payload" => %{
        "validation" => [
          %{
            "command" => "mix test",
            "passed" => false,
            "exit_code" => 1,
            "stderr" => multibyte
          }
        ]
      }
    }

    validation_reason = TerminalReason.from_result(validation, "validation_failed")
    assert is_binary(validation_reason)
    assert String.valid?(validation_reason)
    assert byte_size(validation_reason) <= 1_000
    # stderr excerpt itself is also byte-bounded before joining.
    assert validation_reason =~ "stderr="
  end

  test "invalid UTF-8 sources stay byte-bounded in the encoded representation" do
    # 600 invalid bytes would hex-encode to 1200 chars without a source bound.
    invalid = :binary.copy(<<0xFF>>, 600)
    reason = TerminalReason.from_result(%{"payload" => %{"error" => invalid}}, "pipeline_error")
    assert is_binary(reason)
    assert String.starts_with?(reason, "invalid_utf8:")
    assert byte_size(reason) <= 1_000
    # Source was capped at 500 bytes before hex (1000 hex chars + prefix).
    assert byte_size(reason) <= byte_size("invalid_utf8:") + 1_000
  end

  test "sanitize redacts secrets, bounds multibyte UTF-8, and encodes invalid UTF-8" do
    api_key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
    secret_reason = TerminalReason.sanitize("adapter failed key=#{api_key}")
    assert is_binary(secret_reason)
    refute secret_reason =~ api_key
    assert secret_reason =~ "[REDACTED]"
    assert byte_size(secret_reason) <= 1_000

    multibyte = String.duplicate("é", 800)
    multibyte_reason = TerminalReason.sanitize(multibyte)
    assert String.valid?(multibyte_reason)
    assert byte_size(multibyte_reason) <= 1_000
    # Grapheme slice of 1000 would keep 1600 bytes of "é"; byte ceiling must win.
    assert byte_size(multibyte_reason) < byte_size(multibyte)

    invalid = :binary.copy(<<0xFF>>, 600)
    invalid_reason = TerminalReason.sanitize(invalid)
    assert String.starts_with?(invalid_reason, "invalid_utf8:")
    assert String.valid?(invalid_reason)
    assert byte_size(invalid_reason) <= 1_000
  end

  test "sanitize never invokes a raising custom Inspect implementation" do
    api_key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
    hostile = %CodingBenchmarkHostileInspect{secret: api_key}

    # Default inspect dispatches the hostile protocol. On Elixir 1.19 that becomes
    # an Inspect.Error string rather than a process crash — and still embeds the
    # secret in the fallback map dump.
    plain = inspect(hostile)
    assert plain =~ "hostile inspect leaked" or plain =~ "Inspect.Error"
    assert plain =~ api_key

    reason = TerminalReason.sanitize(hostile)
    assert is_binary(reason)
    assert String.valid?(reason)
    assert byte_size(reason) <= 1_000
    refute reason =~ api_key
    refute reason =~ "hostile inspect"
    refute reason =~ "Inspect.Error"
    # structs: false represents as a plain map-like form; redaction then strips secrets.
    assert reason =~ "secret"
    assert reason =~ "[REDACTED]"
  end

  test "sanitize fails closed on nil and non-text atoms" do
    assert TerminalReason.sanitize(nil) == "unspecified"
    assert TerminalReason.sanitize(:scripted_pipeline_failure) == "scripted_pipeline_failure"
  end
end
