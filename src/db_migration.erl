%% @author Gaurav Kumar <gauravkumar552@gmail.com>

-module(db_migration).

-export([start_mnesia/0,
	 get_base_revision/0,
	 create_migration_file/1,
	 create_migration_file/0,
	 init_migrations/0,
	 get_current_head/0,
	 read_config/0,
	 find_pending_migrations/0,
	 apply_upgrades/0,
	 get_revision_tree/0,
	 get_applied_head/0,
	 detect_conflicts_post_migration/1
	]).

-ifdef(TEST).
-export([get_migration_source_filepath/0,
	 get_migration_beam_filepath/0
	]).
-endif.

-define(TABLE, schema_migrations).

-record(schema_migrations, {prime_key = null, curr_head=null}).

read_config() ->
    Val  = application:get_env(mnesia_migrate, migration_dir, "~/project/mnesia_migrate/src/migrations/"),
    io:format("migration_dir: ~p~n", [Val]).

start_mnesia() ->
	mnesia:start().

init_migrations() ->
    case lists:member(?TABLE, mnesia:system_info(tables)) of
        true ->
            ok;
        false ->
            io:format("Table schema_migration not found, creating...~n", []),
            Attr = [{disc_copies, [node()]}, {attributes, record_info(fields, schema_migrations)}],
            case mnesia:create_table(?TABLE, Attr) of
                {atomic, ok}      -> io:format(" => created~n", []);
                {aborted, Reason} -> io:format("mnesia create table error: ~p~n", [Reason]),
				     throw({error, Reason})
            end
    end,
    ok = mnesia:wait_for_tables([?TABLE], 10000).


%%
%%Functions related to migration info
%%

get_current_head() ->
    BaseRev = get_base_revision(),
    get_current_head(BaseRev).

get_revision_tree() ->
    BaseRev = get_base_revision(),
    List1 = [],
    RevList = append_revision_tree(List1, BaseRev),
    io:format("RevList ~p~n", [RevList]),
    RevList.

find_pending_migrations() ->
   RevList = case get_applied_head() of
                     none -> case get_base_revision() of
			         none -> [] ;
				 BaseRevId -> append_revision_tree([], BaseRevId)
			     end;
                     Id -> case get_next_revision(Id) of
			       [] -> [] ;
			       NextId -> append_revision_tree([], NextId)
			   end
             end,
   io:format("Revisions needing migration : ~p~n", [RevList]),
   RevList.

%%
%% Functions related to migration creation
%%

create_migration_file(CommitMessage) ->
    erlydtl:compile(code:lib_dir(mnesia_migrate) ++ "/schema.template", migration_template),
    NewRevisionId = string:substr(uuid:to_string(uuid:uuid4()),1,8),
    OldRevisionId = get_current_head(),
    Filename = NewRevisionId ++ "_" ++ string:substr(CommitMessage, 1, 20) ,
    {ok, Data} = migration_template:render([{new_rev_id , NewRevisionId}, {old_rev_id, OldRevisionId},
					  {modulename, Filename}, {tabtomig, []},
					  {commitmessage, CommitMessage}]),
    file:write_file(get_migration_source_filepath() ++ Filename ++ ".erl", Data),
    io:format("New file created ~p~n", [Filename ++ ".erl"]),
    get_migration_source_filepath() ++ Filename ++ ".erl".

create_migration_file() ->
    erlydtl:compile(code:lib_dir(mnesia_migrate) ++ "/schema.template", migration_template),
    NewRevisionId = "a" ++ string:substr(uuid:to_string(uuid:uuid4()),1,8),
    OldRevisionId = get_current_head(),
    Filename = NewRevisionId ++ "_migration" ,
    {ok, Data} = migration_template:render([{new_rev_id , NewRevisionId}, {old_rev_id, OldRevisionId},
					  {modulename, Filename}, {tabtomig, []},
					  {commitmessage, "migration"}]),
    file:write_file(get_migration_source_filepath() ++ Filename ++ ".erl", Data),
    io:format("New file created ~p~n", [Filename ++ ".erl"]),
    get_migration_source_filepath() ++ Filename ++ ".erl".


