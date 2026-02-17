defmodule Arbor.Contracts.ErrorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Error

  # ============================================================================
  # new/1
  # ============================================================================

  describe "new/1" do
    test "creates error with required fields" do
      assert {:ok, %Error{code: :not_found, message: "gone"}} =
               Error.new(code: :not_found, message: "gone")
    end

    test "accepts keyword list" do
      assert {:ok, %Error{code: :timeout}} = Error.new(code: :timeout, message: "timed out")
    end

    test "accepts map with atom keys" do
      assert {:ok, %Error{code: :fail}} = Error.new(%{code: :fail, message: "failed"})
    end

    test "accepts map with string keys" do
      assert {:ok, %Error{code: :fail}} = Error.new(%{"code" => :fail, "message" => "failed"})
    end

    test "sets defaults for optional fields" do
      {:ok, err} = Error.new(code: :test, message: "test")
      assert err.detail == %{}
      assert err.redacted == false
      assert err.metadata == %{}
      assert err.source == nil
      assert err.trace_id == nil
      assert %DateTime{} = err.timestamp
    end

    test "accepts all optional fields" do
      ts = DateTime.utc_now()

      {:ok, err} =
        Error.new(
          code: :test,
          message: "test",
          source: :engine,
          detail: %{key: "val"},
          redacted: true,
          timestamp: ts,
          trace_id: "trace_123",
          metadata: %{extra: true}
        )

      assert err.source == :engine
      assert err.detail == %{key: "val"}
      assert err.redacted == true
      assert err.timestamp == ts
      assert err.trace_id == "trace_123"
      assert err.metadata == %{extra: true}
    end

    test "rejects missing code" do
      assert {:error, {:missing_required, :code}} = Error.new(message: "oops")
    end

    test "rejects missing message" do
      assert {:error, {:missing_required, :message}} = Error.new(code: :test)
    end

    test "rejects non-atom code" do
      assert {:error, {:invalid_code, "string"}} = Error.new(code: "string", message: "oops")
    end

    test "rejects non-string message" do
      assert {:error, {:invalid_message, 123}} = Error.new(code: :test, message: 123)
    end

    test "rejects empty string message" do
      assert {:error, {:invalid_message, ""}} = Error.new(code: :test, message: "")
    end

    test "rejects non-atom source" do
      assert {:error, {:invalid_source, "str"}} =
               Error.new(code: :test, message: "m", source: "str")
    end

    test "rejects non-map detail" do
      assert {:error, {:invalid_detail, "str"}} =
               Error.new(code: :test, message: "m", detail: "str")
    end

    test "rejects non-boolean redacted" do
      assert {:error, {:invalid_redacted, 1}} =
               Error.new(code: :test, message: "m", redacted: 1)
    end

    test "rejects non-string trace_id" do
      assert {:error, {:invalid_trace_id, 123}} =
               Error.new(code: :test, message: "m", trace_id: 123)
    end

    test "rejects non-map metadata" do
      assert {:error, {:invalid_metadata, []}} =
               Error.new(code: :test, message: "m", metadata: [])
    end
  end

  # ============================================================================
  # redact/1
  # ============================================================================

  describe "redact/1" do
    test "clears detail and metadata" do
      {:ok, err} =
        Error.new(
          code: :auth,
          message: "bad",
          detail: %{token: "secret"},
          metadata: %{ip: "1.2.3.4"}
        )

      redacted = Error.redact(err)
      assert redacted.detail == %{}
      assert redacted.metadata == %{}
      assert redacted.redacted == true
    end

    test "preserves code, message, source, trace_id" do
      {:ok, err} =
        Error.new(code: :auth, message: "bad", source: :gateway, trace_id: "t1")

      redacted = Error.redact(err)
      assert redacted.code == :auth
      assert redacted.message == "bad"
      assert redacted.source == :gateway
      assert redacted.trace_id == "t1"
    end

    test "is idempotent" do
      {:ok, err} = Error.new(code: :x, message: "x", detail: %{a: 1})
      r1 = Error.redact(err)
      r2 = Error.redact(r1)
      assert r1 == r2
    end
  end

  # ============================================================================
  # wrap/2 — the primary coverage gap
  # ============================================================================

  describe "wrap/2" do
    test "wraps an atom into error struct" do
      err = Error.wrap(:timeout)
      assert %Error{} = err
      assert err.code == :timeout
      assert err.message == "timeout"
    end

    test "wraps atom with options" do
      err = Error.wrap(:timeout, source: :engine, trace_id: "t1")
      assert err.source == :engine
      assert err.trace_id == "t1"
    end

    test "wraps a binary string" do
      err = Error.wrap("something went wrong")
      assert err.code == :wrapped_error
      assert err.message == "something went wrong"
    end

    test "wraps a binary string with options" do
      err = Error.wrap("oops", source: :parser, metadata: %{line: 5})
      assert err.source == :parser
      assert err.metadata == %{line: 5}
    end

    test "wraps a RuntimeError exception" do
      err = Error.wrap(%RuntimeError{message: "boom"})
      assert err.code == :runtime_error
      assert err.message == "boom"
      assert err.detail == %{}
    end

    test "wraps an ArgumentError exception" do
      err = Error.wrap(%ArgumentError{message: "bad arg"})
      assert err.code == :argument_error
      assert err.message == "bad arg"
    end

    test "wraps exception with opts" do
      err = Error.wrap(%RuntimeError{message: "boom"}, source: :lib)
      assert err.source == :lib
    end

    test "wraps exception and captures extra fields in detail" do
      err = Error.wrap(%KeyError{key: :foo, term: %{}})
      # KeyError has key and term fields beyond message
      assert is_map(err.detail)
      assert Map.has_key?(err.detail, :key)
    end

    test "wraps {atom, binary} tuple" do
      err = Error.wrap({:invalid_input, "bad data"})
      assert err.code == :invalid_input
      assert err.message == "bad data"
    end

    test "wraps {atom, binary} tuple with opts" do
      err = Error.wrap({:invalid_input, "bad"}, source: :session)
      assert err.source == :session
    end

    test "wraps {atom, non-binary} tuple" do
      err = Error.wrap({:processing_error, {:nested, :reason}})
      assert err.code == :processing_error
      assert err.message == "processing_error"
      assert err.detail == %{reason: {:nested, :reason}}
    end

    test "wraps arbitrary term with inspect" do
      err = Error.wrap(12345)
      assert err.code == :wrapped_error
      assert err.message == "12345"
    end

    test "wraps a list" do
      err = Error.wrap([:a, :b])
      assert err.code == :wrapped_error
      assert err.message == "[:a, :b]"
    end

    test "wraps a map" do
      err = Error.wrap(%{reason: "unknown"})
      assert err.code == :wrapped_error
      assert String.contains?(err.message, "reason")
    end

    test "wraps nil as atom" do
      # nil is an atom in Elixir, so it hits the is_atom clause
      err = Error.wrap(nil)
      assert err.code == nil
      assert err.message == "nil"
    end

    test "passes through existing Error struct unchanged" do
      {:ok, original} = Error.new(code: :test, message: "test", source: :orig)
      wrapped = Error.wrap(original)
      assert wrapped.code == :test
      assert wrapped.message == "test"
      assert wrapped.source == :orig
    end

    test "merges opts into existing Error struct" do
      {:ok, original} = Error.new(code: :test, message: "test")
      wrapped = Error.wrap(original, source: :new_source, trace_id: "t2")
      assert wrapped.source == :new_source
      assert wrapped.trace_id == "t2"
    end

    test "merges metadata into existing Error struct" do
      {:ok, original} = Error.new(code: :test, message: "test", metadata: %{a: 1})
      wrapped = Error.wrap(original, metadata: %{b: 2})
      assert wrapped.metadata == %{a: 1, b: 2}
    end

    test "does not overwrite existing Error fields with nil opts" do
      {:ok, original} = Error.new(code: :test, message: "test", source: :keep)
      wrapped = Error.wrap(original)
      assert wrapped.source == :keep
    end

    test "all wrapped errors have a timestamp" do
      err = Error.wrap(:anything)
      assert %DateTime{} = err.timestamp
    end

    test "all wrapped errors default redacted to false" do
      err = Error.wrap(:anything)
      assert err.redacted == false
    end

    test "wraps exception and extracts code from module name" do
      # RuntimeError -> :runtime_error is a well-known conversion
      err = Error.wrap(%RuntimeError{message: "test"})
      assert err.code == :runtime_error

      # KeyError -> :key_error
      err = Error.wrap(%KeyError{key: :missing, term: %{}})
      assert err.code == :key_error
    end
  end

  # ============================================================================
  # Jason.Encoder
  # ============================================================================

  describe "Jason.Encoder" do
    test "encodes error to JSON" do
      {:ok, err} = Error.new(code: :test, message: "test")
      assert {:ok, json} = Jason.encode(err)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["code"] == "test"
      assert decoded["message"] == "test"
    end
  end
end
