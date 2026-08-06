defmodule Arbor.Orchestrator.CodingPlan.AuthorityHorizonCore do
  @moduledoc """
  Pure authority-horizon calculations for coding-run preflight.

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

  defp sum_count(findings, classification) do
    findings
    |> Enum.filter(&(&1.classification == classification))
    |> Enum.reduce(0, fn finding, acc -> acc + finding.total_count end)
  end

  defp findings_digest(findings) do
    findings
    |> Enum.flat_map(fn finding ->
      Enum.map(finding.resource_uris, fn uri ->
        "#{finding.role}\t#{finding.classification}\t#{uri}"
      end)
    end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

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
