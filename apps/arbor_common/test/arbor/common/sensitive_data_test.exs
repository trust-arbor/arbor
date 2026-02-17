defmodule Arbor.Common.SensitiveDataTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SensitiveData

  describe "scan_pii/2" do
    test "detects email addresses" do
      findings = SensitiveData.scan_pii("Contact john.doe@company.com for help")
      assert Enum.any?(findings, fn {label, _} -> label == "Email Address" end)
    end

    test "filters out test emails" do
      findings = SensitiveData.scan_pii("Send to test@example.com")
      refute Enum.any?(findings, fn {label, _} -> label == "Email Address" end)
    end

    test "detects hardcoded user paths" do
      findings = SensitiveData.scan_pii("Path is /Users/johnsmith/projects/app")
      assert Enum.any?(findings, fn {label, _} -> label == "Hardcoded User Path" end)
    end

    test "detects phone numbers" do
      findings = SensitiveData.scan_pii("Call 555-123-4567")
      assert Enum.any?(findings, fn {label, _} -> label == "Phone Number" end)
    end

    test "detects credit card with valid Luhn" do
      findings = SensitiveData.scan_pii("Card: 4532015112830366")
      assert Enum.any?(findings, fn {label, _} -> label == "Credit Card Number" end)
    end

    test "filters credit cards with invalid Luhn" do
      findings = SensitiveData.scan_pii("Number: 4532015112830367")
      refute Enum.any?(findings, fn {label, _} -> label == "Credit Card Number" end)
    end

    test "detects SSN" do
      findings = SensitiveData.scan_pii("SSN: 123-45-6788")
      assert Enum.any?(findings, fn {label, _} -> label == "US Social Security Number" end)
    end

    test "detects non-local IP addresses" do
      findings = SensitiveData.scan_pii("Server at 203.0.113.45")
      assert Enum.any?(findings, fn {label, _} -> label == "IP Address" end)
    end

    test "filters local/private IPs" do
      findings = SensitiveData.scan_pii("Localhost: 127.0.0.1 Private: 192.168.1.1")
      refute Enum.any?(findings, fn {label, _} -> label == "IP Address" end)
    end

    test "returns empty list for clean text" do
      assert SensitiveData.scan_pii("Nothing sensitive here") == []
    end
  end

  describe "scan_secrets/2" do
    test "detects AWS access key" do
      findings = SensitiveData.scan_secrets("key: AKIAIOSFODNN7EXAMPLE")
      assert Enum.any?(findings, fn {label, _} -> label == "AWS Access Key" end)
    end

    test "detects Anthropic API key" do
      findings =
        SensitiveData.scan_secrets("ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz")

      assert Enum.any?(findings, fn {label, _} -> label == "Anthropic API Key" end)
    end

    test "detects GitHub token" do
      findings = SensitiveData.scan_secrets("Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij")
      assert Enum.any?(findings, fn {label, _} -> label == "GitHub Token" end)
    end

    test "detects GitLab PAT" do
      findings = SensitiveData.scan_secrets("export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx")
      assert Enum.any?(findings, fn {label, _} -> label == "GitLab PAT" end)
    end

    test "detects Slack token" do
      findings = SensitiveData.scan_secrets("SLACK_TOKEN=xoxb-123456789012-abcdefghij")
      assert Enum.any?(findings, fn {label, _} -> label == "Slack Token" end)
    end

    test "detects Google API key" do
      findings = SensitiveData.scan_secrets("GOOGLE_KEY=AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe")
      assert Enum.any?(findings, fn {label, _} -> label == "Google API Key" end)
    end

    test "detects Stripe key" do
      key = "sk_" <> "live_" <> String.duplicate("a1b2c3d4", 4)
      findings = SensitiveData.scan_secrets("stripe_key: #{key}")
      assert Enum.any?(findings, fn {label, _} -> label == "Stripe Key" end)
    end

    test "detects private keys" do
      text = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...\n-----END RSA PRIVATE KEY-----"
      findings = SensitiveData.scan_secrets(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Private Key" end)
    end

    test "detects JWT tokens" do
      text =
        "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

      findings = SensitiveData.scan_secrets(text)
      assert Enum.any?(findings, fn {label, _} -> label == "JWT Token" end)
    end

    test "detects database connection strings" do
      text = "DATABASE_URL=postgres://admin:secretpass@db.example.com:5432/mydb"
      findings = SensitiveData.scan_secrets(text)
      assert Enum.any?(findings, fn {label, _} -> label == "Database Connection String" end)
    end

    test "returns empty list for clean text" do
      assert SensitiveData.scan_secrets("Nothing secret here") == []
    end

    test "supports additional patterns" do
      extra = [{~r/CUSTOM_SECRET_[a-zA-Z0-9]+/, "Custom Secret"}]

      findings =
        SensitiveData.scan_secrets("key: CUSTOM_SECRET_abc123", additional_patterns: extra)

      assert Enum.any?(findings, fn {label, _} -> label == "Custom Secret" end)
    end
  end

  describe "scan_all/2" do
    test "combines PII and secret findings" do
      text = "Email john@company.com and key AKIAIOSFODNN7EXAMPLE"
      findings = SensitiveData.scan_all(text)

      assert Enum.any?(findings, fn {label, _} -> label == "Email Address" end)
      assert Enum.any?(findings, fn {label, _} -> label == "AWS Access Key" end)
    end
  end

  describe "redact/1" do
    test "redacts secrets" do
      text = "My key is AKIAIOSFODNN7EXAMPLE"
      redacted = SensitiveData.redact(text)
      refute String.contains?(redacted, "AKIAIOSFODNN7EXAMPLE")
      assert String.contains?(redacted, "[REDACTED]")
    end

    test "redacts PII" do
      text = "Path: /Users/johnsmith/projects"
      redacted = SensitiveData.redact(text)
      refute String.contains?(redacted, "/Users/johnsmith/")
      assert String.contains?(redacted, "[REDACTED]")
    end

    test "leaves clean text unchanged" do
      text = "Nothing sensitive here"
      assert SensitiveData.redact(text) == text
    end
  end

  describe "redact_pii/1" do
    test "only redacts PII, not secrets" do
      key = "AKIAIOSFODNN7EXAMPLE"
      text = "Path /Users/admin/code and key #{key}"
      redacted = SensitiveData.redact_pii(text)

      refute String.contains?(redacted, "/Users/admin/")
      assert String.contains?(redacted, key)
    end
  end

  describe "redact_secrets/1" do
    test "only redacts secrets, not PII" do
      text = "Path /Users/admin/code and key AKIAIOSFODNN7EXAMPLE"
      redacted = SensitiveData.redact_secrets(text)

      assert String.contains?(redacted, "/Users/admin/")
      refute String.contains?(redacted, "AKIAIOSFODNN7EXAMPLE")
    end
  end

  describe "shannon_entropy/1" do
    test "returns 0.0 for empty string" do
      assert SensitiveData.shannon_entropy("") == 0.0
    end

    test "returns 0.0 for uniform string" do
      assert SensitiveData.shannon_entropy("aaaa") == 0.0
    end

    test "returns higher entropy for random-looking strings" do
      entropy = SensitiveData.shannon_entropy("K7gNU3sdo+OL0wNhqoVWhr3g6s1xYv72")
      assert entropy > 3.0
    end

    test "binary string has entropy 1.0" do
      assert_in_delta SensitiveData.shannon_entropy("ab"), 1.0, 0.01
    end
  end

  describe "valid_luhn?/1" do
    test "validates known good card numbers" do
      assert SensitiveData.valid_luhn?("4532015112830366")
      assert SensitiveData.valid_luhn?("5425233430109903")
      assert SensitiveData.valid_luhn?("374245455400126")
    end

    test "rejects invalid checksum" do
      refute SensitiveData.valid_luhn?("4532015112830367")
    end

    test "rejects short numbers" do
      refute SensitiveData.valid_luhn?("1234")
    end
  end
end
