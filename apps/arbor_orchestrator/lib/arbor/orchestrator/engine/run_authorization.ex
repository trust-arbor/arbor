defmodule Arbor.Orchestrator.Engine.RunAuthorization do
  @moduledoc false

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.Viz.DotSerializer

  @version 1
  @authority_node_id "__run_authorization__"

  @unbound_override_opts [
    :actions_executor,
    :function_handler,
    :middleware,
    :parallel_branch_executor,
    :shell_authorizer,
    :tool_command_runner,
    :tool_hooks,
    :transforms
  ]

  @enforce_keys [
    :execution_principal,
    :caller_id,
    :author_id,
    :graph_hash,
    :workdir,
    :binding_digest
  ]
  defstruct [
    :execution_principal,
    :caller_id,
    :author_id,
    :task_id,
    :session_id,
    :graph_hash,
    :workdir,
    :binding_digest
  ]

  @type t :: %__MODULE__{
          execution_principal: String.t(),
          caller_id: String.t(),
          author_id: String.t(),
          task_id: String.t() | nil,
          session_id: String.t() | nil,
          graph_hash: String.t(),
          workdir: String.t(),
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
        {:ok, {nil, opts}}

      match?(%__MODULE__{}, inherited) ->
        with :ok <- reject_unbound_overrides(opts),
             :ok <- verify_digest(inherited),
             :ok <- verify_inherited_opts(inherited, opts),
             {:ok, current_graph_hash} <- current_graph_hash(graph, opts),
             :ok <- validate_graph(graph) do
          {:ok, {inherited, bind_opts(opts, inherited, current_graph_hash)}}
        end

      is_nil(inherited) ->
        with :ok <- reject_unbound_overrides(opts),
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
         {:ok, caller_id} <- optional_id(opts, :caller_id, execution_principal),
         {:ok, author_id} <- author_id(opts, caller_id),
         {:ok, task_id} <- optional_id(opts, :task_id, nil),
         {:ok, session_id} <- optional_id(opts, :session_id, nil),
         {:ok, graph_hash} <- current_graph_hash(graph, opts),
         {:ok, workdir} <- fixed_workdir(opts) do
      base = %{
        execution_principal: execution_principal,
        caller_id: caller_id,
        author_id: author_id,
        task_id: task_id,
        session_id: session_id,
        graph_hash: graph_hash,
        workdir: workdir
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
      "workdir" => authority.workdir,
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
    case Map.get(node.attrs, "agent_id") do
      nil -> :ok
      "" -> :ok
      _ -> {:error, {:graph_principal_override, node.id}}
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
      {:ok, Path.expand(workdir)}
    else
      {:error, :invalid_run_authorization_workdir}
    end
  end

  defp current_graph_hash(graph, opts) do
    case Keyword.get(opts, :graph_hash) do
      nil -> {:ok, graph_hash(graph)}
      hash when is_binary(hash) and hash != "" -> {:ok, hash}
      _ -> {:error, :invalid_run_authorization_graph_hash}
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
      {:session_id, Keyword.get(opts, :session_id)}
    ]

    mismatch =
      Enum.find(checks, fn {field, value} ->
        not is_nil(value) and Map.fetch!(authority, field) != value
      end)

    cond do
      mismatch ->
        {:error, {:inherited_run_authorization_mismatch, elem(mismatch, 0)}}

      Keyword.has_key?(opts, :workdir) and
          Path.expand(Keyword.fetch!(opts, :workdir)) != authority.workdir ->
        {:error, {:inherited_run_authorization_mismatch, :workdir}}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :invalid_inherited_run_authorization}
  end

  defp validate_graph(%Graph{} = graph) do
    Enum.reduce_while(graph.nodes, :ok, fn {_id, node}, :ok ->
      cond do
        Map.get(node.attrs, "agent_id") not in [nil, ""] ->
          {:halt, {:error, {:graph_principal_override, node.id}}}

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
    |> maybe_put_keyword(:task_id, authority.task_id)
    |> maybe_put_keyword(:session_id, authority.session_id)
  end

  defp digest(base) do
    base
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
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
end
