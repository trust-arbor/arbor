defmodule Arbor.Orchestrator.Handlers.OutputValidateHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.OutputValidateHandler

  @moduletag :output_validate_handler

  # --- Helpers ---

  defp make_node(attrs) do
    base = %{"type" => "output.validate"}
    %Node{id: "validate_1", attrs: Map.merge(base, attrs)}
  end

  defp graph do
    %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}
  end

  defp run(node, context_values) do
    context = Context.new(context_values)
    OutputValidateHandler.execute(node, context, graph(), [])
  end

  # ==============================
  # Idempotency
  # ==============================

  describe "idempotency" do
    test "returns :read_only" do
      assert OutputValidateHandler.idempotency() == :read_only
    end
  end

  # ==============================
  # No validation attrs (all optional)
  # ==============================

  describe "no validation attrs" do
    test "passes when no validation constraints are specified" do
      node = make_node(%{"source_key" => "input"})
      outcome = run(node, %{"input" => "any content at all"})

      assert %Outcome{status: :success} = outcome
      assert outcome.notes == "All validations passed"
      assert outcome.context_updates["validate.validate_1.passed"] == true
      assert outcome.context_updates["validate.validate_1.errors"] == []
    end
  end

  # ==============================
  # Missing source_key
  # ==============================

  describe "missing source_key in context" do
    test "fails when source_key is not present in context" do
      node = make_node(%{"source_key" => "missing_key"})
      outcome = run(node, %{})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "source key 'missing_key' not found in context"
    end

    test "uses default source_key 'last_response' when not specified" do
      node = make_node(%{})
      outcome = run(node, %{"last_response" => "hello"})

      assert %Outcome{status: :success} = outcome
    end
  end

  # ==============================
  # JSON format validation
  # ==============================

  describe "JSON format validation" do
    test "valid JSON passes" do
      node = make_node(%{"source_key" => "input", "format" => "json"})
      outcome = run(node, %{"input" => ~s({"name": "test", "value": 42})})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
      assert outcome.context_updates["validate.validate_1.format"] == "json"
    end

    test "invalid JSON fails" do
      node = make_node(%{"source_key" => "input", "format" => "json"})
      outcome = run(node, %{"input" => "not json {{"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "content is not valid JSON"
      assert outcome.context_updates["validate.validate_1.passed"] == false
    end
  end

  # ==============================
  # Elixir format validation
  # ==============================

  describe "Elixir format validation" do
    test "valid Elixir passes" do
      node = make_node(%{"source_key" => "input", "format" => "elixir"})
      outcome = run(node, %{"input" => "defmodule Foo do\n  def bar, do: :ok\nend"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end

    test "invalid Elixir fails" do
      node = make_node(%{"source_key" => "input", "format" => "elixir"})
      outcome = run(node, %{"input" => "defmodule Foo do\n  def bar do\n"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "content is not valid Elixir"
    end
  end

  # ==============================
  # DOT format validation
  # ==============================

  describe "DOT format validation" do
    test "content containing 'digraph' passes" do
      node = make_node(%{"source_key" => "input", "format" => "dot"})
      outcome = run(node, %{"input" => "digraph G {\n  a -> b;\n}"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end

    test "content without 'digraph' fails" do
      node = make_node(%{"source_key" => "input", "format" => "dot"})
      outcome = run(node, %{"input" => "graph G { a -- b; }"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "missing 'digraph'"
    end
  end

  # ==============================
  # Length validation
  # ==============================

  describe "length validation" do
    test "max_length exceeded fails" do
      node = make_node(%{"source_key" => "input", "max_length" => "5"})
      outcome = run(node, %{"input" => "too long content"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "exceeds maximum"
    end

    test "min_length not met fails" do
      node = make_node(%{"source_key" => "input", "min_length" => "100"})
      outcome = run(node, %{"input" => "short"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "below minimum"
    end

    test "length within bounds passes" do
      node = make_node(%{"source_key" => "input", "min_length" => "3", "max_length" => "20"})
      outcome = run(node, %{"input" => "just right"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end
  end

  # ==============================
  # must_contain validation
  # ==============================

  describe "must_contain validation" do
    test "all required substrings present passes" do
      node = make_node(%{"source_key" => "input", "must_contain" => "foo, bar"})
      outcome = run(node, %{"input" => "this has foo and bar in it"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end

    test "missing required substring fails" do
      node = make_node(%{"source_key" => "input", "must_contain" => "foo, baz"})
      outcome = run(node, %{"input" => "this has foo but not the other"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "missing required content: 'baz'"
    end
  end

  # ==============================
  # must_not_contain validation
  # ==============================

  describe "must_not_contain validation" do
    test "prohibited content present fails" do
      node = make_node(%{"source_key" => "input", "must_not_contain" => "secret, password"})
      outcome = run(node, %{"input" => "the secret is here"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "contains prohibited content: 'secret'"
    end

    test "no prohibited content passes" do
      node = make_node(%{"source_key" => "input", "must_not_contain" => "secret, password"})
      outcome = run(node, %{"input" => "safe public content"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end
  end

  # ==============================
  # Regex pattern validation
  # ==============================

  describe "regex pattern validation" do
    test "matching pattern passes" do
      node = make_node(%{"source_key" => "input", "pattern" => "^def \\w+"})
      outcome = run(node, %{"input" => "def hello_world do\n  :ok\nend"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end

    test "non-matching pattern fails" do
      node = make_node(%{"source_key" => "input", "pattern" => "^def \\w+"})
      outcome = run(node, %{"input" => "not a function definition"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "does not match pattern"
    end

    test "invalid regex pattern fails gracefully" do
      node = make_node(%{"source_key" => "input", "pattern" => "["})
      outcome = run(node, %{"input" => "anything"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "invalid regex pattern"
    end
  end

  # ==============================
  # action='warn'
  # ==============================

  describe "action='warn'" do
    test "returns success with errors in notes" do
      node =
        make_node(%{
          "source_key" => "input",
          "format" => "json",
          "action" => "warn"
        })

      outcome = run(node, %{"input" => "not json"})

      assert %Outcome{status: :success} = outcome
      assert outcome.notes =~ "Validation warnings"
      assert outcome.notes =~ "content is not valid JSON"
      assert outcome.context_updates["validate.validate_1.passed"] == false
    end
  end

  # ==============================
  # action='truncate'
  # ==============================

  describe "action='truncate'" do
    test "truncates content exceeding max_length" do
      node =
        make_node(%{
          "source_key" => "input",
          "max_length" => "5",
          "action" => "truncate"
        })

      outcome = run(node, %{"input" => "hello world"})

      assert %Outcome{status: :success} = outcome
      assert outcome.notes =~ "Content truncated"
      assert outcome.context_updates["input"] == "hello"
    end

    test "content within max_length is not truncated" do
      node =
        make_node(%{
          "source_key" => "input",
          "max_length" => "100",
          "must_contain" => "missing_thing",
          "action" => "truncate"
        })

      outcome = run(node, %{"input" => "short"})

      assert %Outcome{status: :success} = outcome
      assert outcome.notes =~ "truncate mode"
      refute Map.has_key?(outcome.context_updates, "input")
    end
  end

  # ==============================
  # JSON schema validation
  # ==============================

  describe "JSON schema validation" do
    test "valid object with required fields passes" do
      schema = Jason.encode!(%{"type" => "object", "required" => ["name", "age"]})

      node =
        make_node(%{
          "source_key" => "input",
          "json_schema" => schema
        })

      outcome = run(node, %{"input" => ~s({"name": "Alice", "age": 30})})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
    end

    test "missing required field fails" do
      schema = Jason.encode!(%{"type" => "object", "required" => ["name", "age"]})

      node =
        make_node(%{
          "source_key" => "input",
          "json_schema" => schema
        })

      outcome = run(node, %{"input" => ~s({"name": "Alice"})})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "missing required field 'age'"
    end

    test "wrong type fails" do
      schema = Jason.encode!(%{"type" => "array"})

      node =
        make_node(%{
          "source_key" => "input",
          "json_schema" => schema
        })

      outcome = run(node, %{"input" => ~s({"key": "value"})})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "expected type 'array'"
    end

    test "invalid schema JSON fails gracefully" do
      node =
        make_node(%{
          "source_key" => "input",
          "json_schema" => "not valid json"
        })

      outcome = run(node, %{"input" => ~s({"key": "value"})})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "invalid json_schema attribute"
    end

    test "non-JSON content with schema fails" do
      schema = Jason.encode!(%{"type" => "object"})

      node =
        make_node(%{
          "source_key" => "input",
          "json_schema" => schema
        })

      outcome = run(node, %{"input" => "plain text"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "content is not valid JSON"
    end
  end

  # ==============================
  # Combined validations
  # ==============================

  describe "combined validations" do
    test "multiple passing constraints all succeed" do
      node =
        make_node(%{
          "source_key" => "input",
          "format" => "json",
          "min_length" => "5",
          "max_length" => "100",
          "must_contain" => "name",
          "must_not_contain" => "password"
        })

      outcome = run(node, %{"input" => ~s({"name": "test"})})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.passed"] == true
      assert outcome.context_updates["validate.validate_1.errors"] == []
    end

    test "multiple failing constraints reports all errors" do
      node =
        make_node(%{
          "source_key" => "input",
          "format" => "json",
          "must_contain" => "required_thing",
          "must_not_contain" => "bad"
        })

      outcome = run(node, %{"input" => "bad content"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "content is not valid JSON"
      assert outcome.failure_reason =~ "missing required content"
      assert outcome.failure_reason =~ "contains prohibited content"

      errors = outcome.context_updates["validate.validate_1.errors"]
      assert length(errors) == 3
    end
  end

  # ==============================
  # Format edge cases
  # ==============================

  describe "format edge cases" do
    test "markdown format always passes" do
      node = make_node(%{"source_key" => "input", "format" => "markdown"})
      outcome = run(node, %{"input" => "# heading\n\nsome text"})

      assert %Outcome{status: :success} = outcome
    end

    test "text format always passes" do
      node = make_node(%{"source_key" => "input", "format" => "text"})
      outcome = run(node, %{"input" => "literally anything"})

      assert %Outcome{status: :success} = outcome
    end

    test "unknown format fails with descriptive error" do
      node = make_node(%{"source_key" => "input", "format" => "yaml"})
      outcome = run(node, %{"input" => "key: value"})

      assert %Outcome{status: :fail} = outcome
      assert outcome.failure_reason =~ "unknown format 'yaml'"
    end

    test "no format attribute skips format validation" do
      node = make_node(%{"source_key" => "input"})
      outcome = run(node, %{"input" => "{{invalid json but no format check}}"})

      assert %Outcome{status: :success} = outcome
      assert outcome.context_updates["validate.validate_1.format"] == "none"
    end
  end
end
