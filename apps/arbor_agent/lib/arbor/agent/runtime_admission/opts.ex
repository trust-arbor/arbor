defmodule Arbor.Agent.RuntimeAdmission.Opts do
  @moduledoc """
  Exhaustive closed inventory for ordinary `Lifecycle.start/2` option identity.

  Validates, projects, and fingerprints behavior-affecting start options.
  Dangerous collaborator selectors are rejected. Manager create-only passthrough
  keys and persisted model_config module/backend fields are stripped so ordinary
  start remains compatible with Manager create/resume forwarding. Pure except for
  `TenantContext.effective_workspace_root/1` path derivation (no process I/O).
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Security.SandboxLevel
  alias Arbor.Contracts.TenantContext

  @allowed_keys MapSet.new([
                  :principal_id,
                  :tenant_context,
                  :start_session,
                  :start_heartbeat,
                  :model,
                  :provider,
                  :runtime,
                  :system_prompt,
                  :tools,
                  :fallback_chain,
                  :model_config,
                  :max_tokens,
                  :stream,
                  :user_media,
                  :temperature,
                  :top_p,
                  :provider_options,
                  :heartbeat_dot,
                  :context_management,
                  :effective_window,
                  :recover_session,
                  :sandbox_level
                ])

  # Hard reject: authority/collaborator selectors and public store-name injection
  # must never reach ordinary start. `:name` is rejected (not silently ignored).
  # Test-only `:task_store` is stripped at OrdinaryStart before project under
  # MIX_ENV=test and is not part of option identity.
  @reject_keys MapSet.new([
                 :signer,
                 :signing_authority,
                 :signing_authority_bootstrap,
                 :runner,
                 :name
               ])

  # Manager create/resume may Keyword.merge create-only opts into Lifecycle.start.
  # Strip them so create-then-start and resume with persisted model_config keep working.
  @strip_passthrough_keys MapSet.new([
                            :template,
                            :character,
                            :return_identity,
                            :exact_template_policy,
                            :capabilities,
                            :initial_goals,
                            :delegator_id,
                            :delegator_private_key,
                            :template_data,
                            :template_module,
                            :template_source,
                            :metadata,
                            :memory_opts,
                            :display_name,
                            :requirements,
                            :strategy,
                            :spawn_on
                          ])

  @model_config_keys MapSet.new(["id", "model", "provider", "runtime", "fallback_chain"])
  @context_management_atoms [:none, :heuristic, :full]
  @max_prompt_bytes 8_192
  @max_id_bytes 256
  @max_path_bytes 512
  @max_tools 32
  @max_tool_name 128
  @max_fallback 8
  @max_provider_opt_keys 16

  @type projection :: %{optional(String.t()) => term()}
  @type fingerprint :: String.t()

  @doc """
  Validate opts, build canonical projection + keyword for the worker, and fingerprint.

  Returns `{:ok, %{fingerprint, projection, keyword}}` or `{:error, :invalid_start_opts}`.
  """
  @spec project(keyword() | map()) ::
          {:ok, %{fingerprint: fingerprint(), projection: projection(), keyword: keyword()}}
          | {:error, :invalid_start_opts}
  def project(opts) when is_list(opts) or is_map(opts) do
    opts =
      opts
      |> normalize_opts()
      |> strip_passthrough_keys()

    with :ok <- reject_forbidden(opts),
         :ok <- only_allowed_keys(opts),
         {:ok, projection} <- build_projection(opts),
         {:ok, keyword} <- projection_to_keyword(projection) do
      fp =
        :crypto.hash(:sha256, :erlang.term_to_binary(projection, [:deterministic]))
        |> Base.encode16(case: :lower)

      {:ok, %{fingerprint: "fp_" <> fp, projection: projection, keyword: keyword}}
    else
      _ -> {:error, :invalid_start_opts}
    end
  end

  def project(_), do: {:error, :invalid_start_opts}

  @doc "Return true when two fingerprints are exact equal binaries."
  @spec fingerprint_equal?(fingerprint(), fingerprint()) :: boolean()
  def fingerprint_equal?(a, b) when is_binary(a) and is_binary(b), do: a == b
  def fingerprint_equal?(_, _), do: false

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  defp strip_passthrough_keys(opts) do
    Enum.reject(opts, fn {k, _} -> k in @strip_passthrough_keys end)
  end

  defp reject_forbidden(opts) do
    if Enum.any?(opts, fn {k, v} ->
         k in @reject_keys or is_function(v) or is_pid(v) or is_reference(v) or
           (is_tuple(v) and mfa_like?(v))
       end) do
      :error
    else
      :ok
    end
  end

  defp mfa_like?({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a), do: true
  defp mfa_like?(_), do: false

  defp only_allowed_keys(opts) do
    if Enum.all?(opts, fn {k, _} -> k in @allowed_keys end), do: :ok, else: :error
  end

  defp build_projection(opts) do
    with {:ok, tenant} <- project_tenant(opts),
         {:ok, principal} <- project_principal(opts, tenant),
         {:ok, model_config} <- project_model_config(Keyword.get(opts, :model_config)),
         {:ok, tools} <- project_tools(Keyword.get(opts, :tools)),
         {:ok, fallback} <-
           project_fallback(
             Keyword.get(opts, :fallback_chain) ||
               get_in(model_config || %{}, ["fallback_chain"])
           ),
         {:ok, runtime} <- project_runtime(opts, model_config),
         {:ok, provider} <- project_provider(opts, model_config),
         {:ok, model} <- project_model(opts, model_config),
         {:ok, system_prompt} <- project_system_prompt(Keyword.get(opts, :system_prompt)),
         {:ok, max_tokens} <- project_max_tokens(Keyword.get(opts, :max_tokens)),
         {:ok, stream} <- project_bool_or_nil(Keyword.get(opts, :stream)),
         :ok <- project_user_media(Keyword.get(opts, :user_media)),
         {:ok, temperature} <- project_temperature(Keyword.get(opts, :temperature)),
         {:ok, top_p} <- project_top_p(Keyword.get(opts, :top_p)),
         {:ok, provider_options} <- project_provider_options(Keyword.get(opts, :provider_options)),
         {:ok, heartbeat_dot} <- project_path(Keyword.get(opts, :heartbeat_dot)),
         {:ok, context_management} <-
           project_context_management(Keyword.get(opts, :context_management, :full)),
         {:ok, effective_window} <- project_effective_window(Keyword.get(opts, :effective_window)),
         {:ok, sandbox} <- project_sandbox(Keyword.get(opts, :sandbox_level)),
         {:ok, start_session} <- require_bool_default(opts, :start_session, true),
         {:ok, start_heartbeat} <- require_bool_default(opts, :start_heartbeat, true),
         {:ok, recover_session} <- require_bool_default(opts, :recover_session, true) do
      proj =
        %{}
        |> put_present("principal_id", principal)
        |> put_present("tenant_context", tenant)
        |> Map.put("start_session", start_session)
        |> Map.put("start_heartbeat", start_heartbeat)
        |> put_present("model", model)
        |> put_present("provider", provider)
        # Omitted runtime stays absent so Lifecycle can resolve profile/template ACP.
        |> put_present("runtime", runtime)
        |> put_present("system_prompt", system_prompt)
        |> put_present("tools", tools)
        |> put_present("fallback_chain", fallback)
        |> put_present("model_config", strip_nil_map(model_config))
        |> put_present("max_tokens", max_tokens)
        |> put_present("stream", stream)
        |> Map.put("user_media", [])
        |> put_present("temperature", temperature)
        |> put_present("top_p", top_p)
        |> put_present("provider_options", provider_options)
        |> put_present("heartbeat_dot", heartbeat_dot)
        |> Map.put("context_management", context_management)
        |> put_present("effective_window", effective_window)
        |> Map.put("recover_session", recover_session)
        |> put_present("sandbox_level", sandbox)
        |> sort_map()

      if map_size(proj) > 48 do
        :error
      else
        {:ok, proj}
      end
    end
  end

  defp require_bool_default(opts, key, default) when is_boolean(default) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, default}
      {:ok, true} -> {:ok, true}
      {:ok, false} -> {:ok, false}
      _ -> :error
    end
  end

  defp project_tenant(opts) do
    case Keyword.get(opts, :tenant_context) do
      nil ->
        {:ok, nil}

      %TenantContext{} = ctx ->
        project_tenant_fields(ctx)

      %{__struct__: _} ->
        :error

      map when is_map(map) ->
        project_tenant_map(map)

      _ ->
        :error
    end
  end

  defp project_tenant_fields(%TenantContext{} = ctx) do
    with :ok <- require_exact_empty_metadata(ctx.metadata),
         root = ctx.workspace_root,
         effective = TenantContext.effective_workspace_root(ctx),
         :ok <- bound_bin(ctx.principal_id, @max_id_bytes),
         :ok <- bound_bin_or_nil(root, @max_path_bytes),
         :ok <- bound_bin_or_nil(effective, @max_path_bytes),
         :ok <- bound_bin_or_nil(ctx.display_name, @max_id_bytes) do
      {:ok,
       sort_map(%{
         "principal_id" => ctx.principal_id,
         "workspace_root" => root,
         "effective_workspace_root" => effective,
         "display_name" => ctx.display_name,
         "metadata" => %{}
       })}
    end
  end

  defp project_tenant_map(map) when is_map(map) do
    with {:ok, canon} <- canonicalize_map_keys(map),
         :ok <- require_exact_empty_metadata(Map.get(canon, "metadata", %{})),
         pid when is_binary(pid) <- Map.get(canon, "principal_id"),
         root = Map.get(canon, "workspace_root"),
         display = Map.get(canon, "display_name") do
      ctx = TenantContext.new(pid, workspace_root: root, display_name: display, metadata: %{})
      project_tenant_fields(ctx)
    else
      _ -> :error
    end
  end

  # Packet: tenant metadata must be exactly %{} when present — never coerce non-maps.
  defp require_exact_empty_metadata(%{} = meta) when map_size(meta) == 0, do: :ok
  defp require_exact_empty_metadata(nil), do: :ok
  defp require_exact_empty_metadata(_), do: :error

  defp project_principal(opts, tenant) do
    explicit = Keyword.get(opts, :principal_id)
    from_tenant = tenant && Map.get(tenant, "principal_id")

    cond do
      is_binary(explicit) and is_binary(from_tenant) and explicit != from_tenant ->
        :error

      is_binary(explicit) ->
        case bound_bin(explicit, @max_id_bytes) do
          :ok -> {:ok, explicit}
          _ -> :error
        end

      is_binary(from_tenant) ->
        {:ok, from_tenant}

      is_nil(explicit) ->
        {:ok, nil}

      true ->
        :error
    end
  end

  defp project_model_config(nil), do: {:ok, nil}

  defp project_model_config(cfg) when is_map(cfg) do
    # Canonicalize keys fail-closed (atom/binary only, no atom/string duplicates).
    # Then whitelist-extract identity keys; drop module/backend without rejecting.
    with {:ok, canon} <- canonicalize_map_keys(cfg) do
      filtered =
        canon
        |> Enum.filter(fn {k, _} -> k in @model_config_keys end)
        |> Map.new()

      with {:ok, id} <- optional_bin(Map.get(filtered, "id"), @max_id_bytes),
           {:ok, model} <- optional_bin(Map.get(filtered, "model"), @max_id_bytes),
           {:ok, provider} <- optional_provider(Map.get(filtered, "provider")),
           {:ok, runtime} <- optional_runtime(Map.get(filtered, "runtime")),
           {:ok, fb} <- project_fallback(Map.get(filtered, "fallback_chain")) do
        {:ok,
         strip_nil_map(%{
           "id" => id,
           "model" => model,
           "provider" => provider,
           "runtime" => runtime,
           "fallback_chain" => fb
         })}
      end
    end
  end

  defp project_model_config(_), do: :error

  defp project_tools(nil), do: {:ok, nil}

  defp project_tools(tools) when is_list(tools) and length(tools) <= @max_tools do
    Enum.reduce_while(tools, {:ok, []}, fn
      name, {:ok, acc} when is_binary(name) ->
        if byte_size(name) <= @max_tool_name and String.valid?(name) do
          {:cont, {:ok, acc ++ [name]}}
        else
          {:halt, :error}
        end

      _atom_or_other, _ ->
        {:halt, :error}
    end)
  end

  defp project_tools(_), do: :error

  defp project_fallback(nil), do: {:ok, nil}
  defp project_fallback([]), do: {:ok, []}

  defp project_fallback(list) when is_list(list) and length(list) <= @max_fallback do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_fallback_entry(entry) do
        {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp project_fallback(_), do: :error

  defp normalize_fallback_entry(entry) when is_map(entry) do
    with {:ok, canon} <- canonicalize_map_keys(entry),
         :ok <- require_only_keys(canon, MapSet.new(["provider", "model"])),
         provider when not is_nil(provider) <- Map.get(canon, "provider"),
         model when not is_nil(model) <- Map.get(canon, "model"),
         {:ok, provider_s} <- scalar_to_bound_string(provider, @max_id_bytes),
         {:ok, model_s} <- scalar_to_bound_string(model, @max_id_bytes) do
      {:ok, %{"provider" => provider_s, "model" => model_s}}
    else
      _ -> :error
    end
  end

  defp normalize_fallback_entry(_), do: :error

  defp scalar_to_bound_string(v, max) when is_binary(v), do: bound_bin_result(v, max)

  defp scalar_to_bound_string(v, max) when is_atom(v) and not is_nil(v) do
    bound_bin_result(Atom.to_string(v), max)
  end

  defp scalar_to_bound_string(_, _), do: :error

  # Runtime omission must stay omitted. Only explicit caller/model_config runtime
  # is projected; never default-insert :arbor (that would override profile/template ACP).
  defp project_runtime(opts, model_config) do
    case Keyword.fetch(opts, :runtime) do
      {:ok, raw} ->
        normalize_runtime(raw)

      :error ->
        case model_config && Map.get(model_config, "runtime") do
          nil -> {:ok, nil}
          raw -> normalize_runtime(raw)
        end
    end
  end

  defp optional_runtime(nil), do: {:ok, nil}
  defp optional_runtime(v), do: normalize_runtime(v)

  defp normalize_runtime(:arbor), do: {:ok, "arbor"}
  defp normalize_runtime(:acp), do: {:ok, "acp"}
  defp normalize_runtime("arbor"), do: {:ok, "arbor"}
  defp normalize_runtime("acp"), do: {:ok, "acp"}
  defp normalize_runtime(_), do: :error

  defp project_provider(opts, model_config) do
    raw =
      Keyword.get(opts, :provider) || (model_config && Map.get(model_config, "provider"))

    optional_provider(raw)
  end

  defp optional_provider(nil), do: {:ok, nil}
  defp optional_provider(v) when is_atom(v), do: bound_bin_result(Atom.to_string(v), @max_id_bytes)
  defp optional_provider(v) when is_binary(v), do: bound_bin_result(v, @max_id_bytes)
  defp optional_provider(_), do: :error

  defp project_model(opts, model_config) do
    raw = Keyword.get(opts, :model) || (model_config && Map.get(model_config, "model"))
    optional_bin(raw, @max_id_bytes)
  end

  defp project_system_prompt(nil), do: {:ok, nil}

  defp project_system_prompt(p) when is_binary(p) and byte_size(p) <= @max_prompt_bytes,
    do: if(String.valid?(p), do: {:ok, p}, else: :error)

  defp project_system_prompt(_), do: :error

  defp project_max_tokens(nil), do: {:ok, nil}

  defp project_max_tokens(n) when is_integer(n) and n > 0 and n <= 1_000_000, do: {:ok, n}
  defp project_max_tokens(_), do: :error

  defp project_bool_or_nil(nil), do: {:ok, nil}
  defp project_bool_or_nil(true), do: {:ok, true}
  defp project_bool_or_nil(false), do: {:ok, false}
  defp project_bool_or_nil(_), do: :error

  defp project_user_media(nil), do: :ok
  defp project_user_media([]), do: :ok
  defp project_user_media(_), do: :error

  defp project_temperature(nil), do: {:ok, nil}

  defp project_temperature(n) when is_number(n) and n >= 0.0 and n <= 2.0, do: {:ok, n}
  defp project_temperature(_), do: :error

  defp project_top_p(nil), do: {:ok, nil}
  defp project_top_p(n) when is_number(n) and n > 0.0 and n <= 1.0, do: {:ok, n}
  defp project_top_p(_), do: :error

  defp project_provider_options(nil), do: {:ok, nil}

  defp project_provider_options(map) when is_map(map) do
    # String-keyed map of scalars/nested maps — compatible with SessionConfig
    # llm_config "provider_options" passthrough. Keys are atom/binary only.
    project_provider_options_map(map, 2)
  end

  defp project_provider_options(_), do: :error

  defp project_provider_options_map(map, depth) when is_map(map) and depth >= 0 do
    if map_size(map) > @max_provider_opt_keys do
      :error
    else
      with {:ok, canon} <- canonicalize_map_keys(map) do
        Enum.reduce_while(canon, {:ok, %{}}, fn {key, v}, {:ok, acc} ->
          case scalarize(v, depth) do
            {:ok, val} -> {:cont, {:ok, Map.put(acc, key, val)}}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, m} -> {:ok, sort_map(m)}
          :error -> :error
        end
      end
    end
  end

  defp project_provider_options_map(_, _), do: :error

  defp scalarize(v, _depth) when is_binary(v), do: bound_bin_result(v, 1024)
  defp scalarize(v, _depth) when is_number(v), do: {:ok, v}
  defp scalarize(v, _depth) when is_boolean(v), do: {:ok, v}
  defp scalarize(v, _depth) when is_atom(v) and not is_nil(v), do: {:ok, Atom.to_string(v)}

  defp scalarize(map, depth) when is_map(map) and depth > 0 do
    project_provider_options_map(map, depth - 1)
  end

  defp scalarize(_, _), do: :error

  # ── Fail-closed map key canonicalization ───────────────────────────
  # Only bounded atom/binary keys. Atom/string forms of the same name are
  # duplicates → reject (no last-wins). Unsupported key types → reject.
  # Never calls to_string/1 on arbitrary terms (no crash on structs/tuples).

  @max_map_key_bytes 128

  defp canonicalize_map_keys(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case canonicalize_key(k) do
        {:ok, key} ->
          if Map.has_key?(acc, key) do
            {:halt, :error}
          else
            {:cont, {:ok, Map.put(acc, key, v)}}
          end

        :error ->
          {:halt, :error}
      end
    end)
  end

  defp canonicalize_map_keys(_), do: :error

  defp canonicalize_key(k) when is_atom(k) and not is_nil(k) do
    s = Atom.to_string(k)
    bound_bin_result(s, @max_map_key_bytes)
  end

  defp canonicalize_key(k) when is_binary(k) do
    bound_bin_result(k, @max_map_key_bytes)
  end

  defp canonicalize_key(_), do: :error

  defp require_only_keys(map, allowed) when is_map(map) do
    keys = map |> Map.keys() |> MapSet.new()

    if MapSet.subset?(keys, allowed), do: :ok, else: :error
  end

  defp project_path(nil), do: {:ok, nil}
  defp project_path(p) when is_binary(p), do: bound_bin_result(p, @max_path_bytes)
  defp project_path(_), do: :error

  defp project_context_management(:none), do: {:ok, "none"}
  defp project_context_management(:heuristic), do: {:ok, "heuristic"}
  defp project_context_management(:full), do: {:ok, "full"}
  defp project_context_management("none"), do: {:ok, "none"}
  defp project_context_management("heuristic"), do: {:ok, "heuristic"}
  defp project_context_management("full"), do: {:ok, "full"}
  defp project_context_management(_), do: :error

  defp project_effective_window(nil), do: {:ok, nil}

  defp project_effective_window(n) when is_integer(n) and n > 0 and n <= 10_000_000, do: {:ok, n}
  defp project_effective_window(_), do: :error

  defp project_sandbox(nil), do: {:ok, nil}

  defp project_sandbox(level) do
    coerced = SandboxLevel.coerce(level)
    {:ok, Atom.to_string(coerced)}
  rescue
    _ -> :error
  end

  defp projection_to_keyword(proj) do
    with {:ok, context_management} <-
           context_management_atom(Map.get(proj, "context_management", "full")) do
      kw =
        []
        |> maybe_kw(:principal_id, Map.get(proj, "principal_id"))
        |> maybe_kw_tenant(Map.get(proj, "tenant_context"))
        |> Keyword.put(:start_session, Map.get(proj, "start_session", true))
        |> Keyword.put(:start_heartbeat, Map.get(proj, "start_heartbeat", true))
        |> maybe_kw(:model, Map.get(proj, "model"))
        |> maybe_kw_provider(Map.get(proj, "provider"))
        # Only put :runtime when explicitly projected — never invent :arbor.
        |> maybe_kw_runtime(Map.get(proj, "runtime"))
        |> maybe_kw(:system_prompt, Map.get(proj, "system_prompt"))
        |> maybe_kw(:tools, Map.get(proj, "tools"))
        |> maybe_kw_fallback(Map.get(proj, "fallback_chain"))
        |> maybe_kw_model_config(Map.get(proj, "model_config"))
        |> maybe_kw(:max_tokens, Map.get(proj, "max_tokens"))
        |> maybe_kw(:stream, Map.get(proj, "stream"))
        |> maybe_kw(:temperature, Map.get(proj, "temperature"))
        |> maybe_kw(:top_p, Map.get(proj, "top_p"))
        |> maybe_kw(:provider_options, atomize_provider_options(Map.get(proj, "provider_options")))
        |> maybe_kw(:heartbeat_dot, Map.get(proj, "heartbeat_dot"))
        |> Keyword.put(:context_management, context_management)
        |> maybe_kw(:effective_window, Map.get(proj, "effective_window"))
        |> Keyword.put(:recover_session, Map.get(proj, "recover_session", true))
        |> maybe_kw_sandbox(Map.get(proj, "sandbox_level"))

      {:ok, kw}
    end
  end

  defp maybe_kw(kw, _k, nil), do: kw
  defp maybe_kw(kw, k, v), do: Keyword.put(kw, k, v)

  defp maybe_kw_runtime(kw, nil), do: kw

  defp maybe_kw_runtime(kw, runtime) when is_binary(runtime) do
    case runtime_atom(runtime) do
      {:ok, atom} -> Keyword.put(kw, :runtime, atom)
      :error -> kw
    end
  end

  defp maybe_kw_tenant(kw, nil), do: kw

  defp maybe_kw_tenant(kw, tenant) when is_map(tenant) do
    ctx =
      TenantContext.new(tenant["principal_id"],
        workspace_root: tenant["workspace_root"],
        display_name: tenant["display_name"],
        metadata: %{}
      )

    Keyword.put(kw, :tenant_context, ctx)
  end

  defp maybe_kw_provider(kw, nil), do: kw

  defp maybe_kw_provider(kw, provider) when is_binary(provider) do
    # Never String.to_atom/1. Prefer existing atom; otherwise keep binary representation.
    Keyword.put(kw, :provider, provider_value(provider))
  end

  defp provider_value(p) when is_binary(p) do
    case SafeAtom.to_existing(p) do
      {:ok, atom} -> atom
      {:error, _} -> p
    end
  end

  defp runtime_atom("arbor"), do: {:ok, :arbor}
  defp runtime_atom("acp"), do: {:ok, :acp}
  defp runtime_atom(_), do: :error

  defp context_management_atom(value) when is_binary(value) or is_atom(value) do
    SafeAtom.to_allowed(value, @context_management_atoms)
  end

  defp context_management_atom(_), do: :error

  defp maybe_kw_fallback(kw, nil), do: kw

  defp maybe_kw_fallback(kw, list) when is_list(list) do
    chain =
      Enum.map(list, fn %{"provider" => p, "model" => m} ->
        # Keep provider as accepted representation (atom if existing, else string).
        %{provider: provider_value(p), model: m}
      end)

    Keyword.put(kw, :fallback_chain, chain)
  end

  defp maybe_kw_model_config(kw, nil), do: kw

  defp maybe_kw_model_config(kw, cfg) when is_map(cfg) do
    mc =
      %{}
      |> maybe_map_put(:id, cfg["id"])
      |> maybe_map_put(:model, cfg["model"])
      |> maybe_map_put(:provider, cfg["provider"] && provider_value(cfg["provider"]))
      |> maybe_map_put(:runtime, model_config_runtime(cfg["runtime"]))
      |> maybe_map_put(
        :fallback_chain,
        cfg["fallback_chain"] &&
          Enum.map(cfg["fallback_chain"], fn %{"provider" => p, "model" => m} ->
            %{provider: provider_value(p), model: m}
          end)
      )

    Keyword.put(kw, :model_config, mc)
  end

  defp model_config_runtime(nil), do: nil

  defp model_config_runtime(runtime) when is_binary(runtime) do
    case runtime_atom(runtime) do
      {:ok, atom} -> atom
      :error -> nil
    end
  end

  defp maybe_map_put(map, _k, nil), do: map
  defp maybe_map_put(map, k, v), do: Map.put(map, k, v)

  defp maybe_kw_sandbox(kw, nil), do: kw

  defp maybe_kw_sandbox(kw, level) when is_binary(level) do
    Keyword.put(kw, :sandbox_level, SandboxLevel.coerce(level))
  end

  defp atomize_provider_options(nil), do: nil
  defp atomize_provider_options(map) when is_map(map), do: map

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp strip_nil_map(nil), do: nil

  defp strip_nil_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      other -> sort_map(other)
    end
  end

  defp sort_map(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
  end

  defp bound_bin(bin, max) when is_binary(bin) do
    if byte_size(bin) <= max and String.valid?(bin) and bin != "", do: :ok, else: :error
  end

  defp bound_bin(_, _), do: :error

  defp bound_bin_or_nil(nil, _), do: :ok
  defp bound_bin_or_nil(bin, max), do: bound_bin(bin, max)

  defp bound_bin_result(bin, max) do
    case bound_bin(bin, max) do
      :ok -> {:ok, bin}
      :error -> :error
    end
  end

  defp optional_bin(nil, _), do: {:ok, nil}
  defp optional_bin(bin, max) when is_binary(bin), do: bound_bin_result(bin, max)
  defp optional_bin(_, _), do: :error
end
