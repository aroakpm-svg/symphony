-module(symphony_runtime_receipt_writer).

-include_lib("kernel/include/file.hrl").

-export([start/0]).

-spec start() -> no_return().
start() ->
    Owner = self(),
    Reader = spawn_link(fun() -> input_loop(Owner) end),
    loop(undefined, Reader, undefined).

input_loop(Owner) ->
    Input =
        try io:get_line(standard_io, "")
        catch
            _Kind:_Reason -> eof
        end,
    Owner ! {writer_input, Input},
    case Input of
        Line when is_list(Line); is_binary(Line) -> input_loop(Owner);
        _Closed -> ok
    end.

loop(State, Reader, PendingPublish) ->
    receive
        {writer_input, eof} ->
            cancel_publish(PendingPublish),
            cleanup(State),
            erlang:halt(0);
        {writer_input, {error, Reason}} ->
            cancel_publish(PendingPublish),
            cleanup(State),
            _ = Reason,
            erlang:halt(1);
        {writer_input, Line} when PendingPublish =:= undefined ->
            case decode_command(Line) of
                {ok, {request, RequestId,
                      {publish, TempName, ReceiptName, Payload, ReceiptLimit}}}
                  when is_binary(RequestId), is_map(State),
                       is_binary(TempName), is_binary(ReceiptName),
                       is_binary(Payload), is_integer(ReceiptLimit), ReceiptLimit > 0 ->
                    Owner = self(),
                    {Worker, Monitor} = spawn_monitor(fun() ->
                        maybe_delay_publish(State),
                        Reply = publish(TempName, ReceiptName, Payload, ReceiptLimit, State),
                        Owner ! {publish_result, self(), Reply}
                    end),
                    loop(State, Reader, {Worker, Monitor, RequestId});
                {ok, {request, RequestId, Command}} when is_binary(RequestId) ->
                    case handle_command(Command, State) of
                        {continue, Reply, NextState} ->
                            _ = write_reply({reply, RequestId, Reply}),
                            loop(NextState, Reader, undefined);
                        {stop, Reply, FinalState} ->
                            cleanup(FinalState),
                            _ = write_reply({reply, RequestId, Reply}),
                            erlang:halt(0)
                    end;
                {ok, _InvalidEnvelope} ->
                    _ = write_reply({reply, <<>>, {error, invalid_envelope}}),
                    loop(State, Reader, undefined);
                {error, Reason} ->
                    _ = write_reply({reply, <<>>, {error, Reason}}),
                    loop(State, Reader, undefined)
            end;
        {writer_input, Line} ->
            case decode_command(Line) of
                {ok, {request, RequestId, _Command}} when is_binary(RequestId) ->
                    _ = write_reply({reply, RequestId, {error, command_in_progress}});
                _Invalid ->
                    ok
            end,
            loop(State, Reader, PendingPublish);
        {publish_result, Worker, Reply} ->
            case PendingPublish of
                {Worker, Monitor, RequestId} ->
                    erlang:demonitor(Monitor, [flush]),
                    _ = write_reply({reply, RequestId, Reply}),
                    loop(State, Reader, undefined);
                _Stale ->
                    loop(State, Reader, PendingPublish)
            end;
        {'DOWN', Monitor, process, Worker, Reason} ->
            case PendingPublish of
                {Worker, Monitor, RequestId} ->
                    _ = write_reply({reply, RequestId, {error, {publish_worker_exit, Reason}}}),
                    loop(State, Reader, undefined);
                _Other ->
                    loop(State, Reader, PendingPublish)
            end
    end.

cancel_publish(undefined) ->
    ok;
cancel_publish({Worker, Monitor, _RequestId}) ->
    exit(Worker, kill),
    receive
        {'DOWN', Monitor, process, Worker, _Reason} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush]),
        ok
    end.

handle_command({init, GuardName, Token, ExpectedGuardPath, PublishDelayMs}, undefined)
  when is_binary(GuardName), is_binary(Token), is_binary(ExpectedGuardPath),
       is_integer(PublishDelayMs), PublishDelayMs >= 0 ->
    case safe_name(GuardName) of
        true ->
            %% A managed file server keeps the pinned guard handle usable by the
            %% monitored publish worker. Raw file handles are process-affine.
            case file:open(GuardName, [write, binary, exclusive]) of
                {ok, Guard} ->
                    case write_guard(Guard, Token) of
                        ok ->
                            State = #{guard => Guard,
                                      guard_name => GuardName,
                                      token => Token,
                                      expected_guard_path => ExpectedGuardPath,
                                      publish_delay_ms => PublishDelayMs},
                            case capability_attestation(Guard, Token) of
                                {ok, Attestation} ->
                                    {continue, {ok, Attestation},
                                     State#{attestation => Attestation}};
                                {error, Reason} ->
                                    cleanup(State),
                                    {continue, {error, Reason}, undefined}
                            end;
                        {error, Reason} ->
                            _ = file:close(Guard),
                            _ = file:delete(GuardName),
                            {continue, {error, Reason}, undefined}
                    end;
                {error, Reason} ->
                    {continue, {error, Reason}, undefined}
            end;
        false ->
            {continue, {error, invalid_guard_name}, undefined}
    end;
handle_command(close, State) ->
    {stop, ok, State};
handle_command(_Command, State) ->
    {continue, {error, invalid_command}, State}.

capability_attestation(Guard, Token) ->
    with_file_info(".", fun(DirectoryInfo) ->
        with_file_info(Guard, fun(GuardInfo) ->
            case file:get_cwd() of
                {ok, Cwd} ->
                    {ok, #{cwd => unicode:characters_to_binary(Cwd),
                           directory_identity => file_identity(DirectoryInfo),
                           guard_identity => file_identity(GuardInfo),
                           guard_token => Token}};
                {error, Reason} ->
                    {error, Reason}
            end
        end)
    end).

