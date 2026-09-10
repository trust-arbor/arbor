defmodule Arbor.Memory.Cores.PrivateRelationshipCore do
  @moduledoc false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.TaintEnvelope

  @namespace "private_relationships"
  @scope_keys ~w(agent_id human_id engagement_id session_id turn_id)
  @body_keys ~w(version snapshot_revision scope current_focus last_source_id last_operation source_proof owner_stamp)
  @max_bytes 16_384

  def namespace, do: @namespace
  def key(scope), do: digest([scope.agent_id, scope.human_id])

  @declare "Remember my current focus: "
  @correct "Correction: my current focus is: "
  @max_value_bytes 512

  def parse(@declare <> value), do: directive(:declare, value)
  def parse(@correct <> value), do: directive(:correct, value)
  def parse(_), do: :ignored

  def decide(nil, %{operation: :declare, value: value}), do: {:write, value}
  def decide(nil, %{operation: :correct}), do: {:error, :private_relationship_missing}
  def decide(value, %{value: value}), do: :unchanged

  def decide(_value, %{operation: :declare}),
    do: {:error, :private_relationship_correction_required}

  def decide(_value, %{operation: :correct, value: value}), do: {:write, value}

  def source_text("declare", value), do: @declare <> value
  def source_text("correct", value), do: @correct <> value

  def value?(value) when is_binary(value) do
    byte_size(value) in 1..@max_value_bytes and String.valid?(value) and
      String.trim(value) == value and
      not Regex.match?(~r/[\x00-\x1F\x7F\x{0085}\x{2028}\x{2029}]/u, value)
  end

  def value?(_), do: false

  def projection(nil), do: %{}

  def projection(%{"current_focus" => focus, "last_operation" => operation}) do
    %{
      "current_focus" => focus,
      "source_kind" => if(operation == "correct", do: "user_corrected", else: "user_declared")
    }
  end

  def body(scope, source, directive, revision) do
    %{
      "version" => 1,
      "snapshot_revision" => revision,
      "scope" => Map.new(@scope_keys, &{&1, Map.fetch!(scope, scope_atom(&1))}),
      "current_focus" => directive.value,
      "last_operation" => Atom.to_string(directive.operation),
      "last_source_id" => source["descriptor"]["source_id"],
      "source_proof" => Map.take(source, ["descriptor", "stamp"])
    }
  end

  def admit_body(body) when is_map(body) and not is_struct(body) do
    with true <- Enum.sort(Map.keys(body)) == Enum.sort(@body_keys),
         true <- body["version"] === 1,
         true <- is_integer(body["snapshot_revision"]) and body["snapshot_revision"] > 0,
         true <- valid_scope?(body["scope"]),
         true <- value?(body["current_focus"]),
         true <- body["last_operation"] in ["declare", "correct"],
         true <- is_map(body["owner_stamp"]),
         proof when is_map(proof) <- body["source_proof"],
         true <- Enum.sort(Map.keys(proof)) == ~w(descriptor stamp),
         descriptor when is_map(descriptor) <- proof["descriptor"],
         true <- is_map(proof["stamp"]),
         true <- Map.take(descriptor, @scope_keys) === body["scope"],
         true <- descriptor["source_id"] === body["last_source_id"],
         text <- source_text(body["last_operation"], body["current_focus"]),
         true <- text_digest(text) === descriptor["user_content_digest"],
         :ok <- bounded(body) do
      :ok
    else
      _ -> {:error, :invalid_private_relationship_snapshot}
    end
  end

  def admit_body(_), do: {:error, :invalid_private_relationship_snapshot}

  def descriptor(body, key) do
    with :ok <- bounded(body), {:ok, digest} <- digest(Map.delete(body, "owner_stamp")) do
      {:ok,
       Map.merge(body["scope"], %{
         "namespace" => @namespace,
         "key" => key,
         "id" => "memory:" <> @namespace <> ":" <> key,
         "body_digest" => digest,
         "snapshot_revision" => body["snapshot_revision"]
       })}
    end
  end

  def record_descriptor(%Record{data: body, key: physical, id: id} = record) do
    with :ok <- admit_body(body),
         scope <- body["scope"],
         {:ok, key} <- digest([scope["agent_id"], scope["human_id"]]),
         true <- physical == @namespace <> ":" <> key,
         true <- id == "memory:" <> physical,
         true <- is_integer(record.generation) and record.generation > 0,
         true <- is_integer(record.revision) and record.revision > 0 do
      descriptor(body, key)
    else
      _ -> {:error, :invalid_private_relationship_snapshot}
    end
  end

  def record_descriptor(_), do: {:error, :invalid_private_relationship_snapshot}

  def same_pair?(body, scope) do
    body["scope"]["agent_id"] == scope.agent_id and
      body["scope"]["human_id"] == scope.human_id
  end

  def next_revision(:not_found), do: 1
  def next_revision(%Record{} = record), do: record.data["snapshot_revision"] + 1

  def bounded(body) do
    case TaintEnvelope.canonical_json(body) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> :ok
      _ -> {:error, :private_relationship_snapshot_too_large}
    end
  end

  defp valid_scope?(scope) when is_map(scope) do
    Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys) and
      Enum.all?(scope, fn {_key, value} -> label?(value) end)
  end

  defp valid_scope?(_), do: false

  defp label?(value) when is_binary(value),
    do: byte_size(value) in 1..256 and String.valid?(value) and String.trim(value) == value

  defp label?(_), do: false
  defp text_digest(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp digest(value) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(value),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp scope_atom("agent_id"), do: :agent_id
  defp scope_atom("human_id"), do: :human_id
  defp scope_atom("engagement_id"), do: :engagement_id
  defp scope_atom("session_id"), do: :session_id
  defp scope_atom("turn_id"), do: :turn_id

  defp directive(operation, value) do
    if value?(value),
      do: {:ok, %{operation: operation, value: value}},
      else: {:error, :invalid_relationship_directive}
  end
end
