-module(mchttp).
-export([start/0]).

%
% 启动服务器
%
start() ->
     Config = config:get(conf),
     Master = start_server(Config),
     start_suppervisor(Config,Master),
     Master ! start_server.
     
 start_server(Config) ->
     process_flag(trap_exit,true),
     spawn(fun() ->pre_start_server(Config) end).

 %
 %启动守护者进程
 %  
 start_suppervisor(Config,Master) ->
   spawn(fun() ->
   	     process_flag(trap_exit,true),
         link(Master),
         receive
         	    {'EXIT',Defunct,Reason} ->
         	        io:format("Master process [~p] has been dead ,caused by ~p~n",[Defunct,Reason]),
         	        NMaster = start_server(Config),
         	        start_suppervisor(Config,NMaster),
         	        NMaster ! start_server(Config)
         end	        
   end.) 

   %
   %启动服务器进程
   %     
   pre_start_server(Config) ->
         receive
         	    start_server ->
         	        spawn(fun() ->
                     %
                     %初始化handler
                     %
                        catch apply(maps:get("handler",Config),init,[Config]),
                %
                %初始化路由器
                % 
                Router = init_router(),
                                    case gen_tcp:listen(collection:get_from_map("port",Config,9527),[binary,{packet,0},{active,false}]) of
                                      {ok,Listen} ->
                                            waiting_for_connections(Listen,Config,Router);
                                      {error,Reason} ->
                                            io:format("starting server faild,reason is ~p~n",[Reason])
                                            end

         	        	end);
         	            {'EXIT',Defunct,Reason} ->
         	                   io:format("Suppervisor process [~p] has been dead,caused by:~p~n",[Defunct,Reason]),
         	              start_suppervisor(Config,self())
         	              end,
         	              pre_start_server(Config).
