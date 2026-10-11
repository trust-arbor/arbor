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

  alias Arbor.Common.{SafeRegex, SensitiveData}

  # Keep the scan's total work finite before any regex runs. A line limit is
  # separate from the total byte limit because each detector visits every line.
  @max_input_bytes 524_288
  @max_line_bytes 65_536
  @max_lines 16_384
  @max_additional_names 100
  @max_additional_patterns 64
  @max_pattern_source_bytes 4_096
  @scan_timeout 1_000
  # Source scans run every detector over every admitted line, so one flat
  # deadline made in-bounds files fail closed deterministically: the 14k-line
  # Orchestration.TaskStore always timed out at 1 s and blocked every
  # arbor_agent commit (2026-10-10). Budget per admitted line on top of the
  # base; @max_lines still caps the total (about 5.1 s), and a pathological
  # pattern on a short input still hits roughly the base deadline.
  @source_scan_timeout_per_line_us 250

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

  # Content digests commonly contain phone-shaped decimal runs. Blank only
  # complete hex tokens before phone matching so a real phone elsewhere on the
  # same line remains visible to the detector.
  @hex_digest_pattern ~r/(?<![0-9a-fA-F])[0-9a-fA-F]{32,}(?![0-9a-fA-F])/

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
      iex> aws = "AKIA" <> "IOSFODNN7EXAMPLE"
      # arbor:allow pii
      iex> PIIDetection.scan_text("My key is " <> aws)
      [{"AWS Access Key", aws}]

      iex> PIIDetection.scan_text("No secrets here")
      []

  """
  @spec scan_text(String.t(), keyword()) :: [{String.t(), String.t()}]
  def scan_text(text, opts \\ [])

  def scan_text(text, opts) when is_binary(text) and is_list(opts) do
    with :ok <- validate_scan_opts(opts),
         :ok <- validate_text(text),
         {:ok, additional_patterns} <-
           bounded_additional_patterns(Keyword.get(opts, :additional_patterns, []), :labeled),
         {:ok, findings} <-
           SafeRegex.within_timeout(
             fn ->
               SensitiveData.scan_secrets(
                 text,
                 Keyword.put(opts, :additional_patterns, additional_patterns)
               )
             end,
             timeout: @scan_timeout
           ) do
      findings
    else
      {:error, reason} -> [{"PII scan failed closed", failure_label(reason)}]
    end
  end

  def scan_text(_text, _opts),
    do: [{"PII scan failed closed", failure_label(:invalid_scan_options)}]

  @impl Arbor.Eval
  def run(%{code: code} = context) when is_binary(code) do
    with {:ok, lines} <- validate_code(code),
         {:ok, additional_names} <- bounded_names(Map.get(context, :additional_names, [])),
         {:ok, additional_patterns} <-
           bounded_additional_patterns(Map.get(context, :additional_patterns, []), :plain),
         {:ok, result} <-
           SafeRegex.within_timeout(
             fn -> do_run(lines, additional_names, additional_patterns) end,
             timeout: source_scan_timeout(lines)
           ) do
      result
    else
      {:error, reason} -> failed_closed_result(reason)
    end
  end

  def run(_context) do
    %{
      passed: false,
      violations: [%{type: :no_code, message: "No code provided", severity: :error}]
    }
  end

  defp do_run(lines, additional_names, additional_patterns) do
    path_patterns = path_patterns()
    phone_patterns = phone_patterns()
    credit_card_patterns = credit_card_patterns()
    secret_patterns = secret_patterns()
    timestamp_regexes = timestamp_regexes()

    # Find allowlisted lines
    allowlisted_lines =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _idx} -> regex_match?(@allowlist_pattern, line) end)
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
      |> Enum.filter(&regex_match?(&1, line))
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
    if regex_match?(@email_pattern, line) and not test_email?(line) do
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
      phone_candidate =
        regex_replace(@hex_digest_pattern, line, fn digest ->
          String.duplicate(" ", byte_size(digest))
        end)

      phone_patterns
      |> Enum.filter(&regex_match?(&1, phone_candidate))
      |> Enum.take(1)
      |> Enum.map(fn pattern ->
        phone = extract_match(pattern, phone_candidate)

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

    if skip? or not regex_match?(@ssn_pattern, line) do
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
    |> Enum.filter(&regex_match?(&1, line))
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
    if regex_match?(@ip_pattern, line) and not localhost_ip?(line) do
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
    escaped_names =
      additional_names
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&(byte_size(&1) in 1..128))
      |> Enum.take(100)
      |> Enum.map(&Regex.escape/1)

    check_escaped_names(violations, lines, allowlisted, escaped_names)
  end

  defp check_escaped_names(violations, _lines, _allowlisted, []), do: violations

  defp check_escaped_names(violations, lines, allowlisted, escaped_names) do
    name_pattern = Regex.compile!("\\b(#{Enum.join(escaped_names, "|")})\\b", "i")

    new_violations =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        if skip_line?(idx, allowlisted), do: [], else: check_names_line(line, idx, name_pattern)
      end)

    violations ++ new_violations
  end

  defp check_names_line(line, idx, name_pattern) do
    if regex_match?(name_pattern, line) do
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
    |> Enum.filter(&regex_match?(&1, line))
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

  defp validate_text(text) do
    cond do
      not String.valid?(text) -> {:error, :invalid_utf8}
      byte_size(text) > @max_input_bytes -> {:error, :input_too_large}
      true -> :ok
    end
  end

  defp validate_scan_opts(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_scan_options}
  end

  defp source_scan_timeout(lines), do: source_scan_timeout_ms(length(lines))

  @doc false
  @spec source_scan_timeout_ms(non_neg_integer()) :: pos_integer()
  def source_scan_timeout_ms(line_count) when is_integer(line_count) and line_count >= 0 do
    @scan_timeout + div(min(line_count, @max_lines) * @source_scan_timeout_per_line_us, 1_000)
  end

  defp validate_code(code) do
    with :ok <- validate_text(code) do
      lines = String.split(code, "\n")

      cond do
        length(lines) > @max_lines -> {:error, :too_many_lines}
        Enum.any?(lines, &(byte_size(&1) > @max_line_bytes)) -> {:error, :line_too_large}
        true -> {:ok, lines}
      end
    end
  end

  defp bounded_names(names) do
    with {:ok, names} <- bounded_list(names, @max_additional_names),
         true <- Enum.all?(names, &valid_name?/1) do
      {:ok, names}
    else
      false -> {:error, :invalid_additional_names}
      {:error, _reason} = error -> error
    end
  end

  defp valid_name?(name), do: is_binary(name) and byte_size(name) in 1..128

  defp bounded_additional_patterns(patterns, kind) do
    with {:ok, patterns} <- bounded_list(patterns, @max_additional_patterns),
         true <- Enum.all?(patterns, &valid_additional_pattern?(&1, kind)) do
      {:ok, patterns}
    else
      false -> {:error, :invalid_additional_patterns}
      {:error, _reason} = error -> error
    end
  end

  defp valid_additional_pattern?(%Regex{source: source}, :plain),
    do: byte_size(source) <= @max_pattern_source_bytes

  defp valid_additional_pattern?({%Regex{source: source}, label}, :labeled),
    do:
      byte_size(source) <= @max_pattern_source_bytes and is_binary(label) and
        byte_size(label) in 1..256

  defp valid_additional_pattern?(_pattern, _kind), do: false

  defp bounded_list(value, limit) when is_list(value) do
    bounded = Enum.take(value, limit + 1)

    if length(bounded) <= limit,
      do: {:ok, bounded},
      else: {:error, :too_many_scan_options}
  rescue
    _exception -> {:error, :invalid_scan_options}
  end

  defp bounded_list(_value, _limit), do: {:error, :invalid_scan_options}

  defp failed_closed_result(reason) do
    %{
      passed: false,
      violations: [
        %{
          type: :pii_scan_incomplete,
          message: "PII scan failed closed: #{failure_label(reason)}",
          line: nil,
          severity: :error
        }
      ],
      suggestions: []
    }
  end

  defp failure_label(:timeout), do: "timeout"
  defp failure_label(:input_too_large), do: "input too large"
  defp failure_label(:line_too_large), do: "line too large"
  defp failure_label(:too_many_lines), do: "too many lines"
  defp failure_label(:too_many_scan_options), do: "too many scan options"
  defp failure_label(:invalid_utf8), do: "invalid UTF-8"
  defp failure_label(:invalid_additional_names), do: "invalid additional names"
  defp failure_label(:invalid_additional_patterns), do: "invalid additional patterns"
  defp failure_label(:invalid_scan_options), do: "invalid scan options"
  defp failure_label(_reason), do: "regex operation failed"

  defp regex_match?(pattern, string) do
    SafeRegex.match?(pattern, string, max_bytes: @max_line_bytes)
    |> unwrap_regex()
  end

  defp regex_run(pattern, string) do
    SafeRegex.run(pattern, string, max_bytes: @max_line_bytes)
    |> unwrap_regex()
  end

  defp regex_replace(pattern, string, replacement) do
    SafeRegex.replace(pattern, string, replacement, max_bytes: @max_line_bytes)
    |> unwrap_regex()
  end

  defp unwrap_regex({:ok, result}), do: result
  defp unwrap_regex({:error, reason}), do: throw({:pii_regex_failed, reason})

  defp skip_line?(idx, allowlisted) do
    MapSet.member?(allowlisted, idx) or MapSet.member?(allowlisted, idx - 1)
  end

  # Extracts credit card matches from a line, validating each with Luhn algorithm.
  defp extract_luhn_matches(patterns, line) do
    Enum.flat_map(patterns, fn pattern -> extract_validated_match(pattern, line) end)
  end

  defp extract_validated_match(pattern, line) do
    case regex_run(pattern, line) do
      [match | _] -> if valid_luhn?(match), do: [match], else: []
      nil -> []
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_match(pattern, string) do
    case regex_run(pattern, string) do
      [match | _] -> match
      nil -> ""
    end
  end

  defp extract_first_match(patterns, string) do
    Enum.find_value(patterns, "", fn pattern ->
      case regex_run(pattern, string) do
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
    Enum.any?(timestamp_regexes, &regex_match?(&1, line))
  end

  defp looks_like_docstring_example?(line) do
    cond do
      String.contains?(line, "iex>") -> true
      regex_match?(~r/^\s*(#|##|Example|Format|URI).*\/home\//, line) -> true
      regex_match?(~r/`[^`]*\/home\/[^`]*`/, line) -> true
      true -> false
    end
  end

  defp looks_like_uri_path?(line) do
    cond do
      regex_match?(~r/arbor:\/\//, line) -> true
      regex_match?(~r/https?:\/\//, line) -> true
      regex_match?(~r/file:\/\//, line) -> true
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
    digits = regex_replace(~r/\D/, phone, "")

    if String.length(digits) > 5 do
      String.slice(digits, 0, 3) <> "***" <> String.slice(digits, -2, 2)
    else
      "***"
    end
  end

  defp mask_credit_card(card) do
    digits = regex_replace(~r/\D/, card, "")

    if String.length(digits) >= 8 do
      String.slice(digits, 0, 4) <> "****" <> String.slice(digits, -4, 4)
    else
      "****"
    end
  end

  defp mask_ssn(ssn) do
    digits = regex_replace(~r/\D/, ssn, "")

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
      regex_match?(~r/(?i)(test|example|sample|mock|fake|dummy)\s*[:=]/, line)
  end

  defp looks_like_test_ssn?(line) do
    String.contains?(line, [
      "123-45-6789",
      "000-00-0000",
      "test_ssn",
      "fake_ssn",
      "sample_ssn"
    ]) or
      regex_match?(~r/(?i)(test|example|sample|mock|fake|dummy)\s*[:=]/, line)
  end

  defp looks_like_version_number?(line) do
    regex_match?(~r/(?i)(version|v\d|release|build)\s*[:=]/, line) or
      regex_match?(~r/\d+\.\d+\.\d+-\d+/, line)
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
    case regex_run(@high_entropy_pattern, line) do
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
