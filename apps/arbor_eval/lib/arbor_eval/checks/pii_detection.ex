defmodule ArborEval.Checks.PIIDetection do
  @moduledoc """
  Detects potential personally identifiable information (PII) in code.

  Scans for: # arbor:allow pii (documentation examples below)
  - Hardcoded paths with usernames (/Users/username/, /home/username/)
  - Email addresses
  - Phone numbers
  - Names (configurable list)
  - API keys and secrets patterns
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
  @phone_patterns [
    ~r/\+?1?[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}/,
    ~r/\+\d{1,3}[-.\s]?\d{6,14}/
  ]

  # API key / secret patterns
  @secret_patterns [
    ~r/(?i)(api[_-]?key|apikey|secret[_-]?key|auth[_-]?token|access[_-]?token)\s*[:=]\s*["'][a-zA-Z0-9_-]{16,}["']/,
    ~r/(?i)(password|passwd|pwd)\s*[:=]\s*["'][^"']+["']/,
    # OpenAI-style keys
    ~r/sk-[a-zA-Z0-9]{32,}/,
    # GitHub personal access tokens
    ~r/ghp_[a-zA-Z0-9]{36}/,
    # Slack tokens
    ~r/xox[baprs]-[a-zA-Z0-9-]+/
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
end
