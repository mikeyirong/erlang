- module(test).
- export([start/2]).

start(X,Y) when X>Y ->X;
start(X,Y) ->Y.