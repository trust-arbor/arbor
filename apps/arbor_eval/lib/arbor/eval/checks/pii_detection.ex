defmodule Arbor.Eval.Checks.PIIDetection do
  @moduledoc """
  Detects potential personally identifiable information (PII) in code.

  Uses SafeRegex for timeout-protected pattern matching to prevent ReDoS attacks.

  Based on patterns from Microsoft Presidio and industry best practices.

  ## References & Attribution

  Patterns in this module are derived from:

  - **Microsoft Presidio** - Open-source PII detection framework
    - GitHub: https://github.com/microsoft/presidio
    - Supported entities: https://microsoft.github.io/presidio/supported_entities/
    - Patterns used: Credit cards, SSN, phone numbers, email validation

  - **Bearer CLI** - SAST tool with 120+ sensitive data types
    - GitHub: https://github.com/Bearer/bearer
    - Data types: https://docs.bearer.com/reference/datatypes/
    - Patterns used: API key formats, secret detection patterns

  - **OWASP** - Sensitive data exposure guidelines
    - https://owasp.org/www-project-web-security-testing-guide/

  ## Detected PII Types
  # arbor:allow pii
  - Hardcoded paths with usernames (/Users/username/, /home/username/)
  - Email addresses
  - Phone numbers (US and international formats)
  - Credit card numbers (with Luhn checksum validation)
  - US Social Security Numbers (SSN)
  - Names (configurable list)
  - API keys and secrets:
    - OpenAI (sk-...)
    - GitHub (ghp_, gho_, ghu_, ghs_, ghr_)
    - AWS (AKIA..., secret access keys)
    - Google (AIza...)
    - Stripe (sk_live_, sk_test_, pk_live_, pk_test_)
    - Slack (xoxb, xoxa, xoxp, xoxr, xoxs)
    - JWT tokens
    - Private keys (PEM format)
  - IP addresses

  ## Configuration

  You can configure additional patterns or names to check:

      Arbor.Eval.run(PIIDetection, code: code,
        additional_names: ["alice", "bob"],
        additional_patterns: [~r/my-secret-pattern/]
      )

  ## Allowlist

  Use comments to mark intentional patterns:

      # arbor:allow pii
      @test_email "test@example.com"

  ## Future Enhancements

  Consider adding from Presidio/Bearer:
  - IBAN (International Bank Account Numbers)
  - UK NHS numbers
  - Passport numbers (various countries)
  - Driver's license patterns
  - Medical record numbers
  - Bitcoin/crypto addresses
  - Azure/GCP credentials

  """

  use Arbor.Eval,
    name: "pii_detection",
    category: :security,
    description: "Detects potential PII in source code"

  # Common username patterns in paths
  @path_patterns [
    ~r{/Users/[a-zA-Z][a-zA-Z0-9_-]+/},
    ~r{/home/[a-zA-Z][a-zA-Z0-9_-]+/},
    ~r{C:\\Users\\[a-zA-Z][a-zA-Z0-9_-]+\\}
  ]

  # Email pattern
  @email_pattern ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/

  # Phone number patterns (various formats)
  # Note: We use word boundaries and specific formats to avoid matching timestamps
  @phone_patterns [
    # US format with area code and 7 digits
    ~r/\+?1?[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}(?!\d)/,
    # International format with country code prefix
    ~r/\+\d{1,3}[-.\s]\d{6,14}(?!\d)/
  ]

  # ===========================================================================
  # Credit Card Patterns
  # Source: Microsoft Presidio - https://microsoft.github.io/presidio/supported_entities/
  # Validated with Luhn algorithm to reduce false positives
  # ===========================================================================
  @credit_card_patterns [
    # Visa: starts with 4, 13-16 digits
    ~r/\b4[0-9]{12}(?:[0-9]{3})?\b/,
    # Mastercard: starts with 51-55 or 2221-2720, 16 digits
    ~r/\b5[1-5][0-9]{14}\b/,
    ~r/\b2(?:2[2-9][1-9]|2[3-9][0-9]{2}|[3-6][0-9]{3}|7[0-1][0-9]{2}|720[0-9])[0-9]{12}\b/,
    # American Express: starts with 34 or 37, 15 digits
    ~r/\b3[47][0-9]{13}\b/,
    # Discover: starts with 6011, 622126-622925, 644-649, 65
    ~r/\b6(?:011|5[0-9]{2})[0-9]{12}\b/
  ]

  # ===========================================================================
  # US Social Security Number
  # Source: Microsoft Presidio - https://microsoft.github.io/presidio/supported_entities/
  # Format: XXX-XX-XXXX (with or without dashes)
  # Excludes invalid patterns: 000, 666, 900-999 in area number
  # ===========================================================================
  @ssn_pattern ~r/\b(?!000|666|9\d{2})\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b/

  # ===========================================================================
  # API Key / Secret Patterns
  # Sources:
  #   - Bearer CLI: https://docs.bearer.com/reference/datatypes/
  #   - GitHub secret scanning: https://docs.github.com/en/code-security/secret-scanning
  #   - AWS documentation
  #   - Stripe documentation
  # ===========================================================================
  @secret_patterns [
    # Generic API key patterns
    ~r/(?i)(api[_-]?key|apikey|secret[_-]?key|auth[_-]?token|access[_-]?token)\s*[:=]\s*["'][a-zA-Z0-9_-]{16,}["']/,
    ~r/(?i)(password|passwd|pwd)\s*[:=]\s*["'][^"']+["']/,
    # Anthropic API keys (sk-ant-...)
    # Source: Anthropic API documentation
    ~r/sk-ant-[A-Za-z0-9\-_]{20,}/,
    # OpenAI-style keys (sk-...)
    # Source: OpenAI API documentation
    # Note: Anthropic pattern above is matched first to avoid false overlap
    ~r/sk-(?!ant-)[a-zA-Z0-9]{32,}/,
    # GitHub personal access tokens (ghp_, gho_, ghu_, ghs_, ghr_)
    # Source: https://github.blog/2021-04-05-behind-githubs-new-authentication-token-formats/
    ~r/gh[pousr]_[a-zA-Z0-9]{36,}/,
    # Slack tokens (xoxb, xoxa, xoxp, xoxr, xoxs)
    # Source: Slack API documentation
    ~r/xox[baprs]-[a-zA-Z0-9-]+/,
    # AWS Access Key ID (starts with AKIA, ABIA, ACCA, ASIA)
    # Source: AWS IAM documentation
    ~r/\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/,
    # AWS Secret Access Key (40 char base64)
    ~r/(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*["'][A-Za-z0-9\/+=]{40}["']/,
    # Google API key
    # Source: Google Cloud documentation
    ~r/AIza[0-9A-Za-z\-_]{35}/,
    # Stripe keys (sk_live_, sk_test_, pk_live_, pk_test_)
    # Source: Stripe API documentation
    ~r/[sp]k_(?:live|test)_[a-zA-Z0-9]{24,}/,
    # Private keys (PEM format marker)
    ~r/-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----/,
    # JWT tokens (three base64 segments)
    # Source: RFC 7519
    ~r/eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*/
  ]

  # IP address pattern (basic IPv4)
  @ip_pattern ~r/\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/

  # Allowlist pattern in comments
  @allowlist_pattern ~r/#\s*arbor:allow\s+pii/i

  # Regex patterns that indicate a timestamp context rather than a phone number
  @timestamp_regexes [
    # Cursor format: timestamp:id
    ~r/\d{10,13}:[a-zA-Z_]/,
    # Docstring examples with timestamps (iex> or result lines)
    ~r/iex>.*\d{10,13}/,
    # Result tuple with timestamp: {:ok, {1705..., ...}}
    ~r/\{:ok,\s*\{\d{10,13}/,
    # Any line with a 10+ digit number that starts with 17 (2024 timestamps)
    # or 16 (2020 timestamps) - these are clearly timestamps, not phone numbers
    ~r/\b1[67]\d{8,11}\b/,
    # Just a number in a docstring example
    ~r/^\s*#.*\d{10,13}/,
    ~r/^\s*@doc.*\d{10,13}/,
    # Lines with 13+ digit sequences are likely credit card numbers, not phones
    ~r/\d{13,}/
  ]

  @impl Arbor.Eval
  def run(%{code: code} = context) do
    additional_names = Map.get(context, :additional_names, [])
    additional_patterns = Map.get(context, :additional_patterns, [])

    lines = String.split(code, "\n")

    # Find allowlisted lines
    allowlisted_lines =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _idx} -> Regex.match?(@allowlist_pattern, line) end)
      |> Enum.map(fn {_line, idx} -> idx end)
      |> MapSet.new()

    violations =
      []
      |> check_paths(lines, allowlisted_lines)
      |> check_emails(lines, allowlisted_lines)
      |> check_phones(lines, allowlisted_lines)
      |> check_credit_cards(lines, allowlisted_lines)
      |> check_ssn(lines, allowlisted_lines)
      |> check_secrets(lines, allowlisted_lines)
      |> check_ips(lines, allowlisted_lines)
      |> check_names(lines, allowlisted_lines, additional_names)
      |> check_additional_patterns(lines, allowlisted_lines, additional_patterns)

    %{
      passed: Enum.empty?(violations),
      violations: violations,
      suggestions: []
    }
  end

  def run(_context) do
    %{
      passed: false,
      violations: [%{type: :no_code, message: "No code provided", severity: :error}]
    }
  end

  # ============================================================================
  # Pattern Checks
  # ============================================================================

  defp check_paths(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_paths_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_paths_line(line, idx) do
    if looks_like_docstring_example?(line) or looks_like_uri_path?(line) do
      []
    else
      @path_patterns
      |> Enum.filter(&Regex.match?(&1, line))
      |> Enum.take(1)
      |> Enum.map(fn _pattern ->
        path = extract_first_match(@path_patterns, line)

        %{
          type: :hardcoded_path,
          message: "Hardcoded user path detected: #{path}",
          line: idx,
          column: nil,
          severity: :error,
          suggestion: "Use Path.expand(\"~\") or environment variables"
        }
      end)
    end
  end

  defp check_emails(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_emails_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_emails_line(line, idx) do
    if Regex.match?(@email_pattern, line) and not test_email?(line) do
      email = extract_match(@email_pattern, line)

      [
        %{
          type: :email_address,
          message: "Email address detected: #{mask_email(email)}",
          line: idx,
          column: nil,
          severity: :warning,
          suggestion: "Use configuration or environment variable for email addresses"
        }
      ]
    else
      []
    end
  end

  defp check_phones(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_phones_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_phones_line(line, idx) do
    if looks_like_timestamp_context?(line) do
      []
    else
      @phone_patterns
      |> Enum.filter(&Regex.match?(&1, line))
      |> Enum.take(1)
      |> Enum.map(fn pattern ->
        phone = extract_match(pattern, line)

        %{
          type: :phone_number,
          message: "Phone number detected: #{mask_phone(phone)}",
          line: idx,
          column: nil,
          severity: :error,
          suggestion: "Use configuration or environment variable for phone numbers"
        }
      end)
    end
  end

  defp check_credit_cards(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_credit_cards_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_credit_cards_line(line, idx) do
    if looks_like_test_card?(line) do
      []
    else
      @credit_card_patterns
      |> extract_luhn_matches(line)
      |> Enum.take(1)
      |> Enum.map(fn card ->
        %{
          type: :credit_card,
          message: "Credit card number detected: #{mask_credit_card(card)}",
          line: idx,
          column: nil,
          severity: :error,
          suggestion: "Never hardcode credit card numbers in source code"
        }
      end)
    end
  end

  defp check_ssn(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_ssn_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_ssn_line(line, idx) do
    skip? = looks_like_test_ssn?(line) or looks_like_version_number?(line)

    if skip? or not Regex.match?(@ssn_pattern, line) do
      []
    else
      ssn = extract_match(@ssn_pattern, line)

      [
        %{
          type: :ssn,
          message: "US Social Security Number detected: #{mask_ssn(ssn)}",
          line: idx,
          column: nil,
          severity: :error,
          suggestion: "Never hardcode SSNs in source code"
        }
      ]
    end
  end

  defp check_secrets(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_secrets_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_secrets_line(line, idx) do
    # Use SafeRegex with timeout protection against ReDoS attacks
    @secret_patterns
    |> Enum.filter(&safe_match?(&1, line))
    |> Enum.take(1)
    |> Enum.map(fn _pattern ->
      %{
        type: :hardcoded_secret,
        message: "Potential hardcoded secret or API key",
        line: idx,
        column: nil,
        severity: :error,
        suggestion: "Use environment variables or secure configuration for secrets"
      }
    end)
  end

  # Timeout-protected regex matching to prevent ReDoS attacks.
  # Inlined rather than using Arbor.Common.SafeRegex since arbor_eval
  # is a standalone library with zero in-umbrella dependencies.
  defp safe_match?(pattern, string) do
    task = Task.async(fn -> Regex.match?(pattern, string) end)

    case Task.yield(task, 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> false
    end
  end

  defp check_ips(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_ips_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_ips_line(line, idx) do
    if Regex.match?(@ip_pattern, line) and not localhost_ip?(line) do
      ip = extract_match(@ip_pattern, line)

      [
        %{
          type: :ip_address,
          message: "IP address detected: #{ip}",
          line: idx,
          column: nil,
          severity: :warning,
          suggestion: "Use configuration for IP addresses"
        }
      ]
    else
      []
    end
  end

  defp check_names(violations, _lines, _allowlisted, []), do: violations

  defp check_names(violations, lines, allowlisted, additional_names) do
    name_pattern = ~r/\b(#{Enum.join(additional_names, "|")})\b/i

    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_names_line(line, idx, name_pattern)
      end)

    violations ++ new_violations
  end

  defp check_names_line(line, idx, name_pattern) do
    if Regex.match?(name_pattern, line) do
      [
        %{
          type: :personal_name,
          message: "Personal name detected in code",
          line: idx,
          column: nil,
          severity: :warning,
          suggestion: "Remove personal names from code"
        }
      ]
    else
      []
    end
  end

  defp check_additional_patterns(violations, _lines, _allowlisted, []), do: violations

  defp check_additional_patterns(violations, lines, allowlisted, patterns) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted),
          do: [],
          else: check_additional_patterns_line(line, idx, patterns)
      end)

    violations ++ new_violations
  end

  defp check_additional_patterns_line(line, idx, patterns) do
    patterns
    |> Enum.filter(&Regex.match?(&1, line))
    |> Enum.map(fn pattern ->
      %{
        type: :custom_pii_pattern,
        message: "Custom PII pattern matched: #{inspect(pattern.source)}",
        line: idx,
        column: nil,
        severity: :warning
      }
    end)
  end

  # ============================================================================
  # Shared Helpers
  # ============================================================================

  defp skip_line?(idx, allowlisted) do
    MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1)
  end

  # Extracts credit card matches from a line, validating each with Luhn algorithm.
  defp extract_luhn_matches(patterns, line) do
    Enum.flat_map(patterns, fn pattern -> extract_validated_match(pattern, line) end)
  end

  defp extract_validated_match(pattern, line) do
    case Regex.run(pattern, line) do
      [match | _] -> if valid_luhn?(match), do: [match], else: []
      nil -> []
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_match(pattern, string) do
    case Regex.run(pattern, string) do
      [match | _] -> match
      nil -> ""
    end
  end

  defp extract_first_match(patterns, string) do
    Enum.find_value(patterns, "", fn pattern ->
      case Regex.run(pattern, string) do
        [match | _] -> match
        nil -> nil
      end
    end)
  end

  defp test_email?(line) do
    # Common test/example email patterns
    String.contains?(line, [
      "@example.com",
      "@example.org",
      "@test.com",
      "test@",
      "example@",
      "foo@",
      "bar@",
      "user@"
    ])
  end

  defp localhost_ip?(line) do
    String.contains?(line, ["127.0.0.1", "0.0.0.0", "192.168.", "10.0.", "172.16."])
  end

  defp looks_like_timestamp_context?(line) do
    # Lines containing Unix timestamps (10-13 digits starting with 1) in contexts like:
    # - "1705123456789:evt_123" (cursor format)
    # - timestamp_ms, DateTime.from_unix, etc.
    has_timestamp_keyword?(line) or matches_any_timestamp_regex?(line)
  end

  defp has_timestamp_keyword?(line) do
    # Timestamp variable/function context
    String.contains?(line, ["timestamp", "unix", "epoch", "millisecond", "DateTime"])
  end

  defp matches_any_timestamp_regex?(line) do
    Enum.any?(@timestamp_regexes, &Regex.match?(&1, line))
  end

  defp looks_like_docstring_example?(line) do
    # Lines that appear to be in @doc or @moduledoc examples
    cond do
      # iex> examples
      String.contains?(line, "iex>") -> true
      # Docstring markers with path examples
      Regex.match?(~r/^\s*(#|##|Example|Format|URI).*\/home\//, line) -> true
      # Quoted examples in docs
      Regex.match?(~r/`[^`]*\/home\/[^`]*`/, line) -> true
      true -> false
    end
  end

  defp looks_like_uri_path?(line) do
    # Lines containing URIs that happen to have path components
    # e.g., "arbor://fs/read/home/user/documents"
    cond do
      Regex.match?(~r/arbor:\/\//, line) -> true
      Regex.match?(~r/https?:\/\//, line) -> true
      Regex.match?(~r/file:\/\//, line) -> true
      true -> false
    end
  end

  defp mask_email(email) do
    case String.split(email, "@") do
      [local, domain] ->
        masked_local = String.slice(local, 0, 2) <> "***"
        "#{masked_local}@#{domain}"

      _ ->
        "***@***"
    end
  end

  defp mask_phone(phone) do
    # Keep first 3 and last 2 digits
    digits = Regex.replace(~r/\D/, phone, "")

    if String.length(digits) > 5 do
      String.slice(digits, 0, 3) <> "***" <> String.slice(digits, -2, 2)
    else
      "***"
    end
  end

  defp mask_credit_card(card) do
    # Keep first 4 and last 4 digits (standard PCI masking)
    digits = Regex.replace(~r/\D/, card, "")

    if String.length(digits) >= 8 do
      String.slice(digits, 0, 4) <> "****" <> String.slice(digits, -4, 4)
    else
      "****"
    end
  end

  defp mask_ssn(ssn) do
    # Keep only last 4 digits (standard SSN masking)
    digits = Regex.replace(~r/\D/, ssn, "")

    if String.length(digits) >= 4 do
      "***-**-" <> String.slice(digits, -4, 4)
    else
      "***-**-****"
    end
  end

  defp looks_like_test_card?(line) do
    # Common test card numbers and patterns
    String.contains?(line, [
      "4111111111111111",
      "5500000000000004",
      "340000000000009",
      "test_card",
      "test_cc",
      "fake_card",
      "sample_card"
    ]) or
      # Lines with "test" or "example" context
      Regex.match?(~r/(?i)(test|example|sample|mock|fake|dummy)\s*[:=]/, line)
  end

  defp looks_like_test_ssn?(line) do
    # Common test SSN patterns and context
    String.contains?(line, [
      "123-45-6789",
      "000-00-0000",
      "test_ssn",
      "fake_ssn",
      "sample_ssn"
    ]) or
      # Lines with "test" or "example" context
      Regex.match?(~r/(?i)(test|example|sample|mock|fake|dummy)\s*[:=]/, line)
  end

  defp looks_like_version_number?(line) do
    # Version numbers like "1.2.3-456" can look like SSN
    # Check for version context
    Regex.match?(~r/(?i)(version|v\d|release|build)\s*[:=]/, line) or
      # Semantic versioning patterns
      Regex.match?(~r/\d+\.\d+\.\d+-\d+/, line)
  end

  # ===========================================================================
  # Luhn Algorithm (ISO/IEC 7812-1)
  # Used by Microsoft Presidio for credit card validation
  # Reduces false positives by validating checksum
  # Reference: https://en.wikipedia.org/wiki/Luhn_algorithm
  # ===========================================================================
  defp valid_luhn?(number) do
    digits =
      number
      |> String.replace(~r/\D/, "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    if length(digits) < 13 do
      false
    else
      sum = luhn_checksum(digits)
      rem(sum, 10) == 0
    end
  end

  defp luhn_checksum(digits) do
    digits
    |> Enum.with_index()
    |> Enum.reduce(0, fn {digit, idx}, sum ->
      sum + luhn_digit_value(digit, idx)
    end)
  end

  defp luhn_digit_value(digit, idx) when rem(idx, 2) == 1 do
    doubled = digit * 2
    if doubled > 9, do: doubled - 9, else: doubled
  end

  defp luhn_digit_value(digit, _idx), do: digit
end
