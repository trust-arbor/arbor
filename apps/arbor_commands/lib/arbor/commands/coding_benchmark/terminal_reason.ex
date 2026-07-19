defmodule Arbor.Commands.CodingBenchmark.TerminalReason do
  @moduledoc false

  # Bounded terminal causality for benchmark report rows. Prefers an explicit
  # reason/error when present; otherwise derives from the first failed legacy
  # validation entry without exposing stdout or unbounded command output.
  # Text fragments pass through Arbor.Common.SensitiveData before the final bound.

  alias Arbor.Common.SensitiveData

  @max_reason_bytes 1_000
  @max_stderr_bytes 400

  @spec from_result(term(), term()) :: String.t() | nil
  def from_result(_result, status) when status in ~w(change_committed no_changes pr_created),
    do: nil

  def from_result(result, _status) when is_map(result) and not is_struct(result) do
    sources = result_sources(result)

    explicit =
      Enum.find_value(sources, fn source ->
        value =
          map_value(source, "reason", :reason) || map_value(source, "error", :error)

        if is_nil(value), do: nil, else: reason_string(value)
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
      parts ++ ["#{label}=#{reason_string(value)}"]
    else
      parts
    end
  end

  defp maybe_reason_part(parts, label, value) when is_integer(value) or is_atom(value) do
    parts ++ ["#{label}=#{reason_string(value)}"]
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
      |> String.slice(0, @max_stderr_bytes)
    else
      nil
    end
  end

  defp bounded_validation_stderr(_stderr), do: nil

  defp reason_string(nil), do: "unspecified"

  defp reason_string(value) when is_binary(value) do
    value
    |> then(fn text ->
      if String.valid?(text) do
        text
      else
        bytes = binary_part(text, 0, min(byte_size(text), 500))
        "invalid_utf8:#{Base.encode16(bytes, case: :lower)}"
      end
    end)
    |> finalize_reason_text()
  end

  defp reason_string(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> finalize_reason_text()
  end

  defp reason_string(value) do
    value
    |> inspect(limit: 30, printable_limit: @max_reason_bytes, width: 120)
    |> finalize_reason_text()
  end

  # Apply the existing SensitiveData redaction boundary, then enforce the
  # final 1000-byte ceiling on the redacted text.
  defp finalize_reason_text(text) when is_binary(text) do
    text
    |> redact_text()
    |> String.slice(0, @max_reason_bytes)
  end

  defp redact_text(text) when is_binary(text) do
    SensitiveData.redact(text)
  rescue
    _ -> text
  end

  defp map_value(map, string_key, atom_key) when is_map(map) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp map_value(_map, _string_key, _atom_key), do: nil
end
