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

    test "multi-cons improper list tails with secrets are walked or fail closed" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      secret_bin = "API_KEY=#{secret}"
      secret_bin2 = "token=#{secret}"

      # Owner regression: at least two heads plus a non-list tail that itself
      # carries secret-bearing binaries. Shape [safe, "secret..." | tail] is
      # [safe | ["secret..." | tail]] — spine must peel cons-by-cons; never
      # pass the multi-cell improper remainder to walk/3 as opaque `other`.
      two_heads_secret_tail = [:safe, secret_bin | {secret_bin2, :end}]
      multi_cons = [:ok | [:more | secret_bin]]
      shallow_improper = [:head | secret_bin]
      nested_improper = [1 | [2 | [3 | secret_bin]]]
      sugar_improper = [1, 2 | secret_bin]

      report = %{
        two_heads: two_heads_secret_tail,
        multi: multi_cons,
        shallow: shallow_improper,
        nested: nested_improper,
        sugar: sugar_improper,
        adjacent: "prefix #{secret}"
      }

      event = %{level: :error, meta: %{}, msg: {:report, report}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])

      refute_sensitive(redacted, secret)
      assert_has_redacted_marker(redacted)

      # Explicit shape check on the two-head improper form.
      assert is_list(redacted.two_heads)
      refute_sensitive(redacted.two_heads, secret)
    end

    test "large tuple does not leak a secret past the node budget" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      # Far beyond the 256-node budget. elem/2 walk must fail closed without
      # materialising every element, and must not emit the secret suffix.
      n = 5_000
      huge = List.to_tuple(Enum.to_list(1..n) ++ ["token=#{secret}"])

      event = %{level: :error, meta: %{}, msg: {:report, %{t: huge}}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])
      refute_sensitive(redacted, secret)

      # Bounded output: mid-tuple budget exhaustion replaces the whole tuple
      # with a plain marker rather than a 5000-element redacted copy.
      assert redacted.t == %{redacted: true} or is_tuple(redacted.t)

      if is_tuple(redacted.t) do
        assert tuple_size(redacted.t) <= 256
      end
    end

    test "large map does not leak a secret past the node budget" do
      secret = "AKIA" <> "IOSFODNN7EXAMPLE"
      n = 5_000

      # Iterator walk scales with the node budget, not container size. Secret
      # only in late keys/values; raw secret must never appear, and walked
      # pair count must stay within the global budget.
      wide =
        1..n
        |> Enum.reduce(%{}, fn i, acc ->
          Map.put(acc, :"k#{i}", i)
        end)
        |> Map.put(:secret_tail, "key=#{secret}")
        |> Map.put("API_KEY=#{secret}", :present)

      event = %{level: :error, meta: %{}, msg: {:report, wide}}
      assert %{msg: {:report, redacted}} = LogRedactor.filter(event, [])
      refute_sensitive(redacted, secret)
      refute_struct_tagged_redaction_markers(redacted)

      # Output map is far smaller than the attacker-controlled input.
      assert map_size(redacted) < n
      assert map_size(redacted) <= 256
    end
  end

  defp refute_sensitive(term, secret) when is_binary(secret) do
    case term do
      bin when is_binary(bin) ->
        refute_binary_contains(bin, secret)

      list when is_list(list) ->
        # Cons-walk so improper tails are checked without Enum.each.
        refute_sensitive_list(list, secret)

      tuple when is_tuple(tuple) ->
        for i <- 0..(tuple_size(tuple) - 1) do
          refute_sensitive(elem(tuple, i), secret)
        end

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

  defp refute_sensitive_list([], _secret), do: :ok

  defp refute_sensitive_list([head | tail], secret) do
    refute_sensitive(head, secret)

    if is_list(tail) do
      refute_sensitive_list(tail, secret)
    else
      refute_sensitive(tail, secret)
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

  defp contains_redacted?(list) when is_list(list), do: contains_redacted_list?(list)

  defp contains_redacted?(tuple) when is_tuple(tuple) do
    Enum.any?(0..(tuple_size(tuple) - 1), fn i -> contains_redacted?(elem(tuple, i)) end)
  end

  defp contains_redacted?(%{__struct__: _} = struct) do
    struct |> Map.delete(:__struct__) |> Map.values() |> Enum.any?(&contains_redacted?/1)
  end

  defp contains_redacted?(map) when is_map(map) do
    map |> Map.values() |> Enum.any?(&contains_redacted?/1)
  end

  defp contains_redacted?(_), do: false

  defp contains_redacted_list?([]), do: false

  defp contains_redacted_list?([head | tail]) do
    contains_redacted?(head) or
      if(is_list(tail), do: contains_redacted_list?(tail), else: contains_redacted?(tail))
  end

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
        refute_struct_tagged_list(list)

      tuple when is_tuple(tuple) ->
        for i <- 0..(tuple_size(tuple) - 1) do
          refute_struct_tagged_redaction_markers(elem(tuple, i))
        end

      _ ->
        :ok
    end
  end

  defp refute_struct_tagged_list([]), do: :ok

  defp refute_struct_tagged_list([head | tail]) do
    refute_struct_tagged_redaction_markers(head)

    if is_list(tail) do
      refute_struct_tagged_list(tail)
    else
      refute_struct_tagged_redaction_markers(tail)
    end
  end
end
