-module(efcm).

-export([start/1, push/3]).

start(ServiceFile) ->
    efcm_conn:start_link(ServiceFile).

push(Pid, RegId, Message) ->
    efcm_conn:push(Pid, RegId, Message).
