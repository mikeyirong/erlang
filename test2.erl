-module(test2).
-compile(export_all).

start(Tag) ->
      spawn(fun() -> loop(Tag) end).

loop(Tag) ->
      sleep(),
      Val=test1:x(),
      io:format("~w~n",[Tag,Val]),
      loop(Tag).

sleep() ->
    receive
       after 5000 -> true
        end.
