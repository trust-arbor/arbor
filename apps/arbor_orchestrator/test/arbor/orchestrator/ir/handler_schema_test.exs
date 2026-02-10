defmodule Arbor.Orchestrator.IR.HandlerSchemaTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.IR.HandlerSchema

  describe "for_type/1" do
    test "returns schema for known types" do
      for type <- HandlerSchema.known_types() do
        schema = HandlerSchema.for_type(type)
        assert %HandlerSchema{} = schema
        assert schema.handler_type == type
      end
    end

    test "returns default schema for unknown type" do
      schema = HandlerSchema.for_type("custom.unknown")
      assert %HandlerSchema{} = schema
      assert schema.handler_type == "custom.unknown"
      assert schema.required_attrs == []
      assert schema.capabilities == []
    end

    test "covers all 12 handler types" do
      types = HandlerSchema.known_types()
      assert length(types) == 12

      assert "start" in types
      assert "exit" in types
      assert "conditional" in types
      assert "tool" in types
      assert "wait.human" in types
      assert "parallel" in types
      assert "parallel.fan_in" in types
      assert "stack.manager_loop" in types
      assert "codergen" in types
      assert "file.write" in types
      assert "pipeline.validate" in types
      assert "pipeline.run" in types
    end
  end

  describe "validate_attrs/2" do
    test "returns errors for missing required attrs" do
      errors = HandlerSchema.validate_attrs("tool", %{})
      assert [{:error, msg}] = errors
      assert msg =~ "tool_command"
    end

    test "returns no errors when required attrs present" do
      errors = HandlerSchema.validate_attrs("tool", %{"tool_command" => "echo test"})
      assert errors == []
    end

    test "returns type warnings for wrong types" do
      errors =
        HandlerSchema.validate_attrs("tool", %{"tool_command" => "ok", "max_retries" => "not_int"})

      assert [{:warning, msg}] = errors
      assert msg =~ "max_retries"
      assert msg =~ "integer"
    end

    test "codergen requires prompt" do
      errors = HandlerSchema.validate_attrs("codergen", %{})
      assert [{:error, msg}] = errors
      assert msg =~ "prompt"
    end

    test "file.write requires content_key and output" do
      errors = HandlerSchema.validate_attrs("file.write", %{})
      assert length(errors) == 2
      messages = Enum.map(errors, fn {:error, msg} -> msg end)
      assert Enum.any?(messages, &(&1 =~ "content_key"))
      assert Enum.any?(messages, &(&1 =~ "output"))
    end

    test "start handler has no required attrs" do
      errors = HandlerSchema.validate_attrs("start", %{})
      assert errors == []
    end

    test "unknown type has no required attrs" do
      errors = HandlerSchema.validate_attrs("custom.thing", %{"anything" => "goes"})
      assert errors == []
    end
  end

  describe "schema properties" do
    test "tool handler requires shell_exec capability" do
      schema = HandlerSchema.for_type("tool")
      assert "shell_exec" in schema.capabilities
    end

    test "codergen handler requires llm_query capability" do
      schema = HandlerSchema.for_type("codergen")
      assert "llm_query" in schema.capabilities
    end

    test "file.write handler requires file_write capability" do
      schema = HandlerSchema.for_type("file.write")
      assert "file_write" in schema.capabilities
    end

    test "start handler requires no capabilities" do
      schema = HandlerSchema.for_type("start")
      assert schema.capabilities == []
    end

    test "tool handler has internal default classification" do
      schema = HandlerSchema.for_type("tool")
      assert schema.default_classification == :internal
    end

    test "start handler has public default classification" do
      schema = HandlerSchema.for_type("start")
      assert schema.default_classification == :public
    end
  end
end
