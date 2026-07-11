defmodule Arbor.Orchestrator.Engine.RunAuthorization do
  @moduledoc false

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Viz.DotSerializer
  alias Arbor.Common.SafePath

  @version 3
  @authority_node_id "__run_authorization__"

  @unbound_override_opts [
    :actions_executor,
    :function_handler,
    :item_handler,
    :middleware,
    :parallel_branch_executor,
    :shell_authorizer,
    :tool_command_runner,
    :tool_executor,
    :tool_hooks,
    :transforms
  ]

  @enforce_keys [
    :execution_principal,
    :caller_id,
    :author_id,
    :graph_hash,
    :compiled_graph_hash,
    :workdir,
    :workdir_identity,
    :execution_manifest,
    :execution_manifest_digest,
    :pinned_action_bindings,
    :pinned_handler_bindings,
    :pinned_node_bindings,
    :parent_binding_digest,
    :binding_digest
  ]
  defstruct [
    :execution_principal,
    :caller_id,
    :author_id,
    :task_id,
    :session_id,
    :graph_hash,
    :compiled_graph_hash,
    :workdir,
    :workdir_identity,
    :execution_manifest,
    :execution_manifest_digest,
    :pinned_action_bindings,
    :pinned_handler_bindings,
    :pinned_node_bindings,
    :parent_binding_digest,
    :binding_digest
  ]

  @type t :: %__MODULE__{
          execution_principal: String.t(),
          caller_id: String.t(),
          author_id: String.t(),
          task_id: String.t() | nil,
          session_id: String.t() | nil,
          graph_hash: String.t(),
          compiled_graph_hash: String.t(),
          workdir: String.t(),
          workdir_identity: %{String.t() => non_neg_integer()},
          execution_manifest: map() | nil,
          execution_manifest_digest: String.t() | nil,
          pinned_action_bindings: map() | nil,
          pinned_handler_bindings: map() | nil,
          pinned_node_bindings: map() | nil,
          parent_binding_digest: String.t() | nil,
          binding_digest: String.t()
        }

  @spec prepare(Graph.t(), keyword()) ::
          {:ok, {t() | nil, keyword()}} | {:error, term()}
  def prepare(%Graph{} = graph, opts) when is_list(opts) do
    authorization? = Keyword.get(opts, :authorization, false) == true
    inherited = Keyword.get(opts, :run_authorization)

    cond do
      not authorization? and not is_nil(inherited) ->
        {:error, :run_authorization_downgrade}

      not authorization? ->
        # Still validate present :signing_authority (including nil/malformed):
        # key presence must never be treated as absence or select a legacy path.
        with :ok <- validate_signing_authority_opts(opts) do
          {:ok, {nil, opts}}
        end

      match?(%__MODULE__{}, inherited) ->
        with :ok <- reject_unbound_overrides(opts),
             :ok <- validate_signing_authority_opts(opts),
             :ok <- verify_digest(inherited),
             :ok <- verify_workdir(inherited),
             :ok <- verify_inherited_opts(inherited, opts),
             current_graph_hash = graph_hash(graph),
             {:ok, current_compiled_graph_hash} <- ExecutionManifest.compiled_graph_hash(graph),
             :ok <- validate_graph(graph),
             {:ok, child_authority} <-
               derive_child_authority(
                 graph,
                 inherited,
                 current_graph_hash,
                 current_compiled_graph_hash
               ) do
          # SigningAuthority stays only in opts (process-local Engine credential).
          # It is never stored on the RunAuthorization struct/digest/projection.
          {:ok, {child_authority, bind_opts(opts, child_authority, current_graph_hash)}}
        end

      is_nil(inherited) ->
        with :ok <- reject_unbound_overrides(opts),
             :ok <- validate_signing_authority_opts(opts),
             {:ok, authority} <- new(graph, opts),
             :ok <- validate_graph(graph) do
          {:ok, {authority, bind_opts(opts, authority, authority.graph_hash)}}
        end

      true ->
        {:error, :invalid_run_authorization}
    end
  end

  @doc false
  @spec new(Graph.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Graph{} = graph, opts) when is_list(opts) do
    with {:ok, execution_principal} <- execution_principal(opts),
         :ok <- validate_signing_authority_opts(opts, execution_principal),
         {:ok, caller_id} <- optional_id(opts, :caller_id, execution_principal),
         {:ok, author_id} <- author_id(opts, caller_id),
         {:ok, task_id} <- optional_id(opts, :task_id, nil),
         {:ok, session_id} <- optional_id(opts, :session_id, nil),
         {:ok, graph_hash} <- current_graph_hash(graph, opts),
         {:ok, compiled_graph_hash} <- current_compiled_graph_hash(graph, opts),
         {:ok, {workdir, workdir_identity}} <- fixed_workdir(opts),
         {:ok,
          {execution_manifest, execution_manifest_digest, pinned_action_bindings,
           pinned_handler_bindings, pinned_node_bindings}} <-
           execution_binding(opts, graph, graph_hash, compiled_graph_hash) do
      # Intentionally no :signing_authority field — process-local Engine opt only.
      base = %{
        execution_principal: execution_principal,
        caller_id: caller_id,
        author_id: author_id,
        task_id: task_id,
        session_id: session_id,
        graph_hash: graph_hash,
        compiled_graph_hash: compiled_graph_hash,
        workdir: workdir,
        workdir_identity: workdir_identity,
        execution_manifest: execution_manifest,
        execution_manifest_digest: execution_manifest_digest,
        pinned_action_bindings: pinned_action_bindings,
        pinned_handler_bindings: pinned_handler_bindings,
        pinned_node_bindings: pinned_node_bindings,
        parent_binding_digest: nil
      }

      {:ok, struct!(__MODULE__, Map.put(base, :binding_digest, digest(base)))}
    end
  end

  @doc false
  @spec graph_hash(Graph.t()) :: String.t()
  def graph_hash(%Graph{} = graph) do
    graph
    |> DotSerializer.serialize()
    |> sha256()
  end

  @doc false
  @spec projection(t()) :: map()
  def projection(%__MODULE__{} = authority) do
    %{
      "version" => @version,
      "execution_principal" => authority.execution_principal,
      "caller_id" => authority.caller_id,
      "author_id" => authority.author_id,
      "task_id" => authority.task_id,
      "session_id" => authority.session_id,
      "graph_hash" => authority.graph_hash,
      "compiled_graph_hash" => authority.compiled_graph_hash,
      "workdir" => authority.workdir,
      "workdir_identity" => authority.workdir_identity,
      "execution_manifest" => authority.execution_manifest,
      "execution_manifest_digest" => authority.execution_manifest_digest,
      "parent_binding_digest" => authority.parent_binding_digest,
      "binding_digest" => authority.binding_digest
    }
  end

  def projection(nil), do: nil

  @doc false
  @spec verify_checkpoint(t() | nil, map() | nil) :: :ok | {:error, term()}
  def verify_checkpoint(nil, nil), do: :ok

  def verify_checkpoint(%__MODULE__{} = authority, checkpoint_projection)
      when is_map(checkpoint_projection) do
    if projection(authority) == stringify_keys(checkpoint_projection) do
      :ok
    else
      {:error, :run_authorization_mismatch}
    end
  end

  def verify_checkpoint(_authority, _checkpoint_projection),
    do: {:error, :run_authorization_mismatch}

  @doc false
  @spec enforce_context(Context.t(), t() | nil) :: Context.t()
  def enforce_context(%Context{} = context, nil), do: context

  def enforce_context(%Context{} = context, %__MODULE__{} = authority) do
    now = DateTime.utc_now()

    context
    |> Context.set(
      "session.agent_id",
      authority.execution_principal,
      @authority_node_id,
      now
    )
    |> Context.set("session.caller_id", authority.caller_id, @authority_node_id, now)
    |> Context.set("workdir", authority.workdir, @authority_node_id, now)
    |> maybe_set_context("session.task_id", authority.task_id, now)
    |> maybe_set_context("session.session_id", authority.session_id, now)
  end

  @doc false
  @spec seed_values(map(), t() | nil, String.t() | nil) :: map()
  def seed_values(values, nil, workdir) when is_map(values) do
    if is_binary(workdir) and String.trim(workdir) != "" do
      Map.put(values, "workdir", Path.expand(workdir))
    else
      values
    end
  end

  def seed_values(values, %__MODULE__{} = authority, _workdir) when is_map(values) do
    values
    |> Map.put("session.agent_id", authority.execution_principal)
    |> Map.put("session.caller_id", authority.caller_id)
    |> Map.put("workdir", authority.workdir)
    |> maybe_put("session.task_id", authority.task_id)
    |> maybe_put("session.session_id", authority.session_id)
  end

  @doc false
  @spec sanitize_node(Node.t(), t() | nil) :: Node.t()
  def sanitize_node(%Node{} = node, nil), do: node

  def sanitize_node(%Node{} = node, %__MODULE__{} = authority) do
    attrs =
      node.attrs
      |> Map.delete("agent_id")
      |> overwrite_if_present("cwd", authority.workdir)
      |> overwrite_if_present("workdir", authority.workdir)

    %{node | attrs: attrs}
  end

  @doc false
  @spec validate_node(Node.t(), t() | nil) :: :ok | {:error, term()}
  def validate_node(%Node{}, nil), do: :ok

  def validate_node(%Node{} = node, %__MODULE__{}) do
    cond do
      Registry.canonical_type(Registry.node_type(node)) == "adapt" ->
        {:error, {:authorized_graph_adaptation_forbidden, node.id}}

      Map.get(node.attrs, "agent_id") in [nil, ""] ->
        :ok

      true ->
        {:error, {:graph_principal_override, node.id}}
    end
  end

  @doc false
  @spec verify_handler(t(), Node.t(), module() | function()) :: :ok | {:error, term()}
  def verify_handler(%__MODULE__{} = authority, %Node{} = node, handler)
      when is_atom(handler) do
    case ExecutionManifest.verify_handler_module(
           Registry.node_type(node),
           handler,
           authority.pinned_handler_bindings
         ) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def verify_handler(%__MODULE__{pinned_handler_bindings: nil}, %Node{}, _handler), do: :ok

  def verify_handler(%__MODULE__{}, %Node{} = node, _handler),
    do: {:error, {:invalid_bound_handler, Registry.node_type(node)}}

  @doc false
  @spec verify_execution_module(t() | nil, Node.t(), String.t(), module() | nil) ::
          :ok | {:error, term()}
  def verify_execution_module(nil, %Node{}, _slot, _module), do: :ok

  def verify_execution_module(%__MODULE__{} = authority, %Node{} = node, slot, module) do
    case ExecutionManifest.verify_node_module(
           node.id,
           slot,
           module,
           authority.pinned_node_bindings
         ) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec verify_graph(t(), Graph.t()) :: :ok | {:error, term()}
  def verify_graph(%__MODULE__{} = authority, %Graph{} = graph) do
    with {:ok, actual} <- ExecutionManifest.compiled_graph_hash(graph),
         true <- actual == authority.compiled_graph_hash do
      :ok
    else
      _other -> {:error, :run_authorization_compiled_graph_changed}
    end
  end

  @doc false
  @spec verify_workdir(t()) :: :ok | {:error, term()}
  def verify_workdir(%__MODULE__{} = authority) do
    with {:ok, resolved} <- SafePath.resolve_real(authority.workdir),
         true <- resolved == authority.workdir,
         {:ok, identity} <- workdir_identity(resolved),
         true <- identity == authority.workdir_identity do
      :ok
    else
      _other -> {:error, :run_authorization_workdir_changed}
    end
  end

  @doc false
  @spec scope_opts(t()) :: keyword()
  def scope_opts(%__MODULE__{} = authority) do
    []
    |> maybe_put_keyword(:task_id, authority.task_id)
    |> maybe_put_keyword(:session_id, authority.session_id)
  end

  defp execution_principal(opts) do
    canonical = Keyword.get(opts, :execution_principal)
    legacy = Keyword.get(opts, :agent_id)

    cond do
      present_id?(canonical) and present_id?(legacy) and canonical != legacy ->
        {:error, :execution_principal_mismatch}

      present_id?(canonical) ->
        validate_id(canonical, :execution_principal)

      present_id?(legacy) ->
        validate_id(legacy, :execution_principal)

      true ->
        {:error, :execution_principal_required}
    end
  end

  defp author_id(opts, default) do
    author_id = Keyword.get(opts, :author_id)
    graph_author_id = Keyword.get(opts, :graph_author_id)

    cond do
      present_id?(author_id) and present_id?(graph_author_id) and author_id != graph_author_id ->
        {:error, :author_id_mismatch}

      present_id?(author_id) ->
        validate_id(author_id, :author_id)

      present_id?(graph_author_id) ->
        validate_id(graph_author_id, :author_id)

      true ->
        {:ok, default}
    end
  end

  defp optional_id(opts, key, default) do
    if Keyword.has_key?(opts, key) do
      case Keyword.get(opts, key) do
        nil when is_nil(default) -> {:ok, nil}
        value -> validate_id(value, key)
      end
    else
      {:ok, default}
    end
  end

  defp validate_id(value, _field) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.valid?(trimmed) and not String.contains?(trimmed, <<0>>) do
      {:ok, trimmed}
    else
      {:error, :invalid_run_authorization_id}
    end
  end

  defp validate_id(_value, _field), do: {:error, :invalid_run_authorization_id}

  defp present_id?(value), do: is_binary(value) and String.trim(value) != ""

  defp fixed_workdir(opts) do
    workdir = Keyword.get(opts, :workdir, File.cwd!())

    if is_binary(workdir) and String.valid?(workdir) and String.trim(workdir) != "" and
         not String.contains?(workdir, <<0>>) do
      expanded = Path.expand(workdir)

      with {:ok, resolved} <- SafePath.resolve_real(expanded),
           true <- resolved == expanded,
           {:ok, identity} <- workdir_identity(resolved) do
        {:ok, {resolved, identity}}
      else
        false -> {:error, :run_authorization_workdir_not_canonical}
        {:error, :not_found} -> {:error, :run_authorization_workdir_not_found}
        {:error, _reason} -> {:error, :invalid_run_authorization_workdir}
      end
    else
      {:error, :invalid_run_authorization_workdir}
    end
  end

  defp workdir_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok,
         %{
           "inode" => stat.inode,
           "major_device" => stat.major_device,
           "minor_device" => stat.minor_device
         }}

      {:ok, %File.Stat{}} ->
        {:error, :workdir_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execution_binding(opts, graph, graph_hash, compiled_graph_hash) do
    manifest = Keyword.get(opts, :execution_manifest)
    digest = Keyword.get(opts, :execution_manifest_digest)
    supplied_actions = Keyword.get(opts, :pinned_action_bindings)
    supplied_handlers = Keyword.get(opts, :pinned_handler_bindings)
    supplied_nodes = Keyword.get(opts, :pinned_node_bindings)

    cond do
      Enum.all?(
        [manifest, digest, supplied_actions, supplied_handlers, supplied_nodes],
        &is_nil/1
      ) ->
        {:ok, {nil, nil, nil, nil, nil}}

      is_map(manifest) and valid_sha256?(digest) ->
        with :ok <- ExecutionManifest.validate(manifest, digest, graph_hash),
             :ok <- ExecutionManifest.verify_compiled_graph(manifest, graph),
             true <- manifest["compiled_graph_hash"] == compiled_graph_hash,
             {:ok, action_bindings} <- ExecutionManifest.action_binding_index(manifest),
             {:ok, handler_bindings} <- ExecutionManifest.handler_binding_index(manifest),
             {:ok, node_bindings} <- ExecutionManifest.node_binding_index(manifest),
             :ok <- require_supplied_index(supplied_actions, action_bindings, :action),
             :ok <- require_supplied_index(supplied_handlers, handler_bindings, :handler),
             :ok <- require_supplied_index(supplied_nodes, node_bindings, :node) do
          {:ok, {manifest, digest, action_bindings, handler_bindings, node_bindings}}
        else
          false -> {:error, :execution_manifest_compiled_graph_mismatch}
          {:error, _reason} = error -> error
        end

      true ->
        {:error, :invalid_execution_manifest_binding}
    end
  end

  defp valid_sha256?(digest) when is_binary(digest),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_sha256?(_digest), do: false

  defp require_supplied_index(nil, _derived, _kind), do: :ok
  defp require_supplied_index(value, value, _kind), do: :ok

  defp require_supplied_index(_supplied, _derived, kind),
    do: {:error, {:execution_manifest_index_mismatch, kind}}

  defp derive_child_authority(graph, parent, graph_hash, compiled_graph_hash) do
    with {:ok, {manifest, manifest_digest, action_bindings, handler_bindings, node_bindings}} <-
           child_execution_binding(graph, parent, graph_hash) do
      base = %{
        execution_principal: parent.execution_principal,
        caller_id: parent.caller_id,
        author_id: parent.author_id,
        task_id: parent.task_id,
        session_id: parent.session_id,
        graph_hash: graph_hash,
        compiled_graph_hash: compiled_graph_hash,
        workdir: parent.workdir,
        workdir_identity: parent.workdir_identity,
        execution_manifest: manifest,
        execution_manifest_digest: manifest_digest,
        pinned_action_bindings: action_bindings,
        pinned_handler_bindings: handler_bindings,
        pinned_node_bindings: node_bindings,
        parent_binding_digest: parent.binding_digest
      }

      {:ok, struct!(__MODULE__, Map.put(base, :binding_digest, digest(base)))}
    end
  end

  defp child_execution_binding(_graph, %{execution_manifest_digest: nil}, _graph_hash),
    do: {:ok, {nil, nil, nil, nil, nil}}

  defp child_execution_binding(graph, parent, graph_hash) do
    with {:ok, catalog} <- ActionCatalog.snapshot(),
         {:ok, {manifest, manifest_digest}} <- ExecutionManifest.build(graph, catalog, graph_hash),
         {:ok, action_bindings} <- ExecutionManifest.action_binding_index(manifest),
         {:ok, handler_bindings} <- ExecutionManifest.handler_binding_index(manifest),
         {:ok, node_bindings} <- ExecutionManifest.node_binding_index(manifest),
         :ok <- ExecutionManifest.require_subset(manifest, parent.execution_manifest),
         :ok <- ExecutionManifest.require_declared_child(manifest, parent.execution_manifest) do
      {:ok, {manifest, manifest_digest, action_bindings, handler_bindings, node_bindings}}
    else
      {:error, reason} -> {:error, {:child_execution_manifest_failed, reason}}
    end
  end

  defp current_graph_hash(graph, opts) do
    case Keyword.get(opts, :graph_hash) do
      nil -> {:ok, graph_hash(graph)}
      hash when is_binary(hash) and hash != "" -> {:ok, hash}
      _ -> {:error, :invalid_run_authorization_graph_hash}
    end
  end

  defp current_compiled_graph_hash(graph, opts) do
    with {:ok, actual} <- ExecutionManifest.compiled_graph_hash(graph) do
      case Keyword.get(opts, :compiled_graph_hash) do
        nil -> {:ok, actual}
        ^actual -> {:ok, actual}
        hash when is_binary(hash) -> {:error, :run_authorization_compiled_graph_hash_mismatch}
        _other -> {:error, :invalid_run_authorization_compiled_graph_hash}
      end
    end
  end

  defp verify_digest(%__MODULE__{} = authority) do
    base =
      authority
      |> Map.from_struct()
      |> Map.delete(:binding_digest)

    if digest(base) == authority.binding_digest,
      do: :ok,
      else: {:error, :invalid_run_authorization_digest}
  end

  defp verify_inherited_opts(authority, opts) do
    checks = [
      {:execution_principal, Keyword.get(opts, :execution_principal)},
      {:execution_principal, Keyword.get(opts, :agent_id)},
      {:caller_id, Keyword.get(opts, :caller_id)},
      {:author_id, Keyword.get(opts, :author_id)},
      {:author_id, Keyword.get(opts, :graph_author_id)},
      {:task_id, Keyword.get(opts, :task_id)},
      {:session_id, Keyword.get(opts, :session_id)},
      {:execution_manifest_digest, Keyword.get(opts, :execution_manifest_digest)},
      {:compiled_graph_hash, Keyword.get(opts, :compiled_graph_hash)}
    ]

    mismatch =
      Enum.find(checks, fn {field, value} ->
        not is_nil(value) and Map.fetch!(authority, field) != value
      end)

    cond do
      mismatch ->
        {:error, {:inherited_run_authorization_mismatch, elem(mismatch, 0)}}

      Keyword.has_key?(opts, :workdir) and not workdir_override_matches?(authority, opts) ->
        {:error, {:inherited_run_authorization_mismatch, :workdir}}

      Keyword.has_key?(opts, :pinned_action_bindings) and
          Keyword.fetch!(opts, :pinned_action_bindings) != authority.pinned_action_bindings ->
        {:error, {:inherited_run_authorization_mismatch, :pinned_action_bindings}}

      Keyword.has_key?(opts, :pinned_handler_bindings) and
          Keyword.fetch!(opts, :pinned_handler_bindings) != authority.pinned_handler_bindings ->
        {:error, {:inherited_run_authorization_mismatch, :pinned_handler_bindings}}

      Keyword.has_key?(opts, :pinned_node_bindings) and
          Keyword.fetch!(opts, :pinned_node_bindings) != authority.pinned_node_bindings ->
        {:error, {:inherited_run_authorization_mismatch, :pinned_node_bindings}}

      Keyword.has_key?(opts, :execution_manifest) and
          Keyword.fetch!(opts, :execution_manifest) != authority.execution_manifest ->
        {:error, {:inherited_run_authorization_mismatch, :execution_manifest}}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :invalid_inherited_run_authorization}
  end

  defp workdir_override_matches?(authority, opts) do
    with workdir when is_binary(workdir) <- Keyword.fetch!(opts, :workdir),
         expanded = Path.expand(workdir),
         {:ok, resolved} <- SafePath.resolve_real(expanded),
         true <- resolved == authority.workdir,
         {:ok, identity} <- workdir_identity(resolved) do
      identity == authority.workdir_identity
    else
      _other -> false
    end
  end

  defp validate_graph(%Graph{} = graph) do
    Enum.reduce_while(graph.nodes, :ok, fn {_id, node}, :ok ->
      cond do
        Map.get(node.attrs, "agent_id") not in [nil, ""] ->
          {:halt, {:error, {:graph_principal_override, node.id}}}

        Registry.canonical_type(Registry.node_type(node)) == "adapt" ->
          {:halt, {:error, {:authorized_graph_adaptation_forbidden, node.id}}}

        Registry.custom_handler_for(Registry.node_type(node)) != nil ->
          {:halt, {:error, {:unbound_custom_handler, node.id}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp reject_unbound_overrides(opts) do
    case Enum.find(@unbound_override_opts, &override_present?(opts, &1)) do
      nil -> :ok
      key -> {:error, {:unbound_authorized_override, key}}
    end
  end

  # Validate SigningAuthority shape/principal/exclusivity when present.
  # Key presence (Keyword.fetch), not value validity, decides whether the
  # authority path is selected. Present nil/malformed fails closed and never
  # selects the legacy signer/authorizer/key path.
  # Does NOT retain the authority on the RunAuthorization struct.
  defp validate_signing_authority_opts(opts) do
    case execution_principal(opts) do
      {:ok, principal} -> validate_signing_authority_opts(opts, principal)
      # Defer principal-required errors to new/1 / inherited path.
      {:error, :execution_principal_required} -> validate_signing_authority_shape_only(opts)
      {:error, _} = error -> error
    end
  end

  defp validate_signing_authority_opts(opts, execution_principal)
       when is_binary(execution_principal) do
    case Keyword.fetch(opts, :signing_authority) do
      :error ->
        :ok

      {:ok, %SigningAuthority{} = authority} ->
        with {:ok, authority} <- canonicalize_authority(authority),
             :ok <- validate_authority_principal_binding(authority, execution_principal),
             :ok <- reject_mixed_authority_credentials(opts) do
          :ok
        end

      {:ok, _invalid} ->
        # Includes explicit nil — present key is not absence.
        {:error, :invalid_signing_authority}
    end
  end

  defp validate_signing_authority_shape_only(opts) do
    case Keyword.fetch(opts, :signing_authority) do
      :error ->
        :ok

      {:ok, %SigningAuthority{} = authority} ->
        with {:ok, _authority} <- canonicalize_authority(authority),
             :ok <- reject_mixed_authority_credentials(opts) do
          :ok
        end

      {:ok, _invalid} ->
        {:error, :invalid_signing_authority}
    end
  end

  defp canonicalize_authority(authority) do
    # Safe Map.get extraction + new/1 — partial/forged struct tags never raise
    # and never reach the broker GenServer.
    case SigningAuthority.canonicalize(authority) do
      {:ok, %SigningAuthority{} = authority} -> {:ok, authority}
      {:error, reason} -> {:error, {:invalid_signing_authority, reason}}
    end
  end

  defp validate_authority_principal_binding(%SigningAuthority{} = authority, execution_principal) do
    if authority.principal_id == execution_principal do
      :ok
    else
      {:error, :principal_mismatch}
    end
  end

  # Key-presence exclusivity: nil/malformed values still count as mixed.
  defp reject_mixed_authority_credentials(opts) do
    mixed? =
      Keyword.has_key?(opts, :signer) or
        Keyword.has_key?(opts, :authorizer) or
        Keyword.has_key?(opts, :identity_private_key)

    if mixed?, do: {:error, :mixed_signing_credentials}, else: :ok
  end

  defp override_present?(opts, key) do
    case Keyword.get(opts, key) do
      nil -> false
      [] -> false
      map when is_map(map) and map_size(map) == 0 -> false
      _ -> true
    end
  end

  defp bind_opts(opts, authority, current_graph_hash) do
    opts
    |> Keyword.put(:authorization, true)
    |> Keyword.put(:run_authorization, authority)
    |> Keyword.put(:execution_principal, authority.execution_principal)
    |> Keyword.put(:agent_id, authority.execution_principal)
    |> Keyword.put(:caller_id, authority.caller_id)
    |> Keyword.put(:author_id, authority.author_id)
    |> Keyword.put(:workdir, authority.workdir)
    |> Keyword.put(:graph_hash, current_graph_hash)
    |> Keyword.put(:compiled_graph_hash, authority.compiled_graph_hash)
    |> maybe_put_keyword(:execution_manifest, authority.execution_manifest)
    |> maybe_put_keyword(:execution_manifest_digest, authority.execution_manifest_digest)
    |> maybe_put_keyword(:pinned_action_bindings, authority.pinned_action_bindings)
    |> maybe_put_keyword(:pinned_handler_bindings, authority.pinned_handler_bindings)
    |> maybe_put_keyword(:pinned_node_bindings, authority.pinned_node_bindings)
    |> maybe_put_keyword(:task_id, authority.task_id)
    |> maybe_put_keyword(:session_id, authority.session_id)
  end

  defp digest(base) do
    base
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> canonicalize()
    |> Jason.encode!()
    |> sha256()
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_set_context(context, _key, nil, _now), do: context

  defp maybe_set_context(context, key, value, now),
    do: Context.set(context, key, value, @authority_node_id, now)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp overwrite_if_present(attrs, key, value) do
    if Map.has_key?(attrs, key), do: Map.put(attrs, key, value), else: attrs
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
