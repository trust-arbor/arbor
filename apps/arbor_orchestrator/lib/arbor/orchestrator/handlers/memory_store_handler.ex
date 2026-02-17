defmodule Arbor.Orchestrator.Handlers.MemoryStoreHandler do
  @moduledoc """
  Handler for memory.store nodes that persist facts to a JSONL-based
  memory store for cross-run pipeline learning.

  This enables pipelines to accumulate knowledge across executions — the pipeline
  equivalent of institutional memory.

  Node attributes:
    - `memory_store` - path to JSONL memory file (REQUIRED)
    - `content_key` - context key containing the fact to store (default: last_response)
    - `tags` - comma-separated tags for categorization (e.g., "architecture,decision")
    - `source` - free-text source attribution (default: node ID)
    - `ttl_days` - days until memory expires (default: none/permanent)
    - `metadata_keys` - comma-separated context keys to include as metadata

  Each stored memory is a JSON object:
    {
      "id": unique UUID,
      "fact": the content string,
      "tags": ["tag1", "tag2"],
      "source": "node_id or custom",
      "pipeline_run": run identifier from context,
      "timestamp": ISO8601,
      "expires_at": ISO8601 or null,
      "metadata": {} extra context data
    }

  Context updates written:
    - last_stage: node ID
    - memory.{node_id}.stored: true
    - memory.{node_id}.memory_id: the UUID of the stored memory
    - memory.{node_id}.store_path: path to the memory store file
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  import Arbor.Orchestrator.Handlers.Helpers, only: [parse_csv: 1]

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def idempotency, do: :side_effecting

  @impl true
  def execute(node, context, _graph, opts) do
    store_path = Map.get(node.attrs, "memory_store")
    content_key = Map.get(node.attrs, "content_key", "last_response")
    tags_str = Map.get(node.attrs, "tags", "")
    source = Map.get(node.attrs, "source", node.id)
    ttl_days = parse_int_or_nil(Map.get(node.attrs, "ttl_days"))
    metadata_keys_str = Map.get(node.attrs, "metadata_keys", "")

    if is_nil(store_path) or store_path == "" do
      %Outcome{status: :fail, failure_reason: "memory.store requires memory_store attribute"}
    else
      # Get the content to store
      content = Context.get(context, content_key)
      content = if is_nil(content), do: "", else: to_string(content)

      # Parse tags
      tags = parse_csv(tags_str)

      # Build metadata from specified context keys
      metadata_keys = parse_csv(metadata_keys_str)

      metadata =
        Enum.reduce(metadata_keys, %{}, fn key, acc ->
          val = Context.get(context, key)
          if val, do: Map.put(acc, key, val), else: acc
        end)

      # Compute expiry
      expires_at =
        if ttl_days do
          DateTime.utc_now()
          |> DateTime.add(ttl_days * 86_400, :second)
          |> DateTime.to_iso8601()
        else
          nil
        end

      # Build memory entry
      memory_id = generate_uuid()

      entry = %{
        "id" => memory_id,
        "fact" => content,
        "tags" => tags,
        "source" => source,
        "pipeline_run" => Context.get(context, "pipeline_run_id") || "unknown",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "expires_at" => expires_at,
        "metadata" => metadata
      }

      # Write to JSONL
      File.mkdir_p!(Path.dirname(store_path))
      line = Jason.encode!(entry) <> "\n"
      File.write!(store_path, line, [:append])

      # Write to stage dir
      case Keyword.get(opts, :logs_root) do
        nil ->
          :ok

        root ->
          stage_dir = Path.join(root, node.id)
          File.mkdir_p!(stage_dir)

          File.write!(
            Path.join(stage_dir, "stored_memory.json"),
            Jason.encode!(entry, pretty: true)
          )
      end

      %Outcome{
        status: :success,
        context_updates: %{
          "last_stage" => node.id,
          "memory.#{node.id}.stored" => true,
          "memory.#{node.id}.memory_id" => memory_id,
          "memory.#{node.id}.store_path" => store_path
        },
        notes: "Stored memory #{memory_id} with tags: #{Enum.join(tags, ", ")}"
      }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "MemoryStore handler error: #{Exception.message(e)}"
      }
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      Base.encode16(<<a::32>>, case: :lower),
      Base.encode16(<<b::16>>, case: :lower),
      Base.encode16(<<c::16>>, case: :lower),
      Base.encode16(<<d::16>>, case: :lower),
      Base.encode16(<<e::48>>, case: :lower)
    ]
    |> Enum.join("-")
  end

  defp parse_int_or_nil(nil), do: nil
  defp parse_int_or_nil(""), do: nil

  defp parse_int_or_nil(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int_or_nil(val) when is_integer(val), do: val
end
