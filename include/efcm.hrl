%%%-------------------------------------------------------------------
%%% @author sedinin
%%% @copyright (C) 2024, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 03. Nov 2024 16:57
%%%-------------------------------------------------------------------
-author("sedinin").

-define(DEBUG_LOG(Format, Args), lager:debug(Format, Args)).
-define(INFO_LOG(Format, Args), lager:info(Format, Args)).
-define(WARN_LOG(Format, Args), lager:warning(Format, Args)).
-define(ERROR_LOG(Format, Args), lager:error(Format, Args)).
