%%% Shared limits between the raw TCP and WebSocket front doors. Kept
%%% low enough that one abusive client can't grow server memory or
%%% flood every other connected client with oversized messages.
-define(MAX_USERNAME_LEN, 24).
-define(MAX_GROUP_NAME_LEN, 32).
-define(MAX_MESSAGE_LEN, 2000).
-define(MAX_WS_FRAME_LEN, 65536).