%%
%% Functions related to applying migrations
%%

apply_upgrades() ->
    RevList = find_pending_migrations(),
    case RevList of
        [] -> io:format("No pending revision found ~n");
        _ ->
            lists:foreach(fun(RevId) -> ModuleName = list_to_atom(atom_to_list(RevId) ++ "_migration") , ModuleName:up() end, RevList),
            io:format("all upgrades successfully applied.~n"),
            %% update head in database
            update_head(lists:last(RevList))
    end.



append_revision_tree(List1, RevId) ->
    case get_next_revision(RevId) of
        [] -> List1 ++ [RevId];
	NewRevId ->
		   List2 = List1 ++ [RevId],
	           append_revision_tree(List2, NewRevId)
    end.

get_applied_head() ->
    {atomic, KeyList} = mnesia:transaction(fun() -> mnesia:read(schema_migrations, head) end),
    Head = case length(KeyList) of
               0 -> none;
               _ ->
               Rec = hd(KeyList),
               Rec#schema_migrations.curr_head
           end,
    io:format("current applied head is : ~p~n", [Head]),
    Head.

update_head(Head) ->
    mnesia:transaction(fun() ->
        case mnesia:wread({schema_migrations, head}) of
            [] ->
                 mnesia:write(schema_migrations, #schema_migrations{prime_key = head, curr_head = Head}, write);
            [CurrRec] ->
                mnesia:write(CurrRec#schema_migrations{curr_head = Head})
        end
    end).

%%
%% Post migration validations
%%

-spec detect_conflicts_post_migration([{tuple(), list()}]) -> list().
detect_conflicts_post_migration(Models) ->
    ConflictingTables = [TableName || {TableName, Options} <- Models , proplists:get_value(attributes, Options) /= mnesia:table_info(TableName, attributes)],
    io:fwrite("Tables having conflicts in structure after applying migrations: ~p~n", [ConflictingTables]),
    ConflictingTables.


%%
%% helper functions
%%

has_migration_behaviour(Modulename) ->
    case catch Modulename:module_info(attributes) of
        {'EXIT', {undef, _}} ->
            false;
        Attributes ->
            case lists:keyfind(behaviour, 1, Attributes) of
                {behaviour, BehaviourList} ->
                    lists:member(migration, BehaviourList);
                false ->
                    false
            end
    end.


get_base_revision() ->
    Modulelist = filelib:wildcard(get_migration_beam_filepath() ++ "*_migration.beam"),
    Res = lists:filter(fun(Filename) ->
        Modulename = list_to_atom(filename:basename(Filename, ".beam")),
        case has_migration_behaviour(Modulename) of
	    true -> string:equal(Modulename:get_prev_rev(),none);
	    false -> false
	end
    end,
    Modulelist),
    BaseModuleName = list_to_atom(filename:basename(Res, ".beam")),
    io:fwrite("Base Rev module is ~p~n", [BaseModuleName]),
    case Res of
        [] -> none;
	_ -> BaseModuleName:get_current_rev()
    end.


get_next_revision(RevId) ->
    Modulelist = filelib:wildcard(get_migration_beam_filepath() ++ "*_migration.beam"),
    Res = lists:filter(fun(Filename) ->
        Modulename = list_to_atom(filename:basename(Filename, ".beam")),
        case has_migration_behaviour(Modulename) of
	    true -> string:equal(Modulename:get_prev_rev(), RevId);
	    false -> false
	end
    end,
    Modulelist),
    case Res of
        [] -> [];
        _ -> ModuleName = list_to_atom(filename:basename(Res, ".beam")), ModuleName:get_current_rev()
    end.

get_current_head(RevId) ->
    case get_next_revision(RevId) of
	[] -> RevId ;
        NextRevId -> get_current_head(NextRevId)
    end.

get_migration_source_filepath() ->
    Val = application:get_env(mnesia_migrate, migration_source_dir, "src/migrations/"),
    ok = filelib:ensure_dir(Val),
    Val.

get_migration_beam_filepath() ->
    Val = application:get_env(mnesia_migrate, migration_beam_dir, "ebin/"),
    ok = filelib:ensure_dir(Val),
    Val.
