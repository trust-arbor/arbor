defmodule Arbor.Commands.CodingBenchmark.TerminalReason do
  @moduledoc false

  # Bounded terminal causality for benchmark report rows. Prefers an explicit
  # reason/error when present; otherwise derives from the first failed legacy
  # validation entry without exposing stdout or unbounded command output.
  # Text fragments pass through Arbor.Common.SensitiveData before the final bound.
  #
  # `sanitize/1` is the reusable total boundary for arbitrary harness/adapter
  # failure reasons (including failure_row terminal_reason). It redacts first,
  # enforces a UTF-8-safe 1000-byte ceiling, and never invokes custom struct
  # Inspect callbacks.

  alias Arbor.Common.SensitiveData

  @max_reason_bytes 1_000
  @max_stderr_bytes 400
  @max_invalid_utf8_source_bytes 500
  @redacted_marker "[REDACTED]"

  @doc """
  Total, fail-closed sanitizer for arbitrary harness/adapter failure reasons.

  Always returns a UTF-8 binary at most 1000 bytes. Sensitive patterns are
  redacted before truncation. Struct-tagged terms are represented without
  invoking custom `Inspect` implementations.
  """
  @spec sanitize(term()) :: String.t()
  def sanitize(value) do
    value
    |> represent()
    |> finalize_reason_text()
  rescue
    # Fail closed: never surface partial unredacted or unbounded text.
    _ -> @redacted_marker
  catch
    # Also catch throw/exit from hostile Inspect or redaction callbacks.
    _kind, _reason -> @redacted_marker
  end

  @doc false
  @spec append(term(), term()) :: String.t()
  def append(existing, suffix) when existing in [nil, ""], do: sanitize(suffix)

  def append(existing, suffix) when is_binary(existing) do
    sanitize(existing <> ";" <> sanitize(suffix))
  end

  def append(_existing, suffix), do: sanitize(suffix)

  @spec from_result(term(), term()) :: String.t() | nil
  def from_result(_result, status) when status in ~w(change_committed no_changes pr_created),
    do: nil

  def from_result(result, _status) when is_map(result) and not is_struct(result) do
    sources = result_sources(result)

    explicit =
      Enum.find_value(sources, fn source ->
        value =
          map_value(source, "reason", :reason) || map_value(source, "error", :error)

        if is_nil(value), do: nil, else: sanitize(value)
      end)

    explicit || validation_failure_reason(sources)
  end

  def from_result(_result, _status), do: nil

  defp result_sources(result) do
    payload = map_value(result, "payload", :payload) || %{}
    report = map_value(payload, "report", :report) || %{}
    raw = map_value(result, "raw", :raw) || %{}
    Enum.filter([report, payload, raw, result], &(is_map(&1) and not is_struct(&1)))
  end

  defp validation_failure_reason(sources) when is_list(sources) do
    sources
    |> Enum.find_value(fn source ->
      case map_value(source, "validation", :validation) do
        validations when is_list(validations) -> first_failed_validation(validations)
        _ -> nil
      end
    end)
    |> case do
      nil -> nil
      entry when is_map(entry) -> format_validation_failure_reason(entry)
      _ -> nil
    end
  end

  defp first_failed_validation(validations) do
    Enum.find(validations, fn
      entry when is_map(entry) and not is_struct(entry) ->
        case map_value(entry, "passed", :passed) do
          false -> true
          "false" -> true
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp format_validation_failure_reason(entry) when is_map(entry) do
    parts =
      []
      |> maybe_reason_part("command", map_value(entry, "command", :command))
      |> maybe_reason_part("status", map_value(entry, "status", :status))
      |> maybe_reason_part("exit_code", map_value(entry, "exit_code", :exit_code))
      |> maybe_reason_flag("timed_out", map_value(entry, "timed_out", :timed_out))
      |> maybe_reason_flag("killed", map_value(entry, "killed", :killed))
      |> maybe_reason_part(
        "stderr",
        bounded_validation_stderr(map_value(entry, "stderr", :stderr))
      )

    case parts do
      [] -> "validation_failed"
      _ -> Enum.join(parts, " ") |> finalize_reason_text()
    end
  end

  defp maybe_reason_part(parts, _label, nil), do: parts
  defp maybe_reason_part(parts, _label, ""), do: parts

  defp maybe_reason_part(parts, label, value) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" do
      # Command/stderr/status text can carry credentials; redact before join.
      parts ++ ["#{label}=#{sanitize(value)}"]
    else
      parts
    end
  end

  defp maybe_reason_part(parts, label, value) when is_integer(value) or is_atom(value) do
    parts ++ ["#{label}=#{sanitize(value)}"]
  end

  defp maybe_reason_part(parts, _label, _value), do: parts

  defp maybe_reason_flag(parts, label, true), do: parts ++ ["#{label}=true"]
  defp maybe_reason_flag(parts, label, "true"), do: parts ++ ["#{label}=true"]
  defp maybe_reason_flag(parts, _label, _value), do: parts

  defp bounded_validation_stderr(stderr) when is_binary(stderr) do
    if String.valid?(stderr) and String.trim(stderr) != "" do
      # Redact before the stderr excerpt bound so secrets near the cut are not kept.
      stderr
      |> redact_text()
      |> truncate_utf8_bytes(@max_stderr_bytes)
    else
      nil
    end
  end

  defp bounded_validation_stderr(_stderr), do: nil

  # Represent arbitrary terms as text before redaction/byte ceiling. Binary and
  # atom paths avoid Inspect entirely. Struct-tagged and other terms use
  # inspect with structs: false so custom Inspect callbacks cannot raise or
  # leak fields.
  defp represent(nil), do: "unspecified"

  defp represent(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      # Bound the raw source by bytes before hex-encoding so the label cannot grow
      # unboundedly from a large invalid binary.
      source =
        binary_part(value, 0, min(byte_size(value), @max_invalid_utf8_source_bytes))

      "invalid_utf8:#{Base.encode16(source, case: :lower)}"
    end
  end

  defp represent(value) when is_atom(value), do: Atom.to_string(value)

  defp represent(value) do
    inspect(value,
      limit: 30,
      printable_limit: @max_reason_bytes,
      structs: false,
      width: 120
    )
  end

  # Apply the existing SensitiveData redaction boundary, then enforce the
  # final 1000-byte ceiling on the redacted text with UTF-8-safe truncation.
  defp finalize_reason_text(text) when is_binary(text) do
    text
    |> redact_text()
    |> truncate_utf8_bytes(@max_reason_bytes)
  end

  defp finalize_reason_text(_other), do: @redacted_marker

  defp redact_text(text) when is_binary(text) do
    SensitiveData.redact(text)
  rescue
    # Fail closed: never return the unredacted secret if redaction crashes.
    _ -> @redacted_marker
  catch
    _kind, _reason -> @redacted_marker
  end

  # UTF-8-safe byte ceiling: reduce until the prefix is valid UTF-8 and
  # within max_bytes. Unlike String.slice/3, this bounds byte_size/1.
  defp truncate_utf8_bytes(bin, max_bytes)
       when is_binary(bin) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(bin) <= max_bytes and String.valid?(bin) do
      bin
    else
      do_truncate_utf8_bytes(bin, min(byte_size(bin), max_bytes))
    end
  end

  defp truncate_utf8_bytes(_bin, _max_bytes), do: ""

  defp do_truncate_utf8_bytes(_bin, size) when size <= 0, do: ""

  defp do_truncate_utf8_bytes(bin, size) do
    prefix = binary_part(bin, 0, size)

    if String.valid?(prefix) do
      prefix
    else
      do_truncate_utf8_bytes(bin, size - 1)
    end
  end

  defp map_value(map, string_key, atom_key) when is_map(map) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp map_value(_map, _string_key, _atom_key), do: nil
end
