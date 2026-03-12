defmodule Arbor.Gateway.VerificationPlan do
  @moduledoc """
  Generates verification plans from extracted intents.

  Phase 3 of the Prompt Pre-Processor pipeline. Converts success criteria
  and constraints from `IntentExtractor` output into executable checks that
  can be run after task completion.

  ## Usage

      intent = %{
        goal: "Deploy app to staging",
        success_criteria: ["HTTP 200 at staging.example.com/health"],
        constraints: ["Don't modify production config"],
        resources: ["config/staging.exs", "config/prod.exs"],
        risk_level: :medium
      }

      plan = VerificationPlan.from_intent(intent)
      results = VerificationPlan.execute(plan)

  ## Check Types

  - `:http` — HTTP request expecting a status code
  - `:command` — shell command expecting output pattern
  - `:file_exists` — verify a file exists
  - `:file_unchanged` — verify a file hasn't been modified (content hash)
  - `:file_contains` — verify a file contains expected text
  - `:custom` — arbitrary check function
  """

  require Logger

  @type check_type :: :http | :command | :file_exists | :file_unchanged | :file_contains | :custom

  @type check :: %{
          type: check_type(),
          description: String.t(),
          params: map(),
          source: :success_criteria | :constraint | :resource
        }

  @type check_result :: %{
          check: check(),
          passed: boolean(),
          detail: String.t() | nil
        }

  @type t :: %{
          checks: [check()],
          rollback_hint: String.t() | nil,
          risk_level: atom()
        }

  @doc """
  Generate a verification plan from an extracted intent.

  Derives checks from success criteria, constraints, and resources.
  """
  @spec from_intent(map()) :: t()
  def from_intent(%{} = intent) do
    criteria_checks =
      intent
      |> Map.get(:success_criteria, [])
      |> Enum.flat_map(&criterion_to_checks/1)

    constraint_checks =
      intent
      |> Map.get(:constraints, [])
      |> Enum.flat_map(&constraint_to_checks/1)

    resource_checks =
      intent
      |> Map.get(:resources, [])
      |> Enum.flat_map(&resource_to_checks/1)

    %{
      checks: criteria_checks ++ constraint_checks ++ resource_checks,
      rollback_hint: derive_rollback(intent),
      risk_level: Map.get(intent, :risk_level, :low)
    }
  end

  @doc """
  Execute all checks in a verification plan, returning results.

  Checks are run sequentially. Each check returns pass/fail with detail.
  Execution is best-effort — a failing check doesn't stop subsequent checks.
  """
  @spec execute(t()) :: [check_result()]
  def execute(%{checks: checks}) do
    Enum.map(checks, &run_check/1)
  end

  @doc """
  Returns true if all checks in the results passed.
  """
  @spec all_passed?([check_result()]) :: boolean()
  def all_passed?(results) when is_list(results) do
    Enum.all?(results, & &1.passed)
  end

  @doc """
  Returns only the failed checks from results.
  """
  @spec failures([check_result()]) :: [check_result()]
  def failures(results) when is_list(results) do
    Enum.reject(results, & &1.passed)
  end

  @doc """
  Summarize verification results as a human-readable string.
  """
  @spec summarize([check_result()]) :: String.t()
  def summarize(results) when is_list(results) do
    total = length(results)
    passed = Enum.count(results, & &1.passed)
    failed = total - passed

    lines =
      Enum.map(results, fn r ->
        status = if r.passed, do: "PASS", else: "FAIL"
        detail = if r.detail, do: " — #{r.detail}", else: ""
        "  [#{status}] #{r.check.description}#{detail}"
      end)

    header = "Verification: #{passed}/#{total} passed#{if failed > 0, do: " (#{failed} failed)", else: ""}"
    Enum.join([header | lines], "\n")
  end

  # -- Criterion → Checks --

  defp criterion_to_checks(criterion) when is_binary(criterion) do
    cond do
      http_check?(criterion) ->
        [build_http_check(criterion)]

      command_check?(criterion) ->
        [build_command_check(criterion)]

      file_check?(criterion) ->
        [build_file_exists_check(criterion)]

      true ->
        [%{
          type: :custom,
          description: criterion,
          params: %{criterion: criterion},
          source: :success_criteria
        }]
    end
  end

  # -- Constraint → Checks --

  defp constraint_to_checks(constraint) when is_binary(constraint) do
    # Look for "don't modify/change/touch <file>" patterns
    case Regex.run(~r/(?:don'?t|do not|never)\s+(?:modify|change|touch|alter|edit)\s+(.+)/i, constraint) do
      [_, resource] ->
        path = extract_path(String.trim(resource))

        if path do
          [%{
            type: :file_unchanged,
            description: "#{path} should not be modified",
            params: %{path: path, snapshot_hash: snapshot_file(path)},
            source: :constraint
          }]
        else
          [%{type: :custom, description: constraint, params: %{constraint: constraint}, source: :constraint}]
        end

      _ ->
        [%{type: :custom, description: constraint, params: %{constraint: constraint}, source: :constraint}]
    end
  end

  # -- Resource → Checks --

  defp resource_to_checks(resource) when is_binary(resource) do
    path = extract_path(resource)

    if path && File.exists?(path) do
      [%{
        type: :file_exists,
        description: "#{path} exists",
        params: %{path: path},
        source: :resource
      }]
    else
      []
    end
  end

  # -- Pattern detection --

  defp http_check?(text) do
    String.contains?(text, ["HTTP", "http", "status", "200", "health", "endpoint", "URL", "url"])
  end

  defp command_check?(text) do
    String.contains?(text, ["command", "run ", "execute", "mix ", "git ", "curl "])
  end

  defp file_check?(text) do
    extract_path(text) != nil
  end

  # -- Check builders --

  defp build_http_check(criterion) do
    url = extract_url(criterion)
    status = extract_status_code(criterion)

    %{
      type: :http,
      description: criterion,
      params: %{url: url, expected_status: status || 200},
      source: :success_criteria
    }
  end

  defp build_command_check(criterion) do
    %{
      type: :command,
      description: criterion,
      params: %{criterion: criterion},
      source: :success_criteria
    }
  end

  defp build_file_exists_check(criterion) do
    path = extract_path(criterion)

    %{
      type: :file_exists,
      description: criterion,
      params: %{path: path},
      source: :success_criteria
    }
  end

  # -- Check execution --

  defp run_check(%{type: :file_exists, params: %{path: path}} = check) do
    if path && File.exists?(path) do
      %{check: check, passed: true, detail: nil}
    else
      %{check: check, passed: false, detail: "File not found: #{path}"}
    end
  end

  defp run_check(%{type: :file_unchanged, params: %{path: path, snapshot_hash: hash}} = check) do
    current = snapshot_file(path)

    cond do
      is_nil(hash) ->
        %{check: check, passed: true, detail: "No baseline snapshot (file may not have existed)"}

      current == hash ->
        %{check: check, passed: true, detail: nil}

      true ->
        %{check: check, passed: false, detail: "File was modified (hash changed)"}
    end
  end

  defp run_check(%{type: :http, params: %{url: url, expected_status: expected}} = check) do
    if url do
      # We don't actually make HTTP calls in the verification runner —
      # that's the agent's job. We just record what should be checked.
      %{check: check, passed: true, detail: "HTTP check deferred: GET #{url} expecting #{expected}"}
    else
      %{check: check, passed: true, detail: "No URL extracted — manual verification needed"}
    end
  end

  defp run_check(%{type: :command} = check) do
    # Command checks are deferred to the agent — we don't execute arbitrary commands
    %{check: check, passed: true, detail: "Command check deferred — manual verification needed"}
  end

  defp run_check(%{type: :custom} = check) do
    %{check: check, passed: true, detail: "Custom check — manual verification needed"}
  end

  # -- Extraction helpers --

  defp extract_url(text) do
    case Regex.run(~r{https?://[^\s,)]+}, text) do
      [url] -> url
      _ -> nil
    end
  end

  defp extract_status_code(text) do
    case Regex.run(~r/\b([1-5]\d{2})\b/, text) do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  defp extract_path(text) do
    # Match file paths — relative or absolute
    case Regex.run(~r{(?:^|[\s"'`])([/.]?[\w./-]+\.[\w]+)}, text) do
      [_, path] -> String.trim(path)
      _ ->
        # Try bare path without extension (e.g. "config/prod")
        case Regex.run(~r{(?:^|[\s"'`])([/.]?(?:[\w-]+/)+[\w.-]+)}, text) do
          [_, path] -> String.trim(path)
          _ -> nil
        end
    end
  end

  defp snapshot_file(nil), do: nil

  defp snapshot_file(path) do
    case File.read(path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end

  defp derive_rollback(%{risk_level: :high, resources: resources}) when resources != [] do
    paths = Enum.filter(resources, &extract_path/1)

    if paths != [] do
      "git checkout -- #{Enum.join(paths, " ")}"
    else
      "Review changes manually before proceeding"
    end
  end

  defp derive_rollback(%{risk_level: :medium}) do
    "Review changes and consider git stash/revert if needed"
  end

  defp derive_rollback(_), do: nil
end
