defmodule Arbor.Actions.Schemas.ActionSchemasTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Schemas

  @moduletag :fast

  describe "File schemas" do
    test "read_params validates required path" do
      schema = Schemas.File.read_params()

      assert {:error, _} = Schemas.File.validate(schema, %{})
      assert {:ok, validated} = Schemas.File.validate(schema, %{"path" => "/tmp/file.txt"})
      assert validated["path"] == "/tmp/file.txt"
    end

    test "read_params validates encoding enum" do
      schema = Schemas.File.read_params()

      for encoding <- ["utf8", "latin1", "binary"] do
        assert {:ok, validated} =
                 Schemas.File.validate(schema, %{"path" => "/tmp/f", "encoding" => encoding})

        assert validated["encoding"] == encoding
      end

      assert {:error, _} =
               Schemas.File.validate(schema, %{"path" => "/tmp/f", "encoding" => "invalid"})
    end

    test "write_params validates required fields" do
      schema = Schemas.File.write_params()

      assert {:error, _} = Schemas.File.validate(schema, %{})
      assert {:error, _} = Schemas.File.validate(schema, %{"path" => "/tmp/f"})

      assert {:ok, validated} =
               Schemas.File.validate(schema, %{"path" => "/tmp/f", "content" => "hello"})

      assert validated["path"] == "/tmp/f"
      assert validated["content"] == "hello"
    end

    test "search_params validates bounds" do
      schema = Schemas.File.search_params()

      # Pattern too long
      long_pattern = String.duplicate("x", 600)

      assert {:error, _} =
               Schemas.File.validate(schema, %{"pattern" => long_pattern, "path" => "/tmp"})

      # max_results bounds
      assert {:error, _} =
               Schemas.File.validate(schema, %{
                 "pattern" => "test",
                 "path" => "/tmp",
                 "max_results" => 2000
               })

      assert {:ok, _} =
               Schemas.File.validate(schema, %{
                 "pattern" => "test",
                 "path" => "/tmp",
                 "max_results" => 500
               })
    end
  end

  describe "Shell schemas" do
    test "execute_params validates required command" do
      schema = Schemas.Shell.execute_params()

      assert {:error, _} = Schemas.Shell.validate(schema, %{})
      assert {:ok, validated} = Schemas.Shell.validate(schema, %{"command" => "echo hello"})
      assert validated["command"] == "echo hello"
    end

    test "execute_params validates timeout bounds" do
      schema = Schemas.Shell.execute_params()

      # Below min
      assert {:error, _} =
               Schemas.Shell.validate(schema, %{"command" => "echo", "timeout" => 100})

      # Above max
      assert {:error, _} =
               Schemas.Shell.validate(schema, %{"command" => "echo", "timeout" => 500_000})

      # Valid
      assert {:ok, _} =
               Schemas.Shell.validate(schema, %{"command" => "echo", "timeout" => 60_000})
    end

    test "execute_params validates sandbox enum" do
      schema = Schemas.Shell.execute_params()

      for sandbox <- ["none", "basic", "strict"] do
        assert {:ok, validated} =
                 Schemas.Shell.validate(schema, %{"command" => "echo", "sandbox" => sandbox})

        assert validated["sandbox"] == sandbox
      end

      assert {:error, _} =
               Schemas.Shell.validate(schema, %{"command" => "echo", "sandbox" => "invalid"})
    end
  end

  describe "AI schemas" do
    test "generate_text_params validates required prompt" do
      schema = Schemas.AI.generate_text_params()

      assert {:error, _} = Schemas.AI.validate(schema, %{})
      assert {:ok, validated} = Schemas.AI.validate(schema, %{"prompt" => "Hello"})
      assert validated["prompt"] == "Hello"
    end

    test "generate_text_params validates temperature bounds" do
      schema = Schemas.AI.generate_text_params()

      # Below min
      assert {:error, _} =
               Schemas.AI.validate(schema, %{"prompt" => "test", "temperature" => -0.5})

      # Above max
      assert {:error, _} =
               Schemas.AI.validate(schema, %{"prompt" => "test", "temperature" => 3.0})

      # Valid
      assert {:ok, _} =
               Schemas.AI.validate(schema, %{"prompt" => "test", "temperature" => 0.8})
    end

    test "generate_text_params validates provider enum" do
      schema = Schemas.AI.generate_text_params()

      assert {:ok, _} =
               Schemas.AI.validate(schema, %{"prompt" => "test", "provider" => "anthropic"})

      assert {:error, _} =
               Schemas.AI.validate(schema, %{"prompt" => "test", "provider" => "unknown"})
    end
  end

  describe "Jobs schemas" do
    test "create_params validates required title" do
      schema = Schemas.Jobs.create_params()

      assert {:error, _} = Schemas.Jobs.validate(schema, %{})
      assert {:ok, validated} = Schemas.Jobs.validate(schema, %{"title" => "My Task"})
      assert validated["title"] == "My Task"
    end

    test "create_params validates priority enum" do
      schema = Schemas.Jobs.create_params()

      for priority <- ["low", "normal", "high", "critical"] do
        assert {:ok, validated} =
                 Schemas.Jobs.validate(schema, %{"title" => "test", "priority" => priority})

        assert validated["priority"] == priority
      end

      assert {:error, _} =
               Schemas.Jobs.validate(schema, %{"title" => "test", "priority" => "urgent"})
    end

    test "update_params validates status transitions" do
      schema = Schemas.Jobs.update_params()

      for status <- ["active", "completed", "failed", "cancelled"] do
        assert {:ok, _} =
                 Schemas.Jobs.validate(schema, %{"job_id" => "job_123", "status" => status})
      end

      # 'created' is not a valid target status for updates
      assert {:error, _} =
               Schemas.Jobs.validate(schema, %{"job_id" => "job_123", "status" => "created"})
    end
  end

  describe "Historian schemas" do
    test "query_events_params accepts all optional fields" do
      schema = Schemas.Historian.query_events_params()

      # All optional, so empty is valid
      assert {:ok, _} = Schemas.Historian.validate(schema, %{})

      assert {:ok, validated} =
               Schemas.Historian.validate(schema, %{
                 "category" => "agent",
                 "limit" => 50
               })

      assert validated["category"] == "agent"
      assert validated["limit"] == 50
    end

    test "causality_tree_params requires event_id" do
      schema = Schemas.Historian.causality_tree_params()

      assert {:error, _} = Schemas.Historian.validate(schema, %{})
      assert {:ok, _} = Schemas.Historian.validate(schema, %{"event_id" => "evt_123"})
    end

    test "taint_trace_params validates query_type enum" do
      schema = Schemas.Historian.taint_trace_params()

      for query_type <- ["trace_backward", "trace_forward", "events", "summary"] do
        assert {:ok, validated} =
                 Schemas.Historian.validate(schema, %{"query_type" => query_type})

        assert validated["query_type"] == query_type
      end

      assert {:error, _} =
               Schemas.Historian.validate(schema, %{"query_type" => "unknown"})
    end
  end
end
