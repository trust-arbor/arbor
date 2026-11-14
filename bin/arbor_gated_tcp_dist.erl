%% Gated IPv4 TCP distribution carrier for the Arbor dev daemon.
%%
%% Selected with `-proto_dist arbor_gated_tcp` by bin/arbor-dev-daemon-launch.
%% The daemon boots with `-nocookie` and no node name, so distribution is not
%% running at boot. bin/arbor-gated-dist-bootstrap.exs compiles this file in
%% memory, starts distribution, sets the real cookie and only then opens the
%% gate. Between `net_kernel:start/2` and `erlang:set_cookie/1` the node's
%% cookie is the public atom `nocookie`; the gate makes that window refuse
%% every peer.
%%
%% Every export delegates unchanged to inet_tcp_dist, and the export list is
%% exactly inet_tcp_dist's (a test asserts this), so net_kernel's optional
%% `try Mod:F(...) catch error:undef` probes see the same surface. The only
%% difference: functions that receive net_kernel's `Allowed` list get a list
%% holding one name no peer can present while the gate is closed. dist_util
%% then answers `not_allowed` at the name stage of the handshake, before it
%% sends a cookie challenge.
%%
%% This file is deliberately outside every Mix source path. It is compiled
%% and loaded once, by the bootstrap, before Mix exists, so no later Mix
%% compile or code reload redefines the module under a running net_kernel.
-module(arbor_gated_tcp_dist).

%% Distribution module callbacks (mirrors inet_tcp_dist).
-export([listen/1, listen/2, accept/1, accept_connection/5,
         setup/5, close/1, select/1, address/0, is_node_name/1]).
-export([setopts/2, getopts/2]).
-export([gen_listen/3, gen_accept/2, gen_accept_connection/6,
         gen_setup/6, gen_select/2, gen_address/1]).
-export([fam_select/2, fam_address/1, fam_listen/4, fam_setup/4]).
-export([gen_hs_data/2, nodelay/0]).
-export([merge_options/2, merge_options/3]).
-export([accept_loop/3, do_accept/7, do_setup/7, getstat/1, tick/2]).

-define(INNER, inet_tcp_dist).
-define(GATE_KEY, {arbor_gated_dist, gate}).
%% Three `@`-separated parts: dist_util:split_node/1 classifies this as
%% invalid, and dist_util:is_allowed/2 compares a peer's name (a string)
%% against it, never an atom, so no handshake name can match it.
-define(CLOSED_ALLOWED, ['arbor_gated_dist@gate_closed@invalid']).

gate_allowed(Allowed) ->
    case persistent_term:get(?GATE_KEY, closed) of
        open -> Allowed;
        _ -> ?CLOSED_ALLOWED
    end.

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    ?INNER:accept_connection(AcceptPid, Socket, MyNode,
                             gate_allowed(Allowed), SetupTime).

gen_accept_connection(Driver, AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    ?INNER:gen_accept_connection(Driver, AcceptPid, Socket, MyNode,
                                 gate_allowed(Allowed), SetupTime).

do_accept(Driver, Kernel, AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    ?INNER:do_accept(Driver, Kernel, AcceptPid, Socket, MyNode,
                     gate_allowed(Allowed), SetupTime).

listen(Name) -> ?INNER:listen(Name).
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
gen_listen(Driver, Name, Host) -> ?INNER:gen_listen(Driver, Name, Host).
gen_accept(Driver, Listen) -> ?INNER:gen_accept(Driver, Listen).
gen_setup(Driver, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    ?INNER:gen_setup(Driver, Node, Type, MyNode, LongOrShortNames, SetupTime).
gen_select(Driver, Node) -> ?INNER:gen_select(Driver, Node).
gen_address(Driver) -> ?INNER:gen_address(Driver).
fam_select(Family, Node) -> ?INNER:fam_select(Family, Node).
fam_address(Family) -> ?INNER:fam_address(Family).
fam_listen(Family, Name, Host, ListenFun) ->
    ?INNER:fam_listen(Family, Name, Host, ListenFun).
fam_setup(Family, Node, LongOrShortNames, ParseAddress) ->
    ?INNER:fam_setup(Family, Node, LongOrShortNames, ParseAddress).
gen_hs_data(Driver, Socket) -> ?INNER:gen_hs_data(Driver, Socket).
nodelay() -> ?INNER:nodelay().
merge_options(Opts, ForcedOpts) -> ?INNER:merge_options(Opts, ForcedOpts).
merge_options(Opts, ForcedOpts, DefaultOpts) ->
    ?INNER:merge_options(Opts, ForcedOpts, DefaultOpts).
accept_loop(Driver, Kernel, Listen) -> ?INNER:accept_loop(Driver, Kernel, Listen).
do_setup(Driver, Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    ?INNER:do_setup(Driver, Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime).
getstat(Socket) -> ?INNER:getstat(Socket).
tick(Driver, Socket) -> ?INNER:tick(Driver, Socket).
