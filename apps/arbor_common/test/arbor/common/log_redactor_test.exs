defmodule Arbor.Common.LogRedactorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.LogRedactor

  # Local opaque struct: maps that do not implement Enumerable (same protocol
  # surface as crash-report terms such as %ExMCP.ACP.Client.HandlerRunner{}).
  defmodule OpaqueHandler do
    defstruct [:id, :token, :nested]
  end

  # M7 security regression (SECURITY_REVIEW 2026-02-16):
  # "API keys logged in debug mode without redaction."
  #
  # The fix installs `Arbor.Common.LogRedactor` as a Logger primary filter that
  # rewrites the log event's :msg, redacting secrets/PII via
  # `Arbor.Common.SensitiveData.redact/1`. These tests call the filter directly
  # (the public seam Logger invokes) and assert that an API-key-like value never
  # survives into the emitted message, while clean text passes through untouched.
  #
  # Red-proof: if `filter/2` is reverted to a passthrough (return the event
  # unchanged), the secret remains in the message and these assertions fail.
  describe "M7 security regression — filter/2 redacts secrets in log events" do
    test "redacts an API-key-like string in a {:string, _} message" do
      secret = "AKIA" <> "IOSFODNN7EXAMPLE"
      event = %{level: :info, meta: %{}, msg: {:string, "Authorization key: #{secret}"}}

      assert %{msg: {:string, redacted}} = LogRedactor.filter(event, [])

      refute String.contains?(redacted, secret)
      assert String.contains?(redacted, "[REDACTED]")
    end

    test "redacts a secret value in a {:report, map} message" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      event = %{level: :info, meta: %{}, msg: {:report, %{detail: "ANTHROPIC_API_KEY=#{secret}"}}}

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])

      refute String.contains?(report.detail, secret)
      assert String.contains?(report.detail, "[REDACTED]")
    end

    test "redacts secrets nested inside a {:report, map} message" do
      secret = "AKIA" <> "IOSFODNN7EXAMPLE"
      event = %{level: :info, meta: %{}, msg: {:report, %{outer: %{inner: "key #{secret} end"}}}}

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])

      refute String.contains?(report.outer.inner, secret)
      assert String.contains?(report.outer.inner, "[REDACTED]")
    end

    test "leaves a message with no secrets unchanged" do
      event = %{level: :info, meta: %{}, msg: {:string, "Nothing sensitive here"}}

      assert %{msg: {:string, "Nothing sensitive here"}} = LogRedactor.filter(event, [])
    end

    test "passes through events whose :msg is not a redactable form" do
      event = %{level: :info, meta: %{}, msg: {:iodata, ["a", "b"]}}

      # Non string/report message shapes must pass through intact
      assert ^event = LogRedactor.filter(event, [])
    end

    test "walks keyword-list reports without raising" do
      secret = "AKIA" <> "IOSFODNN7EXAMPLE"
      event = %{level: :info, meta: %{}, msg: {:report, [a: 1, detail: "key=#{secret}"]}}

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])
      assert is_list(report)
      detail = Keyword.get(report, :detail)
      refute String.contains?(detail, secret)
      assert String.contains?(detail, "[REDACTED]")
    end
  end

  describe "security regression — filter/2 is total over nested non-Enumerable structs" do
    test "nested opaque struct does not raise and adjacent secrets are still redacted" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      aws_key = "AKIA" <> "IOSFODNN7EXAMPLE"

      opaque = %OpaqueHandler{
        id: "handler-1",
        token: "bearer #{secret}",
        nested: %{note: "nested key #{aws_key}"}
      }

      # Representative crash-report shape: map + list + tuple nesting around
      # an opaque struct that does not implement Enumerable.
      report = %{
        label: "crash",
        reason: {:shutdown, opaque},
        crumbs: [
          "prefix #{secret}",
          %{sibling: "AKIA" <> "IOSFODNN7EXAMPLE-adjacent"},
          {"tuple", opaque}
        ],
        state: opaque
      }

      event = %{level: :error, meta: %{}, msg: {:report, report}}

      # Primary regression: filter must return normally. Prior bug called
      # Map.new/2 on the struct → Protocol.UndefinedError → Logger dropped
      # the filter and subsequent logs lost redaction.
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])

      refute_sensitive(redacted, secret)
      refute_sensitive(redacted, aws_key)
      assert_has_redacted_marker(redacted)

      # Struct shape preserved via map rebuild + restored __struct__ key
      # (never via struct/2 callbacks).
      assert %OpaqueHandler{} = redacted.state
      assert redacted.state.id == "handler-1"
      refute String.contains?(redacted.state.token, secret)
      refute String.contains?(redacted.state.nested.note, aws_key)
    end

    test "forged struct-tagged map never raises and redacts its secret fields" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      aws_key = "AKIA" <> "IOSFODNN7EXAMPLE"

      # Forged tag: atom that is not a real struct module. Calling struct/2
      # here would raise UndefinedFunctionError; the filter must not do that.
      forged = %{__struct__: :not_a_struct, token: "bearer #{secret}", note: "x"}

      report = %{
        forged: forged,
        adjacent: "key=#{aws_key}",
        nest: [forged, {:pair, forged}]
      }

      event = %{level: :error, meta: %{}, msg: {:report, report}}

      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])

      refute_sensitive(redacted, secret)
      refute_sensitive(redacted, aws_key)
      assert_has_redacted_marker(redacted)

      # Completely walked forged map restores __struct__ without callbacks.
      assert is_map(redacted.forged)
      assert redacted.forged.__struct__ == :not_a_struct
      refute Map.has_key?(redacted.forged, :__redacted__)
    end

    test "plain map nesting with lists and tuples still redacts binaries" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"

      report = %{
        path: [{"step", [%{cmd: "export KEY=#{secret}"}]}],
        ok: true
      }

      event = %{level: :info, meta: %{}, msg: {:report, report}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])

      refute_sensitive(redacted, secret)
      assert redacted.ok == true
    end

    test "exhaustion markers are plain maps without __struct__" do
      # Wide shallow tree: more than the global node budget. Unvisited branches
      # must become plain markers, never %{__struct__: mod, __redacted__: true}.
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"

      wide =
        for i <- 1..400, into: %{} do
          {:"k#{i}", "token=#{secret}-#{i}"}
        end

      event = %{level: :error, meta: %{}, msg: {:report, wide}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])

      refute_sensitive(redacted, secret)
      refute_struct_tagged_redaction_markers(redacted)
    end

    test "invalid UTF-8 in {:string, binary} never raises and fails closed" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      # Invalid leading bytes can make Regex/String redaction raise on some
      # paths; filter/2 must stay total and never emit the raw secret.
      invalid = <<0xFF, 0xFE, 0xC3>> <> secret
      event = %{level: :error, meta: %{}, msg: {:string, invalid}}

      assert %{msg: {:string, out}} = LogRedactor.filter(event, [])
      assert is_binary(out)
      refute_binary_contains(out, secret)
    end

    test "invalid UTF-8 nested report value never raises and fails closed" do
      secret = "AKIA" <> "IOSFODNN7EXAMPLE"
      invalid = <<0xFF, 0xFE>> <> "key=#{secret}"

      report = %{
        label: "crash",
        detail: invalid,
        nest: [invalid, %{inner: invalid}]
      }

      event = %{level: :error, meta: %{}, msg: {:report, report}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])
      refute_sensitive(redacted, secret)
    end

    test "binary map keys with secrets are redacted under the same walk" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      key = "ANTHROPIC_API_KEY=#{secret}"

      report = %{
        key => "present",
        "safe" => "ok",
        nested: %{("token=" <> secret) => true}
      }

      event = %{level: :info, meta: %{}, msg: {:report, report}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])

      refute_sensitive(redacted, secret)
      assert redacted["safe"] == "ok"
      # Original secret-bearing key must not survive as a map key.
      refute Map.has_key?(redacted, key)
    end
  end

  defp refute_sensitive(term, secret) when is_binary(secret) do
    case term do
      bin when is_binary(bin) ->
        refute_binary_contains(bin, secret)

      list when is_list(list) ->
        Enum.each(list, &refute_sensitive(&1, secret))

      tuple when is_tuple(tuple) ->
        tuple |> Tuple.to_list() |> Enum.each(&refute_sensitive(&1, secret))

      %{__struct__: _} = struct ->
        struct
        |> Map.delete(:__struct__)
        |> Enum.each(fn {k, v} ->
          refute_sensitive(k, secret)
          refute_sensitive(v, secret)
        end)

      map when is_map(map) ->
        Enum.each(map, fn {k, v} ->
          refute_sensitive(k, secret)
          refute_sensitive(v, secret)
        end)

      _other ->
        :ok
    end
  end

  defp refute_binary_contains(bin, secret) when is_binary(bin) and is_binary(secret) do
    refute :binary.match(bin, secret) != :nomatch,
           "secret leaked in binary: #{inspect(bin, limit: 80)}"
  end

  defp assert_has_redacted_marker(term) do
    assert contains_redacted?(term),
           "expected at least one [REDACTED] marker in #{inspect(term, limit: 40)}"
  end

  defp contains_redacted?(bin) when is_binary(bin), do: String.contains?(bin, "[REDACTED]")
  defp contains_redacted?(list) when is_list(list), do: Enum.any?(list, &contains_redacted?/1)

  defp contains_redacted?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_redacted?/1)
  end

  defp contains_redacted?(%{__struct__: _} = struct) do
    struct |> Map.delete(:__struct__) |> Map.values() |> Enum.any?(&contains_redacted?/1)
  end

  defp contains_redacted?(map) when is_map(map) do
    map |> Map.values() |> Enum.any?(&contains_redacted?/1)
  end

  defp contains_redacted?(_), do: false

  defp refute_struct_tagged_redaction_markers(term) do
    case term do
      %{__struct__: _, __redacted__: true} ->
        flunk("malformed struct-tagged redaction marker: #{inspect(term)}")

      %{__struct__: _} = struct ->
        struct
        |> Map.delete(:__struct__)
        |> Enum.each(fn {_k, v} -> refute_struct_tagged_redaction_markers(v) end)

      map when is_map(map) ->
        # Plain markers are allowed; struct-tagged ones are not.
        if map_size(map) == 1 and Map.get(map, :redacted) == true do
          :ok
        else
          Enum.each(map, fn {_k, v} -> refute_struct_tagged_redaction_markers(v) end)
        end

      list when is_list(list) ->
        Enum.each(list, &refute_struct_tagged_redaction_markers/1)

      tuple when is_tuple(tuple) ->
        tuple |> Tuple.to_list() |> Enum.each(&refute_struct_tagged_redaction_markers/1)

      _ ->
        :ok
    end
  end
end
