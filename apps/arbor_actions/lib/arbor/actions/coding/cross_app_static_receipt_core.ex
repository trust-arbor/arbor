defmodule Arbor.Actions.Coding.CrossApp.StaticReceiptCore do
  @moduledoc """
  Neutral static-stage receipt construction, admission, and digest.

  Stored JSON remains the historical closed shape:
  schema_version, continuation_id, identities, checks. The `continuation_id`
  field is identity-derived (`xappc_` plus canonical digest) and is not live
  continuation authority.

  All returned values are closed, string-keyed JSON maps. This core performs
  no filesystem, process, clock, randomness, Application, Registry, GenServer,
  or IO operations.
  """

  alias Arbor.Actions.Coding.CrossApp.EvidenceCore

  @schema_version 1
  @max_excerpt_raw_bytes 2_000
  @max_reason_raw_bytes 256
  @max_continuation_id_raw_bytes 71
  @max_identities_json_bytes 4_096

  @max_excerpt_json_bytes 2 + 6 * @max_excerpt_raw_bytes
  @max_reason_json_bytes 2 + 6 * @max_reason_raw_bytes
  @max_continuation_id_json_bytes 2 + @max_continuation_id_raw_bytes

  @empty_object_json_bytes byte_size(Jason.encode!(%{}))
  @empty_string_json_bytes byte_size(Jason.encode!(""))

  @max_check_fixture %{
    "status" => "completed",
    "passed" => true,
    "exit_code" => 0,
    "reason" => nil,
    "stdout_excerpt" => String.duplicate(<<0>>, @max_excerpt_raw_bytes),
    "stderr_excerpt" => String.duplicate(<<0>>, @max_excerpt_raw_bytes),
    "stdout_truncated" => false,
    "stderr_truncated" => false,
    "stdout_sha256" => String.duplicate("0", 64),
    "stderr_sha256" => String.duplicate("0", 64)
  }
  @max_check_json_bytes byte_size(Jason.encode!(@max_check_fixture))

  @static_receipt_fixture %{
    "schema_version" => @schema_version,
    "continuation_id" => "",
    "identities" => %{},
    "checks" => %{"compile" => %{}, "xref" => %{}, "test_compile" => %{}}
  }
  @static_receipt_fixed_json_bytes byte_size(Jason.encode!(@static_receipt_fixture)) -
                                     4 * @empty_object_json_bytes -
                                     @empty_string_json_bytes
  @max_static_receipt_json_bytes @max_identities_json_bytes +
                                   3 * @max_check_json_bytes +
                                   @max_continuation_id_json_bytes +
                                   @static_receipt_fixed_json_bytes

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @receipt_keys Enum.sort(~w(schema_version continuation_id identities checks))
  @check_names Enum.sort(~w(compile test_compile xref))
  @check_keys Enum.sort(~w(
    exit_code
    passed
    reason
    status
    stderr_excerpt
    stderr_sha256
    stderr_truncated
    stdout_excerpt
    stdout_sha256
    stdout_truncated
  ))
  @forbidden_keys MapSet.new(
                    ~w(authority authorization capability credential fence_token secret token)
                  )

  @type envelope :: %{required(String.t()) => term()}
  @type error :: atom()

  @doc "Static-receipt schema version."
  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @doc "Raw and encoded constituent ceilings for static receipts."
  @spec limits() :: %{required(String.t()) => pos_integer()}
  def limits do
    %{
      "max_excerpt_raw_bytes" => @max_excerpt_raw_bytes,
      "max_excerpt_json_bytes" => @max_excerpt_json_bytes,
      "max_reason_raw_bytes" => @max_reason_raw_bytes,
      "max_reason_json_bytes" => @max_reason_json_bytes,
      "max_continuation_id_raw_bytes" => @max_continuation_id_raw_bytes,
      "max_continuation_id_json_bytes" => @max_continuation_id_json_bytes,
      "max_identities_json_bytes" => @max_identities_json_bytes,
      "max_check_json_bytes" => @max_check_json_bytes,
      "max_static_receipt_json_bytes" => @max_static_receipt_json_bytes
    }
  end

  @doc "Construct and digest a static receipt from identities and successful checks."
  @spec new_static_stage_receipt(term(), term()) ::
          {:ok, envelope(), String.t()} | {:error, error()}
  def new_static_stage_receipt(identities, checks) do
    with {:ok, identities} <- EvidenceCore.admit_identities(identities),
         {:ok, continuation_id} <- EvidenceCore.lineage_key_for_identities(identities),
         {:ok, checks} <- admit_successful_checks(checks),
         receipt <- build_static_receipt(identities, continuation_id, checks),
         :ok <- reject_forbidden_keys(receipt),
         :ok <-
           bound_json(receipt, @max_static_receipt_json_bytes, :oversized_static_receipt),
         {:ok, digest} <- EvidenceCore.digest(receipt) do
      {:ok, receipt, digest}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Admit an arbitrary static receipt and return its canonical form."
  @spec admit_static_stage_receipt(term()) :: {:ok, envelope()} | {:error, error()}
  def admit_static_stage_receipt(receipt) do
    with :ok <- require_json_object(receipt),
         :ok <- require_exact_keys(receipt, @receipt_keys),
         :ok <- require_schema(receipt["schema_version"]),
         :ok <- reject_forbidden_keys(receipt),
         {:ok, identities} <- EvidenceCore.admit_identities(receipt["identities"]),
         {:ok, continuation_id} <- EvidenceCore.lineage_key_for_identities(identities),
         :ok <- match(receipt["continuation_id"], continuation_id, :lineage_drift),
         {:ok, checks} <- admit_successful_checks(receipt["checks"]),
         canonical <- build_static_receipt(identities, continuation_id, checks),
         :ok <-
           bound_json(canonical, @max_static_receipt_json_bytes, :oversized_static_receipt) do
      {:ok, canonical}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Canonical SHA-256 digest of an admitted static receipt."
  @spec static_receipt_digest(term()) :: {:ok, String.t()} | {:error, error()}
  def static_receipt_digest(receipt) do
    with {:ok, admitted} <- admit_static_stage_receipt(receipt) do
      EvidenceCore.digest(admitted)
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  defp admit_successful_checks(checks) do
    with :ok <- require_json_object(checks),
         :ok <- require_exact_keys(checks, @check_names),
         {:ok, compile} <- admit_successful_check(checks["compile"]),
         {:ok, xref} <- admit_successful_check(checks["xref"]),
         {:ok, test_compile} <- admit_successful_check(checks["test_compile"]) do
      {:ok,
       %{
         "compile" => compile,
         "xref" => xref,
         "test_compile" => test_compile
       }}
    end
  end

  defp admit_successful_check(check) do
    with :ok <- require_json_object(check),
         :ok <- require_exact_keys(check, @check_keys),
         :ok <- require_success_fields(check),
         {:ok, stdout} <- admit_excerpt(check["stdout_excerpt"]),
         {:ok, stderr} <- admit_excerpt(check["stderr_excerpt"]),
         :ok <- require_boolean(check["stdout_truncated"]),
         :ok <- require_boolean(check["stderr_truncated"]),
         {:ok, stdout_sha} <- admit_hex(check["stdout_sha256"]),
         {:ok, stderr_sha} <- admit_hex(check["stderr_sha256"]),
         canonical <- %{
           "status" => "completed",
           "passed" => true,
           "exit_code" => 0,
           "reason" => nil,
           "stdout_excerpt" => stdout,
           "stderr_excerpt" => stderr,
           "stdout_truncated" => check["stdout_truncated"],
           "stderr_truncated" => check["stderr_truncated"],
           "stdout_sha256" => stdout_sha,
           "stderr_sha256" => stderr_sha
         },
         :ok <- bound_json(canonical, @max_check_json_bytes, :oversized_static_receipt) do
      {:ok, canonical}
    end
  end

  defp require_success_fields(check) do
    if check["status"] === "completed" and check["passed"] === true and
         check["exit_code"] === 0 and is_nil(check["reason"]),
       do: :ok,
       else: {:error, :malformed_envelope}
  end

  defp admit_excerpt(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_excerpt_raw_bytes,
      do: {:ok, value},
      else: {:error, :malformed_envelope}
  end

  defp admit_excerpt(_value), do: {:error, :malformed_envelope}

  defp admit_hex(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value),
      do: {:ok, value},
      else: {:error, :malformed_envelope}
  end

  defp admit_hex(_value), do: {:error, :malformed_envelope}

  defp require_schema(@schema_version), do: :ok
  defp require_schema(_version), do: {:error, :malformed_envelope}

  defp require_boolean(value) when is_boolean(value), do: :ok
  defp require_boolean(_value), do: {:error, :malformed_envelope}

  defp require_json_object(value) when is_map(value) and not is_struct(value) do
    if json_clean?(value), do: :ok, else: {:error, :malformed_envelope}
  end

  defp require_json_object(_value), do: {:error, :malformed_envelope}

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> String.valid?(key) and json_clean?(nested)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value),
    do: proper_list?(value) and Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp require_exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == keys, do: :ok, else: {:error, :malformed_envelope}
  end

  defp reject_forbidden_keys(value) do
    if contains_forbidden_key?(value),
      do: {:error, :malformed_envelope},
      else: :ok
  end

  defp contains_forbidden_key?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      forbidden_key?(key) or contains_forbidden_key?(nested)
    end)
  end

  defp contains_forbidden_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_key?/1)

  defp contains_forbidden_key?(_value), do: false

  defp forbidden_key?(key) when is_binary(key), do: MapSet.member?(@forbidden_keys, key)
  defp forbidden_key?(_key), do: true

  defp match(left, right, _error) when left === right, do: :ok
  defp match(_left, _right, error), do: {:error, error}

  defp bound_json(value, max, error) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max -> :ok
      {:ok, _encoded} -> {:error, error}
      {:error, _reason} -> {:error, :malformed_envelope}
    end
  end

  defp build_static_receipt(identities, continuation_id, checks) do
    %{
      "schema_version" => @schema_version,
      "continuation_id" => continuation_id,
      "identities" => identities,
      "checks" => checks
    }
  end
end
