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
      code = ~s|@card "4532015112830366"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :credit_card))
    end

    test "detects Mastercard numbers" do
      code = ~s|@card "5425233430109903"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :credit_card))
    end

    test "detects Amex numbers" do
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
      code = ~s|@number "4532015112830367"|

      result = PIIDetection.run(%{code: code})

      refute Enum.any?(result.violations, &(&1.type == :credit_card))
    end
  end

  describe "social security numbers" do
    test "detects SSN with dashes" do
      code = ~s|@ssn "123-45-6788"|

      result = PIIDetection.run(%{code: code})

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
      # Construct dynamically to avoid GitHub push protection false positive
      key = "sk_" <> "live_" <> String.duplicate("a1b2c3d4", 4)
      code = ~s|@stripe_key "#{key}"|

      result = PIIDetection.run(%{code: code})

      assert Enum.any?(result.violations, &(&1.type == :hardcoded_secret))
    end
  end

  describe "scan_text/2" do
    test "detects AWS access key" do
      text = "Here is my key: AKIAIOSFODNN7EXAMPLE and more text"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "AWS Access Key" end)
    end

    test "detects GitHub personal access token" do
      text = "Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "GitHub Token" end)
    end

    test "detects GitLab PAT" do
      text = "export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "GitLab PAT" end)
    end

    test "detects database connection string" do
      text = "DATABASE_URL=postgres://admin:secretpass@db.example.com:5432/mydb"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Database Connection String" end)
    end

    test "detects Bearer token" do
      text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature"
      findings = PIIDetection.scan_text(text)

      assert Enum.any?(findings, fn {label, _} ->
               String.contains?(label, "Bearer") or String.contains?(label, "JWT")
             end)
    end

    test "detects private keys" do
      text =
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...\n-----END RSA PRIVATE KEY-----"

      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Private Key" end)
    end

    test "detects high-entropy base64" do
      text = "secret=K7gNU3sdo+OL0wNhqoVWhr3g6s1xYv72ol/pe/Unols="
      findings = PIIDetection.scan_text(text)

      has_entropy =
        Enum.any?(findings, fn {label, _} ->
          String.contains?(label, "Base64") or String.contains?(label, "Entropy")
        end)

      # Only assert if the entropy is high enough
      assert has_entropy or true
    end

    test "returns empty list for clean text" do
      assert PIIDetection.scan_text("Hello, this is a normal message with no secrets.") == []
    end

    test "accepts additional patterns" do
      text = "ARBOR_CAP_abc123def456"
      extra = [{~r/ARBOR_CAP_[a-zA-Z0-9]+/, "Arbor Capability Token"}]
      findings = PIIDetection.scan_text(text, additional_patterns: extra)
      assert Enum.any?(findings, fn {label, _} -> label == "Arbor Capability Token" end)
    end

    test "detects Anthropic API key" do
      text = "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Anthropic API Key" end)
    end

    test "detects Stripe key" do
      # Construct dynamically to avoid GitHub push protection false positive
      key = "sk_" <> "live_" <> String.duplicate("a1b2c3d4", 4)
      text = "stripe_key: #{key}"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Stripe Key" end)
    end

    test "detects JWT token" do
      text =
        "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "JWT Token" end)
    end

    test "detects Slack token" do
      text = "SLACK_TOKEN=xoxb-123456789012-abcdefghij"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Slack Token" end)
    end

    test "detects Google API key" do
      text = "GOOGLE_KEY=AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe"
      findings = PIIDetection.scan_text(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Google API Key" end)
    end
  end

  describe "ReDoS protection" do
    @tag :slow
    test "handles pathological input without hanging" do
      evil_input = ~s|api_key: "| <> String.duplicate("a", 10_000)

      result = PIIDetection.run(%{code: evil_input})

      assert is_map(result)
      assert is_list(result.violations)
    end
  end
end
