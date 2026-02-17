defmodule Arbor.Eval.Checks.PIIDetection do
  @moduledoc """
  Detects potential personally identifiable information (PII) in code.

  Uses SafeRegex for timeout-protected pattern matching to prevent ReDoS attacks.
  Pattern definitions are shared with `Arbor.Common.SensitiveData`.

  Based on patterns from Microsoft Presidio and industry best practices.

  ## References & Attribution

  Patterns in this module are derived from:

  - **Microsoft Presidio** - Open-source PII detection framework
  - **Bearer CLI** - SAST tool with 120+ sensitive data types
  - **OWASP** - Sensitive data exposure guidelines

  ## Detected PII Types
  # arbor:allow pii
  - Hardcoded paths with usernames (/Users/username/, /home/username/)
  - Email addresses
  - Phone numbers (US and international formats)
  - Credit card numbers (with Luhn checksum validation)
  - US Social Security Numbers (SSN)
  - Names (configurable list)
  - API keys and secrets (see `Arbor.Common.SensitiveData` for full list)
  - IP addresses

  ## Configuration

      Arbor.Eval.run(PIIDetection, code: code,
        additional_names: ["alice", "bob"],
        additional_patterns: [~r/my-secret-pattern/]
      )

  ## Allowlist

  Use comments to mark intentional patterns:

      # arbor:allow pii
      @test_email "test@example.com"
  """

  use Arbor.Eval,
    name: "pii_detection",
    category: :security,
    description: "Detects potential PII in source code"

  alias Arbor.Common.SensitiveData

  # Delegate pattern definitions to SensitiveData
  defdelegate path_patterns(), to: SensitiveData
  defdelegate phone_patterns(), to: SensitiveData
  defdelegate credit_card_patterns(), to: SensitiveData
  defdelegate secret_patterns(), to: SensitiveData
  defdelegate labeled_secret_patterns(), to: SensitiveData
  defdelegate shannon_entropy(string), to: SensitiveData
  defdelegate valid_luhn?(number), to: SensitiveData

  # Email pattern
  @email_pattern ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/

  # US Social Security Number
  @ssn_pattern ~r/\b(?!000|666|9\d{2})\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b/

  # IP address pattern (basic IPv4)
  @ip_pattern ~r/\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/

  # Allowlist pattern in comments
  @allowlist_pattern ~r/#\s*arbor:allow\s+pii/i

  # Regex patterns that indicate a timestamp context rather than a phone number
  defp timestamp_regexes do
    [
      ~r/\d{10,13}:[a-zA-Z_]/,
      ~r/iex>.*\d{10,13}/,
      ~r/\{:ok,\s*\{\d{10,13}/,
      ~r/\b1[67]\d{8,11}\b/,
      ~r/^\s*#.*\d{10,13}/,
      ~r/^\s*@doc.*\d{10,13}/,
      ~r/\d{13,}/
    ]
  end

  @doc """
  Scan arbitrary text for secrets and sensitive data patterns.

  Unlike `run/1` which operates on Elixir source code with line-level
  analysis and allowlisting, this function scans raw text (e.g., LLM
  responses, context values) and returns a list of findings.

  Returns a list of `{label, matched_text}` tuples.

  ## Options

    * `:additional_patterns` - extra `{regex, label}` tuples to check
    * `:entropy_threshold` - minimum Shannon entropy for base64 detection (default: 4.5)

  ## Examples

      # arbor:allow pii
      iex> PIIDetection.scan_text("My key is AKIAIOSFODNN7EXAMPLE")
      # arbor:allow pii
      [{"AWS Access Key", "AKIAIOSFODNN7EXAMPLE"}]

      iex> PIIDetection.scan_text("No secrets here")
      []

  """
  @spec scan_text(String.t(), keyword()) :: [{String.t(), String.t()}]
  def scan_text(text, opts \\ []) when is_binary(text) do
    SensitiveData.scan_secrets(text, opts)
  end

  @impl Arbor.Eval
  def run(%{code: code} = context) do
    additional_names = Map.get(context, :additional_names, [])
    additional_patterns = Map.get(context, :additional_patterns, [])

    lines = String.split(code, "\n")
    path_patterns = path_patterns()
    phone_patterns = phone_patterns()
    credit_card_patterns = credit_card_patterns()
    secret_patterns = secret_patterns()
    timestamp_regexes = timestamp_regexes()

    # Find allowlisted lines
    allowlisted_lines =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _idx} -> Regex.match?(@allowlist_pattern, line) end)
      |> Enum.map(fn {_line, idx} -> idx end)
      |> MapSet.new()

    violations =
      []
      |> check_paths(lines, allowlisted_lines, path_patterns)
      |> check_emails(lines, allowlisted_lines)
      |> check_phones(lines, allowlisted_lines, phone_patterns, timestamp_regexes)
      |> check_credit_cards(lines, allowlisted_lines, credit_card_patterns)
      |> check_ssn(lines, allowlisted_lines)
      |> check_secrets(lines, allowlisted_lines, secret_patterns)
      |> check_high_entropy_secrets(lines, allowlisted_lines)
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

  defp check_paths(violations, lines, allowlisted, path_patterns) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_paths_line(line, idx, path_patterns)
      end)

    violations ++ new_violations
  end

  defp check_paths_line(line, idx, path_patterns) do
    if looks_like_docstring_example?(line) or looks_like_uri_path?(line) do
      []
    else
      path_patterns
      |> Enum.filter(&Regex.match?(&1, line))
      |> Enum.take(1)
      |> Enum.map(fn _pattern ->
        path = extract_first_match(path_patterns, line)

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

  defp check_phones(violations, lines, allowlisted, phone_patterns, timestamp_regexes) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted),
          do: [],
          else: check_phones_line(line, idx, phone_patterns, timestamp_regexes)
      end)

    violations ++ new_violations
  end

  defp check_phones_line(line, idx, phone_patterns, timestamp_regexes) do
    if looks_like_timestamp_context?(line, timestamp_regexes) do
      []
    else
      phone_patterns
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

  defp check_credit_cards(violations, lines, allowlisted, credit_card_patterns) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted),
          do: [],
          else: check_credit_cards_line(line, idx, credit_card_patterns)
      end)

    violations ++ new_violations
  end

  defp check_credit_cards_line(line, idx, credit_card_patterns) do
    if looks_like_test_card?(line) do
      []
    else
      credit_card_patterns
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

  defp check_secrets(violations, lines, allowlisted, secret_patterns) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted),
          do: [],
          else: check_secrets_line(line, idx, secret_patterns)
      end)

    violations ++ new_violations
  end

  defp check_secrets_line(line, idx, secret_patterns) do
    secret_patterns
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

  # Timeout-protected regex matching using SafeRegex
  defp safe_match?(pattern, string) do
    case Arbor.Common.SafeRegex.match?(pattern, string, timeout: 500) do
      {:ok, result} -> result
      {:error, :timeout} -> false
    end
  end

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

  defp looks_like_timestamp_context?(line, timestamp_regexes) do
    has_timestamp_keyword?(line) or matches_any_timestamp_regex?(line, timestamp_regexes)
  end

  defp has_timestamp_keyword?(line) do
    String.contains?(line, ["timestamp", "unix", "epoch", "millisecond", "DateTime"])
  end

  defp matches_any_timestamp_regex?(line, timestamp_regexes) do
    Enum.any?(timestamp_regexes, &Regex.match?(&1, line))
  end

  defp looks_like_docstring_example?(line) do
    cond do
      String.contains?(line, "iex>") -> true
      Regex.match?(~r/^\s*(#|##|Example|Format|URI).*\/home\//, line) -> true
      Regex.match?(~r/`[^`]*\/home\/[^`]*`/, line) -> true
      true -> false
    end
  end

  defp looks_like_uri_path?(line) do
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
    digits = Regex.replace(~r/\D/, phone, "")

    if String.length(digits) > 5 do
      String.slice(digits, 0, 3) <> "***" <> String.slice(digits, -2, 2)
    else
      "***"
    end
  end

  defp mask_credit_card(card) do
    digits = Regex.replace(~r/\D/, card, "")

    if String.length(digits) >= 8 do
      String.slice(digits, 0, 4) <> "****" <> String.slice(digits, -4, 4)
    else
      "****"
    end
  end

  defp mask_ssn(ssn) do
    digits = Regex.replace(~r/\D/, ssn, "")

    if String.length(digits) >= 4 do
      "***-**-" <> String.slice(digits, -4, 4)
    else
      "***-**-****"
    end
  end

  defp looks_like_test_card?(line) do
    String.contains?(line, [
      "4111111111111111",
      "5500000000000004",
      "340000000000009",
      "test_card",
      "test_cc",
      "fake_card",
      "sample_card"
    ]) or
      Regex.match?(~r/(?i)(test|example|sample|mock|fake|dummy)\s*[:=]/, line)
  end

  defp looks_like_test_ssn?(line) do
    String.contains?(line, [
      "123-45-6789",
      "000-00-0000",
      "test_ssn",
      "fake_ssn",
      "sample_ssn"
    ]) or
      Regex.match?(~r/(?i)(test|example|sample|mock|fake|dummy)\s*[:=]/, line)
  end

  defp looks_like_version_number?(line) do
    Regex.match?(~r/(?i)(version|v\d|release|build)\s*[:=]/, line) or
      Regex.match?(~r/\d+\.\d+\.\d+-\d+/, line)
  end

  # ============================================================================
  # High-Entropy Secret Detection (line-based, for run/1)
  # ============================================================================

  @high_entropy_pattern ~r/[a-zA-Z0-9+\/]{40,}={0,2}/

  defp check_high_entropy_secrets(violations, lines, allowlisted) do
    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted),
          do: [],
          else: check_high_entropy_line(line, idx)
      end)

    violations ++ new_violations
  end

  defp check_high_entropy_line(line, idx) do
    case Regex.run(@high_entropy_pattern, line) do
      [match | _] ->
        if shannon_entropy(match) > 4.5 do
          [
            %{
              type: :high_entropy_secret,
              message: "High-entropy base64 blob detected (possible encoded secret)",
              line: idx,
              column: nil,
              severity: :warning,
              suggestion: "Review whether this base64 string contains sensitive data"
            }
          ]
        else
          []
        end

      nil ->
        []
    end
  end
end
