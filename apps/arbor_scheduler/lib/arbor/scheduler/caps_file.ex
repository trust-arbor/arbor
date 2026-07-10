defmodule Arbor.Scheduler.CapsFile do
  @moduledoc """
  Loads and verifies signed scheduler pipeline attestations.

  Version 2 binds every security-relevant execution input in one Ed25519
  signature: issuer, declared capabilities, logical pipeline root and relative
  path, exact DOT SHA-256, canonical workdir, and exact JSON-clean initial
  arguments. A valid capability declaration is therefore not reusable for a
  different graph or invocation.

  Version 1 manifests are deliberately rejected as `{:legacy_version, 1}`.
  They bound only capability declarations and cannot be reinterpreted safely.
  Re-sign them with `arbor.scheduler.sign_caps`, the matching issuer private
  key, an explicit workdir, and explicit JSON arguments.

  Resource handlers remain responsible for authorizing their canonical
  filesystem, shell, and action resources. This attestation limits what the
  scheduler may mint; it does not turn pipeline authorship into resource
  authority.
  """

  alias Arbor.Contracts.Security.{Capability, CapabilityUri}
  alias Arbor.Security.Crypto
  alias Arbor.Security.IssuerRegistry

  @current_version 2
  @signing_domain "arbor.scheduler.caps.v2"
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @root_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  defmodule Attestation do
    @moduledoc "A scheduler execution attestation returned only after verification."

    @enforce_keys [
      :version,
      :issuer_id,
      :pipeline_root,
      :pipeline_path,
      :graph_hash,
      :workdir,
      :initial_args,
      :capabilities,
      :signature
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            version: 2,
            issuer_id: String.t(),
            pipeline_root: String.t(),
            pipeline_path: Path.t(),
            graph_hash: String.t(),
            workdir: Path.t(),
            initial_args: map(),
            capabilities: [Arbor.Scheduler.CapsFile.cap_descriptor()],
            signature: binary()
          }
  end

  @type cap_descriptor :: %{
          required(:resource_uri) => String.t(),
          required(:constraints) => map(),
          optional(:issuer_id) => String.t()
        }

  @type unsigned_payload :: %{
          required(:version) => 2,
          required(:issuer_id) => String.t(),
          required(:pipeline_root) => String.t(),
          required(:pipeline_path) => Path.t(),
          required(:graph_hash) => String.t(),
          required(:workdir) => Path.t(),
          required(:initial_args) => map(),
          required(:capabilities) => [cap_descriptor()]
        }

  @doc "Load and cryptographically verify a version 2 scheduler attestation."
  @spec load(Path.t()) :: {:ok, Attestation.t()} | {:error, term()}
  def load(path) do
    with {:ok, content} <- read_file(path),
         {:ok, raw} <- parse_json(content),
         {:ok, parsed} <- validate_schema(raw),
         :ok <- verify_parsed_attestation(parsed) do
      {:ok, to_attestation(parsed)}
    end
  end

  @doc "Reverify an in-memory attestation before it can mint run authority."
  @spec verify_attestation(Attestation.t()) :: :ok | {:error, term()}
  def verify_attestation(%Attestation{} = attestation) do
    unsigned =
      attestation
      |> Map.from_struct()
      |> Map.delete(:signature)

    with {:ok, payload} <- validate_payload(unsigned) do
      payload
      |> Map.put(:signature, attestation.signature)
      |> verify_parsed_attestation()
    end
  end

  def verify_attestation(_), do: {:error, :verified_attestation_required}

  @doc """
  Build a validated unsigned version 2 payload.

  Required attestation attributes are `:pipeline_root`, `:pipeline_path`,
  `:graph_hash`, `:workdir`, and `:initial_args`.
  """
  @spec build(String.t(), [cap_descriptor()], map() | keyword()) ::
          {:ok, unsigned_payload()} | {:error, term()}
  def build(issuer_id, capabilities, attrs)
      when is_binary(issuer_id) and is_list(capabilities) and
             (is_map(attrs) or is_list(attrs)) do
    attrs = Map.new(attrs)

    validate_payload(%{
      version: @current_version,
      issuer_id: issuer_id,
      pipeline_root: Map.get(attrs, :pipeline_root),
      pipeline_path: Map.get(attrs, :pipeline_path),
      graph_hash: Map.get(attrs, :graph_hash),
      workdir: Map.get(attrs, :workdir),
      initial_args: Map.get(attrs, :initial_args),
      capabilities: capabilities
    })
  end

  def build(_, _, _), do: {:error, {:invalid_schema, :invalid_build_arguments}}

  @doc "Compute the canonical, domain-separated bytes covered by the signature."
  @spec signing_payload(unsigned_payload() | Attestation.t()) :: binary()
  def signing_payload(payload) do
    capabilities_json =
      payload.capabilities
      |> Enum.map(&canonical_capability_json/1)
      |> Enum.sort_by(fn cap ->
        {cap["resource_uri"], canonical_json(cap["constraints"])}
      end)
      |> canonical_json()

    length_prefix(@signing_domain) <>
      length_prefix(Integer.to_string(payload.version)) <>
      length_prefix(payload.issuer_id) <>
      length_prefix(payload.pipeline_root) <>
      length_prefix(payload.pipeline_path) <>
      length_prefix(payload.graph_hash) <>
      length_prefix(payload.workdir) <>
      length_prefix(canonical_json(payload.initial_args)) <>
      length_prefix(capabilities_json)
  end

  @doc "Build the JSON object written by signing tooling."
  @spec manifest_map(unsigned_payload(), binary()) :: map()
  def manifest_map(payload, signature) when is_binary(signature) do
    %{
      "version" => payload.version,
      "issuer_id" => payload.issuer_id,
      "pipeline_root" => payload.pipeline_root,
      "pipeline_path" => payload.pipeline_path,
      "graph_hash" => payload.graph_hash,
      "workdir" => payload.workdir,
      "initial_args" => payload.initial_args,
      "capabilities" =>
        Enum.map(payload.capabilities, fn capability ->
          %{
            "resource_uri" => capability.resource_uri,
            "constraints" => capability.constraints
          }
        end),
      "signature" => Base.encode64(signature)
    }
  end

  @doc false
  @spec initial_args_match?(term(), term()) :: boolean()
  def initial_args_match?(left, right) do
    with :ok <- validate_initial_args(left),
         :ok <- validate_initial_args(right) do
      canonical_json(left) == canonical_json(right)
    else
      _ -> false
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp validate_schema(raw) when is_map(raw) do
    with {:ok, version} <- fetch_int(raw, "version"),
         :ok <- check_version(version),
         {:ok, issuer_id} <- fetch_string(raw, "issuer_id"),
         {:ok, pipeline_root} <- fetch_string(raw, "pipeline_root"),
         {:ok, pipeline_path} <- fetch_string(raw, "pipeline_path"),
         {:ok, graph_hash} <- fetch_string(raw, "graph_hash"),
         {:ok, workdir} <- fetch_string(raw, "workdir"),
         {:ok, initial_args} <- fetch_map(raw, "initial_args"),
         {:ok, capabilities} <- fetch_list(raw, "capabilities"),
         {:ok, signature_b64} <- fetch_string(raw, "signature"),
         {:ok, signature} <- decode_signature(signature_b64),
         {:ok, payload} <-
           validate_payload(%{
             version: version,
             issuer_id: issuer_id,
             pipeline_root: pipeline_root,
             pipeline_path: pipeline_path,
             graph_hash: graph_hash,
             workdir: workdir,
             initial_args: initial_args,
             capabilities: capabilities
           }) do
      {:ok, Map.put(payload, :signature, signature)}
    end
  end

  defp validate_schema(_), do: {:error, {:invalid_schema, :not_a_map}}

  defp validate_payload(payload) do
    with :ok <- check_version(payload.version),
         :ok <- validate_nonempty_string(payload.issuer_id, "issuer_id"),
         :ok <- validate_pipeline_root(payload.pipeline_root),
         :ok <- validate_pipeline_path(payload.pipeline_path),
         :ok <- validate_graph_hash(payload.graph_hash),
         :ok <- validate_workdir(payload.workdir),
         :ok <- validate_initial_args(payload.initial_args),
         {:ok, capabilities} <- validate_capabilities(payload.capabilities) do
      {:ok, %{payload | capabilities: capabilities}}
    end
  end

  defp validate_capabilities([]), do: {:ok, []}

  defp validate_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case validate_capability(raw, index) do
        {:ok, capability} -> {:cont, {:ok, [capability | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, capabilities} -> {:ok, Enum.reverse(capabilities)}
      error -> error
    end
  end

  defp validate_capabilities(_),
    do: {:error, {:invalid_schema, :capabilities_not_list}}

  defp validate_capability(raw, index) when is_map(raw) do
    uri = Map.get(raw, "resource_uri") || Map.get(raw, :resource_uri)
    constraints = Map.get(raw, "constraints", Map.get(raw, :constraints, %{}))

    with true <- is_binary(uri) and uri != "",
         {:ok, canonical_uri} <- canonical_capability_uri(uri),
         {:ok, normalized_constraints} <- normalize_constraints(constraints) do
      {:ok, %{resource_uri: canonical_uri, constraints: normalized_constraints}}
    else
      false -> {:error, {:invalid_schema, {:capability_missing_resource_uri, index}}}
      {:error, {:invalid_resource_uri, _} = reason} -> {:error, {:invalid_schema, reason}}
      {:error, reason} -> {:error, {:invalid_schema, {:invalid_constraints, index, reason}}}
    end
  end

  defp validate_capability(_, index),
    do: {:error, {:invalid_schema, {:capability_missing_resource_uri, index}}}

  defp normalize_constraints(constraints)
       when is_map(constraints) and not is_struct(constraints) do
    with {:ok, encoded} <- Jason.encode(constraints),
         {:ok, decoded} <- Jason.decode(encoded) do
      {:ok, atomize_known_constraint_keys(decoded)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_constraints(_), do: {:error, :not_a_map}

  defp atomize_known_constraint_keys(map) do
    known = [:time_window, :allowed_paths, :rate_limit, :requires_approval, :taint_policy]

    Enum.reduce(known, map, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.pop(acc, string_key) do
        {nil, _} -> acc
        {value, rest} -> Map.put(rest, key, value)
      end
    end)
  end

  defp canonical_capability_json(%{resource_uri: uri, constraints: constraints}) do
    %{
      "resource_uri" => canonical_resource_uri(uri),
      "constraints" => constraints
    }
  end

  defp canonical_resource_uri(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, parsed} -> CapabilityUri.canonical(parsed)
      {:error, _reason} -> uri
    end
  end

  defp canonical_capability_uri(uri) do
    with {:ok, parsed} <- CapabilityUri.parse(uri),
         canonical = CapabilityUri.canonical(parsed),
         true <- CapabilityUri.capability_match?(uri, canonical) do
      {:ok, canonical}
    else
      {:error, reason} -> {:error, {:invalid_resource_uri, reason}}
      false -> {:error, {:invalid_resource_uri, :traversal_segment}}
    end
  end

  defp validate_pipeline_root(root) when is_binary(root) do
    if Regex.match?(@root_id_pattern, root),
      do: :ok,
      else: {:error, {:invalid_schema, {:invalid_pipeline_root, root}}}
  end

  defp validate_pipeline_root(_),
    do: {:error, {:invalid_schema, {:missing_or_invalid, "pipeline_root"}}}

  defp validate_pipeline_path(path) when is_binary(path) and path != "" do
    normalized = path |> Path.split() |> Path.join()

    if Path.type(path) == :relative and Path.extname(path) == ".dot" and normalized == path and
         Enum.all?(Path.split(path), &(&1 not in [".", "..", "/"])) do
      :ok
    else
      {:error, {:invalid_schema, {:invalid_pipeline_path, path}}}
    end
  end

  defp validate_pipeline_path(_),
    do: {:error, {:invalid_schema, {:missing_or_invalid, "pipeline_path"}}}

  defp validate_graph_hash(hash) when is_binary(hash) do
    if Regex.match?(@sha256_pattern, hash),
      do: :ok,
      else: {:error, {:invalid_schema, {:invalid_graph_hash, hash}}}
  end

  defp validate_graph_hash(_),
    do: {:error, {:invalid_schema, {:missing_or_invalid, "graph_hash"}}}

  defp validate_workdir(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute and Path.expand(path) == path and String.valid?(path) and
         not String.contains?(path, <<0>>) do
      :ok
    else
      {:error, {:invalid_schema, {:invalid_workdir, path}}}
    end
  end

  defp validate_workdir(_),
    do: {:error, {:invalid_schema, {:missing_or_invalid, "workdir"}}}

  defp validate_initial_args(args) when is_map(args) and not is_struct(args) do
    validate_json(args, [], 0)
  end

  defp validate_initial_args(_),
    do: {:error, {:invalid_schema, {:missing_or_invalid, "initial_args"}}}

  defp validate_json(_value, _path, depth) when depth > 64,
    do: {:error, {:invalid_schema, :initial_args_too_deep}}

  defp validate_json(value, _path, _depth) when value in [nil, true, false], do: :ok
  defp validate_json(value, _path, _depth) when is_integer(value), do: :ok

  defp validate_json(value, path, _depth) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:invalid_schema, {:invalid_initial_arg, Enum.reverse(path)}}}
    end
  end

  defp validate_json(value, path, _depth) when is_binary(value) do
    if String.valid?(value),
      do: :ok,
      else: {:error, {:invalid_schema, {:invalid_initial_arg, Enum.reverse(path)}}}
  end

  defp validate_json(value, path, depth) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case validate_json(item, [index | path], depth + 1) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  rescue
    _ -> {:error, {:invalid_schema, {:invalid_initial_arg, Enum.reverse(path)}}}
  end

  defp validate_json(value, path, depth) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn
      {key, item}, :ok when is_binary(key) ->
        case validate_json(item, [key | path], depth + 1) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {_key, _item}, :ok ->
        {:halt, {:error, {:invalid_schema, {:non_string_initial_arg_key, Enum.reverse(path)}}}}
    end)
  end

  defp validate_json(_value, path, _depth),
    do: {:error, {:invalid_schema, {:invalid_initial_arg, Enum.reverse(path)}}}

  defp validate_nonempty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_nonempty_string(_value, field),
    do: {:error, {:invalid_schema, {:missing_or_invalid, field}}}

  defp check_version(@current_version), do: :ok
  defp check_version(1), do: {:error, {:legacy_version, 1}}
  defp check_version(version), do: {:error, {:invalid_schema, {:unsupported_version, version}}}

  defp fetch_int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) and not is_struct(value) -> {:ok, value}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp decode_signature(base64) do
    case Base.decode64(base64) do
      {:ok, signature} when byte_size(signature) == 64 -> {:ok, signature}
      _ -> {:error, {:invalid_schema, :invalid_signature_encoding}}
    end
  end

  defp lookup_issuer(issuer_id) do
    case IssuerRegistry.lookup(issuer_id) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, :issuer_not_found}
      {:error, :revoked} -> {:error, :issuer_revoked}
      {:error, :identity_unavailable} -> {:error, :identity_unavailable}
      {:error, other} -> {:error, other}
    end
  end

  defp verify_signature(parsed, public_key) do
    if Crypto.verify(signing_payload(parsed), parsed.signature, public_key),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp verify_parsed_attestation(parsed) do
    with {:ok, %{public_key: public_key, max_envelope_caps: envelopes}} <-
           lookup_issuer(parsed.issuer_id),
         :ok <- verify_signature(parsed, public_key),
         :ok <- verify_all_caps_in_envelope(parsed.capabilities, envelopes, parsed.issuer_id) do
      :ok
    end
  end

  defp to_attestation(parsed) do
    capabilities =
      Enum.map(parsed.capabilities, &Map.put(&1, :issuer_id, parsed.issuer_id))

    struct!(Attestation, %{parsed | capabilities: capabilities})
  end

  defp verify_all_caps_in_envelope(capabilities, envelopes, issuer_id) do
    Enum.reduce_while(capabilities, :ok, fn descriptor, :ok ->
      case build_transient_cap(descriptor, issuer_id) do
        {:ok, cap} ->
          if Enum.any?(envelopes, &Capability.envelope_subset?(cap, &1)) do
            {:cont, :ok}
          else
            {:halt, {:error, {:cap_exceeds_envelope, descriptor.resource_uri}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_schema, reason}}}
      end
    end)
  end

  defp build_transient_cap(%{resource_uri: uri, constraints: constraints}, issuer_id) do
    Capability.new(
      resource_uri: uri,
      principal_id: "#{issuer_id}_pending_run",
      constraints: constraints
    )
  end

  defp canonical_json(term), do: term |> canonicalize() |> Jason.encode!()

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> [to_string(key), canonicalize(value)] end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp length_prefix(field) when is_binary(field), do: <<byte_size(field)::32, field::binary>>
end
