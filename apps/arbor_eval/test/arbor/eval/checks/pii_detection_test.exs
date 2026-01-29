defmodule Arbor.Eval.Checks.PIIDetectionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval.Checks.PIIDetection

  describe "hardcoded paths" do
    test "detects /Users/username/ paths" do
      code = ~s|@path "/Users/johnsmith/projects/my_app"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_path))
    end

    test "detects /home/username/ paths" do
      code = ~s|@path "/home/developer/code"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_path))
    end
  end

  describe "email addresses" do
    test "detects real email addresses" do
      code = ~s|@contact_email "john.doe@company.com"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :email_address))
    end

    test "ignores test/example emails" do
      code = """
      @test_email "test@example.com"
      @example "user@example.org"
      @foo "foo@bar.com"
      """

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :email_address))
    end
  end

  describe "phone numbers" do
    test "detects US phone numbers" do
      code = ~s|@phone "555-123-4567"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :phone_number))
    end

    test "detects international phone numbers" do
      code = ~s|@phone "+1-555-123-4567"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :phone_number))
    end
  end

  describe "secrets and API keys" do
    test "detects API key assignments" do
      code = ~s|api_key = "abc123def456ghi789jkl012mno345pqr"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end

    test "detects OpenAI-style keys" do
      code = ~s|@openai_key "sk-abcdefghijklmnopqrstuvwxyz123456"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end

    test "detects GitHub tokens" do
      code = ~s|@token "ghp_abcdefghijklmnopqrstuvwxyz1234567890"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end
  end

  describe "IP addresses" do
    test "detects non-local IP addresses" do
      code = ~s|@server_ip "203.0.113.45"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :ip_address))
    end

    test "ignores localhost IPs" do
      code = """
      @localhost "127.0.0.1"
      @any "0.0.0.0"
      @private "192.168.1.1"
      """

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :ip_address))
    end
  end

  describe "allowlist" do
    test "ignores lines with arbor:allow pii comment" do
      code = """
      # arbor:allow pii
      @example_path "/Users/example/path"
      """

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :hardcoded_path))
    end

    test "allowlist on previous line works" do
      code = """
      # This is an example path
      # arbor:allow pii
      @example_path "/Users/testuser/documents"
      """

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :hardcoded_path))
    end
  end

  describe "additional names" do
    test "detects configured personal names" do
      code = """
      @author "Alice Smith"
      """

      result = PIIDetection.run(%{code: code, additional_names: ["alice", "smith"]})

      assert Enum.any?(result.violations, &(&1.type == :personal_name))
    end
  end

  describe "credit card numbers" do
    test "detects Visa card numbers" do
      # Valid Visa test number with valid Luhn checksum
      code = ~s|@card "4532015112830366"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :credit_card))
    end

    test "detects Mastercard numbers" do
      # Valid Mastercard test number
      code = ~s|@card "5425233430109903"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :credit_card))
    end

    test "detects Amex numbers" do
      # Valid Amex test number
      code = ~s|@card "374245455400126"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :credit_card))
    end

    test "ignores test card numbers" do
      code = ~s|@test_card "4111111111111111"|

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :credit_card))
    end

    test "ignores numbers failing Luhn check" do
      # Invalid checksum
      code = ~s|@number "4532015112830367"|

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :credit_card))
    end
  end

  describe "social security numbers" do
    test "detects SSN with dashes" do
      code = ~s|@ssn "123-45-6788"|

      result = PIIDetection.run(%{code: code})

      # Note: 123-45-6789 is a common test SSN, so we use a different one
      assert Enum.any?(result.violations, &(&1.type == :ssn))
    end

    test "detects SSN without dashes" do
      code = ~s|@ssn "234567890"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :ssn))
    end

    test "ignores common test SSN" do
      code = ~s|@test_ssn "123-45-6789"|

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :ssn))
    end

    test "ignores version numbers that look like SSN" do
      code = ~s|version = "1.2.3-456"|

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :ssn))
    end
  end

  describe "AWS keys" do
    test "detects AWS access key ID" do
      code = ~s|@aws_key "AKIAIOSFODNN7EXAMPLE"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end
  end

  describe "Google API keys" do
    test "detects Google API key" do
      code = ~s|@google_key "AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end
  end

  describe "Stripe keys" do
    test "detects Stripe secret key" do
      code = ~s|@stripe_key "SK_LIVE_TESTING_PLACEHOLDER"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end
  end

  describe "ReDoS protection" do
    @tag :slow
    test "handles pathological input without hanging" do
      # Input designed to potentially trigger exponential backtracking
      # in patterns like: api_key\s*[:=]\s*["'][a-zA-Z0-9_-]{16,}["']
      evil_input = ~s|api_key: "| <> String.duplicate("a", 10_000)

      # Should complete quickly (timeout or no match), not hang
      result = PIIDetection.run(%{code: evil_input})

      # The important thing is it completes without hanging
      # It may or may not detect a violation depending on timeout
      assert is_map(result)
      assert is_list(result.violations)
    end
  end
end
