
/*
 * Copyright (C) 2001-2011 Ideaworks3D Ltd.
 * All Rights Reserved.
 *
 * This document is protected by copyright, and contains information
 * proprietary to Ideaworks Labs.
 * This file consists of source code released by Ideaworks Labs under
 * the terms of the accompanying End User License Agreement (EULA).
 * Please do not use this program/source code before you have read the
 * EULA and have agreed to be bound by its terms.
 */

#include "s3eIOSGameCenter.h"

// utility function for tracing enum values as strings
const char* GetGameCenterErrorString(s3eIOSGameCenterError enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_ERR_NONE);
    RETURN(S3E_IOSGAMECENTER_ERR_PARAM);
    RETURN(S3E_IOSGAMECENTER_ERR_ALREADY_REG);
    RETURN(S3E_IOSGAMECENTER_ERR_DEVICE);
    RETURN(S3E_IOSGAMECENTER_ERR_UNSUPPORTED);
    RETURN(S3E_IOSGAMECENTER_ERR_STATE);
    RETURN(S3E_IOSGAMECENTER_ERR_GAME_UNRECOGNISED);
    RETURN(S3E_IOSGAMECENTER_ERR_UNAUTHENTICATED);
    RETURN(S3E_IOSGAMECENTER_ERR_AUTHENTICATION_IN_PROGRESS);
    RETURN(S3E_IOSGAMECENTER_ERR_INVALID_CREDENTIALS);
    RETURN(S3E_IOSGAMECENTER_ERR_UNDERAGE);
    RETURN(S3E_IOSGAMECENTER_ERR_ALREADY_IN_PROGRESS);
    RETURN(S3E_IOSGAMECENTER_ERR_FRIENDS_NOT_LOADED);
    RETURN(S3E_IOSGAMECENTER_ERR_COMMUNICATIONS_FAILURE);
    RETURN(S3E_IOSGAMECENTER_ERR_CANCELLED);
    RETURN(S3E_IOSGAMECENTER_ERR_USER_DENIED);
    RETURN(S3E_IOSGAMECENTER_ERR_INVALID_PLAYER);
    RETURN(S3E_IOSGAMECENTER_ERR_SCORE_NOT_SET);
    RETURN(S3E_IOSGAMECENTER_ERR_PARENTAL_CONTROLS_BLOCKED);
    RETURN(S3E_IOSGAMECENTER_ERR_INVALID_MATCH_REQUEST);
    RETURN(S3E_IOSGAMECENTER_ERR_MATCHMAKING_IN_PROGRESS);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterError";
}

// Utility function for iterating through enum
s3eIOSGameCenterError GetGameCenterErrorAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_ERR_NONE;
    case 1: return S3E_IOSGAMECENTER_ERR_PARAM;
    case 2: return S3E_IOSGAMECENTER_ERR_ALREADY_REG;
    case 3: return S3E_IOSGAMECENTER_ERR_DEVICE;
    case 4: return S3E_IOSGAMECENTER_ERR_UNSUPPORTED;
    case 5: return S3E_IOSGAMECENTER_ERR_STATE;
    case 6: return S3E_IOSGAMECENTER_ERR_GAME_UNRECOGNISED;
    case 7: return S3E_IOSGAMECENTER_ERR_UNAUTHENTICATED;
    case 8: return S3E_IOSGAMECENTER_ERR_AUTHENTICATION_IN_PROGRESS;
    case 9: return S3E_IOSGAMECENTER_ERR_INVALID_CREDENTIALS;
    case 10: return S3E_IOSGAMECENTER_ERR_UNDERAGE;
    case 11: return S3E_IOSGAMECENTER_ERR_ALREADY_IN_PROGRESS;
    case 12: return S3E_IOSGAMECENTER_ERR_FRIENDS_NOT_LOADED;
    case 13: return S3E_IOSGAMECENTER_ERR_COMMUNICATIONS_FAILURE;
    case 14: return S3E_IOSGAMECENTER_ERR_CANCELLED;
    case 15: return S3E_IOSGAMECENTER_ERR_USER_DENIED;
    case 16: return S3E_IOSGAMECENTER_ERR_INVALID_PLAYER;
    case 17: return S3E_IOSGAMECENTER_ERR_SCORE_NOT_SET;
    case 18: return S3E_IOSGAMECENTER_ERR_PARENTAL_CONTROLS_BLOCKED;
    case 19: return S3E_IOSGAMECENTER_ERR_INVALID_MATCH_REQUEST;
    case 20: return S3E_IOSGAMECENTER_ERR_MATCHMAKING_IN_PROGRESS;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterError");
    return (s3eIOSGameCenterError)0;
}

#define s3eIOSGameCenterError_COUNT 21

