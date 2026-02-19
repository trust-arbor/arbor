defmodule Arbor.Common.SensitiveData do
  @moduledoc """
  Detects and redacts sensitive data in text: PII and secrets.

  Splits detection into two categories:

  - **PII** — personally identifiable information (emails, phone numbers,
    credit cards, SSNs, IP addresses, hardcoded user paths)
  - **Secrets** — API keys, tokens, private keys, passwords, database
    connection strings, high-entropy base64 blobs

  ## Detection API

      # Scan for everything
      SensitiveData.scan_all("text with sk-ant-abc123...")
      #=> [{"Anthropic API Key", "sk-ant-abc123..."}]

      # Scan only secrets
      SensitiveData.scan_secrets("text with sk-ant-abc123...")

      # Scan only PII
      SensitiveData.scan_pii("text with john@company.com")

  ## Redaction API

      SensitiveData.redact("My key is sk-ant-abc123def456ghi789")
      #=> "My key is [REDACTED]"

      # arbor:allow pii
      SensitiveData.redact_pii("Call me at 555-123-4567")
      #=> "Call me at [REDACTED]"

  ## Pattern Sources

  - **Microsoft Presidio** — PII patterns (credit cards, SSN, phone)
  - **Bearer CLI** — Secret detection patterns (120+ data types)
  - **GitHub Secret Scanning** — Token format patterns
  - **OWASP** — Sensitive data exposure guidelines
  """

  # ===========================================================================
  # PII Patterns
  # ===========================================================================

  @email_pattern ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/

  @ssn_pattern ~r/\b(?!000|666|9\d{2})\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b/

  @ip_pattern ~r/\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/

  @doc false
  def path_patterns do
    [
      ~r{/Users/[a-zA-Z][a-zA-Z0-9_-]+/},
      ~r{/home/[a-zA-Z][a-zA-Z0-9_-]+/},
      ~r{C:\\Users\\[a-zA-Z][a-zA-Z0-9_-]+\\}
    ]
  end

  @doc false
  def phone_patterns do
    [
      ~r/\+?1?[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}(?!\d)/,
      ~r/\+\d{1,3}[-.\s]\d{6,14}(?!\d)/
    ]
  end

  @doc false
  def credit_card_patterns do
    [
      ~r/\b4[0-9]{12}(?:[0-9]{3})?\b/,
      ~r/\b5[1-5][0-9]{14}\b/,
      ~r/\b2(?:2[2-9][1-9]|2[3-9][0-9]{2}|[3-6][0-9]{3}|7[0-1][0-9]{2}|720[0-9])[0-9]{12}\b/,
      ~r/\b3[47][0-9]{13}\b/,
      ~r/\b6(?:011|5[0-9]{2})[0-9]{12}\b/
    ]
  end

  # Labeled PII patterns for scan_pii/2
  defp labeled_pii_patterns do
    path_tuples =
      Enum.map(path_patterns(), fn p -> {p, "Hardcoded User Path"} end)

    phone_tuples =
      Enum.map(phone_patterns(), fn p -> {p, "Phone Number"} end)

    cc_tuples =
      Enum.map(credit_card_patterns(), fn p -> {p, "Credit Card Number"} end)

    path_tuples ++
      [{@email_pattern, "Email Address"}] ++
      phone_tuples ++
      cc_tuples ++
      [
        {@ssn_pattern, "US Social Security Number"},
        {@ip_pattern, "IP Address"}
      ]
  end

  # ===========================================================================
  # Secret Patterns
  # ===========================================================================

  @doc false
  def secret_patterns do
    [
      ~r/(?i)(api[_-]?key|apikey|secret[_-]?key|auth[_-]?token|access[_-]?token)\s*[:=]\s*["'][a-zA-Z0-9_-]{16,}["']/,
      ~r/(?i)(password|passwd|pwd)\s*[:=]\s*["'][^"']+["']/,
      ~r/sk-ant-[A-Za-z0-9\-_]{20,}/,
      ~r/sk-(?!ant-)[a-zA-Z0-9]{32,}/,
      ~r/gh[pousr]_[a-zA-Z0-9]{36,}/,
      ~r/xox[baprs]-[a-zA-Z0-9-]+/,
      ~r/\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/,
      ~r/(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*["'][A-Za-z0-9\/+=]{40}["']/,
      ~r/AIza[0-9A-Za-z\-_]{35}/,
      ~r/[sp]k_(?:live|test)_[a-zA-Z0-9]{24,}/,
      ~r/-----BEGIN\s+(?:RSA\s+|EC\s+|DSA\s+|OPENSSH\s+)?PRIVATE\s+KEY-----/,
      ~r/eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*/,
      ~r/glpat-[a-zA-Z0-9\-_]{20,}/,
      ~r/github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}/,
      ~r/(?:mongodb|postgres|mysql|redis|amqp):\/\/[^:]+:[^@]+@/,
      ~r/Bearer\s+[a-zA-Z0-9\-._~+\/]{20,}/
    ]
  end

  # Labeled secret patterns for scan_secrets/2
  @doc false
  def labeled_secret_patterns do
    [
      {~r/(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}/, "AWS Access Key"},
      {~r/(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*["'][A-Za-z0-9\/+=]{40}["']/,
       "AWS Secret Key"},
      {~r/sk-ant-[A-Za-z0-9\-_]{20,}/, "Anthropic API Key"},
      {~r/sk-(?!ant-)[a-zA-Z0-9]{32,}/, "OpenAI API Key"},
      {~r/gh[pousr]_[a-zA-Z0-9]{36,}/, "GitHub Token"},
      {~r/github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}/, "GitHub Fine-Grained PAT"},
      {~r/glpat-[a-zA-Z0-9\-_]{20,}/, "GitLab PAT"},
      {~r/xox[baprs]-[a-zA-Z0-9-]+/, "Slack Token"},
      {~r/AIza[0-9A-Za-z\-_]{35}/, "Google API Key"},
      {~r/[sp]k_(?:live|test)_[a-zA-Z0-9]{24,}/, "Stripe Key"},
      {~r/-----BEGIN\s+(?:RSA\s+|EC\s+|DSA\s+|OPENSSH\s+)?PRIVATE\s+KEY-----/, "Private Key"},
      {~r/eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*/, "JWT Token"},
      {~r/(?:mongodb|postgres|mysql|redis|amqp):\/\/[^:]+:[^@]+@/, "Database Connection String"},
      {~r/Bearer\s+[a-zA-Z0-9\-._~+\/]{20,}/, "Bearer Token"},
      {~r/(?i)(password|passwd|pwd)\s*[:=]\s*["'][^"']{8,}["']/, "Password in Config"},
      {~r/(?i)(api[_-]?key|apikey|secret[_-]?key|auth[_-]?token|access[_-]?token)\s*[:=]\s*["'][a-zA-Z0-9_-]{16,}["']/,
       "API Key/Token"}
    ]
  end

  # ===========================================================================
  # Scan API
  # ===========================================================================

  @doc """
  Scan text for all sensitive data (PII + secrets).

  Returns a list of `{label, matched_text}` tuples.

  ## Options

    * `:additional_patterns` — extra `{regex, label}` tuples to check
    * `:entropy_threshold` — minimum Shannon entropy for base64 detection (default: 4.5)
  """
  @spec scan_all(String.t(), keyword()) :: [{String.t(), String.t()}]
  def scan_all(text, opts \\ []) when is_binary(text) do
    scan_pii(text, opts) ++ scan_secrets(text, opts)
  end

  @doc """
  Scan text for PII only (emails, phones, credit cards, SSN, IPs, paths).

  Returns a list of `{label, matched_text}` tuples.
  """
  @spec scan_pii(String.t(), keyword()) :: [{String.t(), String.t()}]
  def scan_pii(text, opts \\ []) when is_binary(text) do
    extra = Keyword.get(opts, :additional_patterns, [])

    for {regex, label} <- labeled_pii_patterns() ++ extra,
        match <- find_all_matches(regex, text),
        not false_positive_pii?(label, match, text),
        do: {label, match}
  end

  @doc """
  Scan text for secrets only (API keys, tokens, private keys, passwords).

  Returns a list of `{label, matched_text}` tuples.

  ## Options

    * `:additional_patterns` — extra `{regex, label}` tuples to check
    * `:entropy_threshold` — minimum Shannon entropy for base64 detection (default: 4.5)
  """
  @spec scan_secrets(String.t(), keyword()) :: [{String.t(), String.t()}]
  def scan_secrets(text, opts \\ []) when is_binary(text) do
    extra = Keyword.get(opts, :additional_patterns, [])
    entropy_threshold = Keyword.get(opts, :entropy_threshold, 4.5)

    base_findings =
      for {regex, label} <- labeled_secret_patterns() ++ extra,
          match <- find_all_matches(regex, text),
          do: {label, match}

    entropy_findings =
      for match <- find_all_matches(~r/[a-zA-Z0-9+\/]{40,}={0,2}/, text),
          shannon_entropy(match) > entropy_threshold,
          do: {"High-Entropy Base64", match}

    Enum.uniq(base_findings ++ entropy_findings)
  end

  # ===========================================================================
  # Redact API
  # ===========================================================================

  @doc """
  Redact all sensitive data (PII + secrets) from text.

  Replaces matches with `[REDACTED]`.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> redact_secrets()
    |> redact_pii()
  end

  @doc """
  Redact only PII from text.
  """
  @spec redact_pii(String.t()) :: String.t()
  def redact_pii(text) when is_binary(text) do
    pii_regexes =
      Enum.map(labeled_pii_patterns(), fn {regex, _label} -> regex end)

    Enum.reduce(pii_regexes, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  @doc """
  Redact only secrets from text.
  """
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(text) when is_binary(text) do
    secret_regexes =
      Enum.map(labeled_secret_patterns(), fn {regex, _label} -> regex end)

    Enum.reduce(secret_regexes, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  # ===========================================================================
  # Helpers (public for eval check reuse)
  # ===========================================================================

  @doc """
  Calculate Shannon entropy of a string.

  Used for detecting high-entropy base64 blobs that may be secrets.
  """
  @spec shannon_entropy(String.t()) :: float()
  def shannon_entropy(string) when is_binary(string) do
    freq = string |> String.graphemes() |> Enum.frequencies()
    len = String.length(string)

    if len == 0 do
      0.0
    else
      -Enum.reduce(freq, 0.0, fn {_char, count}, acc ->
        p = count / len
        acc + p * :math.log2(p)
      end)
    end
  end

  @doc """
  Validate a number string using the Luhn algorithm (ISO/IEC 7812-1).

  Used for credit card validation to reduce false positives.
  """
  @spec valid_luhn?(String.t()) :: boolean()
  def valid_luhn?(number) when is_binary(number) do
    digits =
      number
      |> String.replace(~r/\D/, "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    if length(digits) < 13 do
      false
    else
      sum =
        digits
        |> Enum.with_index()
        |> Enum.reduce(0, fn {digit, idx}, acc ->
          acc + luhn_digit_value(digit, idx)
        end)

      rem(sum, 10) == 0
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp luhn_digit_value(digit, idx) when rem(idx, 2) == 1 do
    doubled = digit * 2
    if doubled > 9, do: doubled - 9, else: doubled
  end

  defp luhn_digit_value(digit, _idx), do: digit

  defp find_all_matches(regex, text) do
    regex
    |> Regex.scan(text)
    |> Enum.map(&hd/1)
  end

  # Filter out common false positives for PII patterns
  defp false_positive_pii?("Email Address", match, _text) do
    String.contains?(match, [
      "@example.com",
      "@example.org",
      "@test.com"
    ]) or String.starts_with?(match, ["test@", "example@", "foo@", "bar@", "user@"])
  end

  defp false_positive_pii?("IP Address", match, _text) do
    String.starts_with?(match, ["127.0.", "0.0.0.", "192.168.", "10.0.", "172.16."])
  end

  defp false_positive_pii?("Credit Card Number", match, _text) do
    not valid_luhn?(match)
  end

  defp false_positive_pii?(_label, _match, _text), do: false
end
