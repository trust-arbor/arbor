defmodule Arbor.Common.LogRedactorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.LogRedactor

  # M7 security regression (SECURITY_REVIEW 2026-02-16):
  # "API keys logged in debug mode without redaction."
  #
  # The fix installs `Arbor.Common.LogRedactor` as a Logger primary filter that
  # rewrites the log event's :msg, redacting secrets/PII via
  # `Arbor.Common.SensitiveData.redact/1`. These tests call the filter directly
  # (the public seam Logger invokes) and assert that an API-key-like value never
  # survives into the emitted message, while clean text passes through untouched.
  #
  # Red-proof: if `filter/2` is reverted to a passthrough (return the event
  # unchanged), the secret remains in the message and these assertions fail.
  describe "M7 security regression — filter/2 redacts secrets in log events" do
    test "redacts an API-key-like string in a {:string, _} message" do
      secret = "AKIAIOSFODNN7EXAMPLE"
      event = %{level: :info, meta: %{}, msg: {:string, "Authorization key: #{secret}"}}

      assert %{msg: {:string, redacted}} = LogRedactor.filter(event, [])

      refute String.contains?(redacted, secret)
      assert String.contains?(redacted, "[REDACTED]")
    end

    test "redacts a secret value in a {:report, map} message" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      event = %{level: :info, meta: %{}, msg: {:report, %{detail: "ANTHROPIC_API_KEY=#{secret}"}}}

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])

      refute String.contains?(report.detail, secret)
      assert String.contains?(report.detail, "[REDACTED]")
    end

    test "redacts secrets nested inside a {:report, map} message" do
      secret = "AKIAIOSFODNN7EXAMPLE"
      event = %{level: :info, meta: %{}, msg: {:report, %{outer: %{inner: "key #{secret} end"}}}}

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])

      refute String.contains?(report.outer.inner, secret)
      assert String.contains?(report.outer.inner, "[REDACTED]")
    end

    test "leaves a message with no secrets unchanged" do
      event = %{level: :info, meta: %{}, msg: {:string, "Nothing sensitive here"}}

      assert %{msg: {:string, "Nothing sensitive here"}} = LogRedactor.filter(event, [])
    end

    test "passes through events whose :msg is not a redactable form" do
      event = %{level: :info, meta: %{}, msg: {:report, [a: 1, b: 2]}}

      # keyword-list reports are not string/map reports; event must pass through intact
      assert ^event = LogRedactor.filter(event, [])
    end
  end
end