// utility function for tracing enum values as strings
const char* GetGameCenterPropertyString(s3eIOSGameCenterProperty enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_AUTHENTICATED);
    RETURN(S3E_IOSGAMECENTER_LOCAL_PLAYER_ID);
    RETURN(S3E_IOSGAMECENTER_LOCAL_PLAYER_ALIAS);
    RETURN(S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_UNDERAGE);
    RETURN(S3E_IOSGAMECENTER_LOCAL_PLAYER_HAS_FRIENDS_LOADED);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterProperty";
}

// Utility function for iterating through enum
s3eIOSGameCenterProperty GetGameCenterPropertyAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_AUTHENTICATED;
    case 1: return S3E_IOSGAMECENTER_LOCAL_PLAYER_ID;
    case 2: return S3E_IOSGAMECENTER_LOCAL_PLAYER_ALIAS;
    case 3: return S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_UNDERAGE;
    case 4: return S3E_IOSGAMECENTER_LOCAL_PLAYER_HAS_FRIENDS_LOADED;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterProperty");
    return (s3eIOSGameCenterProperty)0;
}

#define s3eIOSGameCenterProperty_COUNT 5

// utility function for tracing enum values as strings
const char* GetGameCenterPlayerPropertyString(s3eIOSGameCenterPlayerProperty enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_PLAYER_ID);
    RETURN(S3E_IOSGAMECENTER_PLAYER_ALIAS);
    RETURN(S3E_IOSGAMECENTER_PLAYER_IS_FRIEND);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterPlayerProperty";
}

// Utility function for iterating through enum
s3eIOSGameCenterPlayerProperty GetGameCenterPlayerPropertyAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_PLAYER_ID;
    case 1: return S3E_IOSGAMECENTER_PLAYER_ALIAS;
    case 2: return S3E_IOSGAMECENTER_PLAYER_IS_FRIEND;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterPlayerProperty");
    return (s3eIOSGameCenterPlayerProperty)0;
}

#define s3eIOSGameCenterPlayerProperty_COUNT 3

// utility function for tracing enum values as strings
const char* GetGameCenterMatchPropertyString(s3eIOSGameCenterMatchProperty enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_MATCH_EXPECTED_PLAYERS);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterMatchProperty";
}

// Utility function for iterating through enum
s3eIOSGameCenterMatchProperty GetGameCenterMatchPropertyAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_MATCH_EXPECTED_PLAYERS;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterMatchProperty");
    return (s3eIOSGameCenterMatchProperty)0;
}

#define s3eIOSGameCenterMatchProperty_COUNT 1

// utility function for tracing enum values as strings
const char* GetGameCenterMatchSendDataModeString(s3eIOSGameCenterMatchSendDataMode enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_MATCH_SEND_DATA_RELIABLE);
    RETURN(S3E_IOSGAMECENTER_MATCH_SEND_DATA_UNRELIABLE);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterMatchSendDataMode";
}

// Utility function for iterating through enum
s3eIOSGameCenterMatchSendDataMode GetGameCenterMatchSendDataModeAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_MATCH_SEND_DATA_RELIABLE;
    case 1: return S3E_IOSGAMECENTER_MATCH_SEND_DATA_UNRELIABLE;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterMatchSendDataMode");
    return (s3eIOSGameCenterMatchSendDataMode)0;
}

#define s3eIOSGameCenterMatchSendDataMode_COUNT 2

// utility function for tracing enum values as strings
const char* GetGameCenterPlayerConnectionStateString(s3eIOSGameCenterPlayerConnectionState enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_PLAYER_STATE_UNKNOWN);
    RETURN(S3E_IOSGAMECENTER_PLAYER_STATE_CONNECTED);
    RETURN(S3E_IOSGAMECENTER_PLAYER_STATE_DISCONNECTED);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterPlayerConnectionState";
}

// Utility function for iterating through enum
s3eIOSGameCenterPlayerConnectionState GetGameCenterPlayerConnectionStateAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_PLAYER_STATE_UNKNOWN;
    case 1: return S3E_IOSGAMECENTER_PLAYER_STATE_CONNECTED;
    case 2: return S3E_IOSGAMECENTER_PLAYER_STATE_DISCONNECTED;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterPlayerConnectionState");
    return (s3eIOSGameCenterPlayerConnectionState)0;
}

#define s3eIOSGameCenterPlayerConnectionState_COUNT 3

// utility function for tracing enum values as strings
const char* GetGameCenterPlayerScopeString(s3eIOSGameCenterPlayerScope enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_PLAYER_SCOPE_GLOBAL);
    RETURN(S3E_IOSGAMECENTER_PLAYER_SCOPE_FRIENDS_ONLY);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterPlayerScope";
}

