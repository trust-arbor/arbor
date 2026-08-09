defmodule Arbor.Orchestrator.CodingPlan.AuthorityHorizonCore do
  @moduledoc """
  Pure authority-horizon calculations and bounded JSON projections for coding
  runs.

  Classifies whether principals hold authorizing capabilities that remain valid
  through an immutable run deadline plus cleanup reserve. No IO, no Security
  calls, no capability minting, no wall-clock reads — pure CRC over injected facts.
  """

  @projected_uri_limit 64
  @max_message_bytes 256
  @max_evidence_ref_bytes 256
  @role_order [:execution_principal, :authenticated_caller]
  @classification_order [:missing, :expiring]
  # Deterministic fallback when callers pass a non-binary observed_at.
  # Not wall-clock; keeps the core free of DateTime.utc_now/0.
  @fallback_observed_at "1970-01-01T00:00:00.000000Z"

  @type principal_role :: :execution_principal | :authenticated_caller
  @type classification :: :missing | :expiring
  @type cap_expiry :: %{optional(:expires_at) => DateTime.t() | nil} | map()

  @type finding :: %{
          role: principal_role(),
          classification: classification(),
          resource_uris: [String.t()],
          total_count: non_neg_integer()
        }

  @type principal_resource_result ::
          {principal_role(), String.t(), classification() | :ok}

  @doc """
  Compute the absolute horizon unix-ms from run deadline and cleanup reserve.
  """
  @spec horizon_unix_ms(term(), term()) :: {:ok, pos_integer()} | {:error, :invalid_horizon}
  def horizon_unix_ms(run_deadline_unix_ms, cleanup_reserve_ms)
      when is_integer(run_deadline_unix_ms) and run_deadline_unix_ms >= 0 and
             is_integer(cleanup_reserve_ms) and cleanup_reserve_ms >= 0 do
    horizon = run_deadline_unix_ms + cleanup_reserve_ms

    if horizon > 0 do
      {:ok, horizon}
    else
      {:error, :invalid_horizon}
    end
  end

  def horizon_unix_ms(_run_deadline_unix_ms, _cleanup_reserve_ms),
    do: {:error, :invalid_horizon}

  @doc """
  Build the principal list with same-principal deduplication.
  """
  @spec principals(String.t(), term()) :: [{principal_role(), String.t()}]
  def principals(execution_principal, caller_id)
      when is_binary(execution_principal) and execution_principal != "" do
    base = [{:execution_principal, execution_principal}]

    case caller_id do
      cid when is_binary(cid) and cid != "" and cid != execution_principal ->
        base ++ [{:authenticated_caller, cid}]

      _ ->
        base
    end
  end

  def principals(_execution_principal, _caller_id), do: []

  @doc """
  Union resource URI lists into a sorted unique list of non-blank binaries.
  """
  @spec union_resources([term()]) :: [String.t()]
  def union_resources(lists) when is_list(lists) do
    lists
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def union_resources(_lists), do: []

  @doc """
  Classify coverage of one resource from authorizing caps' expiry values.
  """
  @spec classify_resource_coverage([cap_expiry()], DateTime.t()) ::
          :ok | classification()
  def classify_resource_coverage(authorizing_caps, %DateTime{} = horizon_dt)
      when is_list(authorizing_caps) do
    cond do
      authorizing_caps == [] ->
        :missing

      Enum.any?(authorizing_caps, &covers_horizon?(&1, horizon_dt)) ->
        :ok

      true ->
        :expiring
    end
  end

  def classify_resource_coverage(_authorizing_caps, _horizon_dt), do: :missing

  @doc """
  Aggregate per-principal per-resource results into full findings.

  Every input result is considered; no truncation occurs here.
  """
  @spec aggregate_findings([principal_resource_result()]) ::
          :ok | {:error, [finding()]}
  def aggregate_findings(results) when is_list(results) do
    grouped =
      results
      |> Enum.reduce(%{}, fn
        {_role, _resource, :ok}, acc ->
          acc

        {role, resource, classification}, acc
        when classification in @classification_order and is_binary(resource) ->
          key = {role, classification}
          Map.update(acc, key, [resource], &[resource | &1])

        _other, acc ->
          acc
      end)

    if map_size(grouped) == 0 do
      :ok
    else
      findings =
        for role <- @role_order,
            classification <- @classification_order,
            Map.has_key?(grouped, {role, classification}) do
          uris =
            grouped
            |> Map.fetch!({role, classification})
            |> Enum.uniq()
            |> Enum.sort()

          %{
            role: role,
            classification: classification,
            resource_uris: uris,
            total_count: length(uris)
          }
        end

      {:error, findings}
    end
  end

  def aggregate_findings(_results), do: :ok

  @doc """
  Bound a complete resource URI set into a JSON-clean projection envelope.

  Samples are truncated; `total_count` and `resource_uris_digest` cover the
  complete sorted unique set.
  """
  @spec project_resource_set(term()) :: map()
  def project_resource_set(resources) when is_list(resources) do
    uris =
      resources
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "total_count" => length(uris),
      "resource_uris" => Enum.take(uris, @projected_uri_limit),
      "resource_uris_digest" => uri_list_digest(uris)
    }
  end

  def project_resource_set(_resources), do: project_resource_set([])

  @doc """
  Project full findings into bounded string-keyed finding maps.
  """
  @spec project_findings_report(term()) :: [map()]
  def project_findings_report(findings) when is_list(findings) do
    findings
    |> Enum.map(&project_one_finding/1)
    |> Enum.reject(&is_nil/1)
  end

  def project_findings_report(_findings), do: []

  @doc """
  Derive projection status from findings. Missing wins over expiring.
  """
  @spec projection_status(term()) :: String.t()
  def projection_status(:ok), do: "ready"

  def projection_status({:error, findings}) when is_list(findings),
    do: projection_status(findings)

  def projection_status(findings) when is_list(findings) do
    cond do
      findings == [] ->
        "ready"

      Enum.any?(findings, &finding_classification?(&1, :missing)) ->
        "missing"

      Enum.any?(findings, &finding_classification?(&1, :expiring)) ->
        "expiring"

      true ->
        "error"
    end
  end

  def projection_status(_findings), do: "error"

  @doc """
  Assemble a bounded JSON-clean authority-horizon projection report.

  All time and security facts must be injected; this function performs no IO.
  """
  @spec project_horizon_report(map()) :: map()
  def project_horizon_report(attrs) when is_map(attrs) do
    observed_at =
      normalize_observed_at(Map.get(attrs, :observed_at) || Map.get(attrs, "observed_at"))

    findings =
      case Map.get(attrs, :findings) || Map.get(attrs, "findings") do
        list when is_list(list) -> list
        :ok -> []
        {:error, list} when is_list(list) -> list
        _ -> []
      end

    resources =
      case Map.get(attrs, :resources) || Map.get(attrs, "resources") do
        list when is_list(list) -> list
        _ -> []
      end

    status =
      case Map.get(attrs, :status) || Map.get(attrs, "status") do
        status when status in ["ready", "missing", "expiring", "error"] ->
          status

        _ ->
          projection_status(findings)
      end

    scope_mode =
      case Map.get(attrs, :scope_mode) || Map.get(attrs, "scope_mode") do
        mode when mode in ["future_task", "bound_task"] -> mode
        :future_task -> "future_task"
        :bound_task -> "bound_task"
        _ -> "future_task"
      end

    task_id = nullable_binary(Map.get(attrs, :task_id) || Map.get(attrs, "task_id"))
    session_id = nullable_binary(Map.get(attrs, :session_id) || Map.get(attrs, "session_id"))

    principals =
      case Map.get(attrs, :principals) || Map.get(attrs, "principals") do
        list when is_list(list) -> project_principals(list)
        _ -> []
      end

    run_deadline =
      Map.get(attrs, :run_deadline_unix_ms) || Map.get(attrs, "run_deadline_unix_ms")

    cleanup_reserve =
      Map.get(attrs, :cleanup_reserve_ms) || Map.get(attrs, "cleanup_reserve_ms")

    horizon_unix_ms =
      Map.get(attrs, :horizon_unix_ms) || Map.get(attrs, "horizon_unix_ms")

    missing_n = sum_count(findings, :missing)
    expiring_n = sum_count(findings, :expiring)
    projected_findings = project_findings_report(findings)

    error =
      case Map.get(attrs, :error) || Map.get(attrs, "error") do
        %{code: code, message: message} ->
          %{
            "code" => stable_error_code(code),
            "message" => bound_text(message, @max_message_bytes)
          }

        %{"code" => code, "message" => message} ->
          %{
            "code" => stable_error_code(code),
            "message" => bound_text(message, @max_message_bytes)
          }

        code when is_atom(code) and not is_nil(code) ->
          %{
            "code" => Atom.to_string(code),
            "message" => bound_text(Atom.to_string(code), @max_message_bytes)
          }

        code when is_binary(code) and code != "" ->
          %{
            "code" => code,
            "message" => bound_text(code, @max_message_bytes)
          }

        _ ->
          nil
      end

    %{
      "version" => 1,
      "kind" => "authority_horizon_projection",
      "status" => status,
      "observed_at" => observed_at,
      "scope" => %{
        "mode" => scope_mode,
        # future_task never exposes or credits task-/session-scoped identity.
        "task_id" => if(scope_mode == "future_task", do: nil, else: task_id),
        "session_id" => if(scope_mode == "future_task", do: nil, else: session_id)
      },
      "horizon" => %{
        "run_deadline_unix_ms" => non_neg_int_or_null(run_deadline),
        "cleanup_reserve_ms" => non_neg_int_or_null(cleanup_reserve),
        "horizon_unix_ms" => non_neg_int_or_null(horizon_unix_ms)
      },
      "principals" => principals,
      "required_resources" => project_resource_set(resources),
      "findings" => projected_findings,
      "summary" => %{
        "missing_n" => missing_n,
        "expiring_n" => expiring_n,
        "findings_digest" => findings_digest(findings)
      },
      "error" => error
    }
  end

  def project_horizon_report(_attrs) do
    project_horizon_report(%{
      status: "error",
      findings: [],
      resources: [],
      error: :invalid_authority_horizon_opts
    })
  end

  @doc """
  Project full findings into a Diagnostic-compatible attribute map.

  Truncates projected URI samples only; retains total_count and a digest of
  the full sorted URI set. `observed_at` must be an injected ISO8601 string;
  invalid values fall back to a deterministic sentinel (never wall-clock).
  """
  @spec project_diagnostic_payload([finding()], term()) :: map()
  def project_diagnostic_payload(findings, observed_at) when is_list(findings) do
    observed = normalize_observed_at(observed_at)
    has_missing? = Enum.any?(findings, &(&1.classification == :missing))
    code = if has_missing?, do: "authority_horizon_missing", else: "authority_horizon_expiring"

    full_uri_digest = findings_digest(findings)
    missing_n = sum_count(findings, :missing)
    expiring_n = sum_count(findings, :expiring)

    primary =
      Enum.find(findings, &(&1.classification == :missing)) ||
        List.first(findings)

    sample_uri =
      case primary do
        %{resource_uris: [uri | _]} -> uri
        _ -> nil
      end

    role_label =
      case primary do
        %{role: role} -> Atom.to_string(role)
        _ -> "unknown"
      end

    classification_label =
      case primary do
        %{classification: c} -> Atom.to_string(c)
        _ -> "unknown"
      end

    total =
      case primary do
        %{total_count: n} -> n
        _ -> 0
      end

    message =
      bound_text(
        "#{role_label} #{classification_label} total_count=#{total}" <>
          if(is_binary(sample_uri), do: "; first=#{sample_uri}", else: ""),
        @max_message_bytes
      )

    evidence_ref =
      bound_text(
        "missing_n=#{missing_n};expiring_n=#{expiring_n};digest=#{full_uri_digest}",
        @max_evidence_ref_bytes
      )

    remediation =
      if has_missing? do
        "Grant permanent or horizon-covering capabilities for the listed resources; do not rely on mid-run renewal."
      else
        "Extend or replace expiring capabilities so they remain valid through the run horizon; do not rely on mid-run renewal."
      end

    projected_findings =
      Enum.map(findings, fn finding ->
        %{
          "principal_role" => Atom.to_string(finding.role),
          "classification" => Atom.to_string(finding.classification),
          "total_count" => finding.total_count,
          "resource_uris" => Enum.take(finding.resource_uris, @projected_uri_limit),
          "resource_uris_digest" => uri_list_digest(finding.resource_uris)
        }
      end)

    %{
      version: 1,
      gate_id: "authority_horizon",
      phase: "preflight",
      decision: "blocked",
      code: code,
      observed_at: observed,
      message: message,
      remediation: remediation,
      evidence_ref: evidence_ref,
      # Internal projection aid for tests; Diagnostic.normalize drops unknown fields.
      findings: projected_findings
    }
  end

  def project_diagnostic_payload(_findings, observed_at) do
    %{
      version: 1,
      gate_id: "authority_horizon",
      phase: "preflight",
      decision: "blocked",
      code: "authority_horizon_missing",
      observed_at: normalize_observed_at(observed_at),
      message: "authority horizon preflight failed",
      remediation: "Grant horizon-covering capabilities for required resources."
    }
  end

  @doc "Return the projection URI limit used by diagnostic projection."
  @spec projected_uri_limit() :: pos_integer()
  def projected_uri_limit, do: @projected_uri_limit

  @doc "Digest a sorted list of resource URIs."
  @spec uri_list_digest([String.t()]) :: String.t()
  def uri_list_digest(uris) when is_list(uris) do
    uris
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def uri_list_digest(_uris), do: uri_list_digest([])

  @doc """
  UTF-8-safe bound of a diagnostic text field to at most `max_bytes` bytes.

  Strips control characters, never splits a multi-byte codepoint, and never
  returns an empty string (Diagnostic rejects blank optional text).
  """
  @spec bound_text(term(), pos_integer()) :: String.t()
  def bound_text(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    if String.valid?(text) do
      cleaned =
        text
        |> strip_controls()
        |> String.trim()

      cond do
        cleaned == "" ->
          "authority horizon blocked"

        byte_size(cleaned) <= max_bytes ->
          cleaned

        true ->
          case utf8_byte_prefix(cleaned, max_bytes) do
            "" -> "authority horizon blocked"
            prefix -> prefix
          end
      end
    else
      "authority horizon blocked"
    end
  end

  def bound_text(_text, _max_bytes), do: "authority horizon blocked"

  defp covers_horizon?(cap, horizon_dt) do
    case expiry_of(cap) do
      nil -> true
      %DateTime{} = expires_at -> DateTime.compare(expires_at, horizon_dt) == :gt
      _ -> false
    end
  end

  # Only an explicit nil expiration is permanent. Missing or malformed expiry
  # data fails closed as non-covering.
  defp expiry_of(%{expires_at: expires_at}), do: expires_at
  defp expiry_of(%{"expires_at" => expires_at}), do: expires_at
  defp expiry_of(_cap), do: :invalid

  defp project_one_finding(%{
         role: role,
         classification: classification,
         resource_uris: resource_uris,
         total_count: total_count
       })
       when role in @role_order and classification in @classification_order and
              is_list(resource_uris) and is_integer(total_count) and total_count >= 0 do
    uris =
      resource_uris
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "principal_role" => Atom.to_string(role),
      "classification" => Atom.to_string(classification),
      "total_count" => total_count,
      "resource_uris" => Enum.take(uris, @projected_uri_limit),
      "resource_uris_digest" => uri_list_digest(uris)
    }
  end

  defp project_one_finding(_other), do: nil

  defp finding_classification?(%{classification: classification}, expected),
    do: classification == expected

  defp finding_classification?(_finding, _expected), do: false

  defp sum_count(findings, classification) when is_list(findings) do
    findings
    |> Enum.filter(fn
      %{classification: ^classification, total_count: n} when is_integer(n) and n >= 0 -> true
      _ -> false
    end)
    |> Enum.reduce(0, fn finding, acc -> acc + finding.total_count end)
  end

  defp sum_count(_findings, _classification), do: 0

  defp findings_digest(findings) when is_list(findings) do
    findings
    |> Enum.flat_map(fn
      %{role: role, classification: classification, resource_uris: uris}
      when is_list(uris) ->
        Enum.map(uris, fn uri ->
          if is_binary(uri) do
            "#{role}\t#{classification}\t#{uri}"
          else
            nil
          end
        end)

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp findings_digest(_findings), do: findings_digest([])

  defp project_principals(principals) do
    Enum.flat_map(principals, fn
      {role, principal_id}
      when role in @role_order and is_binary(principal_id) and principal_id != "" ->
        [%{"role" => Atom.to_string(role), "principal_id" => principal_id}]

      %{"role" => role, "principal_id" => principal_id}
      when is_binary(role) and is_binary(principal_id) and principal_id != "" ->
        [%{"role" => role, "principal_id" => principal_id}]

      _ ->
        []
    end)
  end

  defp nullable_binary(value) when is_binary(value) and value != "", do: value
  defp nullable_binary(_value), do: nil

  defp non_neg_int_or_null(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_int_or_null(_value), do: nil

  defp stable_error_code(code) when is_atom(code), do: Atom.to_string(code)
  defp stable_error_code(code) when is_binary(code) and code != "", do: code
  defp stable_error_code(_code), do: "authority_horizon_exception"

  defp normalize_observed_at(observed_at) when is_binary(observed_at) and observed_at != "" do
    if String.valid?(observed_at), do: observed_at, else: @fallback_observed_at
  end

  defp normalize_observed_at(_observed_at), do: @fallback_observed_at

  defp strip_controls(text) when is_binary(text) do
    String.replace(text, ~r/[\x00-\x1F\x7F]/, " ")
  end

  # Walk complete UTF-8 codepoints until the byte budget is exhausted.
  defp utf8_byte_prefix(text, max_bytes) when is_binary(text) and max_bytes > 0 do
    do_utf8_byte_prefix(text, max_bytes, [])
  end

  defp do_utf8_byte_prefix(<<>>, _remaining, acc) do
    acc |> Enum.reverse() |> :erlang.iolist_to_binary()
  end

  defp do_utf8_byte_prefix(<<cp::utf8, rest::binary>>, remaining, acc) do
    encoded = <<cp::utf8>>
    size = byte_size(encoded)

    if size <= remaining do
      do_utf8_byte_prefix(rest, remaining - size, [encoded | acc])
    else
      acc |> Enum.reverse() |> :erlang.iolist_to_binary()
    end
  end

  defp do_utf8_byte_prefix(_invalid, _remaining, acc) do
    acc |> Enum.reverse() |> :erlang.iolist_to_binary()
  end
end
