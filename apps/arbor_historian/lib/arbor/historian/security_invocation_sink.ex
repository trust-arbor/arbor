defmodule Arbor.Historian.SecurityInvocationSink do
  @moduledoc false
  alias Arbor.Historian.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  @stages ~w(attempt authorization effect_admitted outcome)
  @keys ~w(schema id invocation_id parent_invocation_id principal_id surface tool execution_id session_id task_id provider_call_id destination sequence stage timestamp decision checked_principal_id resource_digest outcome)

  def persist(data) when is_map(data) do
    with :ok <- validate(data),
         {:ok, timestamp, 0} <- DateTime.from_iso8601(data["timestamp"]),
         {:ok, target} <- durable_target() do
      stream = stream(data["invocation_id"])

      submitted =
        Event.new(stream, "security.invocation." <> data["stage"], data,
          id: data["id"],
          timestamp: timestamp,
          agent_id: data["principal_id"],
          correlation_id: data["invocation_id"],
          causation_id: data["parent_invocation_id"]
        )

      case Persistence.append(target.name, target.backend, stream, submitted, target.opts) do
        {:ok, [committed]} ->
          if Persistence.committed_event_matches_submission?(stream, submitted, committed),
            do: {:ok, submitted.id},
            else: {:error, :invocation_audit_unavailable}

        _ ->
          # Append may have committed before its acknowledgment was lost.
          # Reobserve full content and assigned positions, not just an ID.
          reconcile(target, stream, submitted)
      end
    else
      _ -> {:error, :invocation_audit_unavailable}
    end
  rescue
    _ -> {:error, :invocation_audit_unavailable}
  catch
    _, _ -> {:error, :invocation_audit_unavailable}
  end

  def persist(_), do: {:error, :invocation_audit_unavailable}

  def read(id) do
    with true <- valid_id?(id),
         {:ok, target} <- durable_target(),
         {:ok, events} <-
           Persistence.read_stream(
             target.name,
             target.backend,
             stream(id),
             Keyword.put(target.opts, :limit, 256)
           ) do
      outcome = Enum.find(events, &(&1.type == "security.invocation.outcome"))

      {:ok,
       %{
         invocation_id: id,
         outcome: if(outcome, do: outcome.data["outcome"], else: "indeterminate"),
         events: events
       }}
    else
      _ -> {:error, :invocation_audit_unavailable}
    end
  rescue
    _ -> {:error, :invocation_audit_unavailable}
  catch
    _, _ -> {:error, :invocation_audit_unavailable}
  end

  def identity do
    with {:ok, target} <- durable_target() do
      modules = [
        __MODULE__,
        Arbor.Historian,
        Config,
        target.backend,
        Arbor.Persistence,
        Arbor.Persistence.Event
      ]

      implementation =
        Enum.map(Enum.uniq(modules), fn module ->
          Code.ensure_loaded!(module)

          %{
            "module" => Atom.to_string(module),
            "loaded_md5" => Base.encode16(module.module_info(:md5), case: :lower)
          }
        end)

      {:ok,
       %{
         "schema" => "arbor.security.audit.identity.v1",
         "durability" => "node_restart",
         "target" => Atom.to_string(target.name),
         "backend" => Atom.to_string(target.backend),
         "repo" => inspect(Keyword.get(target.opts, :repo)),
         "implementation" => implementation
       }}
    end
  rescue
    _ -> {:error, :invocation_audit_unavailable}
  catch
    _, _ -> {:error, :invocation_audit_unavailable}
  end

  defp durable_target do
    with {:ok, target} <- Config.durable_event_log_target(),
         {:ok, :node_restart} <-
           Persistence.durability_class(target.name, target.backend, target.opts) do
      {:ok, target}
    else
      _ -> {:error, :invocation_audit_unavailable}
    end
  end

  defp reconcile(target, stream, submitted) do
    case Persistence.read_stream(
           target.name,
           target.backend,
           stream,
           Keyword.put(target.opts, :limit, 256)
         ) do
      {:ok, events} ->
        if Enum.any?(
             events,
             &Persistence.committed_event_matches_submission?(stream, submitted, &1)
           ), do: {:ok, submitted.id}, else: {:error, :invocation_audit_unavailable}

      _ ->
        {:error, :invocation_audit_unavailable}
    end
  end

  defp validate(data) do
    if data["schema"] == "arbor.security.invocation.v1" and
         valid_id?(data["invocation_id"]) and data["stage"] in @stages and
         is_integer(data["sequence"]) and data["sequence"] in 0..255 and
         data["id"] ==
           data["invocation_id"] <> ":" <> data["stage"] <> ":" <> to_string(data["sequence"]) and
         Enum.all?(Map.keys(data), &(&1 in @keys)) and
         byte_size(Jason.encode!(data)) <= 8_192,
       do: :ok,
       else: {:error, :invalid_invocation_event}
  end

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/\Ainv_[0-9a-f]{32}\z/, id)
  defp valid_id?(_), do: false
  defp stream(id), do: "security:invocation:" <> id
end
