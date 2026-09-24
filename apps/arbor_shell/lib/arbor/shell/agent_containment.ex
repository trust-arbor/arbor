defmodule Arbor.Shell.AgentContainment do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security

  @max_path_bytes 4096
  @max_capabilities 256
  @protected ~r{(?:^|/)(?:\.ssh|\.aws|\.azure|\.gnupg|\.claude|\.codex|\.agents|\.config|\.arbor|\.git|\.kube|\.docker|\.netrc|\.npmrc|\.pypirc|\.env(?:\.[^/]*)?|credentials(?:\.[^/]*)?|secrets?(?:\.[^/]*)?|id_rsa|id_ed25519)(?:/|$)|/Library/(?:Keychains|Application Support)(?:/|$)}

  # Admission is re-evaluated for each invocation. A live child's kernel policy
  # is immutable; capability revocation does not retroactively kill that child.
  def admit(agent, prepared, opts) do
    with :ok <- qualified_platform(),
         {:ok, cwd} <- canonical_directory(Keyword.get(opts, :cwd)),
         false <- protected?(cwd),
         {:ok, caps} when is_list(caps) and length(caps) <= @max_capabilities <-
           Security.list_capabilities(agent),
         {:ok, authorizer} <- filesystem_authorizer(),
         :ok <- authorize_root(agent, cwd, :read, caps, authorizer, opts),
         :ok <- authorize_write(agent, cwd, prepared.command_name, caps, authorizer, opts) do
      {:ok, %{cwd: cwd, write: prepared.command_name == "touch"}}
    else
      true -> {:error, :agent_filesystem_protected}
      {:error, _} = error -> error
      _ -> {:error, :agent_filesystem_authority_unavailable}
    end
  rescue
    _ -> {:error, :agent_filesystem_authority_unavailable}
  catch
    _, _ -> {:error, :agent_filesystem_authority_unavailable}
  end

  def qualified_platform do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> {:error, {:agent_containment_unavailable, :platform_not_qualified}}
    end
  end

  # The projection is constructed only above. Lower native entry points remain
  # trusted host internals, like execute_direct; this is not a bearer credential.
  def validate_projection(%{cwd: cwd, write: write} = plan, actual_cwd)
      when map_size(plan) == 2 and is_boolean(write) and cwd == actual_cwd do
    with :ok <- qualified_platform(),
         {:ok, ^cwd} <- canonical_directory(cwd),
         false <- protected?(cwd) do
      :ok
    else
      _ -> {:error, :invalid_agent_containment}
    end
  end

  def validate_projection(_, _), do: {:error, :invalid_agent_containment}

  defp authorize_write(agent, cwd, "touch", caps, authorizer, opts),
    do: authorize_root(agent, cwd, :write, caps, authorizer, opts)

  defp authorize_write(_agent, _cwd, _command, _caps, _authorizer, _opts), do: :ok

  defp authorize_root(agent, cwd, operation, caps, authorizer, opts) do
    uri = "arbor://fs/#{operation}#{cwd}"

    candidate =
      Enum.find(caps, fn cap ->
        ordinary?(cap, agent) and covering_directory?(cap.resource_uri, operation, cwd) and
          Security.capability_authorizes?(cap, uri)
      end)

    with %{id: id} <- candidate,
         {:ok, :authorized} <- authorizer.authorize_filesystem(agent, uri, operation, id, opts),
         # Re-read the exact stored grant after the Trust callback. It cannot
         # substitute a broader minted grant, stale copy, or caller projection.
         {:ok, current} <- Security.list_capabilities(agent),
         %{id: ^id} = cap <- Enum.find(current, &(&1.id == id)),
         true <- ordinary?(cap, agent) and covering_directory?(cap.resource_uri, operation, cwd),
         true <- Security.capability_authorizes?(cap, uri),
         {:ok, :authorized} <-
           Security.authorize_source_owned_selected_ordinary_capability(
             agent,
             uri,
             :execute,
             id,
             payload_digest(cap)
           ) do
      :ok
    else
      _ -> {:error, :agent_filesystem_unauthorized}
    end
  end

  defp payload_digest(cap) do
    :crypto.hash(:sha256, Capability.signing_payload(cap))
    |> Base.encode16(case: :lower)
  end

  defp ordinary?(cap, agent) do
    cap.principal_id == agent and cap.parent_capability_id == nil and
      cap.delegation_chain == [] and cap.constraints == %{} and cap.max_uses == nil and
      cap.session_id == nil and cap.task_id == nil and cap.principal_scope == nil and
      is_binary(cap.issuer_signature) and byte_size(cap.issuer_signature) == 64
  end

  defp covering_directory?(uri, operation, cwd) when is_binary(uri) do
    prefix = "arbor://fs/#{operation}"

    with true <- String.starts_with?(uri, prefix <> "/"),
         true <- String.ends_with?(uri, "/**"),
         root <- uri |> String.replace_prefix(prefix, "") |> String.trim_trailing("/**"),
         false <- String.contains?(root, ["*", "?", "#", "%", "\\"]),
         {:ok, ^root} <- canonical_directory(root) do
      cwd == root or String.starts_with?(cwd, root <> "/")
    else
      _ -> false
    end
  end

  defp covering_directory?(_, _, _), do: false

  defp canonical_directory(path) when is_binary(path) and byte_size(path) in 2..@max_path_bytes do
    with true <- String.valid?(path) and not Regex.match?(~r/[\x00-\x1f\x7f]/, path),
         true <- Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, ^path} <- SafePath.resolve_real(path),
         {:ok, %File.Stat{type: :directory}} <- File.stat(path) do
      {:ok, path}
    else
      _ -> {:error, :agent_workdir_required}
    end
  end

  defp canonical_directory(_), do: {:error, :agent_workdir_required}
  defp protected?(path), do: Regex.match?(@protected, path)

  defp filesystem_authorizer do
    case Application.get_env(:arbor_shell, :agent_authorizer) do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :authorize_filesystem, 5),
          do: {:ok, module},
          else: {:error, :agent_filesystem_authorizer_unavailable}

      _ ->
        {:error, :agent_filesystem_authorizer_unavailable}
    end
  end
end
