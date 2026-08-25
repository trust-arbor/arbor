defmodule Arbor.Agent.MessageFacade do
  @moduledoc false

  # Library-local implementation of authorized live-agent messaging.
  # Public entries are Arbor.Agent.send_message/4 and send_message_response/4,
  # which always pass fixed production collaborators. deliver/5 and deliver/6
  # accept funs only so unit tests can inject authorization and delivery faults
  # without ambient Process/Application hijacking.

  alias Arbor.Contracts.Pipeline.Response, as: PipelineResponse
  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Contracts.Session.UserMessage

  # The DEFAULT stays conservative. The CEILING is separate and larger: a human
  # chat turn waits on a model, and the ceiling previously equalled the default
  # — a strong sign it was never chosen as a bound, just inherited from it.
  #
  # `validate_timeout/1` REJECTS anything above the ceiling rather than clamping,
  # so `mix arbor.agent chat`'s own 60s default was an outright
  # `:invalid_timeout`. And 30s is genuinely too short here: the keyless
  # free-tier model takes 20–23s for the LLM call alone, before turn overhead,
  # so a real first reply was abandoned mid-flight as `:delivery_ambiguous`
  # while the turn was still running.
  #
  # Still bounded — an unbounded delivery ties up a caller indefinitely.
  @default_timeout_ms 30_000
  @max_timeout_ms 120_000
  @max_id_bytes 256
  @max_content_bytes 32_768
  @max_engagement_id_bytes 256
  @max_session_token_bytes 4096
  @session_token_absent :__session_token_absent__
  @proof_absent :__proof_absent__
  @allowed_opt_keys [:timeout, :session_token, :signed_request]
  # Whole-string positive allowlist for ids interpolated into
  # arbor://chat/agent/<target>. Equivalent to
  # \A(?:agent|human)_[A-Za-z0-9_-]+\z plus the 256-byte bound.
  @principal_id_re ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/

  # Denied secret-key *names* reject the channel even when the associated value
  # is blank, redacted, or nil — key presence alone fails closed.
  @denied_secret_keys MapSet.new([
                        :session_token,
                        "session_token",
                        :delivery_receipt,
                        "delivery_receipt",
                        :receipt,
                        "receipt",
                        :bearer_token,
                        "bearer_token"
                      ])

  @type error_reason ::
          :invalid_opts
          | :invalid_timeout
          | :invalid_caller_id
          | :invalid_agent_id
          | :invalid_message
          | :invalid_content
          | :invalid_sender
          | :invalid_engagement_id
          | :unauthorized
          | :delivery_ambiguous
          | :delivery_failed

  @type mode :: :text | :response

  @type collaborators :: %{
          required(:authorize) => (String.t(), String.t(), atom(), keyword() -> term()),
          required(:issue_receipt) => (String.t(), String.t(), atom(), keyword() -> term()),
          required(:discard_receipt) => (term() -> term()),
          required(:chat) => (term(), String.t(), keyword() -> term()),
          required(:chat_response) => (term(), String.t(), keyword() -> term()),
          required(:chat_authenticated) => (term(), String.t(), term(), keyword() -> term()),
          required(:chat_response_authenticated) => (term(), String.t(), term(), keyword() ->
                                                       term())
        }

  @doc false
  @spec deliver_text(String.t(), String.t(), UserMessage.t(), keyword()) ::
          {:ok, String.t()} | {:error, error_reason()}
  def deliver_text(caller_id, target_agent_id, message, opts \\ []) do
    deliver_with(caller_id, target_agent_id, message, opts, :text, production_collaborators())
  end

  @doc false
  @spec deliver_text(String.t(), String.t(), UserMessage.t(), keyword(), collaborators()) ::
          {:ok, String.t()} | {:error, error_reason()}
  def deliver_text(caller_id, target_agent_id, message, opts, collaborators)
      when is_map(collaborators) do
    deliver_with(caller_id, target_agent_id, message, opts, :text, collaborators)
  end

  @doc false
  @spec deliver_response(String.t(), String.t(), UserMessage.t(), keyword()) ::
          {:ok, PipelineResponse.t() | map()} | {:error, error_reason()}
  def deliver_response(caller_id, target_agent_id, message, opts \\ []) do
    deliver_with(
      caller_id,
      target_agent_id,
      message,
      opts,
      :response,
      production_collaborators()
    )
  end

  @doc false
  @spec deliver_response(String.t(), String.t(), UserMessage.t(), keyword(), collaborators()) ::
          {:ok, PipelineResponse.t() | map()} | {:error, error_reason()}
  def deliver_response(caller_id, target_agent_id, message, opts, collaborators)
      when is_map(collaborators) do
    deliver_with(caller_id, target_agent_id, message, opts, :response, collaborators)
  end

  @doc false
  # Ordinary-path test adapter: maps (authorize, chat) into the collaborator map.
  @spec deliver(
          String.t(),
          String.t(),
          UserMessage.t(),
          keyword(),
          (String.t(), String.t(), atom(), keyword() -> term()),
          (term(), String.t(), keyword() -> term())
        ) :: {:ok, String.t()} | {:error, error_reason()}
  def deliver(caller_id, target_agent_id, message, opts, authorize_fun, chat_fun)
      when is_function(authorize_fun, 4) and is_function(chat_fun, 3) do
    collaborators = %{
      authorize: authorize_fun,
      issue_receipt: fn _c, _r, _a, _o ->
        unexpected_collaborator_result(:issue_not_expected)
      end,
      discard_receipt: fn _receipt -> :ok end,
      chat: chat_fun,
      chat_response: fn msg, sender, chat_opts ->
        case chat_fun.(msg, sender, chat_opts) do
          {:ok, binary} when is_binary(binary) -> {:ok, %{text: binary}}
          other -> other
        end
      end,
      chat_authenticated: fn _m, _s, _receipt, _o ->
        unexpected_collaborator_result(:auth_chat_not_expected)
      end,
      chat_response_authenticated: fn _m, _s, _receipt, _o ->
        unexpected_collaborator_result(:auth_chat_not_expected)
      end
    }

    deliver_with(caller_id, target_agent_id, message, opts, :text, collaborators)
  end

  defp unexpected_collaborator_result(reason) do
    {:error, reason}
  end

  defp production_collaborators do
    %{
      authorize: &Arbor.Security.authorize/4,
      issue_receipt: &Arbor.Security.authorize_and_issue_delivery_receipt/4,
      discard_receipt: &Arbor.Security.discard_delivery_receipt/1,
      chat: &Arbor.Agent.Manager.chat/3,
      chat_response: &Arbor.Agent.Manager.chat_response/3,
      chat_authenticated: &Arbor.Agent.Manager.chat_authenticated/4,
      chat_response_authenticated: &Arbor.Agent.Manager.chat_response_authenticated/4
    }
  end

  defp deliver_with(caller_id, target_agent_id, message, opts, mode, collaborators) do
    with {:ok, timeout_ms, proof} <- validate_opts(opts),
         :ok <- validate_principal_id(caller_id, :invalid_caller_id),
         :ok <- validate_principal_id(target_agent_id, :invalid_agent_id),
         :ok <- validate_message_for_branch(message, caller_id, proof) do
      case proof do
        @proof_absent ->
          ordinary_path(
            caller_id,
            target_agent_id,
            message,
            timeout_ms,
            mode,
            collaborators
          )

        {_kind, _value} = proof ->
          authenticated_path(
            caller_id,
            target_agent_id,
            message,
            timeout_ms,
            proof,
            mode,
            collaborators
          )
      end
    end
  end

  defp ordinary_path(caller_id, target_agent_id, message, timeout_ms, mode, collaborators) do
    with :ok <-
           authorize_chat(
             collaborators.authorize,
             caller_id,
             target_agent_id,
             @session_token_absent
           ) do
      deliver_ordinary(collaborators, mode, message, caller_id, target_agent_id, timeout_ms)
    end
  end

  defp authenticated_path(
         caller_id,
         target_agent_id,
         message,
         timeout_ms,
         proof,
         mode,
         collaborators
       ) do
    resource = "arbor://chat/agent/" <> target_agent_id

    case issue_receipt(collaborators.issue_receipt, caller_id, resource, proof) do
      {:ok, receipt} ->
        secrets = secrets_for(proof, receipt)

        deliver_authenticated(
          collaborators,
          mode,
          message,
          caller_id,
          target_agent_id,
          timeout_ms,
          receipt,
          secrets
        )

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  # Only a session token is itself a bearer secret that must be scrubbed from
  # the turn. A signed request is a per-request proof, not a reusable credential,
  # and carries no value to redact here.
  defp secrets_for(proof, receipt) do
    bearer =
      case DeliveryReceipt.bearer_token(receipt) do
        {:ok, b} when is_binary(b) and byte_size(b) > 0 -> b
        _ -> nil
      end

    token =
      case proof do
        {:session_token, value} -> value
        _ -> nil
      end

    [token, bearer]
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 0))
  end

  defp validate_opts(opts) when not is_list(opts), do: {:error, :invalid_opts}

  defp validate_opts(opts) do
    # Keyword.keyword?/1 can raise on improper lists; fail closed.
    try do
      cond do
        not Keyword.keyword?(opts) ->
          {:error, :invalid_opts}

        has_duplicate_keys?(opts) ->
          {:error, :invalid_opts}

        true ->
          case Enum.reject(Keyword.keys(opts), &(&1 in @allowed_opt_keys)) do
            [] ->
              with {:ok, timeout_ms} <-
                     validate_timeout(Keyword.get(opts, :timeout, @default_timeout_ms)),
                   {:ok, proof} <- extract_proof_opt(opts) do
                {:ok, timeout_ms, proof}
              end

            _unknown ->
              {:error, :invalid_opts}
          end
      end
    rescue
      _ -> {:error, :invalid_opts}
    catch
      :exit, _ -> {:error, :invalid_opts}
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  # A human principal may prove itself in more than one way —
  # `Arbor.Security.authorize/4` lists `:signed_request` (per-request Ed25519)
  # and `:session_token` (HMAC session) as ALTERNATIVES.
  #
  # This previously branched on session-token presence alone, conflating "is
  # authenticated" with "authenticated by one specific mechanism". A caller
  # holding a perfectly good signed request fell into the ordinary branch and
  # was told it needed an `engagement_id` — which the authenticated path then
  # rejects, since it resolves the engagement itself. That left the CLI unable
  # to reach the authenticated path at all despite holding the operator key
  # `mix arbor.user.link` already signs with.
  #
  # Exactly one proof may be supplied. Two would leave which one authorized the
  # turn ambiguous.
  defp extract_proof_opt(opts) do
    token = Keyword.get_values(opts, :session_token)
    signed = Keyword.get_values(opts, :signed_request)

    case {token, signed} do
      {[], []} ->
        {:ok, @proof_absent}

      {[_ | _], [_ | _]} ->
        {:error, :invalid_opts}

      {[], [request]} ->
        {:ok, {:signed_request, request}}

      {[], _duplicates} ->
        {:error, :invalid_opts}

      {_token_values, []} ->
        case extract_session_token_opt(opts) do
          {:ok, @session_token_absent} -> {:ok, @proof_absent}
          {:ok, value} -> {:ok, {:session_token, value}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp extract_session_token_opt(opts) do
    case Keyword.get_values(opts, :session_token) do
      [] ->
        {:ok, @session_token_absent}

      [token]
      when is_binary(token) and byte_size(token) > 0 and
             byte_size(token) <= @max_session_token_bytes ->
        {:ok, token}

      [_invalid] ->
        {:error, :invalid_opts}

      _duplicates ->
        {:error, :invalid_opts}
    end
  end

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms,
       do: {:ok, timeout}

  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp validate_principal_id(id, error)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_id_bytes do
    if String.valid?(id) and Regex.match?(@principal_id_re, id) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_principal_id(_id, error), do: {:error, error}

  defp validate_message_for_branch(%UserMessage{} = message, caller_id, proof) do
    with :ok <- validate_content(message.content),
         :ok <- validate_sender(message.sender_id, caller_id) do
      case proof do
        @proof_absent ->
          validate_engagement_id_required(message.engagement_id)

        {_kind, _value} ->
          # Any accepted proof reaches the authenticated path, which resolves
          # the principal's canonical engagement itself and REJECTS a
          # caller-supplied one as a route claim.
          validate_engagement_id_nil(message.engagement_id)
      end
    end
  end

  defp validate_message_for_branch(_message, _caller_id, _session_token),
    do: {:error, :invalid_message}

  defp validate_content(content)
       when is_binary(content) and byte_size(content) > 0 and
              byte_size(content) <= @max_content_bytes do
    cond do
      not String.valid?(content) -> {:error, :invalid_content}
      String.trim(content) == "" -> {:error, :invalid_content}
      true -> :ok
    end
  end

  defp validate_content(_), do: {:error, :invalid_content}

  defp validate_sender(sender_id, caller_id) when sender_id === caller_id, do: :ok
  defp validate_sender(_sender_id, _caller_id), do: {:error, :invalid_sender}

  # Ordinary path: non-empty engagement required.
  defp validate_engagement_id_required(engagement_id)
       when is_binary(engagement_id) and byte_size(engagement_id) > 0 and
              byte_size(engagement_id) <= @max_engagement_id_bytes do
    cond do
      not String.valid?(engagement_id) -> {:error, :invalid_engagement_id}
      String.contains?(engagement_id, <<0>>) -> {:error, :invalid_engagement_id}
      String.trim(engagement_id) == "" -> {:error, :invalid_engagement_id}
      true -> :ok
    end
  end

  defp validate_engagement_id_required(_), do: {:error, :invalid_engagement_id}

  # Authenticated path: engagement_id must be exactly nil (route-free).
  defp validate_engagement_id_nil(nil), do: :ok
  defp validate_engagement_id_nil(_), do: {:error, :invalid_engagement_id}

  defp authorize_chat(authorize_fun, caller_id, target_agent_id, session_token) do
    resource = "arbor://chat/agent/" <> target_agent_id

    auth_opts =
      case session_token do
        @session_token_absent -> []
        token when is_binary(token) -> [session_token: token]
      end

    case authorize_fun.(caller_id, resource, :chat, auth_opts) do
      {:ok, :authorized} -> :ok
      {:ok, :pending_approval, _proposal_id} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :unauthorized}
      _other -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :throw, _ -> {:error, :unauthorized}
    :exit, _ -> {:error, :unauthorized}
  end

  # Forward the proof under its own option name so Security applies the right
  # verification: `:session_token` takes the HMAC path, `:signed_request` the
  # per-request Ed25519 path.
  defp issue_receipt(issue_fun, caller_id, resource, {kind, value}) do
    case issue_fun.(caller_id, resource, :chat, [{kind, value}]) do
      {:ok, %DeliveryReceipt{} = receipt} ->
        {:ok, receipt}

      {:ok, _other} ->
        {:error, :unauthorized}

      {:error, _reason} ->
        {:error, :unauthorized}

      _other ->
        {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :throw, _ -> {:error, :unauthorized}
    :exit, _ -> {:error, :unauthorized}
  end

  defp deliver_ordinary(collaborators, :text, message, caller_id, target_agent_id, timeout_ms) do
    case collaborators.chat.(message, caller_id, agent_id: target_agent_id, timeout: timeout_ms) do
      {:ok, reply} when is_binary(reply) ->
        {:ok, reply}

      {:ok, _non_binary} ->
        {:error, :delivery_failed}

      {:error, _reason} ->
        {:error, :delivery_failed}

      _other ->
        {:error, :delivery_failed}
    end
  rescue
    _ -> {:error, :delivery_failed}
  catch
    :throw, _ -> {:error, :delivery_failed}
    :exit, _ -> {:error, :delivery_failed}
  end

  defp deliver_ordinary(
         collaborators,
         :response,
         message,
         caller_id,
         target_agent_id,
         timeout_ms
       ) do
    case collaborators.chat_response.(message, caller_id,
           agent_id: target_agent_id,
           timeout: timeout_ms
         ) do
      {:ok, response} when is_map(response) ->
        {:ok, response}

      {:ok, _non_map} ->
        {:error, :delivery_failed}

      {:error, _reason} ->
        {:error, :delivery_failed}

      _other ->
        {:error, :delivery_failed}
    end
  rescue
    _ -> {:error, :delivery_failed}
  catch
    :throw, _ -> {:error, :delivery_failed}
    :exit, _ -> {:error, :delivery_failed}
  end

  defp deliver_authenticated(
         collaborators,
         mode,
         message,
         caller_id,
         target_agent_id,
         timeout_ms,
         receipt,
         secrets
       ) do
    opts = [agent_id: target_agent_id, timeout: timeout_ms]

    result =
      case mode do
        :text ->
          collaborators.chat_authenticated.(message, caller_id, receipt, opts)

        :response ->
          collaborators.chat_response_authenticated.(message, caller_id, receipt, opts)
      end

    admit_authenticated_result(result, mode, secrets, collaborators, receipt)
  rescue
    exception ->
      discard_receipt(collaborators, receipt)
      log_delivery_failure({:raised, Exception.message(exception)})
      {:error, :delivery_failed}
  catch
    :throw, value ->
      discard_receipt(collaborators, receipt)
      log_delivery_failure({:threw, value})
      {:error, :delivery_failed}

    :exit, reason ->
      discard_receipt(collaborators, receipt)
      log_delivery_failure({:exited, reason})
      {:error, :delivery_failed}
  end

  # `:delivery_failed` is returned for a raise, a throw, an exit, a non-binary
  # reply, and a sensitive-content rejection. Collapsing them is deliberate —
  # the CALLER must not learn which — but discarding the cause entirely left
  # nothing to diagnose from in any log, anywhere. Record it server-side while
  # the returned error stays uniform.
  defp log_delivery_failure(cause) do
    require Logger
    Logger.warning("[MessageFacade] authenticated delivery failed: #{inspect(cause, limit: 12)}")
  end

  defp admit_authenticated_result({:ok, reply}, :text, secrets, collaborators, receipt)
       when is_binary(reply) do
    case refute_sensitive(reply, secrets) do
      :ok ->
        emit_assistant_signal(reply)
        {:ok, reply}

      :reject ->
        discard_receipt(collaborators, receipt)
        log_delivery_failure(:reply_contained_a_delivery_secret)
        {:error, :delivery_failed}
    end
  end

  defp admit_authenticated_result(
         {:ok, %PipelineResponse{} = response},
         :response,
         secrets,
         collaborators,
         receipt
       ) do
    case admit_auth_response(response, secrets) do
      {:ok, projected} ->
        emit_assistant_signal(PipelineResponse.content(projected))
        {:ok, projected}

      :reject ->
        discard_receipt(collaborators, receipt)
        log_delivery_failure(:reply_contained_a_delivery_secret)
        {:error, :delivery_failed}
    end
  end

  # Text mode admits binaries only. Production Manager.chat_authenticated/4
  # extracts content from Pipeline.Response before returning.
  defp admit_authenticated_result({:ok, other}, _mode, _secrets, collaborators, receipt) do
    log_delivery_failure({:unexpected_ok_shape, other})
    discard_receipt(collaborators, receipt)
    {:error, :delivery_failed}
  end

  defp admit_authenticated_result(
         {:error, :delivery_ambiguous},
         _mode,
         _secrets,
         collaborators,
         receipt
       ) do
    discard_receipt(collaborators, receipt)
    {:error, :delivery_ambiguous}
  end

  defp admit_authenticated_result({:error, reason}, _mode, _secrets, collaborators, receipt) do
    log_delivery_failure({:session_error, reason})
    discard_receipt(collaborators, receipt)
    {:error, :delivery_failed}
  end

  defp admit_authenticated_result(other, _mode, _secrets, collaborators, receipt) do
    log_delivery_failure({:unexpected_result, other})
    discard_receipt(collaborators, receipt)
    {:error, :delivery_failed}
  end

  defp discard_receipt(collaborators, receipt) do
    _ = collaborators.discard_receipt.(receipt)
    :ok
  rescue
    _ -> :ok
  catch
    :throw, _ -> :ok
    :exit, _ -> :ok
  end

  # Assistant signal is emitted only after call-local secret admission succeeds,
  # so a malicious Session cannot surface proof/bearer via chat_message before reject.
  defp emit_assistant_signal(text) when is_binary(text) do
    Arbor.Signals.emit(:agent, :chat_message, %{
      role: :assistant,
      content: text,
      sender: "Agent"
    })

    :ok
  rescue
    _ -> :ok
  catch
    :throw, _ -> :ok
    :exit, _ -> :ok
  end

  defp emit_assistant_signal(_), do: :ok

  # ── Authenticated response admission (MessageFacade-only) ───────────

  defp admit_auth_response(%PipelineResponse{} = r, secrets) when is_list(secrets) do
    projected = %PipelineResponse{
      content: r.content,
      tool_history: r.tool_history,
      tool_rounds: r.tool_rounds,
      usage: r.usage,
      finish_reason: r.finish_reason,
      content_parts: r.content_parts,
      discovered_tools: r.discovered_tools,
      raw: nil,
      metadata: %{}
    }

    with :ok <- type_check_projected(projected),
         :ok <- refute_sensitive(projected, secrets) do
      {:ok, projected}
    else
      _ -> :reject
    end
  end

  defp admit_auth_response(_other, _secrets), do: :reject

  defp type_check_projected(%PipelineResponse{} = r) do
    cond do
      not is_binary(r.content) ->
        :reject

      not is_list(r.tool_history) ->
        :reject

      not (is_integer(r.tool_rounds) and r.tool_rounds >= 0) ->
        :reject

      not is_map(r.usage) ->
        :reject

      not (is_atom(r.finish_reason) or is_nil(r.finish_reason)) ->
        :reject

      not is_list(r.content_parts) ->
        :reject

      not is_list(r.discovered_tools) ->
        :reject

      true ->
        :ok
    end
  end

  defp refute_sensitive(term, secrets) when is_list(secrets) do
    secrets = Enum.filter(secrets, &(is_binary(&1) and byte_size(&1) > 0))
    do_refute_sensitive(term, secrets, MapSet.new())
  end

  defp do_refute_sensitive(%DeliveryReceipt{}, _secrets, _seen), do: :reject

  # Structs are maps but not Enumerable — always walk via Map.to_list/1.
  # Recursively scan BOTH keys and values so composite keys (tuple/list/struct)
  # cannot smuggle proof or receipt bearer material.
  defp do_refute_sensitive(term, secrets, seen) when is_map(term) do
    if MapSet.member?(seen, term) do
      :ok
    else
      seen = MapSet.put(seen, term)

      term
      |> Map.to_list()
      |> Enum.reduce_while(:ok, fn {k, v}, :ok ->
        cond do
          MapSet.member?(@denied_secret_keys, k) ->
            {:halt, :reject}

          true ->
            case do_refute_sensitive(k, secrets, seen) do
              :reject ->
                {:halt, :reject}

              :ok ->
                case do_refute_sensitive(v, secrets, seen) do
                  :ok -> {:cont, :ok}
                  :reject -> {:halt, :reject}
                end
            end
        end
      end)
    end
  end

  defp do_refute_sensitive(list, secrets, seen) when is_list(list) do
    if iodata_list?(list) do
      case safe_iodata_to_binary(list) do
        {:ok, bin} ->
          if contains_secret?(bin, secrets), do: :reject, else: :ok

        :error ->
          # Fall back to element-wise walk
          Enum.reduce_while(list, :ok, fn el, :ok ->
            case do_refute_sensitive(el, secrets, seen) do
              :ok -> {:cont, :ok}
              :reject -> {:halt, :reject}
            end
          end)
      end
    else
      Enum.reduce_while(list, :ok, fn el, :ok ->
        case do_refute_sensitive(el, secrets, seen) do
          :ok -> {:cont, :ok}
          :reject -> {:halt, :reject}
        end
      end)
    end
  end

  defp do_refute_sensitive(tuple, secrets, seen) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> do_refute_sensitive(secrets, seen)
  end

  defp do_refute_sensitive(bin, secrets, _seen) when is_binary(bin) do
    if contains_secret?(bin, secrets), do: :reject, else: :ok
  end

  defp do_refute_sensitive(_other, _secrets, _seen), do: :ok

  defp contains_secret?(_haystack, []), do: false

  defp contains_secret?(haystack, secrets) when is_binary(haystack) do
    Enum.any?(secrets, fn secret ->
      byte_size(secret) > 0 and :binary.match(haystack, secret) != :nomatch
    end)
  end

  defp iodata_list?([]), do: true

  defp iodata_list?([h | t]) when is_binary(h) or is_integer(h), do: iodata_list?(t)

  defp iodata_list?([h | t]) when is_list(h), do: iodata_list?(h) and iodata_list?(t)

  defp iodata_list?(_), do: false

  defp safe_iodata_to_binary(iodata) do
    {:ok, IO.iodata_to_binary(iodata)}
  rescue
    _ -> :error
  catch
    :throw, _ -> :error
    :exit, _ -> :error
  end
end
