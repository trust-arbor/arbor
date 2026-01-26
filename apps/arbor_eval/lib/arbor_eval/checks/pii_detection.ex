defmodule ArborEval.Checks.PIIDetection do
  @moduledoc """
  Detects potential personally identifiable information (PII) in code.

  Based on patterns from Microsoft Presidio and industry best practices.

  Scans for: # arbor:allow pii (documentation examples below)
  - Hardcoded paths with usernames (/Users/username/, /home/username/)
  - Email addresses
  - Phone numbers (US and international formats)
  - Credit card numbers (with Luhn validation)
  - US Social Security Numbers (SSN)
  - Names (configurable list)
  - API keys and secrets patterns (OpenAI, GitHub, AWS, Slack, etc.)
  - IP addresses

  ## Configuration

  You can configure additional patterns or names to check:

      ArborEval.run(PIIDetection, code: code,
        additional_names: ["alice", "bob"],
        additional_patterns: [~r/my-secret-pattern/]
      )

  ## Allowlist

  Use comments to mark intentional patterns:

      # arbor:allow pii
      @test_email "test@example.com"

  """

  use ArborEval,
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

  # Credit card patterns (validated with Luhn algorithm in check)
  # Patterns from Microsoft Presidio
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

  # US Social Security Number pattern
  # Format: XXX-XX-XXXX (with or without dashes)
  # Excludes invalid patterns like 000, 666, 900-999 in area number
  @ssn_pattern ~r/\b(?!000|666|9\d{2})\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b/

  # API key / secret patterns (expanded based on Presidio and Bearer)
  @secret_patterns [
    # Generic API key patterns
    ~r/(?i)(api[_-]?key|apikey|secret[_-]?key|auth[_-]?token|access[_-]?token)\s*[:=]\s*["'][a-zA-Z0-9_-]{16,}["']/,
    ~r/(?i)(password|passwd|pwd)\s*[:=]\s*["'][^"']+["']/,
    # OpenAI-style keys (sk-...)
    ~r/sk-[a-zA-Z0-9]{32,}/,
    # GitHub personal access tokens (ghp_, gho_, ghu_, ghs_, ghr_)
    ~r/gh[pousr]_[a-zA-Z0-9]{36,}/,
    # Slack tokens (xoxb, xoxa, xoxp, xoxr, xoxs)
    ~r/xox[baprs]-[a-zA-Z0-9-]+/,
    # AWS Access Key ID (starts with AKIA, ABIA, ACCA, ASIA)
    ~r/\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/,
    # AWS Secret Access Key (40 char base64)
    ~r/(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*["'][A-Za-z0-9\/+=]{40}["']/,
    # Google API key
    ~r/AIza[0-9A-Za-z\-_]{35}/,
    # Stripe keys (sk_live_, sk_test_, pk_live_, pk_test_)
    ~r/[sp]k_(?:live|test)_[a-zA-Z0-9]{24,}/,
    # Private keys (PEM format marker)
    ~r/-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----/,
    # JWT tokens (three base64 segments)
    ~r/eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*/
  ]

  # IP address pattern (basic IPv4)
  @ip_pattern ~r/\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/

  # Allowlist pattern in comments
  @allowlist_pattern ~r/#\s*arbor:allow\s+pii/i

  @impl ArborEval
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
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
          # Skip lines in docstrings that look like examples or URIs
          if looks_like_docstring_example?(line) or looks_like_uri_path?(line) do
            []
          else
            @path_patterns
            |> Enum.filter(&Regex.match?(&1, line))
            |> Enum.map(fn _pattern ->
              # Extract the matched path for the message
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
            # One violation per line
            |> Enum.take(1)
          end
        end
      end)

    violations ++ new_violations
  end

  defp check_emails(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
          # Skip if it looks like a test/example email
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
      end)

    violations ++ new_violations
  end

  defp check_phones(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
          # Skip lines that look like they contain timestamps or cursor formats
          if looks_like_timestamp_context?(line) do
            []
          else
            @phone_patterns
            |> Enum.filter(&Regex.match?(&1, line))
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
            |> Enum.take(1)
          end
        end
      end)

    violations ++ new_violations
  end

  defp check_credit_cards(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
          # Skip lines that look like test data or documentation
          if looks_like_test_card?(line) do
            []
          else
            @credit_card_patterns
            |> Enum.flat_map(fn pattern ->
              case Regex.run(pattern, line) do
                [match | _] ->
                  # Validate with Luhn algorithm to reduce false positives
                  if valid_luhn?(match) do
                    [match]
                  else
                    []
                  end

                nil ->
                  []
              end
            end)
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
      end)

    violations ++ new_violations
  end

  defp check_ssn(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
          # Skip lines that look like test data or version numbers
          if looks_like_test_ssn?(line) or looks_like_version_number?(line) do
            []
          else
            if Regex.match?(@ssn_pattern, line) do
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
            else
              []
            end
          end
        end
      end)

    violations ++ new_violations
  end

  defp check_secrets(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
          @secret_patterns
          |> Enum.filter(&Regex.match?(&1, line))
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
          |> Enum.take(1)
        end
      end)

    violations ++ new_violations
  end

  defp check_ips(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
          []
        else
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
      end)

    violations ++ new_violations
  end

  defp check_names(violations, lines, allowlisted, additional_names) do
    # Default names to check for (common in personal projects)
    # These would be configured per-project
    default_names = []
    names = default_names ++ additional_names

    if names == [] do
      violations
    else
      name_pattern = ~r/\b(#{Enum.join(names, "|")})\b/i

      new_violations =
        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, idx} ->
          if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
            []
          else
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
        end)

      violations ++ new_violations
    end
  end

  defp check_additional_patterns(violations, lines, allowlisted, patterns) do
    if patterns == [] do
      violations
    else
      new_violations =
        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, idx} ->
          if MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1) do
            []
          else
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
        end)

      violations ++ new_violations
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
    cond do
      # Cursor format: timestamp:id
      Regex.match?(~r/\d{10,13}:[a-zA-Z_]/, line) -> true
      # Timestamp variable/function context
      String.contains?(line, ["timestamp", "unix", "epoch", "millisecond", "DateTime"]) -> true
      # Docstring examples with timestamps (iex> or result lines)
      Regex.match?(~r/iex>.*\d{10,13}/, line) -> true
      # Result tuple with timestamp: {:ok, {1705..., ...}}
      Regex.match?(~r/\{:ok,\s*\{\d{10,13}/, line) -> true
      # Any line with a 10+ digit number that starts with 17 (2024 timestamps)
      # or 16 (2020 timestamps) - these are clearly timestamps, not phone numbers
      Regex.match?(~r/\b1[67]\d{8,11}\b/, line) -> true
      # Just a number in a docstring example
      Regex.match?(~r/^\s*#.*\d{10,13}/, line) -> true
      Regex.match?(~r/^\s*@doc.*\d{10,13}/, line) -> true
      # Lines with 13+ digit sequences are likely credit card numbers, not phones
      Regex.match?(~r/\d{13,}/, line) -> true
      true -> false
    end
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

  # Luhn algorithm for credit card validation
  # Reduces false positives by validating checksum
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
      {sum, _} =
        Enum.reduce(digits, {0, 0}, fn digit, {sum, idx} ->
          value =
            if rem(idx, 2) == 1 do
              doubled = digit * 2
              if doubled > 9, do: doubled - 9, else: doubled
            else
              digit
            end

          {sum + value, idx + 1}
        end)

      rem(sum, 10) == 0
    end
  end
end
