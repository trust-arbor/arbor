defmodule Arbor.Client do
  @moduledoc """
  Public facade for Arbor's standalone authenticated Gateway client.

  The client owns transport and wire encoding. The caller owns conversation
  state, operation serialization, reconnect decisions, and lookup before retry.
  The Gateway owns identity, capabilities, engagement binding, and admission.

  Device login returns a redacted `Arbor.Client.Login.Pending` followed by an
  in-memory `Arbor.Client.Login.Session`. Poll at the pending receipt's interval
  and pass the session to `start_link/1`. Never persist or render its credential.
  Signed-key clients instead pass an identity loaded with `load_key/1`.

  A socket requires `owner: self()` and `gateway_url:`. Only that process may
  send. Owner messages carry the exact socket pid so the caller can fence stale
  generations. `send_frame/3` takes an absolute monotonic millisecond deadline;
  `close/1` returns `:ok` only after that generation has exited. Network failures
  retain the bounded error results of the underlying transport.

  The established `Login`, `Socket`, `Signer`, and `Protocol` modules remain
  available for compatibility. New integrations can use this facade.
  """

  alias Arbor.Client.{Login, Management, Protocol, Signer, Socket}

  # Discovery and lifecycle commands require an explicit signed identity;
  # human conversation sessions intentionally have no operator authority.
  defdelegate list_agents(identity, gateway_url, opts \\ []), to: Management
  defdelegate resolve_agent(identity, gateway_url, token, opts \\ []), to: Management
  defdelegate list_aliases(identity, gateway_url, opts \\ []), to: Management
  defdelegate set_alias(identity, gateway_url, name, target, opts \\ []), to: Management
  defdelegate remove_alias(identity, gateway_url, name, opts \\ []), to: Management
  defdelegate create_agent(identity, gateway_url, params, opts \\ []), to: Management
  defdelegate start_agent(identity, gateway_url, target, opts \\ []), to: Management
  defdelegate stop_agent(identity, gateway_url, target, opts \\ []), to: Management

  @doc "Validate the existing destination policy and return its public HTTP origin."
  def gateway_origin(url, policy \\ :session)

  def gateway_origin(url, policy) when policy in [:signed, :session] do
    with {:ok, uri} <- Arbor.Client.Endpoint.parse(url, policy), do: {:ok, URI.to_string(uri)}
  end

  def gateway_origin(_, _), do: {:error, :unsafe_gateway_url}

  defdelegate start_login(gateway_url, target), to: Login, as: :start
  defdelegate poll_login(gateway_url, handle), to: Login, as: :poll
  defdelegate cancel_login(gateway_url, handle), to: Login, as: :cancel
  defdelegate logout(gateway_url, session_or_credential), to: Login
  defdelegate normalize_session(session), to: Login, as: :session

  defdelegate start_link(options), to: Socket
  defdelegate send_frame(socket, text), to: Socket
  defdelegate send_frame(socket, text, deadline), to: Socket
  defdelegate close(socket), to: Socket
  defdelegate max_message_bytes(), to: Socket
  defdelegate max_fragments(), to: Socket

  defdelegate load_key(path), to: Signer
  defdelegate parse_key(contents), to: Signer
  defdelegate authorization_header(identity, method, path), to: Signer
  defdelegate authorization_header(identity, method, path, body), to: Signer
  defdelegate authorization_for_payload(identity, payload), to: Signer

  defdelegate encode(command), to: Protocol
  defdelegate decode(frame), to: Protocol

  def conversation_payload(operation, caller, target, input, options \\ []),
    do: Protocol.conversation_payload(operation, caller, target, input, options)

  def conversation_window_payload(caller, target, options \\ []),
    do: Protocol.conversation_window_payload(caller, target, options)

  @doc "Encode a bounded notice read; expected_engagement_id is required in options."
  def conversation_notices_payload(caller, target, options \\ []),
    do: Protocol.conversation_payload(:notices, caller, target, nil, options)

  @doc "Validate a notice page against an established scope; this grants no authority."
  def decode_notice_page(page, expected_scope \\ %{}),
    do: Arbor.Client.NoticePage.decode(page, expected_scope)

  def signed_operation(identity, target, operation, input, options \\ []),
    do: Protocol.signed_operation(identity, target, operation, input, options)

  def session_operation(caller, target, operation, input, options \\ []),
    do: Protocol.session_operation(caller, target, operation, input, options)
end