// Utility function for iterating through enum
s3eIOSGameCenterPlayerScope GetGameCenterPlayerScopeAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_PLAYER_SCOPE_GLOBAL;
    case 1: return S3E_IOSGAMECENTER_PLAYER_SCOPE_FRIENDS_ONLY;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterPlayerScope");
    return (s3eIOSGameCenterPlayerScope)0;
}

#define s3eIOSGameCenterPlayerScope_COUNT 2

// utility function for tracing enum values as strings
const char* GetGameCenterTimeScopeString(s3eIOSGameCenterTimeScope enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_TIME_SCOPE_TODAY);
    RETURN(S3E_IOSGAMECENTER_PLAYER_SCOPE_WEEK);
    RETURN(S3E_IOSGAMECENTER_PLAYER_SCOPE_ALL_TIME);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterTimeScope";
}

// Utility function for iterating through enum
s3eIOSGameCenterTimeScope GetGameCenterTimeScopeAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_TIME_SCOPE_TODAY;
    case 1: return S3E_IOSGAMECENTER_PLAYER_SCOPE_WEEK;
    case 2: return S3E_IOSGAMECENTER_PLAYER_SCOPE_ALL_TIME;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterTimeScope");
    return (s3eIOSGameCenterTimeScope)0;
}

#define s3eIOSGameCenterTimeScope_COUNT 3

// utility function for tracing enum values as strings
const char* GetGameCenterLeaderboardPropertyString(s3eIOSGameCenterLeaderboardProperty enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_CATEGORY);
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_RANGE_START);
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_RANGE_SIZE);
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_PLAYER_SCOPE);
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_TIME_SCOPE);
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_TITLE);
    RETURN(S3E_IOSGAMECENTER_LEADERBOARD_MAX_RANGE);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterLeaderboardProperty";
}

// Utility function for iterating through enum
s3eIOSGameCenterLeaderboardProperty GetGameCenterLeaderboardPropertyAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_LEADERBOARD_CATEGORY;
    case 1: return S3E_IOSGAMECENTER_LEADERBOARD_RANGE_START;
    case 2: return S3E_IOSGAMECENTER_LEADERBOARD_RANGE_SIZE;
    case 3: return S3E_IOSGAMECENTER_LEADERBOARD_PLAYER_SCOPE;
    case 4: return S3E_IOSGAMECENTER_LEADERBOARD_TIME_SCOPE;
    case 5: return S3E_IOSGAMECENTER_LEADERBOARD_TITLE;
    case 6: return S3E_IOSGAMECENTER_LEADERBOARD_MAX_RANGE;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterLeaderboardProperty");
    return (s3eIOSGameCenterLeaderboardProperty)0;
}

#define s3eIOSGameCenterLeaderboardProperty_COUNT 7

// utility function for tracing enum values as strings
const char* GetGameCenterVoiceChatStateString(s3eIOSGameCenterVoiceChatState enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_CONNECTED);
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_DISCONNECTED);
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_SPEAKING);
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_SILENT);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterVoiceChatState";
}

// Utility function for iterating through enum
s3eIOSGameCenterVoiceChatState GetGameCenterVoiceChatStateAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_VOICE_CHAT_CONNECTED;
    case 1: return S3E_IOSGAMECENTER_VOICE_CHAT_DISCONNECTED;
    case 2: return S3E_IOSGAMECENTER_VOICE_CHAT_SPEAKING;
    case 3: return S3E_IOSGAMECENTER_VOICE_CHAT_SILENT;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterVoiceChatState");
    return (s3eIOSGameCenterVoiceChatState)0;
}

#define s3eIOSGameCenterVoiceChatState_COUNT 4

// utility function for tracing enum values as strings
const char* GetGameCenterVoiceChatPropertyString(s3eIOSGameCenterVoiceChatProperty enumValue)
{
    #define RETURN(c) case c: return #c
    switch(enumValue)
    {
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_START);
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_ACTIVE);
    RETURN(S3E_IOSGAMECENTER_VOICE_CHAT_VOLUME);
    }
    
    return "ERROR- bad enum value for enum s3eIOSGameCenterVoiceChatProperty";
}

// Utility function for iterating through enum
s3eIOSGameCenterVoiceChatProperty GetGameCenterVoiceChatPropertyAtIndex(int i)
{
    switch(i)
    {
    case 0: return S3E_IOSGAMECENTER_VOICE_CHAT_START;
    case 1: return S3E_IOSGAMECENTER_VOICE_CHAT_ACTIVE;
    case 2: return S3E_IOSGAMECENTER_VOICE_CHAT_VOLUME;
    }
    
    IwTestTrace("Bad Index for enum s3eIOSGameCenterVoiceChatProperty");
    return (s3eIOSGameCenterVoiceChatProperty)0;
}

#define s3eIOSGameCenterVoiceChatProperty_COUNT 3
