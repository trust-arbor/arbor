defmodule Arbor.Security.InvocationAudit do
  @moduledoc false
  # Process-local provenance, never supplied through action params or Engine context.
  # The host and loaded BEAM are trusted; this is not an isolation boundary against
  # arbitrary code executing inside the VM. The configured sink owns durability.
  alias Arbor.Security.Config
  require Logger

  @active_key {__MODULE__, :active}
  @max_id_bytes 256

  def run(attributes, fun) when is_map(attributes) and is_function(fun, 0) do
    case Config.invocation_audit_mode() do
      :disabled -> fun.()
      :required -> run_required(attributes, fun)
      _ -> {:error, :invocation_audit_unavailable}
    end
  end

  defp run_required(attributes, fun) do
    parent = Process.get(@active_key)
    id = "inv_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    current = %{
      "invocation_id" => id,
      "parent_invocation_id" => parent && parent["invocation_id"],
      "principal_id" => identifier(attributes[:principal_id]),
      "surface" => surface(attributes[:surface]),
      "tool" => identifier(attributes[:tool]),
      "execution_id" => identifier(attributes[:execution_id]),
      "session_id" => identifier(attributes[:session_id]),
      "task_id" => identifier(attributes[:task_id]),
      "provider_call_id" => identifier(attributes[:provider_call_id]),
      "destination" => destination(attributes[:destination]),
      "sequence" => 0
    }

    with :ok <- persist(event(current, "attempt", %{})) do
      Process.put(@active_key, current)

      try do
        result = fun.()
        status = finish(result)
        if status != :ok, do: report_gap(id, status)
        # An acknowledged effect is not rolled back by a later storage failure.
        # Durable attempt without outcome is explicitly indeterminate on read.
        if status != :ok and result == :authorized,
          do: {:error, :invocation_audit_unavailable},
          else: result
      catch
        kind, reason ->
          _ = finish({:error, :execution_interrupted})
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        if parent, do: Process.put(@active_key, parent), else: Process.delete(@active_key)
      end
    else
      _ -> {:error, :invocation_audit_unavailable}
    end
  end

  def observe_authorization(result, principal_id, resource) do
    case Process.get(@active_key) do
      nil ->
        result

      current ->
        next = Map.update!(current, "sequence", &(&1 + 1))
        Process.put(@active_key, next)

        decision =
          case result do
            {:ok, :authorized} -> "allowed"
            {:ok, :authorized, _} -> "allowed"
            {:ok, :pending_approval, _} -> "approval_required"
            _ -> "refused"
          end

        data = %{
          "decision" => decision,
          "checked_principal_id" => identifier(principal_id),
          "resource_digest" => digest(resource)
        }

        case persist(event(next, "authorization", data)) do
          :ok -> result
          _ -> {:error, :invocation_audit_unavailable}
        end
    end
  end

  def current_id do
    case Process.get(@active_key) do
      %{"invocation_id" => id} -> id
      _ -> nil
    end
  end

  def admit_effect do
    case Process.get(@active_key) do
      nil ->
        if Config.invocation_audit_mode() == :disabled,
          do: :ok,
          else: {:error, :invocation_audit_unavailable}

      current ->
        next = current |> Map.update!("sequence", &(&1 + 1)) |> Map.put("effect_started", true)

        with :ok <- persist(event(next, "effect_admitted", %{})) do
          Process.put(@active_key, next)
          :ok
        end
    end
  end

  defp finish(result) do
    current = Process.get(@active_key)

    outcome =
      case result do
        {:ok, :pending_approval, _} -> "approval_required"
        {:ok, _, _} -> "completed"
        {:ok, _} -> "completed"
        :ok -> "completed"
        :authorized -> "permission_allowed"
        {:denied, _} -> "refused"
        {:error, :execution_interrupted} -> "interrupted"
        {:error, _} -> if(current["effect_started"], do: "failed", else: "refused")
        _ -> "unknown"
      end

    persist(event(current, "outcome", %{"outcome" => outcome}))
  end

  defp event(current, stage, data) do
    current
    |> Map.delete("effect_started")
    |> Map.put("schema", "arbor.security.invocation.v1")
    |> Map.put(
      "id",
      current["invocation_id"] <> ":" <> stage <> ":" <> to_string(current["sequence"])
    )
    |> Map.put("stage", stage)
    |> Map.put("timestamp", DateTime.to_iso8601(DateTime.utc_now()))
    |> Map.merge(data)
  end

  defp persist(event) do
    sink = Config.invocation_audit_sink()

    with true <- is_atom(sink) and not is_nil(sink),
         true <- Code.ensure_loaded?(sink),
         true <- function_exported?(sink, :persist_security_invocation, 1),
         {:ok, id} <- apply(sink, :persist_security_invocation, [event]),
         true <- id == event["id"] do
      :ok
    else
      _ -> {:error, :invocation_audit_unavailable}
    end
  rescue
    _ -> {:error, :invocation_audit_unavailable}
  catch
    _, _ -> {:error, :invocation_audit_unavailable}
  end

  defp report_gap(id, _status) do
    Logger.error("Security invocation #{id}: known result returned with degraded terminal audit")

    :telemetry.execute([:arbor, :security, :invocation_audit_degraded], %{count: 1}, %{
      invocation_id: id
    })
  end

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..@max_id_bytes do
    if String.valid?(value), do: value, else: nil
  end

  defp identifier(value) when is_atom(value) and not is_nil(value),
    do: identifier(Atom.to_string(value))

  defp identifier(_), do: nil

  defp surface(value) when value in [:action, :acp_permission, :acp_file, :tool],
    do: Atom.to_string(value)

  defp surface(_), do: "unknown"

  # Query, userinfo, fragments and file paths can contain secrets. Keep only a
  # remote origin and a digest; no argument or tool output preview is recorded.
  defp destination(value) when is_binary(value) and byte_size(value) <= 8_192 do
    uri = URI.parse(value)

    origin =
      if uri.scheme in ["http", "https"] and is_binary(uri.host),
        do: URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port}),
        else: nil

    %{"origin" => origin, "digest" => digest(value)}
  rescue
    _ -> nil
  end

  defp destination(_), do: nil

  defp digest(value) when is_binary(value) and byte_size(value) <= 16_384,
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp digest(_), do: nil
end
