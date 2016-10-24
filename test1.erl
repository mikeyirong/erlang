-module(test1).
-export([x/1,sleep/0]).

x(A) ->
sleep(),
io:format("~w~n----->",[A]),
x(A).

sleep() ->
  receive
      after  3000 -> true
  end.
