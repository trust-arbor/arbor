defmodule Arbor.AI.AgentSDK.ToolTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Tool

  # Define a test tools module
  defmodule TestTools do
    use Arbor.AI.AgentSDK.Tool

    deftool :greet, "Greet a user by name" do
      param(:name, :string, required: true, description: "Name to greet")
      param(:title, :string, description: "Optional title")

      def execute(%{name: name} = args) do
        title = Map.get(args, :title)

        if title do
          {:ok, "Hello, #{title} #{name}!"}
        else
          {:ok, "Hello, #{name}!"}
        end
      end
    end

    deftool :add, "Add two numbers" do
      param(:a, :number, required: true, description: "First number")
      param(:b, :number, required: true, description: "Second number")

      def execute(%{a: a, b: b}) do
        {:ok, "#{a + b}"}
      end
    end

    deftool :fail_tool, "Always fails" do
      def execute(_args) do
        {:error, "intentional failure"}
      end
    end

    deftool :bare_result, "Returns a bare value" do
      def execute(_args) do
        42
      end
    end
  end

  describe "tool definition with deftool macro" do
    test "lists all defined tools" do
      tools = TestTools.__tools__()
      assert length(tools) == 4
      names = Enum.map(tools, & &1.name)
      assert "greet" in names
      assert "add" in names
      assert "fail_tool" in names
      assert "bare_result" in names
    end

    test "tool schema has correct structure" do
      schema = TestTools.__tool_schema__("greet")
      assert schema.name == "greet"
      assert schema.description == "Greet a user by name"
      assert is_atom(schema.function)
      assert length(schema.params) == 2
    end

    test "tool params have correct metadata" do
      schema = TestTools.__tool_schema__("greet")
      name_param = Enum.find(schema.params, &(&1.name == :name))
      assert name_param.type == :string
      assert name_param.required == true
      assert name_param.description == "Name to greet"

      title_param = Enum.find(schema.params, &(&1.name == :title))
      assert title_param.type == :string
      assert title_param.required == false
      assert title_param.description == "Optional title"
    end

    test "tool schema lookup with atom name" do
      schema = TestTools.__tool_schema__(:greet)
      assert schema.name == "greet"
    end

    test "unknown tool schema returns nil" do
      assert TestTools.__tool_schema__("nonexistent") == nil
    end
  end

  describe "tool execution via __call_tool__" do
    test "calls tool with matching args" do
      assert {:ok, "Hello, World!"} = TestTools.__call_tool__("greet", %{name: "World"})
    end

    test "calls tool with optional args" do
      assert {:ok, "Hello, Dr. Smith!"} =
               TestTools.__call_tool__("greet", %{name: "Smith", title: "Dr."})
    end

    test "calls tool with atom name" do
      assert {:ok, "Hello, World!"} = TestTools.__call_tool__(:greet, %{name: "World"})
    end

    test "returns error for unknown tool" do
      assert {:error, {:unknown_tool, "unknown"}} = TestTools.__call_tool__("unknown", %{})
    end

    test "error results pass through" do
      assert {:error, "intentional failure"} = TestTools.__call_tool__("fail_tool", %{})
    end

    test "bare values are normalized" do
      assert {:ok, "42"} = TestTools.__call_tool__("bare_result", %{})
    end
  end

  describe "to_json_schema/1" do
    test "converts tool to JSON schema format" do
      schema = TestTools.__tool_schema__("greet")
      json = Tool.to_json_schema(schema)

      assert json["name"] == "greet"
      assert json["description"] == "Greet a user by name"
      assert json["input_schema"]["type"] == "object"
      assert json["input_schema"]["properties"]["name"]["type"] == "string"
      assert json["input_schema"]["required"] == ["name"]
    end

    test "includes description for params" do
      schema = TestTools.__tool_schema__("greet")
      json = Tool.to_json_schema(schema)

      assert json["input_schema"]["properties"]["name"]["description"] == "Name to greet"
    end

    test "tool with no required params omits required field" do
      schema = TestTools.__tool_schema__("bare_result")
      json = Tool.to_json_schema(schema)

      refute Map.has_key?(json["input_schema"], "required")
    end

    test "tool with multiple required params" do
      schema = TestTools.__tool_schema__("add")
      json = Tool.to_json_schema(schema)

      assert "a" in json["input_schema"]["required"]
      assert "b" in json["input_schema"]["required"]
    end
  end

  describe "normalize_result/1" do
    test "ok with string passes through" do
      assert {:ok, "hello"} = Tool.normalize_result({:ok, "hello"})
    end

    test "ok with non-string inspects" do
      assert {:ok, "42"} = Tool.normalize_result({:ok, 42})
    end

    test "error with string passes through" do
      assert {:error, "bad"} = Tool.normalize_result({:error, "bad"})
    end

    test "error with non-string inspects" do
      assert {:error, ":oops"} = Tool.normalize_result({:error, :oops})
    end

    test "bare string becomes ok" do
      assert {:ok, "hello"} = Tool.normalize_result("hello")
    end

    test "bare value becomes ok with inspect" do
      assert {:ok, "42"} = Tool.normalize_result(42)
    end
  end
end
