-module(grpcbox_channel).

-behaviour(gen_statem).

-export([start_link/3,
         is_ready/1,
         pick/2,
         stop/1]).
-export([init/1,
         callback_mode/0,
         terminate/3,
         connected/3,
         idle/3]).

-include("grpcbox.hrl").

-type t() :: any().
-type name() :: t().
-type transport() :: http | https.
-type host() :: inet:ip_address() | inet:hostname().
-type endpoint() :: {transport(), host(), inet:port_number(), ssl:ssl_option()}.

-type options() :: #{balancer => load_balancer(),
                     encoding => gprcbox:encoding(),
                     unary_interceptor => grpcbox_client:unary_interceptor(),
                     stream_interceptor => grpcbox_client:stream_interceptor(),
                     stats_handler => module(),
                     sync_start => boolean()}.
-type load_balancer() :: round_robin | random | hash | direct | claim.
-export_type([t/0,
              name/0,
              options/0,
              endpoint/0]).

-record(data, {endpoints :: [endpoint()],
               pool :: atom(),
               resolver :: module(),
               balancer :: grpcbox:balancer(),
               encoding :: grpcbox:encoding(),
               workers = [] :: [pid()],
               interceptors :: #{unary_interceptor => grpcbox_client:unary_interceptor(),
                                 stream_interceptor => grpcbox_client:stream_interceptor()}
                             | undefined,
               stats_handler :: module() | undefined,
               refresh_interval :: timer:time()}).

-spec start_link(name(), [endpoint()], options()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Name, Endpoints, Options) ->
    gen_statem:start_link({local, Name}, ?MODULE, [Name, Endpoints, Options], []).

-spec is_ready(name()) -> boolean().
is_ready(Name) ->
    gen_statem:call(Name, is_ready).

%% @doc Picks a subchannel from a pool using the configured strategy.
-spec pick(name(), unary | stream) -> {ok, {pid(), grpcbox_client:interceptor() | undefined}} |
                                   {error, undefined_channel | no_endpoints}.
pick(Name, CallType) ->
    gen_statem:call(Name, {pick_worker, Name, CallType}).

-spec interceptor(name(), unary | stream) -> grpcbox_client:interceptor() | undefined.
interceptor(Name, CallType) ->
    case ets:lookup(?CHANNELS_TAB, {Name, CallType}) of
        [] ->
            undefined;
        [{_, I}] ->
            I
    end.

stop(Name) ->
    gen_statem:stop(Name).

init([Name, Endpoints, Options]) ->
    process_flag(trap_exit, true),

    Encoding = maps:get(encoding, Options, identity),
    StatsHandler = maps:get(stats_handler, Options, undefined),

    insert_interceptors(Name, Options),

    Data = #data{
        pool = Name,
        encoding = Encoding,
        stats_handler = StatsHandler,
        endpoints = Endpoints
    },

    case maps:get(sync_start, Options, false) of
        false ->
            {ok, idle, Data, [{next_event, internal, connect}]};
        true ->
            L = start_workers(Name, StatsHandler, Encoding, Endpoints),
            {ok, connected, Data#data{workers = L}}
    end.

callback_mode() ->
    state_functions.

connected({call, From}, is_ready, _Data) ->
    {keep_state_and_data, [{reply, From, true}]};
connected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

idle(internal, connect, Data=#data{pool=Pool,
                                   stats_handler=StatsHandler,
                                   encoding=Encoding,
                                   endpoints=Endpoints}) ->
    L = start_workers(Pool, StatsHandler, Encoding, Endpoints),
    {next_state, connected, Data#data{workers = L}};
idle({call, From}, is_ready, _Data) ->
    {keep_state_and_data, [{reply, From, false}]};
idle(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

handle_event({call, From}, {pick_worker, Name, CallType}, #data{workers = L}) ->
    case L of
    [Pid|_] when is_pid(Pid) -> % FIXME implement shuffle
        Ret = {ok, {Pid, interceptor(Name, CallType)}},
        {keep_state_and_data, [{reply, From, Ret}]};
    _ ->
        {keep_state_and_data, [{reply, From, {error, no_endpoints}}]}
    end;

handle_event(info, {'EXIT', Pid, _}, Data = #data{workers = L}) ->
    {keep_state, Data#data{workers = L -- [Pid]}};

handle_event(_, _, Data) ->
    {keep_state, Data}.

terminate(_Reason, _State, _) ->
    ok.

insert_interceptors(Name, Interceptors) ->
    insert_unary_interceptor(Name, Interceptors),
    insert_stream_interceptor(Name, stream_interceptor, Interceptors).

insert_unary_interceptor(Name, Interceptors) ->
    case maps:get(unary_interceptor, Interceptors, undefined) of
        undefined ->
            ok;
        {Interceptor, Arg} ->
            ets:insert(?CHANNELS_TAB, {{Name, unary}, Interceptor(Arg)});
        Interceptor ->
            ets:insert(?CHANNELS_TAB, {{Name, unary}, Interceptor})
    end.

insert_stream_interceptor(Name, _Type, Interceptors) ->
    case maps:get(stream_interceptor, Interceptors, undefined) of
        undefined ->
            ok;
        {Interceptor, Arg} ->
            ets:insert(?CHANNELS_TAB, {{Name, stream}, Interceptor(Arg)});
        Interceptor when is_atom(Interceptor) ->
            ets:insert(?CHANNELS_TAB, {{Name, stream}, #{new_stream => fun Interceptor:new_stream/6,
                                                         send_msg => fun Interceptor:send_msg/3,
                                                         recv_msg => fun Interceptor:recv_msg/3}});
        Interceptor=#{new_stream := _,
                      send_msg := _,
                      recv_msg := _} ->
            ets:insert(?CHANNELS_TAB, {{Name, stream}, Interceptor})
    end.

start_workers(Pool, StatsHandler, Encoding, Endpoints) ->
    [begin
         {ok, Pid} = grpcbox_subchannel:start_link(Endpoint, Pool, {Transport, Host, Port, SSLOptions},
             Encoding, StatsHandler),
         Pid
     end || Endpoint={Transport, Host, Port, SSLOptions} <- Endpoints].
