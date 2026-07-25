defmodule Arbor.Actions.Coding.DesignCheckpoint do
  @moduledoc """
  Shared validation and binding helpers for the durable CodingPlan v2 design
  checkpoint actions.

  The public action modules below are pipeline-internal syscalls. The request
  id is derived from the exact, normalized evidence and is never accepted as
  authority supplied by a caller.
  """

  alias Arbor.Contracts.Coding.WorkPacket

  @max_identifier_bytes 256
  @max_design_bytes 16_384
  @max_description_bytes 16_384
  @max_metadata_bytes 32_768
  @default_timeout 60_000
  @max_timeout 3_600_000
  @request_prefix "irq_design_"
  @evidence_keys ~w(
    task_id
    workspace_id
    worker_session_id
    provider_session_id
    design_attempt
    packet_digest
    design
    design_digest
  )

  @doc false
  def max_design_bytes, do: @max_design_bytes

  @doc false
  def build_binding(params, context) when is_map(params) and is_map(context) do
    with {:ok, work_packet_input} <- required(params, context, :work_packet, :work_packet),
         {:ok, packet} <- normalize_work_packet(work_packet_input),
         :ok <- require_design_policy(packet),
         {:ok, supplied_packet_digest} <- packet_digest_input(params, context),
         {:ok, packet_digest} <- validate_packet_digest(packet, supplied_packet_digest),
         {:ok, task_id} <- required_identifier(params, context, :task_id),
         {:ok, workspace_id} <- required_identifier(params, context, :workspace_id),
         {:ok, worker_session_id} <- required_worker_session(params, context),
         {:ok, provider_session_id} <- optional_identifier(params, context, :provider_session_id),
         {:ok, design_attempt} <- required_attempt(params, context),
         {:ok, design} <- required_design(params, context),
         {:ok, design_digest} <- required_design_digest(params, context, design) do
      base_evidence = %{
        "task_id" => task_id,
        "workspace_id" => workspace_id,
        "worker_session_id" => worker_session_id,
        "provider_session_id" => provider_session_id,
        "design_attempt" => design_attempt,
        "packet_digest" => packet_digest,
        "design" => design,
        "design_digest" => design_digest
      }

      with {:ok, request_id} <- request_id(base_evidence),
           {:ok, description} <- description(packet, task_id, design),
           {:ok, metadata} <- metadata(base_evidence, packet) do
        {:ok,
         %{
           agent_id: context_agent_id(params, context),
           packet: packet,
           base_evidence: base_evidence,
           evidence: Map.put(base_evidence, "request_id", request_id),
           request_id: request_id,
           description: description,
           metadata: metadata
         }}
      end
    end
  end

  def build_binding(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  @doc false
  def request_id(evidence) when is_map(evidence) do
    with {:ok, canonical} <- canonical_evidence(evidence) do
      digest = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
      {:ok, @request_prefix <> digest}
    end
  end

  @doc false
  def request_id(_evidence), do: {:error, :invalid_design_checkpoint_evidence}

  @doc false
  def canonical_evidence(evidence) when is_map(evidence) do
    if Enum.all?(@evidence_keys, &Map.has_key?(evidence, &1)) do
      ordered =
        @evidence_keys
        |> Enum.map(&{&1, Map.fetch!(evidence, &1)})
        |> Jason.OrderedObject.new()

      case Jason.encode(ordered) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, _reason} -> {:error, :design_checkpoint_evidence_not_json}
      end
    else
      {:error, :design_checkpoint_evidence_incomplete}
    end
  end

  @doc false
  def canonical_evidence(_evidence), do: {:error, :design_checkpoint_evidence_not_map}

  @doc false
  def normalize_response(response, metadata, request_id, evidence)
      when is_binary(request_id) and is_map(evidence) do
    with :ok <- validate_authority_evidence(metadata, request_id, evidence) do
      case Arbor.Contracts.Comms.ApprovalAnswer.normalize(response, metadata) do
        {:ok, :approve} -> {:ok, "approve", ""}
        {:ok, :rework, note} -> {:ok, "rework", note}
        {:ok, :deny, note} -> {:ok, "deny", note}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def normalize_response(_response, _metadata, _request_id, _evidence),
    do: {:error, :invalid_design_checkpoint_response}

  @doc false
  def timeout(context, params) do
    value = value(params, context, :timeout) || value(context, %{}, :approval_timeout_ms)

    case value || @default_timeout do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout ->
        {:ok, timeout}

      _ ->
        {:error, :invalid_design_checkpoint_timeout}
    end
  end

  @doc false
  def comms_boundary(context) when is_map(context) do
    case Map.get(context, :comms_boundary) || Map.get(context, "comms_boundary") do
      nil -> {:ok, Arbor.Comms}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_design_checkpoint_comms_boundary}
    end
  end

  @doc false
  def comms_boundary(_context), do: {:error, :invalid_design_checkpoint_comms_boundary}

  @doc false
  def call(module, function, args) when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  rescue
    UndefinedFunctionError -> {:error, {:design_checkpoint_comms_unavailable, function}}
    _ -> {:error, {:design_checkpoint_comms_failed, function}}
  catch
    :exit, _ -> {:error, {:design_checkpoint_comms_unavailable, function}}
  end

  @doc false
  def call(_module, _function, _args), do: {:error, :invalid_design_checkpoint_comms_boundary}

  @doc false
  def durable_ready?(module) do
    case call(module, :durable_ready?, []) do
      true -> :ok
      false -> {:error, :durable_interaction_unavailable}
      {:error, _reason} -> {:error, :durable_interaction_unavailable}
      _ -> {:error, :durable_interaction_unavailable}
    end
  end

  @doc false
  def validate_operator(value) when is_binary(value), do: validate_identifier(value, :operator_id)
  def validate_operator(_value), do: {:error, :design_checkpoint_operator_invalid}

  @doc false
  def string_value(value) when is_binary(value), do: value

  def string_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def string_value(_value), do: nil

  defp normalize_work_packet(value) do
    case WorkPacket.normalize(value) do
      {:ok, packet} -> {:ok, packet}
      {:error, reason} -> {:error, {:invalid_work_packet, reason}}
    end
  end

  defp require_design_policy(%{"checkpoint_policy" => "design_required"}), do: :ok
  defp require_design_policy(_packet), do: {:error, :design_checkpoint_policy_required}

  defp validate_packet_digest(packet, supplied) do
    with {:ok, expected} <- WorkPacket.digest(packet),
         true <- is_binary(supplied) and supplied === expected do
      {:ok, expected}
    else
      false -> {:error, :work_packet_digest_mismatch}
      {:error, reason} -> {:error, {:work_packet_digest_unavailable, reason}}
    end
  end

  defp required(params, context, key, context_key) do
    case value(params, context, key) || value(context, %{}, context_key) do
      nil -> {:error, {:design_checkpoint_field_required, Atom.to_string(key)}}
      value -> {:ok, value}
    end
  end

  defp packet_digest_input(params, context) do
    case value(params, context, :packet_digest) || value(params, context, :work_packet_digest) ||
           value(context, %{}, :coding_plan_work_packet_digest) do
      nil -> {:error, {:design_checkpoint_field_required, "packet_digest"}}
      digest -> {:ok, digest}
    end
  end

  defp required_identifier(params, context, key) do
    case string_value(value(params, context, key)) do
      value when is_binary(value) -> validate_identifier(value, key)
      _ -> {:error, {:design_checkpoint_identifier_required, Atom.to_string(key)}}
    end
  end

  defp required_worker_session(params, context) do
    value =
      value(params, context, :worker_session_id) ||
        value(params, context, :worker_acp_handle) ||
        value(params, context, :worker_session)

    case string_value(value) do
      value when is_binary(value) -> validate_identifier(value, :worker_session_id)
      _ -> {:error, :design_checkpoint_worker_session_required}
    end
  end

  defp optional_identifier(params, context, key) do
    case value(params, context, key) || value(params, context, :worker_provider_session_id) do
      nil ->
        {:ok, nil}

      value ->
        case string_value(value) do
          value when is_binary(value) -> validate_identifier(value, key)
          _ -> {:error, {:design_checkpoint_identifier_invalid, Atom.to_string(key)}}
        end
    end
  end

  defp validate_identifier(value, key) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes and
         String.valid?(value) and value == String.trim(value) and
         not String.contains?(value, <<0>>) and not has_ascii_control?(value) do
      {:ok, value}
    else
      {:error, {:design_checkpoint_identifier_invalid, Atom.to_string(key)}}
    end
  end

  defp validate_identifier(_value, key),
    do: {:error, {:design_checkpoint_identifier_invalid, Atom.to_string(key)}}

  defp required_attempt(params, context) do
    case value(params, context, :design_attempt) do
      value when is_integer(value) and value > 0 and value <= 1_000_000 -> {:ok, value}
      _ -> {:error, :design_checkpoint_attempt_invalid}
    end
  end

  defp required_design(params, context) do
    case value(params, context, :design) do
      value
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_design_bytes ->
        cond do
          not String.valid?(value) ->
            {:error, :design_checkpoint_design_invalid_utf8}

          String.trim(value) == "" ->
            {:error, :design_checkpoint_design_blank}

          String.contains?(value, <<0>>) or has_disallowed_design_control?(value) ->
            {:error, :design_checkpoint_design_control_character}

          true ->
            {:ok, value}
        end

      value when is_binary(value) and byte_size(value) > @max_design_bytes ->
        {:error, :design_checkpoint_design_too_large}

      _ ->
        {:error, :design_checkpoint_design_required}
    end
  end

  defp required_design_digest(params, context, design) do
    supplied = value(params, context, :design_digest)
    expected = "sha256:" <> (:crypto.hash(:sha256, design) |> Base.encode16(case: :lower))

    if is_binary(supplied) and supplied === expected,
      do: {:ok, expected},
      else: {:error, :design_digest_mismatch}
  end

  defp description(packet, task_id, design) do
    with {:ok, packet_bytes} <- WorkPacket.canonical_bytes(packet),
         description =
           "Design checkpoint for task #{task_id}.\n\nCanonical work-packet intent:\n" <>
             packet_bytes <> "\n\nWorker design:\n" <> design,
         true <- String.valid?(description) and byte_size(description) <= @max_description_bytes do
      {:ok, description}
    else
      false -> {:error, :design_checkpoint_description_too_large}
      {:error, _reason} -> {:error, :design_checkpoint_description_unavailable}
    end
  end

  defp metadata(base_evidence, packet) do
    metadata = Map.put(base_evidence, "work_packet", packet)

    case Jason.encode(metadata) do
      {:ok, encoded} when byte_size(encoded) <= @max_metadata_bytes -> {:ok, metadata}
      {:ok, _encoded} -> {:error, :design_checkpoint_metadata_too_large}
      {:error, _reason} -> {:error, :design_checkpoint_metadata_not_json}
    end
  end

  defp validate_authority_evidence(metadata, request_id, evidence) when is_map(metadata) do
    with :ok <- optional_equal(metadata, :request_id, request_id),
         :ok <- optional_equal(metadata, :task_id, evidence["task_id"]),
         :ok <- optional_equal(metadata, :workspace_id, evidence["workspace_id"]),
         :ok <- optional_equal(metadata, :worker_session_id, evidence["worker_session_id"]),
         :ok <- optional_equal(metadata, :provider_session_id, evidence["provider_session_id"]),
         :ok <- optional_equal(metadata, :design_attempt, evidence["design_attempt"]),
         :ok <- optional_equal(metadata, :packet_digest, evidence["packet_digest"]),
         :ok <- optional_equal(metadata, :design_digest, evidence["design_digest"]),
         :ok <- optional_nested_evidence(metadata, request_id, evidence) do
      :ok
    end
  end

  defp validate_authority_evidence(_metadata, _request_id, _evidence),
    do: {:error, :malformed_design_checkpoint_authority_evidence}

  defp optional_equal(metadata, key, expected) do
    case fetch_optional(metadata, key) do
      :missing -> :ok
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, {:design_checkpoint_authority_mismatch, Atom.to_string(key)}}
    end
  end

  defp optional_nested_evidence(metadata, request_id, evidence) do
    nested =
      case fetch_optional(metadata, :evidence) do
        :missing -> fetch_optional(metadata, :authority_evidence)
        found -> found
      end

    case nested do
      :missing ->
        :ok

      {:ok, value} when is_map(value) ->
        expected = Map.put(evidence, "request_id", request_id)
        if value == expected, do: :ok, else: {:error, :design_checkpoint_authority_mismatch}

      {:ok, _value} ->
        {:error, :malformed_design_checkpoint_authority_evidence}
    end
  end

  defp fetch_optional(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :missing
    end
  end

  defp context_agent_id(params, context) do
    direct = value(params, context, :agent_id) || value(params, context, :principal_id)

    authority =
      case Map.get(context, :auth_context) || Map.get(context, "auth_context") do
        auth when is_map(auth) ->
          Map.get(auth, :agent_id) || Map.get(auth, "agent_id") ||
            Map.get(auth, :principal_id) || Map.get(auth, "principal_id")

        _ ->
          nil
      end

    case string_value(direct || authority) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp value(primary, secondary, key) do
    Map.get(primary, key) || Map.get(primary, Atom.to_string(key)) || Map.get(secondary, key) ||
      Map.get(secondary, Atom.to_string(key))
  end

  defp has_ascii_control?(value), do: has_ascii_control?(value, false)
  defp has_ascii_control?(<<>>, seen), do: seen

  defp has_ascii_control?(<<byte, _rest::binary>>, _seen) when byte <= 0x1F or byte == 0x7F,
    do: true

  defp has_ascii_control?(<<_byte, rest::binary>>, seen), do: has_ascii_control?(rest, seen)

  defp has_disallowed_design_control?(value), do: has_disallowed_design_control?(value, false)
  defp has_disallowed_design_control?(<<>>, seen), do: seen

  defp has_disallowed_design_control?(<<byte, _rest::binary>>, _seen)
       when byte in [0x00, 0x0B, 0x0C, 0x7F],
       do: true

  defp has_disallowed_design_control?(<<_byte, rest::binary>>, seen),
    do: has_disallowed_design_control?(rest, seen)
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Open do
  @moduledoc """
  Open a durable, operator-facing design approval for a CodingPlan v2 task.

  This pipeline-internal action is the one external-peer edge in the design
  checkpoint. It uses `:external_peer` classification so the human approval
  request does not recursively ask for provider approval.
  """

  use Jido.Action,
    name: "coding_design_checkpoint_open",
    description: "Open a durable operator approval for the exact coding design",
    category: "coding",
    tags: ["coding", "design_checkpoint", "approval", "pipeline_internal"],
    schema: [
      work_packet: [type: :map, required: true, doc: "Canonical CodingPlan v2 work packet"],
      packet_digest: [type: :string, required: false, doc: "Exact sha256: work-packet digest"],
      work_packet_digest: [type: :string, required: false, doc: "Alias for packet_digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      workspace_id: [type: :string, required: true, doc: "Leased workspace identity"],
      worker_session_id: [type: :string, required: true, doc: "Managed ACP worker handle"],
      provider_session_id: [type: :string, required: false, doc: "Provider session id alias"],
      worker_provider_session_id: [type: :string, required: false, doc: "Provider session id"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"],
      design: [type: :string, required: true, doc: "Exact worker design text"],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      agent_id: [type: :string, required: false, doc: "Owning agent identity"]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Contracts.Comms.Interaction

  def taint_roles do
    %{
      work_packet: :data,
      packet_digest: :control,
      work_packet_digest: :control,
      task_id: :control,
      workspace_id: :control,
      worker_session_id: :control,
      provider_session_id: :control,
      worker_provider_session_id: :control,
      design_attempt: :control,
      design: :data,
      design_digest: :control,
      agent_id: :control
    }
  end

  def effect_class, do: :network_egress
  def egress_tier(_params, _context), do: :external_peer

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, binding} <- DesignCheckpoint.build_binding(params, context),
         {:ok, agent_id} <- required_agent_id(binding),
         {:ok, comms} <- DesignCheckpoint.comms_boundary(context),
         :ok <- DesignCheckpoint.durable_ready?(comms),
         {:ok, operator_id} <- operator_id(comms, agent_id),
         {:ok, interaction} <- interaction(binding, agent_id, operator_id),
         {:ok, returned_id} <-
           DesignCheckpoint.call(comms, :request_interaction, [
             interaction,
             [durability: :node_restart]
           ]),
         :ok <- same_request_id(returned_id, binding.request_id) do
      {:ok,
       %{
         "checkpoint_outcome" => "pending",
         "request_id" => binding.request_id,
         "evidence" => binding.evidence
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  defp required_agent_id(%{agent_id: agent_id}) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp required_agent_id(_binding), do: {:error, :design_checkpoint_agent_id_required}

  defp operator_id(comms, agent_id) do
    case DesignCheckpoint.call(comms, :operator_for_agent, [agent_id]) do
      operator when is_binary(operator) ->
        DesignCheckpoint.validate_operator(operator)

      {:error, _reason} ->
        {:error, :design_checkpoint_operator_unavailable}

      _ ->
        {:error, :design_checkpoint_operator_invalid}
    end
  end

  defp interaction(binding, agent_id, operator_id) do
    attrs = %{
      request_id: binding.request_id,
      kind: :approval,
      agent_id: agent_id,
      user_id: operator_id,
      description: binding.description,
      metadata: binding.metadata,
      resource_uri: "arbor://action/coding/design_checkpoint"
    }

    case Interaction.new(attrs) do
      {:ok, interaction} -> {:ok, interaction}
      {:error, reason} -> {:error, {:design_checkpoint_interaction_invalid, reason}}
    end
  end

  defp same_request_id(returned_id, expected) when returned_id === expected, do: :ok

  defp same_request_id(_returned_id, _expected),
    do: {:error, :design_checkpoint_request_id_mismatch}
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Await do
  @moduledoc """
  Await the durable CodingPlan v2 design approval and return a structured
  approve, rework, deny, or timeout branch.

  This pipeline-internal action is a local write/wait. It reconstructs all
  evidence and recomputes the request id before consulting the public comms
  facade, so a caller-provided id cannot select another approval.
  """

  use Jido.Action,
    name: "coding_design_checkpoint_await",
    description: "Await the exact durable coding design approval",
    category: "coding",
    tags: ["coding", "design_checkpoint", "approval", "pipeline_internal"],
    schema: [
      request_id: [type: :string, required: true, doc: "Expected deterministic approval id"],
      work_packet: [type: :map, required: true, doc: "Canonical CodingPlan v2 work packet"],
      packet_digest: [type: :string, required: false, doc: "Exact sha256: work-packet digest"],
      work_packet_digest: [type: :string, required: false, doc: "Alias for packet_digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      workspace_id: [type: :string, required: true, doc: "Leased workspace identity"],
      worker_session_id: [type: :string, required: true, doc: "Managed ACP worker handle"],
      provider_session_id: [type: :string, required: false, doc: "Provider session id alias"],
      worker_provider_session_id: [type: :string, required: false, doc: "Provider session id"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"],
      design: [type: :string, required: true, doc: "Exact worker design text"],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      agent_id: [type: :string, required: false, doc: "Owning agent identity"],
      timeout: [type: :integer, required: false, doc: "Wait timeout in milliseconds"]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Contracts.Comms.ApprovalAnswer

  def taint_roles do
    %{
      request_id: :control,
      work_packet: :data,
      packet_digest: :control,
      work_packet_digest: :control,
      task_id: :control,
      workspace_id: :control,
      worker_session_id: :control,
      provider_session_id: :control,
      worker_provider_session_id: :control,
      design_attempt: :control,
      design: :data,
      design_digest: :control,
      agent_id: :control,
      timeout: :data
    }
  end

  def effect_class, do: :local_write

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, binding} <- DesignCheckpoint.build_binding(params, context),
         {:ok, supplied_id} <- supplied_request_id(params, context),
         {:ok, _validated_id} <- ApprovalAnswer.validate_request_id(supplied_id),
         :ok <- same_request_id(supplied_id, binding.request_id),
         {:ok, agent_id} <- required_agent_id(binding),
         {:ok, timeout} <- DesignCheckpoint.timeout(context, params),
         {:ok, comms} <- DesignCheckpoint.comms_boundary(context),
         result <-
           DesignCheckpoint.call(comms, :await_interaction_response, [
             binding.request_id,
             agent_id,
             [timeout: timeout]
           ]) do
      settle(result, binding)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  defp supplied_request_id(params, context) do
    case Map.get(params, :request_id) || Map.get(params, "request_id") ||
           Map.get(context, :request_id) || Map.get(context, "request_id") do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :design_checkpoint_request_id_required}
    end
  end

  defp required_agent_id(%{agent_id: agent_id}) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp required_agent_id(_binding), do: {:error, :design_checkpoint_agent_id_required}

  defp same_request_id(id, id), do: :ok
  defp same_request_id(_supplied, _expected), do: {:error, :design_checkpoint_request_id_mismatch}

  defp settle({:ok, response, metadata}, binding) do
    case DesignCheckpoint.normalize_response(
           response,
           metadata,
           binding.request_id,
           binding.evidence
         ) do
      {:ok, outcome, note} -> {:ok, payload(outcome, note, binding)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle({:error, :timeout}, binding), do: {:ok, payload("timeout", "", binding)}
  defp settle({:error, reason}, _binding), do: {:error, reason}
  defp settle(_other, _binding), do: {:error, :malformed_design_checkpoint_await_response}

  defp payload(outcome, note, binding) do
    %{
      "checkpoint_outcome" => outcome,
      "request_id" => binding.request_id,
      "note" => note,
      "evidence" => binding.evidence
    }
  end
end