with_file_info(PathOrHandle, Fun) ->
    case file:read_file_info(PathOrHandle, [{time, posix}]) of
        {ok, Info} -> Fun(Info);
        {error, Reason} -> {error, Reason}
    end.

file_identity(#file_info{size = Size,
                         type = Type,
                         mode = Mode,
                         links = Links,
                         major_device = MajorDevice,
                         minor_device = MinorDevice,
                         inode = Inode}) ->
    #{size => Size,
      type => Type,
      mode => Mode,
      links => Links,
      major_device => MajorDevice,
      minor_device => MinorDevice,
      inode => Inode}.

maybe_delay_publish(#{publish_delay_ms := DelayMs}) when DelayMs > 0 ->
    timer:sleep(DelayMs);
maybe_delay_publish(_State) ->
    ok.

write_guard(Guard, Token) ->
    case file:write(Guard, Token) of
        ok -> file:sync(Guard);
        {error, _Reason} = Error -> Error
    end.

publish(TempName, ReceiptName, Payload, ReceiptLimit, State) ->
    case safe_name(TempName) andalso safe_name(ReceiptName) of
        true ->
            case guard_reachable(State) of
                ok -> publish_relative(TempName, ReceiptName, Payload, ReceiptLimit);
                {error, Reason} -> {error, Reason}
            end;
        false ->
            {error, invalid_receipt_name}
    end.

guard_reachable(#{guard := Guard,
                  expected_guard_path := GuardPath,
                  token := Token,
                  attestation := InitialAttestation}) ->
    case capability_attestation(Guard, Token) of
        {ok, CurrentAttestation} when CurrentAttestation =:= InitialAttestation ->
            case with_file_info(GuardPath, fun(GuardPathInfo) ->
                PathIdentity = file_identity(GuardPathInfo),
                case {maps:get(guard_identity, InitialAttestation, undefined),
                      file:read_file(GuardPath)} of
                    {PathIdentity, {ok, Token}} -> ok;
                    {PathIdentity, {ok, _OtherToken}} -> {error, guard_token_changed};
                    {PathIdentity, {error, _ReadReason}} -> {error, guard_path_unreadable};
                    {_OtherIdentity, _ReadResult} -> {error, guard_path_identity_changed}
                end
            end) of
                {error, _InfoReason} -> {error, guard_path_unreadable};
                Result -> Result
            end;
        {ok, _ChangedAttestation} ->
            {error, capability_attestation_changed};
        {error, _Reason} ->
            {error, capability_attestation_unavailable}
    end.

publish_relative(TempName, ReceiptName, Payload, ReceiptLimit) ->
    case file:write_file(TempName, Payload, [binary, exclusive, sync]) of
        ok ->
            case file:make_link(TempName, ReceiptName) of
                ok ->
                    _ = file:delete(TempName),
                    prune_receipts(ReceiptName, ReceiptLimit),
                    ok;
                {error, _Reason} = Error ->
                    _ = file:delete(TempName),
                    Error
            end;
        {error, _Reason} = Error ->
            _ = file:delete(TempName),
            Error
    end.

prune_receipts(CurrentReceipt, ReceiptLimit) ->
    case file:list_dir(".") of
        {ok, Names} ->
            Receipts = lists:sort([Name || Name <- Names, receipt_name(Name)]),
            Others = [Name || Name <- Receipts, Name =/= binary_to_list(CurrentReceipt)],
            Excess = max(0, length(Receipts) - ReceiptLimit),
            lists:foreach(fun(Name) -> _ = file:delete(Name) end,
                          lists:sublist(Others, Excess));
        {error, _Reason} ->
            ok
    end.

receipt_name(Name) when is_list(Name) ->
    case re:run(Name, "^stop-[A-Za-z0-9][A-Za-z0-9._-]*\\.json$", [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

safe_name(Name) ->
    Name =/= <<>> andalso
    Name =/= <<".">> andalso
    Name =/= <<"..">> andalso
    filename:basename(Name) =:= Name andalso
    binary:match(Name, <<"/">>) =:= nomatch andalso
    binary:match(Name, <<"\\">>) =:= nomatch.

decode_command(Line) ->
    try
        Encoded = string:trim(iolist_to_binary(Line)),
        {ok, binary_to_term(base64:decode(Encoded), [safe])}
    catch
        _Kind:_Reason -> {error, invalid_encoding}
    end.

write_reply(Reply) ->
    try
        Encoded = base64:encode(term_to_binary(Reply)),
        io:put_chars(standard_io, [Encoded, $\n])
    catch
        _Kind:_Reason -> {error, output_closed}
    end.

cleanup(undefined) ->
    ok;
cleanup(#{guard := Guard, guard_name := GuardName}) ->
    _ = file:close(Guard),
    _ = file:delete(GuardName),
    ok.