%
%服务器主进程
%
 waiting_for_connections(Listen,Config,Router) ->
    case gen_tcp:accept(Listen) of
    	{ok,Sock} ->
    	        spawn(fun() -> start_session(Sock,Config,Router) end);
    	{_,Reason} ->
    	        io:format("accept socket faild,reason is ~n~p",[Reason])
    	 end,
    	 waiting_for_connections(Listen,Config,Router).
  %
  % 处理接入的客户端请求
  %  	                 
  start_session(Sock,Config,Router) ->
       case receive_from_sock(0,Sock,<<>>) of
       	 {ok,Bin} ->
       	  case Bin of
       	  	<<"CLOSE">> ->
       	  	    io:format("client wants to disconnect\n"),
       	  	    gen_tcp:close(Sock);
       	  	_->
       	  	  spawn(fun() ->
                put(router,Router),
                handle(Sock,Config,binary_to_list(Bin))
       	  	  	end)
       	  end;
       	  {error,Reason} ->
       	        R = io_lib:format("~p",[Reason]),
       	        httputil:http_error(Sock,#{},list_to_binary(R))
       	end.
  
  receive_from_sock(0,Sock,<<>>) ->
       case gen_tcp:recv(Sock,0) of
           {ok,Bin} ->
              %
              % 第一次进入这里
              %  
              {HttpHead,_} = case re:split(Bin,"\r\n\r\n",[{return,list}]) of
                [A,B] ->
                   %
                   %解析Body
                   %
                   {string:tokens(A,"\r\n"),resovle_http_body(string:tokens(B,"&"),#{})};
                A ->
                {string:tokens(A,"\r\n"),#{}}
                end,

                Headers =resovle_http_headers(HttpHead,#{}),
                ContentLength = maps:get("Content-Length",Headers),
                receive_from_sock(list_to_integer(ContentLength),Sock,Bin);
               _ ->
                 io:format("Fall back of connections\n") 
              end;
 receive_form_sock(Mas,Sock,SoFar) ->
   case Max > byte_size(SoFar) of
        true ->
            case gen_tcp:recv(Sock,0) of
                    {ok,Bin} ->
                           receive_from_sock(Max,Sock,<<SoFar/binary,Bin/binary>>);
                     _ ->
                        io:format("Fall back of connections\n")                       	        	  	    

        false ->
             %%已经按照数据包大小接收完毕
             % 
             {ok,SoFar}
    end.
   %
   % 通用请求受理函数
   %          
   handle(Sock,Config,Bin) ->
       %
       %解析出HTTP请求头和请求体
       %
       {HttpHead,HttpBody} = case re:split(Bin,"\r\n\r\n",[{return,list}]) of
       	  [A,B] ->
       	      %
       	      %解析Body
              %
              {string:tokens(A,"\r\n"),resovle_http_body(string:tokens(B,"&"),#{})};
          A ->
             {string:tokens(A,"\r\n"),#{}}
          end,
          
          Headers = resovle_http_headers(HttpHead,#{}),

          [Head | _] =string : tokens(Bin,"\r\n"),
          R = string : tokens(Head," "),

          F = fun(Body) ->
          	              %
          	              % METHOD RESOURCE VERSION
          	              % eg:GET / HTTP/1.1

          	              [Method,Resource,HttpVersion] = R,

          	              RecognizedResource = get_resource_with_filter_cross_domain(Resource),

          	              %
          	              %链接到处理器
          	              %

          	              put(config,Config),
          	              try 
          	                 apply(maps:get("handler",Config),execute,[Sock,[Method,RecognizedResource,HttpVersion],Headers,Body])
          	              catch
          	                    Error ->
          	                        io:format("Error occurred!,caused by ~p~n",[Error]) 
          	                    end,
          	                    %
          	                    gen_tcp:close(Sock)
          	             end,
          	             

          	             case collection:get_from_map("Content-Type",Headers,none) of
          	                    none -> F(HttpBody);
          	                    ContentType ->
          	                        %
          	                        % 判断是否为"multipart/form-data"类型
          	                        %             
          	                     case(lists:filter(fun(E) ->
          	                              case E of
          	                              	"multipart/form-data" ->true;
          	                              	_ -> false
          	                              end end,string:tokens(ContentType,";"))) of
          	                              [] -> F(HttpBody);
          	                              _  ->
          	                                   io:format("multipart/form-data\n"),

          	                              Max = maps:get("Content-Length",Headers),

          	                                   Multipart = get_multi_part_datas(Sock,list_to_integer(Max),<<>>),

          	                                   [_,TagBoundary] = string:tokens(ContentType,";"),
          	                                   [_,Boundary] = string:tokens(TagBoundary,"="),
          	                                   io:format("Boundary is [~s]~n",[Boundary]),

          	                                   Parts = [E||E <- binary:split(Multipart,[list_to_binary("--"++Boundary)],[global]),byte_size(E) > 0,E=/=<<"--\r\n">>],
          	                                   io:format("Parts is ~p~n",[length(Parts)]),
          	                                   Mime = [parse_multi_part(E)||E <- Parts],
          	                                   F(Mime) 
          	                                   end
          	                                 end.
          	                                 
          	                                 parse_multi_part(Bin) ->
          	                                     [Header,Body] = binary:split(Bin,<<"\r\n\r\n">>),
          	                                     Headers = parse_multi_part_headers(string:tokens(binary_to_list(Header),"\r\n",#{})),

          	                                     ContentDisposition = maps:get("Content-Disposition",Headers),
          	                                     Segments = string:tokens(ContentDisposition,";"),

          	                                     %
          	                                     % 创建multipart对象
          	                                     %      
          	                                     #multipart{
          	                                             content_disposition = convert_multi_part_segments(Segments,#{}),
          	                                             content_type = maps:get("Content-Type",Headers),
          	                                             content =Body
          	                                     }.

          	                                parse_multi_part_headers([],R) -> R;
          	                                parse_multi_part_headers([H|T],R) ->
          	                                   parse_multi_part_headers(T,parse_multi_part_header(H,R)).
          	                                parse_multi_part_header(H,R) ->
          	                                   case string:tokens(H,":") of
          	                                     [A,B] ->
          	                                         maps:put(string:strip(A),string:strip(B),R);
          	                                      _Others -> R
          	                                    end.

          	                              convert_multi_part_segments([],R) -> R;             

