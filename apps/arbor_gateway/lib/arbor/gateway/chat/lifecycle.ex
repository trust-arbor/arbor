defmodule Arbor.Gateway.Chat.Lifecycle do
  @moduledoc """
  Agent-lifecycle operations behind the signed HTTP endpoints in
  `Arbor.Gateway.Chat.Router`:

    * `POST /api/chat/agents`           → `create/3` (create+start from a template)
    * `POST /api/chat/agents/:id/start` → `start/2`  (start an existing stopped agent)
    * `POST /api/chat/agents/:id/stop`  → `stop/2`   (stop a running agent)

  Each op is *gated* by the principal's capabilities via the existing
  `Arbor.Agent` authorization wrappers — we do NOT invent new caps:

    * create → `Arbor.Agent.authorize_create/3` — `arbor://agent/lifecycle/create`
      (the create cap is GENERIC, not per-agent). The wrapper both gates and runs
      `Lifecycle.create/2`, so we pass it the full creation opts (template,
      display_name, model_config, `principal_id:`); `principal_id` makes
      `Lifecycle` grant the principal `arbor://chat/agent/<new>` so they can chat
      with the new agent immediately. We then `Lifecycle.start/2` it.
    * start  → `Arbor.Agent.authorize_restore/2` — `arbor://agent/lifecycle/restore`
      (gates + restores the persisted profile; idempotent), then `Lifecycle.start/2`.
    * stop   → `Arbor.Agent.authorize_stop/2` — `arbor://agent/stop/<id>` (gates +
      stops the supervised tree).

  Cross-app reach (Agent / Lifecycle / TemplateStore / LLMDefaults are at/above
  this app's level) goes through the same `bridge_call/3` runtime indirection the
  Socket + `Chat.Agents` use — no compile-time deps on arbor_agent are added. The
  collaborators are config-resolved so tests can inject fakes.

  Every public function returns a `{:ok, map}` (string-keyed, JSON-ready) or a
  `{:error, status, message}` tuple the router renders directly.
  """

  require Logger

  @typedoc "Successful result payload (string-keyed for JSON)."
  @type ok_result :: %{required(String.t()) => String.t() | boolean()}

  @typedoc "Failure: an HTTP status + a human-readable message."
  @type error :: {:error, pos_integer(), String.t()}

  # ── create+start from a template ───────────────────────────────────────────

  @doc """
  Create an agent from `template`, start it, and grant `principal` chat access.

  `name` and `model` are optional overrides. Returns
  `{:ok, %{"agent_id", "display_name", "running" => true}}` on success.
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, ok_result()} | error()
  def create(principal, params, opts \\ []) when is_binary(principal) and is_map(params) do
    with {:ok, template} <- fetch_template_name(params),
         {:ok, template_data} <- load_template(template),
         display_name = display_name_for(params, template_data, template),
         model_config = build_model_config(params),
         create_opts = [
           template: template,
           display_name: display_name,
           model_config: model_config,
           principal_id: principal,
           signed_request: Keyword.get(opts, :signed_request)
         ],
         {:ok, profile} <- do_create(principal, display_name, create_opts),
         agent_id = profile_agent_id(profile),
         {:ok, _pid} <- do_start(agent_id, principal_id: principal) do
      {:ok, %{"agent_id" => agent_id, "display_name" => display_name, "running" => true}}
    end
  end

  # ── start an existing (stopped) agent ──────────────────────────────────────

  @doc """
  Start an existing, stopped agent `id` after gating on the restore cap.
  Returns `{:ok, %{"agent_id", "running" => true}}` on success.
  """
  @spec start(String.t(), String.t(), keyword()) :: {:ok, ok_result()} | error()
  def start(principal, token, opts \\ []) when is_binary(principal) and is_binary(token) do
    with {:ok, id} <- resolve_token_or_error(principal, token) do
      do_start_resolved(principal, id, opts)
    end
  end

  defp do_start_resolved(principal, id, opts) do
    case bridge_call(agent_facade(), :authorize_restore, [principal, id, auth_opts(opts)]) do
      {:ok, {:ok, _profile}} ->
        case do_start(id, principal_id: principal) do
          {:ok, _pid} -> {:ok, %{"agent_id" => id, "running" => true}}
          {:error, status, msg} -> {:error, status, msg}
        end

      {:ok, {:error, {:unauthorized, reason}}} ->
        unauthorized(reason)

      {:ok, {:error, :not_found}} ->
        {:error, 404, "agent not found: #{id}"}

      {:ok, {:error, reason}} ->
        {:error, 409, "could not start #{id}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, 503, "agent subsystem unavailable: #{inspect(reason)}"}
    end
  end

  # ── stop a running agent ───────────────────────────────────────────────────

  @doc """
  Stop a running agent `id` after gating on `arbor://agent/stop/<id>`.
  Returns `{:ok, %{"agent_id", "running" => false}}` on success.
  """
  @spec stop(String.t(), String.t(), keyword()) :: {:ok, ok_result()} | error()
  def stop(principal, token, opts \\ []) when is_binary(principal) and is_binary(token) do
    with {:ok, id} <- resolve_token_or_error(principal, token) do
      do_stop_resolved(principal, id, opts)
    end
  end

  defp do_stop_resolved(principal, id, opts) do
    case bridge_call(agent_facade(), :authorize_stop, [principal, id, auth_opts(opts)]) do
      {:ok, :ok} ->
        {:ok, %{"agent_id" => id, "running" => false}}

      {:ok, {:error, {:unauthorized, reason}}} ->
        unauthorized(reason)

      {:ok, {:error, :not_found}} ->
        {:error, 404, "agent not running: #{id}"}

      {:ok, {:error, reason}} ->
        {:error, 409, "could not stop #{id}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, 503, "agent subsystem unavailable: #{inspect(reason)}"}
    end
  end

  # ── create internals (gate via authorize_create, then start) ───────────────

  defp do_create(principal, display_name, create_opts) do
    case bridge_call(agent_facade(), :authorize_create, [principal, display_name, create_opts]) do
      {:ok, {:ok, profile}} -> {:ok, profile}
      {:ok, {:ok, profile, _identity}} -> {:ok, profile}
      {:ok, {:error, {:unauthorized, reason}}} -> unauthorized(reason)
      {:ok, {:error, reason}} -> {:error, 422, "could not create agent: #{inspect(reason)}"}
      {:error, reason} -> {:error, 503, "agent subsystem unavailable: #{inspect(reason)}"}
    end
  end

  defp do_start(agent_id, opts) do
    case bridge_call(lifecycle_mod(), :start, [agent_id, opts]) do
      {:ok, {:ok, pid}} -> {:ok, pid}
      {:ok, {:error, :not_found}} -> {:error, 404, "agent not found: #{agent_id}"}
      {:ok, {:error, reason}} -> {:error, 409, "could not start #{agent_id}: #{inspect(reason)}"}
      {:error, reason} -> {:error, 503, "agent subsystem unavailable: #{inspect(reason)}"}
    end
  end

  # ── template / model resolution (mirrors mix arbor.agent do_start) ──────────

  defp fetch_template_name(params) do
    case Map.get(params, "template") do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> {:error, 422, "missing required field: template"}
    end
  end

  defp load_template(template) do
    case bridge_call(template_store(), :get, [template]) do
      {:ok, {:ok, data}} when is_map(data) -> {:ok, data}
      {:ok, {:error, :not_found}} -> {:error, 404, "template not found: #{template}"}
      {:ok, _other} -> {:error, 404, "template not found: #{template}"}
      {:error, reason} -> {:error, 503, "template subsystem unavailable: #{inspect(reason)}"}
    end
  end

  defp display_name_for(params, template_data, template) do
    case Map.get(params, "name") do
      n when is_binary(n) and n != "" -> n
      _ -> template_character_name(template_data) || template
    end
  end

  defp template_character_name(template_data) do
    case get_in(template_data, ["character", "name"]) do
      n when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  # Mirror Mix.Tasks.Arbor.Agent.do_start's model_config, with the model id
  # defaulting to LLMDefaults.default_model() unless the request overrides it.
  defp build_model_config(params) do
    model_id =
      case Map.get(params, "model") do
        m when is_binary(m) and m != "" -> m
        _ -> default_model()
      end

    %{
      id: model_id,
      provider: default_provider(),
      runtime: :arbor,
      module: Arbor.Agent.APIAgent,
      start_opts: []
    }
  end

  defp default_model do
    case bridge_call(llm_defaults(), :default_model, []) do
      {:ok, id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp default_provider do
    case bridge_call(llm_defaults(), :default_provider, []) do
      {:ok, provider} -> provider
      _ -> nil
    end
  end

  # ── result helpers ─────────────────────────────────────────────────────────

  defp profile_agent_id(%{agent_id: id}) when is_binary(id), do: id
  defp profile_agent_id(%{"agent_id" => id}) when is_binary(id), do: id
  defp profile_agent_id(id) when is_binary(id), do: id

  defp unauthorized(reason), do: {:error, 403, "unauthorized: #{inspect(reason)}"}

  # Resolve a user-typed token (full id, unique prefix, display_name, or alias) to
  # a full agent_id, scoped to the principal's authorized agents — so /start and
  # /stop accept the same shorthands as /agent. Maps resolution failure to the
  # {:error, status, message} shape the router renders.
  defp resolve_token_or_error(principal, token) do
    case Arbor.Gateway.Chat.Agents.resolve_token(principal, token) do
      {:ok, id} ->
        {:ok, id}

      {:error, {:ambiguous, candidates}} ->
        {:error, 422, ambiguous_msg(token, candidates)}

      {:error, :not_found} ->
        # An `agent_`-shaped token falls through to the existing lifecycle gates
        # (a real full id still works even if the listing path is degraded); a
        # non-`agent_` shorthand that didn't match is a helpful 404.
        if String.starts_with?(token, "agent_"),
          do: {:ok, token},
          else: {:error, 404, "no agent matches \"#{token}\""}
    end
  end

  defp ambiguous_msg(token, candidates) do
    list =
      candidates
      |> Enum.take(6)
      |> Enum.map_join(", ", fn a ->
        "#{a["display_name"]} (#{String.slice(a["agent_id"], 0, 14)}…)"
      end)

    "\"#{token}\" is ambiguous — matches #{list}. Be more specific."
  end

  # Forward the gateway-verified `:signed_request` to the `Arbor.Agent`
  # authorize wrappers. `identity_verification` is config-ON in dev/prod, so the
  # lifecycle gates reject as `:missing_signed_request` without it; nil is fine
  # (the wrapper treats absence as "no identity proof to forward").
  defp auth_opts(opts), do: [signed_request: Keyword.get(opts, :signed_request)]

  # ── bridge + config seams ──────────────────────────────────────────────────

  # Returns {:ok, result} | {:error, reason}; never raises. Mirror of
  # Chat.Agents.bridge_call/3.
  defp bridge_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      {:ok, apply(module, function, args)}
    else
      {:error, :not_available}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp agent_facade,
    do: Application.get_env(:arbor_gateway, :chat_agent_facade, Arbor.Agent)

  defp lifecycle_mod,
    do: Application.get_env(:arbor_gateway, :chat_lifecycle, Arbor.Agent.Lifecycle)

  defp template_store,
    do: Application.get_env(:arbor_gateway, :chat_template_store, Arbor.Agent.TemplateStore)

  defp llm_defaults,
    do: Application.get_env(:arbor_gateway, :chat_llm_defaults, Arbor.Agent.LLMDefaults)
end
