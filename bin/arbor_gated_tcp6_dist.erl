%% Gated IPv6 TCP distribution carrier for the Arbor dev daemon.
%%
%% Selected with `-proto_dist arbor_gated_tcp6` when the daemon binds the IPv6
%% loopback. Same contract as arbor_gated_tcp_dist.erl (read that header): an
%% exact mirror of inet6_tcp_dist's exports, with the `Allowed` list replaced
%% by an unmatchable name until the bootstrap opens the shared gate.
-module(arbor_gated_tcp6_dist).

%% Distribution module callbacks (mirrors inet6_tcp_dist).
-export([listen/2, accept/1, accept_connection/5,
         setup/5, close/1, select/1, address/0, is_node_name/1]).
-export([setopts/2, getopts/2]).

-define(INNER, inet6_tcp_dist).
-define(GATE_KEY, {arbor_gated_dist, gate}).
-define(CLOSED_ALLOWED, ['arbor_gated_dist@gate_closed@invalid']).

gate_allowed(Allowed) ->
    case persistent_term:get(?GATE_KEY, closed) of
        open -> Allowed;
        _ -> ?CLOSED_ALLOWED
    end.

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    ?INNER:accept_connection(AcceptPid, Socket, MyNode,
                             gate_allowed(Allowed), SetupTime).

listen(Name, Host) -> ?INNER:listen(Name, Host).
accept(Listen) -> ?INNER:accept(Listen).
setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    ?INNER:setup(Node, Type, MyNode, LongOrShortNames, SetupTime).
close(Socket) -> ?INNER:close(Socket).
select(Node) -> ?INNER:select(Node).
address() -> ?INNER:address().
is_node_name(Node) -> ?INNER:is_node_name(Node).
setopts(Socket, Opts) -> ?INNER:setopts(Socket, Opts).
getopts(Socket, Opts) -> ?INNER:getopts(Socket, Opts).
