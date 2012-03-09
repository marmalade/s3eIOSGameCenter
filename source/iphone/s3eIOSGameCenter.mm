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

#include "IwDebug.h"

#include "s3eEdk.h"
#include "s3eEdk_iphone.h"

#include "s3eIOSGameCenter_internal.h"
#include <GameKit/GameKit.h>
#include "IwDebug.h"
#include <unistd.h>
#include "s3eConfig.h"

#define S3E_CURRENT_EXT IOSGAMECENTER
#include "s3eEdkError.h"
#define S3E_DEVICE_IOSGAMECENTER S3E_EXT_IOSGAMECENTER_HASH


@interface s3eReAuthenticationHandler : NSObject
- (void)authenticationChanged:(NSNotification *)notif;
@end

@implementation s3eReAuthenticationHandler
- (void)authenticationChanged:(NSNotification *)notif
{
    IwTrace(GAMECENTER, ("authenticationChanged"));
    if (![GKLocalPlayer localPlayer].authenticated)
    {
        IwTrace(GAMECENTER,("local player no longer signed in"));
        
        // Note user authentication callback will be triggered if reuse flag was set on initial call to s3eIOSGameCenterAuthenticate
        
        // the login prompt should automatically be shown so lock the statusbar (workaround for keyboard rotation issue: 15991 on IOS5)
        // is this dangerous?  is there a case where we are signed out and the ui doesn't come up automatically?        
        if (s3eEdkIPhoneGetVerMaj() > 4)
            s3eEdkLockOSRotation(S3E_TRUE); // lock the display
    }
}
-(void) dealloc 
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
@end

static s3eReAuthenticationHandler* g_Authentication; 
static s3eBool g_ReUseAuthenticationCB;

@interface s3eIOSGameKitMatchDelegate : NSObject <GKMatchDelegate>
{
    @public NSError*            m_Error;     // Last error (for trace/error codes and to keep functions that need error pointers happy)
}
@end

// Voice Chat struct
struct s3eIOSGameCenterVoiceChat
{
    GKVoiceChat*    m_VoiceChat;
    s3eBool         m_Started;
};

// Dummy view controller used to enforce correct orientation of Game Center
// GUIs on iPad. The modal GUIs from the GameKit framework are unusual in that,
// on iPad, they rotate themselves to match the parent view and not the
// statusbar/device orientation. This behaviour is not present on other device
// types becuase these GUIs are only supported portrait on them. This is a
// minor iOS bug/quirk: on iPad it ought to use a popover or the device
// orientation.
//
// Since Marmalade uses a fixed portrait UIView, these GUIs would always be in
// portrait even if the iPad is held in landscape. A dummy view is
// positioned between the main marmalade view and the modal views and allowed to
// rotate so that modal view will be the correct way up.
@interface DummyController : UIViewController
- (void)loadView;
@end
@implementation DummyController
- (void)loadView
{
}
// Note that this is only called once (will rotate on launch but not after) since the
// view immediately looses focus to a modal Game Center view.
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    int fixOrientation = 0; // 1=portrait, 2=landscape
    s3eConfigGetInt("s3e", "DispFixRot", &fixOrientation);
    
    if (fixOrientation == 2 && (interfaceOrientation == UIInterfaceOrientationPortrait
                                || interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown ))
        return S3E_FALSE;
    if (fixOrientation == 1 && (interfaceOrientation == UIInterfaceOrientationLandscapeLeft
                                || interfaceOrientation == UIInterfaceOrientationLandscapeRight))
        return S3E_FALSE;

    return YES;
}
@end

// Module private data
// NOTE: Only one match at a time is currently supported so we just keep a
// global instance. Could be extended but unlikely to need more than 1 match
// and GK doesn't explicitly support that.

static GKMatch* g_Match = NULL;
static bool g_MatchMaking = false;
s3eIOSGameKitMatchDelegate* g_MatchDelegate = NULL;
static bool g_HasFriends = false;
static s3eIOSGameCenterMatchCallbacks g_MatchCallbacks = { NULL };
static char g_StringPropertyBuffer[S3E_IOSGAMECENTER_STRING_MAX];
volatile bool g_InGUI = 0;
s3eResult g_GUIResult = S3E_RESULT_SUCCESS;

static DummyController* g_DummyController = 0;

#define CHECK_AUTH(RTN) if (!s3eLocalPlayerIsAuthenticated()) return RTN

#define CHECK_MATCH(RTN) CHECK_AUTH(RTN); if (!g_Match) { S3E_EXT_ERROR(STATE, ("No current match")); return RTN; }

#define RETURN_GAMECENTER_ERROR(ERROR_CODE) \
    { \
    if (setError) \
        S3E_EXT_ERROR(ERROR_CODE, ("%s (%d) (%s)", [[gamekitError localizedDescription] UTF8String], [gamekitError code], failingComponent ? failingComponent : "")); \
    return S3E_IOSGAMECENTER_ERR_##ERROR_CODE; \
    }

static s3eIOSGameCenterError ObjcToS3EError(NSError* gamekitError, bool setError=false, const char* failingComponent=NULL, bool traceDetails=true)
{
    if (traceDetails && !setError)
    {
        IwTrace(GAMECENTER, ("%s%s %s (%d)", failingComponent ? failingComponent : "Internal error:", failingComponent ? " failed with error:" : "", [[gamekitError localizedDescription] UTF8String], [gamekitError code]));
    }

    switch ([gamekitError code])
    {
        case GKErrorCancelled:
            RETURN_GAMECENTER_ERROR(CANCELLED)
        case GKErrorCommunicationsFailure:
            RETURN_GAMECENTER_ERROR(COMMUNICATIONS_FAILURE)
        case GKErrorUserDenied:
            RETURN_GAMECENTER_ERROR(USER_DENIED)
        case GKErrorInvalidCredentials:
            RETURN_GAMECENTER_ERROR(INVALID_CREDENTIALS)
        case GKErrorNotAuthenticated:
            RETURN_GAMECENTER_ERROR(UNAUTHENTICATED)
        case GKErrorAuthenticationInProgress:
            RETURN_GAMECENTER_ERROR(AUTHENTICATION_IN_PROGRESS)
        case GKErrorInvalidPlayer:
            RETURN_GAMECENTER_ERROR(INVALID_PLAYER)
        case GKErrorScoreNotSet:
            RETURN_GAMECENTER_ERROR(SCORE_NOT_SET)
        case GKErrorParentalControlsBlocked:
            RETURN_GAMECENTER_ERROR(PARENTAL_CONTROLS_BLOCKED)
        case GKErrorMatchRequestInvalid:
            RETURN_GAMECENTER_ERROR(INVALID_MATCH_REQUEST)
        case GKErrorUnderage:
            RETURN_GAMECENTER_ERROR(UNDERAGE)
        case GKErrorGameUnrecognized:
            RETURN_GAMECENTER_ERROR(GAME_UNRECOGNISED)
        case GKErrorUnknown:
        default:
            RETURN_GAMECENTER_ERROR(DEVICE)

        //These dont appear to be used anymore (as player status was deprecated)...
        //GKErrorPlayerStatusInvalid
        //GKErrorPlayerStatusExceedsMaximumLength
    }
}

static void s3eIOSGameKitGotMatch(GKMatch* match)
{
    g_Match = match;
    g_MatchDelegate = [[s3eIOSGameKitMatchDelegate alloc] init];
    g_Match.delegate = g_MatchDelegate;
    [match retain];

    // Register match callbacks now we know we have a valid match
    EDK_CALLBACK_REG(IOSGAMECENTER, CONNECTION_FAILURE, (s3eCallback)g_MatchCallbacks.m_ConnectionFailureCB, NULL, false);
    EDK_CALLBACK_REG(IOSGAMECENTER, CONNECT_TO_PLAYER_FAILURE, (s3eCallback)g_MatchCallbacks.m_ConnectToPlayerFailureCB, NULL, false);
    EDK_CALLBACK_REG(IOSGAMECENTER, PLAYER_STATE_CHANGE, (s3eCallback)g_MatchCallbacks.m_PlayerStateChangeCB, NULL, false);
    EDK_CALLBACK_REG(IOSGAMECENTER, RECEIVE_DATA, (s3eCallback)g_MatchCallbacks.m_ReceiveDataCB, NULL, false);
}

static void DoneMatchMaking(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    g_MatchMaking = false;
}


static char** AllocCStrings(int* numStrings, NSArray *objCStringArray, int maxLimit=0)
{
    int num = [objCStringArray count];

    if (maxLimit && num > maxLimit)
        num = maxLimit;

    char** stringArray = (char**)s3eEdkMallocOS(sizeof(char*) * num);
    IwTrace(GAMECENTER, ("alloc string array: %p %d", stringArray, num));

    for (int i = 0; i < num; i++)
    {
        NSString* objCString = [objCStringArray objectAtIndex:i];
        int len = strlen([objCString UTF8String]);
        stringArray[i] = (char*)s3eEdkMallocOS(len+1);
        strcpy(stringArray[i], [objCString UTF8String]);
    }

    *numStrings = num;
    return stringArray;
}

static void FreeCStrings(char** stringArray, int numStrings)
{
    IwTrace(GAMECENTER, ("free string array: %p %d", stringArray, numStrings));

    if (!stringArray)
        return;

    for (int i = 0; i < numStrings; i++)
    {
        s3eEdkFreeOS(stringArray[i]);
    }
    s3eEdkFreeOS(stringArray);
}

// ---- Static/global callbacks completion functions ----

static void s3eGCReleaseReceivedData(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    NSData* nsdata = (NSData*)data;
    [nsdata release];
}

static void s3eGCReleasePlayerIDs(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    s3eIOSGameCenterPlayerIDsInfo* playersInfo = (s3eIOSGameCenterPlayerIDsInfo*)systemData;

    if (playersInfo->m_PlayerIDs)
    {
        for (int i = 0; i < playersInfo->m_PlayerCount; i++)
        {
            s3eEdkFreeOS((void*)playersInfo->m_PlayerIDs[i]);
        }
        s3eEdkFreeOS(playersInfo->m_PlayerIDs);
    }

    g_MatchMaking = false;
}

static void s3eGCReleaseCategories(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    s3eIOSGameCenterLoadCategoriesResult* categoriesResult = (s3eIOSGameCenterLoadCategoriesResult*)systemData;

    FreeCStrings(categoriesResult->m_Categories, categoriesResult->m_CategoriesCount);
    FreeCStrings(categoriesResult->m_Titles, categoriesResult->m_CategoriesCount);
}

static void s3eGCReleaseAcheivementInfo(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    IwTrace(GAMECENTER, ("ReleaseAchievementInfo"));
    s3eIOSGameCenterAchievementInfoList* list = (s3eIOSGameCenterAchievementInfoList*)systemData;
    s3eEdkFreeOS(list->m_Achievements);
}

static void s3eGCReleaseAcheivements(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    IwTrace(GAMECENTER, ("ReleaseAchievements"));
    s3eIOSGameCenterAchievementList* list = (s3eIOSGameCenterAchievementList*)systemData;
    s3eEdkFreeOS(list->m_Achievements);
}

static void s3eGCReleasePlayerInfo(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    s3eIOSGameCenterPlayerInfo* playersInfo = (s3eIOSGameCenterPlayerInfo*)systemData;

    // Just free the array of pointers. Each player is a GKPlayer that is being retained until the app is done with it
    if (playersInfo->m_Players)
        s3eEdkFreeOS(playersInfo->m_Players);
}

static void s3eInviteHandlerComplete(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* data)
{
    s3eIOSGameCenterInvite* invite = (s3eIOSGameCenterInvite*)systemData;

    if (!invite->m_RetainInviteID)
    {
        GKInvite* gkinvite = (GKInvite*)(invite->m_InviteID);
        [gkinvite release];
    }

    if (!invite->m_RetainPlayers && invite->m_AllPlayersCount && invite->m_AllPlayersToInvite)
        s3eIOSGameCenterReleasePlayers(invite->m_AllPlayersToInvite, invite->m_AllPlayersCount);
}


// ----------------------- implement match delegate -----------------------
@implementation s3eIOSGameKitMatchDelegate

// handler functions that fire s3e callbacks
- (void)match:(GKMatch *)match didReceiveData:(NSData *)data fromPlayer:(NSString *)playerID
{
    // Assuming match is our global match for now...
    s3eIOSGameCenterReceivedData receivedData;
    memset(&receivedData, 0, sizeof(receivedData));

    strlcpy(receivedData.m_PlayerID, [playerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
    receivedData.m_DataSize = [data length];
    receivedData.m_Data = (const char*)[data bytes];

    [data retain];

    IwTrace(GAMECENTER,("receiveData %u bytes", receivedData.m_DataSize));

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_RECEIVE_DATA,
                           &receivedData,
                           sizeof(receivedData),
                           NULL,
                           S3E_FALSE,
                           s3eGCReleaseReceivedData,
                           data);
}

// The player state changed (e.g. connected or disconnected)
- (void)match:(GKMatch *)match player:(NSString *)playerID didChangeState:(GKPlayerConnectionState)state
{
    s3eIOSGameCenterPlayerStateChangeInfo info;
    strlcpy(info.m_PlayerID, [playerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
    IwTrace(GAMECENTER_VERBOSE, ("player %s didChangeState to %d", info.m_PlayerID, (int)state));

    switch (state)
    {
        case GKPlayerStateConnected:
            info.m_State = S3E_IOSGAMECENTER_PLAYER_STATE_CONNECTED;
            break;

        case GKPlayerStateDisconnected:
            info.m_State = S3E_IOSGAMECENTER_PLAYER_STATE_DISCONNECTED;
            break;

        case GKPlayerStateUnknown:
        default:
            info.m_State = S3E_IOSGAMECENTER_PLAYER_STATE_UNKNOWN;
            break;
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_PLAYER_STATE_CHANGE,
                           &info,
                           sizeof(info),
                           NULL,
                           S3E_FALSE,
                           NULL,
                           NULL);
}

// The match was unable to connect with the player due to an error.
- (void)match:(GKMatch *)match connectionWithPlayerFailed:(NSString *)playerID withError:(NSError *)error
{
    // TODO: check what "connect" actually means in this instance. Is this actually sending data?
    IwTrace(GAMECENTER,("connectionWithPlayerFailed %s %s", [playerID UTF8String], [[error localizedDescription] UTF8String]));

    s3eIOSGameCenterConnectWithPlayerResult result;
    memset(&result, 0, sizeof(result));
    strlcpy(result.m_PlayerID, [playerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
    if (error)
        result.m_Error = ObjcToS3EError(error);

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_CONNECT_TO_PLAYER_FAILURE,
                           &result,
                           sizeof(result),
                           NULL,
                           S3E_FALSE,
                           NULL,
                           NULL);
}

// The match was unable to be established with any players due to an error.
- (void)match:(GKMatch *)match didFailWithError:(NSError *)error
{
    IwTrace(GAMECENTER, ("match connection %p failed with error %d %s", match, [error code], [[error localizedDescription] UTF8String]));

    s3eIOSGameCenterError res = ObjcToS3EError(error);
    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_CONNECTION_FAILURE,
                           &res,
                           sizeof(res),
                           NULL,
                           S3E_FALSE,
                           NULL,
                           NULL);
}

// If we need to store anything and free it
/*-(void) dealloc
 {
 if (m_Players)
 {
 for (int i = 0; i < m_PlayerCount; i++)
 [m_Players[i] release];

 s3eEdkFreeOS(m_Players);
 }

 [super dealloc];
 }*/

@end


// ---------- Global blocks to handle completions -----------
//NB: these mostly could just be coded in-line in the fuctions they are called
//     from but it is neater to separate them out here.

void(^s3eFindPlayersCompletionHandler)(NSArray*, NSError*) = ^(NSArray *playerIDs, NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS))
        return;

    s3eIOSGameCenterPlayerIDsInfo playersInfo;

    if (error)
    {
        IwTrace(GAMECENTER, ("FindPlayersForHostedRequest failed with error: %d %s", [error code], [[error localizedDescription] UTF8String]));

        playersInfo.m_Error = ObjcToS3EError(error);

        playersInfo.m_PlayerIDs = NULL;
        playersInfo.m_PlayerCount = 0;
    }
    else
    {
        playersInfo.m_Error = S3E_IOSGAMECENTER_ERR_NONE;
        IwTrace(GAMECENTER,("FindPlayersForHostedRequest succeeded"));

        // create c array of string IDs and register callback-complete function to free them later
        playersInfo.m_PlayerCount = [playerIDs count];

        if (playerIDs)
        {
            playersInfo.m_PlayerIDs = (const char**)s3eEdkMallocOS(sizeof(char*) * playersInfo.m_PlayerCount);
            for (int i = 0; i < playersInfo.m_PlayerCount; i++)
            {
                NSString* objCPlayerID = [playerIDs objectAtIndex:i];
                playersInfo.m_PlayerIDs[i] = (const char*)s3eEdkMallocOS(sizeof(char) * (strlen([objCPlayerID UTF8String])+1));
                strlcpy((char*)playersInfo.m_PlayerIDs[i], [objCPlayerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            }
        }
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS,
                           &playersInfo,
                           sizeof(playersInfo),
                           NULL,
                           S3E_TRUE,
                           s3eGCReleasePlayerIDs,
                           NULL);
};

void(^s3eMatchMakerQueryGroupCompletionHandler)(NSInteger, NSError*) = ^(NSInteger activity, NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_QUERY_ACTIVITY))
        return;

    s3eIOSGameCenterActivityInfo info;
    if (error)
    {
        info.m_Error = ObjcToS3EError(error, true, "MatchmakerQueryGroup completion handler");
        info.m_Activity = NULL;
    }
    else
    {
        info.m_Error = S3E_IOSGAMECENTER_ERR_NONE;
        info.m_Activity = activity;
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_QUERY_ACTIVITY,
                           &info,
                           sizeof(info),
                           NULL,
                           S3E_TRUE,
                           NULL,
                           NULL);
};

void(^s3eLoadPlayersHandler)(NSArray*, NSError*) = ^(NSArray* players, NSError* error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_RECEIVE_PLAYERS))
        return;

    s3eIOSGameCenterPlayerInfo info;
    memset(&info, 0, sizeof(info));

    if (error)
    {
        info.m_Error = ObjcToS3EError(error, true, "LoadPlayers handler");
    }
    else
    {
        IwTrace(GAMECENTER,("received player data"));

        // Allocate C array of pointers and copy from ObjC array
        GKPlayer** cPlayersArray = (GKPlayer**)s3eEdkMallocOS(sizeof(GKPlayer*) * [players count]);
        info.m_PlayerCount = [players count];

        for (int i = 0; i < info.m_PlayerCount; i++)
        {
            cPlayersArray[i] = [players objectAtIndex:i];
            [cPlayersArray[i] retain];
        }
        info.m_Players = (s3eIOSGameCenterPlayer**)cPlayersArray;
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_RECEIVE_PLAYERS,
                           &info,
                           sizeof(info),
                           NULL,
                           S3E_TRUE,
                           s3eGCReleasePlayerInfo,
                           NULL);
};


// Genius matchmaking to find a peer-to-peer match for the specified request. Error will be nil on success:
static void (^s3eCreateMatchCompletionHandler)(GKMatch*, NSError*) = ^(GKMatch *match, NSError *error)
{
    IwTrace(GAMECENTER, ("s3eCreateMatchCompletionHandler"));
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_CREATE_MATCH))
        return;

    s3eIOSGameCenterError s3eError;

    if (error || !match) //safety check match exists
    {
        if (!error)
        {
            S3E_EXT_ERROR(DEVICE, ("Create Match completed with null match pointer"))
            s3eError = S3E_IOSGAMECENTER_ERR_DEVICE;
        }
        else
        {
            if ([error code] == GKErrorCancelled) // User cancelled request and this callback fired (dont set error flag).
                s3eError = ObjcToS3EError(error, false, "CreateMatch completion handler", true);
            else
                s3eError = ObjcToS3EError(error, true, "CreateMatch completion handler");
        }
    }
    else
    {
        s3eIOSGameKitGotMatch(match);
        s3eError = S3E_IOSGAMECENTER_ERR_NONE;
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_CREATE_MATCH,
                           &s3eError,
                           sizeof(s3eError),
                           NULL,
                           S3E_TRUE,
                           DoneMatchMaking,
                           NULL);
};

// Invitation handler. Gets registered as a property of matchmaker singleton, then gets called
// whenever an invitation is sent from a match/other users.
// TODO: Looks like we need initialise a matchviewcontroller to handle this via UI popup...
static void (^s3eInviteHandler)(GKInvite*, NSArray*) = ^(GKInvite *gkinvite, NSArray *playersToInvite)
{
    // Dismiss existing GUI and cancel matchmaking if desired
    int cancelMatchmaking = 1; // default to 1 (cancel GUI but not already-started matchmaking)
    s3eConfigGetInt("s3e", "IOSGameCenterInviteCancelsMatchmaking", &cancelMatchmaking);
    if (cancelMatchmaking)
    {
        if (g_InGUI)
        {
            IwTrace(GAMECENTER, ("dismissing MatchmakerDelegate"));
            g_GUIResult = S3E_RESULT_ERROR;
            [g_DummyController dismissModalViewControllerAnimated:YES];
            
            S3E_EXT_ERROR_SIMPLE(CANCELLED); // error will be set for gui function that is currently in wait loop
        }

        if (cancelMatchmaking == 2)
            s3eIOSGameCenterCancelMatchmaking();

    }

    [gkinvite retain];
    [playersToInvite retain];

    s3eIOSGameCenterInvite invite;

    // Set flags, pointers and string 0 by default
    memset(&invite, 0, sizeof(invite));
    invite.m_InviteID = gkinvite;
    invite.m_Hosted = [gkinvite isHosted];
    const char* inviter = [gkinvite.inviter UTF8String];
    strcpy(invite.m_InviterID, inviter);

    // Allocate C array of invited players
    GKPlayer** cPlayersArray = (GKPlayer**)s3eEdkMallocOS(sizeof(GKPlayer*) * [playersToInvite count]);
    invite.m_AllPlayersCount = [playersToInvite count];

    for (int i = 0; i < invite.m_AllPlayersCount; i++)
    {
        cPlayersArray[i] = [playersToInvite objectAtIndex:i];
        [cPlayersArray[i] retain];
    }
    invite.m_AllPlayersToInvite = (s3eIOSGameCenterPlayer**)cPlayersArray;

    IwTrace(GAMECENTER, ("invitation arrived from: id=%s hosted=%d", invite.m_InviterID, invite.m_Hosted));

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_INVITE,
                           &invite,
                           sizeof(invite),
                           NULL,
                           S3E_FALSE,
                           s3eInviteHandlerComplete,
                           NULL);
};

// Add players to match
static void (^s3eAddPlayersToMatchCompletionHandler)(NSError*) = ^(NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_ADD_PLAYERS_TO_MATCH))
        return;

    s3eIOSGameCenterError s3eError = S3E_IOSGAMECENTER_ERR_NONE;

    if (error)
        s3eError = ObjcToS3EError(error, true, "AddPlayersToMatch completion handler");
    else
        IwTrace(GAMECENTER,("AddPlayersToMatch success, enqueuing callback"));

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_ADD_PLAYERS_TO_MATCH,
                           &s3eError,
                           sizeof(s3eError),
                           NULL,
                           S3E_TRUE,
                           NULL,
                           NULL);
};

static void (^AuthenticateCompletionHandler)(NSError*) = ^(NSError* error)
{
    IwTrace(GAMECENTER, ("AuthenticateCompletionHandler"));

    // >=4.2 "Each time your application is moved from the background to the foreground, Game Kit automatically 
    // authenticates the local player again on your behalf and calls your completion handler to provide 
    // updated information about the state of the authenticated player."
    
    s3eEdkLockOSRotation(S3E_FALSE);    // unlock the statusbar
    s3eEdkUpdateStatusBarOrient();        // reorient statusbar to correct orientation - shouldn't be necessary but just in case
    
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_AUTHENTICATION))
        return;

    s3eIOSGameCenterError s3eError = S3E_IOSGAMECENTER_ERR_NONE;

    if (error)
        s3eError = ObjcToS3EError(error, true, "Authenticate completion handler");
    else    
        IwTrace(GAMECENTER,("Authenticate success, enqueuing callback"));
        
    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_AUTHENTICATION,
                           &s3eError,
                           sizeof(s3eError),
                           NULL,
                           !g_ReUseAuthenticationCB, //S3E_TRUE 
                           NULL,
                           NULL);
};

/**
 * Asynchronously load the friends list as an array of players. Calls
 * completionHandler when finished. Error will be nil on success.
 */
static void (^s3eLoadFriendsCompletionHandler)(NSArray*, NSError*) = ^(NSArray *friends, NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_LOAD_FRIENDS))
        return;

    s3eIOSGameCenterError s3eError = S3E_IOSGAMECENTER_ERR_NONE;
    g_HasFriends = true;

    if (error)
    {
        g_HasFriends = false;
        s3eError = ObjcToS3EError(error, true, "LoadFriends completion handler");
    }
    else
        IwTrace(GAMECENTER, ("s3eLoadFriendsCompletionHandler"));

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_LOAD_FRIENDS,
                           &s3eError,
                           sizeof(s3eError),
                           NULL,
                           S3E_TRUE,
                           NULL,
                           NULL);
};

static void (^s3eLeaderboardLoadCategoriesHandler)(NSArray*, NSArray*, NSError*) = ^(NSArray *categories, NSArray *titles, NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_LEADERBOARD_LOAD_CATEGORIES))
        return;

    s3eIOSGameCenterLoadCategoriesResult res;
    res.m_CategoriesCount = 0;
    res.m_Categories = NULL;
    res.m_Titles = NULL;

    if (error)
    {
        res.m_Error = ObjcToS3EError(error, true, "LeaderboardLoadCategoriesHandler");
    }
    else
    {
        res.m_Error = S3E_IOSGAMECENTER_ERR_NONE;
        IwTrace(GAMECENTER, ("LeaderboardLoadCategories complete: %d", [categories count]));

        // create c array of string IDs and register callback-complete function to free them later
        res.m_Categories = AllocCStrings(&res.m_CategoriesCount, categories);
        res.m_Titles = AllocCStrings(&res.m_CategoriesCount, titles, res.m_CategoriesCount);
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_LEADERBOARD_LOAD_CATEGORIES,
                           &res,
                           sizeof(res),
                           NULL,
                           S3E_TRUE,
                           s3eGCReleaseCategories,
                           NULL);
};

static void (^s3eReportScoreCompletionHandler)(NSError*) = ^(NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_REPORT_SCORE))
        return;

    s3eIOSGameCenterError res = S3E_IOSGAMECENTER_ERR_NONE;

    if (error)
        res = ObjcToS3EError(error, true, "ReportScore completion handler");
    else
        IwTrace(GAMECENTER, ("ReportScore done"));

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                        S3E_IOSGAMECENTER_CALLBACK_REPORT_SCORE,
                        &res,
                        sizeof(res),
                        NULL,
                        S3E_TRUE,
                        NULL,
                        NULL);
};

static void s3eGCReleaseScores(uint32 deviceID, int32 notification, void* systemData, void* instance, int32 returnCode, void* userData)
{
    s3eIOSGameCenterLoadScoresResult* data = (s3eIOSGameCenterLoadScoresResult*)systemData;
    IwTrace(GAMECENTER, ("releasing score data"));
    s3eEdkFreeOS(data->m_Scores);
}

static void (^s3eLoadScoresCompletionHandler)(NSArray*, NSError*) = ^(NSArray *scores, NSError *error)
{
    if (!s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_LEADERBOARD_LOAD_SCORES))
        return;

    s3eIOSGameCenterLoadScoresResult res;
    memset(&res, 0, sizeof(res));

    if (error)
    {
        res.m_Error = ObjcToS3EError(error, true, "LoadScores completion handler");
    }
    else
    {
        res.m_ScoreCount = [scores count];
        IwTrace(GAMECENTER, ("LoadScores success: %d", res.m_ScoreCount));
        int size = res.m_ScoreCount * sizeof(res.m_Scores[0]);
        res.m_Scores = (s3eIOSGameCenterScore*)s3eEdkMallocOS(size);
        memset(res.m_Scores, 0, size);
        for (int i = 0; i < res.m_ScoreCount; i++)
        {
            GKScore* score = [scores objectAtIndex:i];
            strlcpy(res.m_Scores[i].m_PlayerID, [score.playerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            if (score.category)
                strlcpy(res.m_Scores[i].m_Category, [score.category UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            strlcpy(res.m_Scores[i].m_FormattedValue, [score.formattedValue UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            res.m_Scores[i].m_Date = [score.date timeIntervalSince1970];
            res.m_Scores[i].m_Value = score.value;
            res.m_Scores[i].m_Rank = score.rank;
        }
        res.m_LocalPlayerScore = NULL;
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_LEADERBOARD_LOAD_SCORES,
                           &res,
                           sizeof(res),
                           NULL,
                           S3E_TRUE,
                           s3eGCReleaseScores,
                           NULL);
};


// --------- Leaderboard GUI ---------

@interface s3eIOSGameKitLeaderboardViewController : GKLeaderboardViewController
@end

@interface s3eIOSGameKitLeaderboardDelegate : NSObject <GKLeaderboardViewControllerDelegate>
@end

@implementation s3eIOSGameKitLeaderboardViewController
- (void)dealloc
{
    IwTrace(GAMECENTER, ("deallocating LeaderboardViewController"));
    [super dealloc];

    [g_DummyController.view removeFromSuperview];
    [g_DummyController.view release];
    [g_DummyController release];
    g_DummyController = 0;

    g_InGUI = 0;
}
@end

@implementation s3eIOSGameKitLeaderboardDelegate
- (void)dealloc
{
    IwTrace(GAMECENTER, ("Loaderboard GUI completed"));
    [super dealloc];
}

- (void)leaderboardViewControllerDidFinish:(GKLeaderboardViewController *)viewController
{
    [g_DummyController dismissModalViewControllerAnimated:YES];
    [self release];
}
@end


// --------- Achievements GUI ---------

@interface s3eIOSGameKitAchievementsViewController : GKAchievementViewController 
@end

@interface s3eIOSGameKitAchievementsDelegate : NSObject <GKAchievementViewControllerDelegate>
@end

@implementation s3eIOSGameKitAchievementsViewController
- (void)dealloc
{
    IwTrace(GAMECENTER, ("deallocating AchievementsViewController"));
    [super dealloc];

    [g_DummyController.view removeFromSuperview];
    [g_DummyController.view release];
    [g_DummyController release];
    g_DummyController = 0;

    g_InGUI = 0;
}
@end

@implementation s3eIOSGameKitAchievementsDelegate
- (void)dealloc
{
    IwTrace(GAMECENTER, ("Loaderboard GUI completed"));
    [super dealloc];
}

- (void)achievementViewControllerDidFinish:(GKAchievementViewController *)viewController
{
    [g_DummyController dismissModalViewControllerAnimated:YES];
    [self release];
}
@end

// --------- Matchmaking / invite GUI ---------

@interface s3eIOSGameKitMatchmakerViewController : GKMatchmakerViewController
@end

@interface s3eIOSGameKitMatchmakerDelegate : NSObject <GKMatchmakerViewControllerDelegate>
@end

@implementation s3eIOSGameKitMatchmakerViewController
- (void)dealloc
{
    IwTrace(GAMECENTER, ("deallocating MatchmakerViewController"));
    [self.matchmakerDelegate release];
    self.matchmakerDelegate = NULL;
    [super dealloc];
    
    [g_DummyController.view removeFromSuperview];
    [g_DummyController.view release];
    [g_DummyController release];
    g_DummyController = 0;
    
    g_InGUI = 0;
}
@end

@implementation s3eIOSGameKitMatchmakerDelegate
- (void)dealloc
{
    IwTrace(GAMECENTER, ("deallocating MatchmakerDelegate"));
    [super dealloc];
}

- (void)dismiss:(s3eResult)result
{
    IwTrace(GAMECENTER, ("dismissing MatchmakerDelegate"));
    g_GUIResult = result;
    
    [g_DummyController dismissModalViewControllerAnimated:YES];
}

- (void)matchmakerViewController:(GKMatchmakerViewController *)viewController didFailWithError:(NSError *)error
{
    IwTrace(GAMECENTER, ("matchmakerViewController didFailWithError"));
    ObjcToS3EError(error, true);
    [self dismiss: S3E_RESULT_ERROR];
}

- (void)matchmakerViewControllerWasCancelled:(GKMatchmakerViewController *)viewController
{
    IwTrace(GAMECENTER, ("matchmakerViewControllerWasCancelled"));
    S3E_EXT_ERROR_SIMPLE(CANCELLED);
    [self dismiss: S3E_RESULT_ERROR];
}

- (void)matchmakerViewController:(GKMatchmakerViewController *)viewController didFindPlayers:(NSArray *)playerIDs
{
    IwTrace(GAMECENTER, ("matchmakerViewController didFindPlayers"));
    s3eFindPlayersCompletionHandler(playerIDs, nil);
    [self dismiss: S3E_RESULT_SUCCESS];
}

-(void)matchmakerViewController:(GKMatchmakerViewController *)viewController didFindMatch:(GKMatch *)match
{
    IwTrace(GAMECENTER, ("matchmakerViewController didFindMatch: %p", match));
    s3eIOSGameKitGotMatch(match);
    [self dismiss: S3E_RESULT_SUCCESS];
}
@end

// ----------------------------------------------------------------------
// s3e C++ functions

s3eResult s3eIOSGameCenterInit()
{
    g_Authentication = 0;
        
    if (s3eEdkIPhoneGetVerMaj() > 4 || (s3eEdkIPhoneGetVerMaj() == 4 && s3eEdkIPhoneGetVerMin() >= 1))
    {
        // Want to fail if running on 3G or 2nd gen Touch since those are not
        // supported, but no documented way to check (GKMatchmaker responds
        // to selectors on those devices; no "is supported" type function).

        // Although Apple's documentation states that 2nd gen touches are in 
        // fact supported, during testing on the device the stability of
        // GameCenter is questionable and thus it has been hardcoded out
        const char* deviceID = s3eDeviceGetString(S3E_DEVICE_ID);
        if (strcmp(deviceID, "iPod2,1") && strcmp(deviceID, "iPhone1,2"))
            return S3E_RESULT_SUCCESS;
    }
    
    S3E_EXT_ERROR_SIMPLE(UNSUPPORTED);
    return S3E_RESULT_ERROR;
}

void s3eIOSGameCenterTerminate()
{
    if (g_Authentication)
        [g_Authentication release];
}

// Check for callbacks that can only be registered one at a time. null function unregisters if possible
#define GAMECENTER_CALLBACK_CHECK(callbackFn, CALLBACK_NAME) \
    if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_##CALLBACK_NAME)) \
    { \
        if (callbackFn) \
        { \
            S3E_EXT_ERROR_SIMPLE(ALREADY_REG); \
            return S3E_RESULT_ERROR; \
        } \
        else \
        { \
            if (s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_##CALLBACK_NAME, NULL) == S3E_RESULT_SUCCESS) \
                return S3E_RESULT_SUCCESS; \
            else \
            { \
                IwTrace(GAMECENTER, ("Failed to unregister callback %d", (int)S3E_IOSGAMECENTER_CALLBACK_##CALLBACK_NAME)); \
                S3E_EXT_ERROR_SIMPLE(DEVICE); \
                return S3E_RESULT_ERROR; \
            } \
        } \
    } \
    else if (!callbackFn) \
    { \
        S3E_EXT_ERROR(PARAM, ("cannot register null callbackFn")); \
        return S3E_RESULT_ERROR; \
    }

// ------- General player & authentication funcs -------

// Always call this function before doing anything that requires the player to be authenticated
static bool s3eLocalPlayerIsAuthenticated(bool raiseError=true)
{
    if ([[GKLocalPlayer localPlayer] isAuthenticated])
    {
        IwTrace(GAMECENTER_VERBOSE, ("s3eLocalPlayerIsAuthenticated: TRUE"));
        return true;
    }

    IwTrace(GAMECENTER_VERBOSE, ("s3eLocalPlayerIsAuthenticated: FALSE"));

    // Dont allow this value to be true when offline (may not be neccessary...)
    g_HasFriends = false;

    if (raiseError)
        S3E_EXT_ERROR_SIMPLE(UNAUTHENTICATED);

    return false;
}

// Authenticate the player for access to player details and game statistics. 
// This may present login UI to the user if necessary to login or create an account. 
// The user must be autheticated in order to use other APIs. 
// This should be called for each launch of the application as soon as the UI is ready.
s3eResult s3eIOSGameCenterAuthenticate(s3eIOSGameCenterAuthenticationCallbackFn authenticationCB, void* userData, s3eBool reuse)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterAuthenticate"));

    GAMECENTER_CALLBACK_CHECK(authenticationCB, AUTHENTICATION);

    g_ReUseAuthenticationCB = reuse;
    
    // One at a time callback to indicate check completion. Will be notified
    // with oneShot=true so that it unregisters itself for the next call (if reuse==0)
    EDK_CALLBACK_REG(IOSGAMECENTER, AUTHENTICATION, (s3eCallback)authenticationCB, userData, true);

    // TODO: GKPlayerAuthenticationDidChangeNotificationName implemented but needs looking into
    // to handle the special case of user sign off then on when in background
    // to handle the special case of user signing to another account when in background
    // we may want the userdata to reflect these cases
    
    // adding dummyview seems to have no effect on login modal on ios5 so commenting it out:
    // g_DummyController = [[DummyController alloc] init];
    // UIView* dummyView = [[UIView alloc] initWithFrame:[UIScreen mainScreen].applicationFrame];
    // g_DummyController.view = dummyView;    
    // [s3eEdkGetUIView() addSubview:g_DummyController.view];
    // [dummyView setBackgroundColor:[UIColor colorWithWhite:1.0 alpha:0.5]];
        
    g_Authentication = [[s3eReAuthenticationHandler alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:g_Authentication selector:@selector(authenticationChanged:) name:GKPlayerAuthenticationDidChangeNotificationName object:nil];
        
    if (s3eEdkIPhoneGetVerMaj() > 4)
        s3eEdkLockOSRotation(S3E_TRUE); 
        
    [[GKLocalPlayer localPlayer] authenticateWithCompletionHandler:AuthenticateCompletionHandler];
    
    return S3E_RESULT_SUCCESS;
}

s3eResult s3eIOSGameCenterLoadFriends(s3eIOSGameCenterLoadFriendsCallbackFn loadFriendsCB, void* userData)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterLoadFriends"));
    CHECK_AUTH(S3E_RESULT_ERROR);
    GAMECENTER_CALLBACK_CHECK(loadFriendsCB, LOAD_FRIENDS)
    EDK_CALLBACK_REG(IOSGAMECENTER, LOAD_FRIENDS, (s3eCallback)loadFriendsCB, userData, true);
    [[GKLocalPlayer localPlayer] loadFriendsWithCompletionHandler:s3eLoadFriendsCompletionHandler];
    return S3E_RESULT_SUCCESS;
}

int32 s3eIOSGameCenterGetFriendIDs(char** friendIDs, int maxFriendIDs)
{
    // May want to allow it to cache firends after local player sign-out in
    // which case, remove this
    CHECK_AUTH(-1);

    if (!g_HasFriends)
    {
        S3E_EXT_ERROR_SIMPLE(FRIENDS_NOT_LOADED);
        return -1;
    }

    NSArray* playerIDArray = [[GKLocalPlayer localPlayer] friends];
    int   size = [playerIDArray count];

    if (friendIDs)
    {
        if (playerIDArray && maxFriendIDs)
        {
            if (maxFriendIDs > size)
                maxFriendIDs = size;

            for (int i = 0; i < maxFriendIDs; i++)
                strlcpy(friendIDs[i], [(NSString*)[playerIDArray objectAtIndex:i] UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
        }
    }
    //else just return the amount

    return size;
}

int32 s3eIOSGameCenterGetInt(s3eIOSGameCenterProperty property)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterGetInt"));

    GKLocalPlayer* player = [GKLocalPlayer localPlayer];

    if (property != S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_AUTHENTICATED && !s3eLocalPlayerIsAuthenticated())
    {
        return -1;
    }

    switch (property)
    {
        case S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_AUTHENTICATED:
        {
            IwTrace(GAMECENTER, ("get authentic"));
            int authentic = [player isAuthenticated] ? 1 : 0;
            IwTrace(GAMECENTER, ("got authentic"));
            return authentic;
        }
        case S3E_IOSGAMECENTER_LOCAL_PLAYER_IS_UNDERAGE:
            return [player isUnderage] ? 1 : 0;
        case S3E_IOSGAMECENTER_LOCAL_PLAYER_HAS_FRIENDS_LOADED:
            return g_HasFriends;
        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return -1;
}

const char* s3eIOSGameCenterGetString(s3eIOSGameCenterProperty property)
{
    if (!s3eLocalPlayerIsAuthenticated())
        return "";

    char* buf = g_StringPropertyBuffer;

    switch (property)
    {
        case S3E_IOSGAMECENTER_LOCAL_PLAYER_ID:
            strlcpy(buf, [[GKLocalPlayer localPlayer].playerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            return buf;
        case S3E_IOSGAMECENTER_LOCAL_PLAYER_ALIAS:
            strlcpy(buf, [[GKLocalPlayer localPlayer].alias UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            return buf;
        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return "";
}

s3eResult s3eIOSGameCenterGetPlayers(const char** playerIDs, int numPlayers, s3eIOSGameCenterGetPlayersCallbackFn receivePlayersCB)
{
    GAMECENTER_CALLBACK_CHECK(receivePlayersCB, RECEIVE_PLAYERS)

    if (!numPlayers || !playerIDs)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    EDK_CALLBACK_REG(IOSGAMECENTER, RECEIVE_PLAYERS, (s3eCallback)receivePlayersCB, NULL, true);

    // Auto-releasing array from c strings
    NSMutableArray* playerArray = [NSMutableArray arrayWithCapacity: numPlayers];
    for (int i = 0; i < numPlayers; i++)
    {
        [playerArray addObject:[NSString stringWithUTF8String:playerIDs[i]]];
    }

    [GKPlayer loadPlayersForIdentifiers:playerArray withCompletionHandler:s3eLoadPlayersHandler];

    return S3E_RESULT_SUCCESS;
}

// Query for activity level of either whole application or a group of players using application if playerGroup = 0
// Only one request ongoing at a time. To cancel existing request, pass queryActivityCB=NULL.
s3eResult s3eIOSGameCenterQueryPlayersActivity(s3eIOSGameCenterActivityCallbackFn queryActivityCB, int playerGroup, void* userData)
{
    if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_QUERY_ACTIVITY))
    {
        if (!queryActivityCB && s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_QUERY_ACTIVITY, NULL) == S3E_RESULT_SUCCESS)
            return S3E_RESULT_SUCCESS;

        S3E_EXT_ERROR_SIMPLE(ALREADY_REG);
        return S3E_RESULT_ERROR;
    }

    EDK_CALLBACK_REG(IOSGAMECENTER, QUERY_ACTIVITY, (s3eCallback)queryActivityCB, userData, true);

    GKMatchmaker* matchMaker = [GKMatchmaker sharedMatchmaker];

    if (playerGroup)
        [matchMaker queryPlayerGroupActivity:playerGroup withCompletionHandler:s3eMatchMakerQueryGroupCompletionHandler];
    else
        [matchMaker queryActivityWithCompletionHandler:s3eMatchMakerQueryGroupCompletionHandler];

    return S3E_RESULT_SUCCESS;
}


// ---------- Mathchmaking ----------

// Players uses auto-releasing array from c strings. Request also autoreleases
GKMatchRequest* makeMatchRequest(s3eIOSGameCenterMatchRequest* request)
{
    GKMatchRequest* rtn = [[[GKMatchRequest alloc] init] autorelease];
    rtn.minPlayers = request->m_MinPlayers;
    rtn.maxPlayers = request->m_MaxPlayers;
    rtn.playerGroup = request->m_PlayerGroup;

    // This is ignored if not set! zero is a valid value IF explicitly set.
    if (request->m_UsePlayerAttributes)
        rtn.playerAttributes = request->m_PlayerAttributes;

    IwTrace(GAMECENTER, ("creating match request: min=%d max=%d group=%d attribs=%#x", rtn.minPlayers, rtn.maxPlayers, rtn.playerGroup, rtn.playerAttributes));
    if (request->m_NumPlayersToInvite && request->m_PlayersToInvite)
    {
        IwTrace(GAMECENTER, ("creating match invite: %d", request->m_NumPlayersToInvite));
        NSMutableArray* playerArray = [NSMutableArray arrayWithCapacity: request->m_NumPlayersToInvite];
        for (int i = 0; i < request->m_NumPlayersToInvite; i++)
        {
            if (!request->m_PlayersToInvite[i])
            {
                S3E_EXT_ERROR_SIMPLE(PARAM);
                IwTrace(GAMECENTER,("m_NumPlayersToInvite array contians null pointers"));
                return NULL;
            }
            [playerArray addObject:[NSString stringWithUTF8String:request->m_PlayersToInvite[i]]];
        }
        rtn.playersToInvite = playerArray;
    }

    return rtn;
}


// Register a function to recieve invites from matches created by other users.
// This should be called as early as possible in an application using game center (otherwise invites may be ignored).
// Passing NULL for inviteListenerCB stops the application processing invitations.
s3eResult s3eIOSGameCenterSetInviteHandler(s3eIOSGameCenterInviteCallbackFn callback)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterSetInviteHandler"));
    GAMECENTER_CALLBACK_CHECK(callback, INVITE)
    EDK_CALLBACK_REG(IOSGAMECENTER, INVITE, (s3eCallback)callback, NULL, true);
    [GKMatchmaker sharedMatchmaker].inviteHandler = s3eInviteHandler;
    return S3E_RESULT_SUCCESS;
}

void s3eIOSGameCenterInviteAcceptGUI_real(GKInvite* invite)
{
    GKMatchmakerViewController* controller = [[[s3eIOSGameKitMatchmakerViewController alloc] initWithInvite: invite] autorelease];
    controller.matchmakerDelegate = [[s3eIOSGameKitMatchmakerDelegate alloc] init];
    
    g_DummyController = [[DummyController alloc] init];
    UIView* dummyView = [[UIView alloc] init];
    g_DummyController.view = dummyView;
    [s3eEdkGetUIView() addSubview:g_DummyController.view];
    [g_DummyController presentModalViewController:controller animated:YES];
}

s3eBool s3eIOSGameCenterInviteAcceptGUI(void* inviteID, s3eIOSGameCenterMatchCallbacks* callbacks)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterInviteAcceptGUI: %p", inviteID));

    if (!inviteID || !callbacks)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    // Don't allow accept invite gui to display over matchmaking gui. Both use same globals
    // plus the accept always fails if you try to accept while matchmaking anyway. The app can
    // check if this function fails and retain the invite till the matchmaking UI closes (next yield)
    // if it wants to.
    if (g_InGUI)
    {
        S3E_EXT_ERROR(MATCHMAKING_IN_PROGRESS, ("Cannot launch invite GUI over Matchmaking GUI. Retry once matchmaking completes."));
        return S3E_FALSE;
    }

    g_MatchCallbacks = *callbacks;
    g_InGUI = 1;
    g_GUIResult = S3E_RESULT_ERROR;

    s3eEdkThreadRunOnOS((s3eEdkThreadFunc)s3eIOSGameCenterInviteAcceptGUI_real, 1, inviteID);

    while (g_InGUI)
    {
        usleep(10000);
        IwTrace(GAMECENTER, ("waiting for GUI ..."));
    }

    //[(GKInvite*)inviteID release];
    IwTrace(GAMECENTER, ("InviteAcceptGUI done: %d", g_GUIResult));
    return g_GUIResult == S3E_RESULT_SUCCESS;
}

// Invites need releasing due to being passed around callbacks. Can't assume s3eIOSGameCenterInviteAcceptGUI will
// get called, e.g. if the user cancels multiplayer while invite is incoming, so we should have an explicit release.
s3eResult s3eIOSGameCenterReleaseInvite(void* inviteID)
{
    if (!inviteID)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    IwTrace(GAMECENTER, ("Releasing invite: %p", inviteID));
    [(GKInvite*)inviteID release];
    return S3E_RESULT_SUCCESS;
}

bool requestedPlayerAmountIsValid(s3eIOSGameCenterMatchRequest* request)
{
    // invalid player min/max would cause internal GKMatchRequest invalid error in callback
    // but with no useful info so we do it instead
    if (request->m_MinPlayers < 2)
    {
        S3E_EXT_ERROR(PARAM, ("s3eIOSGameCenterMatchRequest invalid: m_MinPlayers must be >= 2"));
        return false;
    }

    if (request->m_MaxPlayers < request->m_MinPlayers)
    {
        S3E_EXT_ERROR(PARAM, ("s3eIOSGameCenterMatchRequest invalid: m_MaxPlayers must be >= m_MinPlayers"));
        return false;
    }

    return true;
}

// Find players for a match to be hosted externally from Game Center (matchmaking only, gamecenter does not manage the match).
s3eResult s3eIOSGameCenterMatchmakerFindPlayersForHostedRequest(s3eIOSGameCenterMatchRequest* request, s3eIOSGameCenterFindPlayersCallbackFn findPlayersCB, void* userData)
{
    CHECK_AUTH(S3E_RESULT_ERROR);

    GAMECENTER_CALLBACK_CHECK(findPlayersCB, FIND_PLAYERS)

    if (!request || !findPlayersCB)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    if (!requestedPlayerAmountIsValid(request))
        return S3E_RESULT_ERROR;

    EDK_CALLBACK_REG(IOSGAMECENTER, FIND_PLAYERS, (s3eCallback)findPlayersCB, userData, true);

    // makeMatchRequest autoreleases the request when done with
    GKMatchRequest* req = makeMatchRequest(request);
    if (!req)
    {
        if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS))
            s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS, NULL);

        return S3E_RESULT_ERROR;
    }

    [[GKMatchmaker sharedMatchmaker] findPlayersForHostedMatchRequest:req withCompletionHandler:s3eFindPlayersCompletionHandler];

    return S3E_RESULT_SUCCESS;
}

// Create a match based on a request. Match pointer will be passed to createMatchCB callback on
// success and the other callbacks will be registered. On failure,
s3eResult s3eIOSGameCenterMatchmakerCreateMatch(s3eIOSGameCenterMatchRequest* request,
                                             s3eIOSGameCenterCreateMatchCallbackFn createMatchCB,
                                             s3eIOSGameCenterMatchCallbacks* callbacks)
{
    if (g_MatchMaking)
    {
        S3E_EXT_ERROR_SIMPLE(ALREADY_IN_PROGRESS);
        return S3E_RESULT_ERROR;
    }

    if (!createMatchCB
    || !callbacks->m_ConnectionFailureCB
    || !callbacks->m_ConnectToPlayerFailureCB
    || !callbacks->m_PlayerStateChangeCB
    || !callbacks->m_ReceiveDataCB)
    {
        S3E_EXT_ERROR(PARAM, ("One or more callback functions were null"));
        return S3E_RESULT_ERROR;
    }

    EDK_CALLBACK_REG(IOSGAMECENTER, CREATE_MATCH, (s3eCallback)createMatchCB, NULL, true);

    // Will register other callbacks once match been created...
    g_MatchCallbacks = *callbacks;

    GKMatchRequest* req = makeMatchRequest(request);
    if (!req)
        return S3E_RESULT_ERROR;

    g_MatchMaking = true;
    IwTrace(GAMECENTER, ("findMatchForRequest"));
    [[GKMatchmaker sharedMatchmaker] findMatchForRequest:req withCompletionHandler:s3eCreateMatchCompletionHandler];
    return S3E_RESULT_SUCCESS;
}

static s3eResult s3eIOSGameCenterMatchmakerGUI_real(s3eIOSGameCenterMatchRequest* request)
{
    GKMatchRequest* req = makeMatchRequest(request);
    if (!req)
        return S3E_RESULT_ERROR;

    GKMatchmakerViewController* controller = [[[s3eIOSGameKitMatchmakerViewController alloc] initWithMatchRequest: req] autorelease];
    controller.hosted = request->m_Hosted ? YES : NO;
    controller.matchmakerDelegate = [[s3eIOSGameKitMatchmakerDelegate alloc] init];

    g_DummyController = [[DummyController alloc] init];
    UIView* dummyView = [[UIView alloc] init];
    g_DummyController.view = dummyView;
    [s3eEdkGetUIView() addSubview:g_DummyController.view];
    [g_DummyController presentModalViewController:controller animated:YES];
    return S3E_RESULT_SUCCESS;
}

s3eResult s3eIOSGameCenterMatchmakerGUI_Generic(s3eIOSGameCenterMatchRequest* request, s3eIOSGameCenterMatchCallbacks* callbacks, s3eIOSGameCenterFindPlayersCallbackFn findPlayersCB)
{
    CHECK_AUTH(S3E_RESULT_ERROR);
    if (g_MatchMaking)
    {
        S3E_EXT_ERROR_SIMPLE(ALREADY_IN_PROGRESS);
        return S3E_RESULT_ERROR;
    }

    if (!requestedPlayerAmountIsValid(request))
        return S3E_RESULT_ERROR;

    if (g_InGUI)
    {
        S3E_EXT_ERROR_SIMPLE(MATCHMAKING_IN_PROGRESS);
        return S3E_RESULT_ERROR;
    }

    if (request->m_Hosted)
        // register players list callback once params are checked. Using callback to allow app to
        // copy data out. Will occur in next yield after s3eIOSGameCenterMatchmakerGUIHosted returns.
        EDK_CALLBACK_REG(IOSGAMECENTER, FIND_PLAYERS, (s3eCallback)findPlayersCB, NULL, true);
    else
        // Register in-match callbacks once match has been created...
        g_MatchCallbacks = *callbacks;

    g_InGUI = 1;
    g_GUIResult = S3E_RESULT_ERROR;

    s3eResult rtn = (s3eResult)(intptr_t)
        s3eEdkThreadRunOnOS((s3eEdkThreadFunc)s3eIOSGameCenterMatchmakerGUI_real, 1, request);

    if (rtn != S3E_RESULT_SUCCESS)
    {
        if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS))
            s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS, NULL);

        return S3E_RESULT_ERROR;
    }

    while (g_InGUI)
    {
        usleep(10000);
        IwTrace(GAMECENTER, ("waiting for GUI ..."));
    }

    if (g_GUIResult == S3E_RESULT_ERROR && s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS))
        s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS, NULL);

    return g_GUIResult;
}

s3eResult s3eIOSGameCenterMatchmakerGUI(s3eIOSGameCenterMatchRequest* request, s3eIOSGameCenterMatchCallbacks* callbacks)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterMatchmakerGUI"));

    if (!request || !callbacks)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    // hosted is readonly in native request. use to idetify match type in generic code
    request->m_Hosted = false;

    return s3eIOSGameCenterMatchmakerGUI_Generic(request, callbacks, NULL);
}

s3eResult s3eIOSGameCenterMatchmakerHostedGUI(s3eIOSGameCenterMatchRequest* request, s3eIOSGameCenterFindPlayersCallbackFn findPlayersCB)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterMatchmakerHostedGUI"));

    if (!request || !findPlayersCB)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    // hosted is readonly in native request. use to idetify match type in generic code
    request->m_Hosted = true;

    return s3eIOSGameCenterMatchmakerGUI_Generic(request, NULL, findPlayersCB);
}

s3eResult s3eIOSGameCenterMatchmakerAddPlayersToMatch(s3eIOSGameCenterMatchRequest* request, s3eIOSGameCenterAddPlayersToMatchCallbackFn addPlayersCB, void* userData)
{
    CHECK_MATCH(S3E_RESULT_ERROR);

    GAMECENTER_CALLBACK_CHECK(addPlayersCB, ADD_PLAYERS_TO_MATCH)
    GKMatchRequest* req = makeMatchRequest(request);
    if (!req)
        return S3E_RESULT_ERROR;

    EDK_CALLBACK_REG(IOSGAMECENTER, ADD_PLAYERS_TO_MATCH, (s3eCallback)addPlayersCB, userData, true);

    [[GKMatchmaker sharedMatchmaker] addPlayersToMatch:g_Match matchRequest:req completionHandler:s3eAddPlayersToMatchCompletionHandler];
    return S3E_RESULT_SUCCESS;
}

// Cancel all matchmaking requests
void s3eIOSGameCenterCancelMatchmaking()
{
    // Unregister all callbacks for matchfinding at this point. Do this first to avoid callbacks being called with "cancelled" errors
    if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS))
        s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS, NULL);

    if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_CREATE_MATCH))
        s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_CREATE_MATCH, NULL);

    if (s3eEdkCallbacksIsRegistered(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_ADD_PLAYERS_TO_MATCH))
        s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_ADD_PLAYERS_TO_MATCH, NULL);

    [[GKMatchmaker sharedMatchmaker] cancel];
    g_MatchMaking = false;
}

// ---------- Match interaction functions ----------

// Note these implementations are very similar to IphoneGameKit since GKMatch is basically
// an easier to use but more powerful replacement for GKSession...

// Disconnect match
s3eResult s3eIOSGameCenterMatchDisconnect()
{
    // Note wec urrently just have the one global match and assume that was passed to the user originally.
    // Could expand this though doubtful anyone would want multiple matches. Not clear apples API supports it anyway.
    CHECK_MATCH(S3E_RESULT_ERROR);

    // Unregister match callbacks
    s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_CONNECTION_FAILURE, NULL);
    s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_CONNECT_TO_PLAYER_FAILURE, NULL);
    s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_PLAYER_STATE_CHANGE, NULL);
    s3eEdkCallbacksUnRegister(S3E_EXT_IOSGAMECENTER_HASH, S3E_IOSGAMECENTER_CALLBACK_MAX, S3E_IOSGAMECENTER_CALLBACK_RECEIVE_DATA, NULL);

    IwTrace(GAMECENTER_VERBOSE, ("s3eIOSGameCenterMatchDisconnect g_Match = %p", g_Match));

    // TODO: For sessions, we had to flag disconnection and then timeout for a second for bluetooth crap...
    // check something like that isn't needed here (unlikely)... ?

    // Disconnect and free all objects
    [g_Match disconnect];
    [g_Match release];
    [g_MatchDelegate release];
    g_Match = NULL;
    g_MatchDelegate = NULL;
    return S3E_RESULT_SUCCESS;
}

int32 s3eIOSGameCenterMatchGetInt(s3eIOSGameCenterMatchProperty property)
{
    CHECK_MATCH(-1);

    switch (property)
    {
        case S3E_IOSGAMECENTER_MATCH_EXPECTED_PLAYERS:
        {
            return (int32)(g_Match.expectedPlayerCount);
        }   
        default:
            break;
    }
    S3E_EXT_ERROR_SIMPLE(PARAM);
    return -1;
}

// Requests a list of players connected to the match, to be passed asynchronously to callback registered on start match
int32 s3eIOSGameCenterGetPlayerIDsInMatch(char** playerIDs, int maxPlayerIDs)
{
    CHECK_MATCH(-1);
    NSArray* playerIDArray = g_Match.playerIDs;
    int size = [playerIDArray count];

    if (playerIDs)
    {
        if (playerIDArray && maxPlayerIDs)
        {
            if (maxPlayerIDs > size)
                maxPlayerIDs = size;

            for (int i = 0; i < maxPlayerIDs; i++)
                strlcpy(playerIDs[i], [(NSString*)[playerIDArray objectAtIndex:i] UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
        }
    }
    // else just return amount

    return size;
}

void s3eIOSGameCenterReleasePlayers(struct s3eIOSGameCenterPlayer** players, int numPlayers)
{
    if (!numPlayers || !players)
        return;

    for (int i = 0; i < numPlayers; i++)
    {
        if (players[i])
        {
            GKPlayer* objCPlayer = (GKPlayer*)players[i];
            [objCPlayer release];
        }
        else
        {
            IwTrace(GAMECENTER, ("Trying to release null s3eIOSGameCenterPlayer object - ignoring"));
        }
    }
}

// Retrieves a string property for a player.
const char* s3eIOSGameCenterPlayerGetString(struct s3eIOSGameCenterPlayer* player, s3eIOSGameCenterPlayerProperty property)
{
    if (!player)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return 0;
    }

    GKPlayer* objCPlayer = (GKPlayer*)player;

    /*if (property != S3E_IOSGAMECENTER_PLAYER_VALID && !_CheckPlayerIsValid(objCPlayer)) //ignore _VALID as not a string property
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return 0;
    }*/

    switch (property)
    {
        case S3E_IOSGAMECENTER_PLAYER_ALIAS:
            return [objCPlayer.alias UTF8String];

        case S3E_IOSGAMECENTER_PLAYER_ID:
            return [objCPlayer.playerID UTF8String];

        // deprecated by apple
        //case S3E_IOSGAMECENTER_PLAYER_STATUS:
        //   return [objCPlayer.status UTF8String];

        default:
            break;
    }
    S3E_EXT_ERROR_SIMPLE(PARAM);
    return 0;
}

// Retrieves an int property for a player.
int32 s3eIOSGameCenterPlayerGetInt(struct s3eIOSGameCenterPlayer* player, s3eIOSGameCenterPlayerProperty property)
{
    if (!player)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return 0;
    }

    GKPlayer*   objCPlayer = (GKPlayer*)player;

    switch (property)
    {
        case S3E_IOSGAMECENTER_PLAYER_IS_FRIEND:
            return objCPlayer.isFriend ? 1 : 0;

        // used to be checking players in match, now app should just get IDs and search for player in them
        //case S3E_IOSGAMECENTER_PLAYER_VALID:
        //  return (_CheckPlayerIsValid(objCPlayer) ? 1 : 0);

        default:
            break;
    }
    S3E_EXT_ERROR_SIMPLE(PARAM);
    return 0;
}


s3eResult s3eIOSGameCenterSendDataToPlayers(char** playerIDs, int numPlayers, const void* data, int dataLen, s3eIOSGameCenterMatchSendDataMode mode)
{
    CHECK_MATCH(S3E_RESULT_ERROR);

    if (!playerIDs || !numPlayers || !data || !dataLen)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GKMatchSendDataMode objCMode = (mode == S3E_IOSGAMECENTER_MATCH_SEND_DATA_UNRELIABLE) ? GKMatchSendDataUnreliable : GKMatchSendDataReliable;

    // may want to check players are valid if this is possible...
    /*
    uint32 numValidPlayers = 0;
    for (int p=0; p < numPlayers; p++)
    {
        if _CheckPlayerIsValid((GKPlayer*)players[p])
        {
            validPlayers[numValidPlayers] = players[p];
            numValidPlayers++
        }
    }
    */

    // Auto-releasing array from c strings
    NSMutableArray* playerArray = [NSMutableArray arrayWithCapacity: numPlayers];
    for (int i = 0; i < numPlayers; i++)
    {
        [playerArray addObject:[NSString stringWithUTF8String:playerIDs[i]]];
    }

    NSData* nsdata =[NSData dataWithBytes:data length:dataLen];
    BOOL result = [g_Match sendData:nsdata
            toPlayers:playerArray
            withDataMode:objCMode error:&g_MatchDelegate->m_Error];

    if (result == YES)
        return S3E_RESULT_SUCCESS;

    IwTrace(GAMECENTER, ("SendDataToPlayers Failed %s\n", [[g_MatchDelegate->m_Error localizedDescription] UTF8String]));
    return S3E_RESULT_ERROR;
}

s3eResult s3eIOSGameCenterSendDataToAllPlayers(const void* data, int dataLen, s3eIOSGameCenterMatchSendDataMode mode)
{
    CHECK_MATCH(S3E_RESULT_ERROR);

    if (!data || !dataLen)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GKMatchSendDataMode objCMode = (mode == S3E_IOSGAMECENTER_MATCH_SEND_DATA_UNRELIABLE) ? GKMatchSendDataUnreliable : GKMatchSendDataReliable;

    BOOL success = [g_Match sendDataToAllPlayers:[NSData dataWithBytes:data length:dataLen]
                                                    withDataMode:objCMode
                                                    error:&g_MatchDelegate->m_Error];

    if (success)
    {
        IwTrace(GAMECENTER, ("sendDataToAllPlayers success\n"));
        return S3E_RESULT_SUCCESS;
    }

    IwTrace(GAMECENTER, ("sendDataToAllPlayers Failed %s\n", [[g_MatchDelegate->m_Error localizedFailureReason] UTF8String]));
    return S3E_RESULT_ERROR;
}


// ---------- Leaderboard  ----------

// Asynchronously load a list of categories (different leaderboards) available for the app.
s3eResult s3eIOSGameCenterLeaderboardLoadCategories(s3eIOSGameCenterLeaderboardLoadCategoriesCallbackFn loadCategoriesCB)
{
    // TODO: check if you need to log in before using leaderboards.
    GAMECENTER_CALLBACK_CHECK(loadCategoriesCB, LEADERBOARD_LOAD_CATEGORIES)
    EDK_CALLBACK_REG(IOSGAMECENTER, LEADERBOARD_LOAD_CATEGORIES, (s3eCallback)loadCategoriesCB, NULL, true);
    [GKLeaderboard loadCategoriesWithCompletionHandler:s3eLeaderboardLoadCategoriesHandler];
    return S3E_RESULT_SUCCESS;
}

void s3eIOSGameCenterLeaderboardShowGUI_real(const char* category, s3eIOSGameCenterTimeScope timeScope)
{
    GKLeaderboardViewController* controller = [[s3eIOSGameKitLeaderboardViewController alloc] init];
    controller.leaderboardDelegate = [[s3eIOSGameKitLeaderboardDelegate alloc] init];
    controller.category = [NSString stringWithUTF8String:category];

    switch (timeScope)
    {
        case S3E_IOSGAMECENTER_TIME_SCOPE_TODAY:
            controller.timeScope = GKLeaderboardTimeScopeToday;
            break;

        case S3E_IOSGAMECENTER_PLAYER_SCOPE_WEEK:
            controller.timeScope = GKLeaderboardTimeScopeWeek;
            break;

        case S3E_IOSGAMECENTER_PLAYER_SCOPE_ALL_TIME:
        default:
            controller.timeScope = GKLeaderboardTimeScopeAllTime;
            break;
    }

    g_DummyController = [[DummyController alloc] init];
    UIView* dummyView = [[UIView alloc] init];
    g_DummyController.view = dummyView;
    [s3eEdkGetUIView() addSubview:g_DummyController.view];
    [g_DummyController presentModalViewController:controller animated:YES];
    [controller release];
}

// Display default GUI (only category and time limits supported natively)
s3eResult s3eIOSGameCenterLeaderboardShowGUI(const char* category, s3eIOSGameCenterTimeScope timeScope)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterLeaderboardShowGUI: %s %d", category, (int)timeScope));

    if (!category)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    // Ban display while other GUIs are in use for simplicity
    if (g_InGUI)
    {
        S3E_EXT_ERROR(MATCHMAKING_IN_PROGRESS, ("Matchmaking GUI currently displayed"));
        return S3E_RESULT_ERROR;
    }

    g_InGUI = 1;
    s3eEdkThreadRunOnOS((s3eEdkThreadFunc)s3eIOSGameCenterLeaderboardShowGUI_real, 2, category, timeScope);

    while (g_InGUI)
    {
        usleep(10000);
        IwTrace(GAMECENTER, ("waiting for leaderboard GUI ..."));
    }

    return S3E_RESULT_SUCCESS;
}

// Create a leaderboard to then use to request score information
s3eIOSGameCenterLeaderboard* s3eIOSGameCenterCreateLeaderboard(const char** playerIDs, int numPlayers)
{
    GKLeaderboard* objCBoard = NULL;

    if (!s3eLocalPlayerIsAuthenticated())
        return NULL;

    if (!numPlayers)
    {
        objCBoard = [[GKLeaderboard alloc] init];
    }
    else
    {
        if (!playerIDs)
        {
            S3E_EXT_ERROR_SIMPLE(PARAM);
            return NULL;
        }

        // Autoreleasing array
        NSMutableArray* playerArray = [NSMutableArray arrayWithCapacity: numPlayers];
        for (int i = 0; i < numPlayers; i++)
        {
            [playerArray addObject:[NSString stringWithUTF8String:playerIDs[i]]];
        }

        objCBoard = [[GKLeaderboard alloc] initWithPlayerIDs:playerArray];
    }

    return (s3eIOSGameCenterLeaderboard*)objCBoard;
}

// Get a leaderboard value
int32 s3eIOSGameCenterLeaderboardGetInt(s3eIOSGameCenterLeaderboard* leaderboard, s3eIOSGameCenterLeaderboardProperty property)
{
    if (!leaderboard)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GKLeaderboard* objCBoard = (GKLeaderboard*)leaderboard;

    switch (property)
    {
        case S3E_IOSGAMECENTER_LEADERBOARD_PLAYER_SCOPE:
        {
            switch (objCBoard.playerScope)
            {
                case GKLeaderboardPlayerScopeFriendsOnly:
                    return (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_FRIENDS_ONLY;
                case GKLeaderboardPlayerScopeGlobal:
                    return (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_GLOBAL;
                default:
                    break;
            }
        }
        case S3E_IOSGAMECENTER_LEADERBOARD_RANGE_START:
            return objCBoard.range.location;

        case S3E_IOSGAMECENTER_LEADERBOARD_RANGE_SIZE:
            return objCBoard.range.length;

        case S3E_IOSGAMECENTER_LEADERBOARD_TIME_SCOPE:
        {
            switch (objCBoard.timeScope)
            {
                case GKLeaderboardTimeScopeToday:
                    return (int32)S3E_IOSGAMECENTER_TIME_SCOPE_TODAY;
                case GKLeaderboardTimeScopeWeek:
                    return (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_WEEK;
                case GKLeaderboardTimeScopeAllTime:
                default:
                    return (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_ALL_TIME;
            }
        }
        /*
        case S3E_IOSGAMECENTER_LEADERBOARD_LOADING:
            return objCBoard.loading ? 1 : 0;
            */
        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return 0;
}

// Set a leaderboard value to specify which scores to retrieve
s3eResult s3eIOSGameCenterLeaderboardSetInt(s3eIOSGameCenterLeaderboard* leaderboard, s3eIOSGameCenterLeaderboardProperty property, int32 value)
{
    if (!leaderboard)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GKLeaderboard* objCBoard = (GKLeaderboard*)leaderboard;

    switch (property)
    {
        case S3E_IOSGAMECENTER_LEADERBOARD_PLAYER_SCOPE:
        {
            if (value == (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_GLOBAL)
            {
                objCBoard.playerScope = GKLeaderboardPlayerScopeGlobal;
                return S3E_RESULT_SUCCESS;
            }
            else if (value == (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_FRIENDS_ONLY)
            {
                objCBoard.playerScope = GKLeaderboardPlayerScopeFriendsOnly;
                return S3E_RESULT_SUCCESS;
            }
            else
                break;
        }
        case S3E_IOSGAMECENTER_LEADERBOARD_RANGE_START:
        {
            // Note these have limits of 1 to 100 but this might change so we'll let the iphone api handle it and error
            objCBoard.range.location = value;
            return S3E_RESULT_SUCCESS;
        }   
        case S3E_IOSGAMECENTER_LEADERBOARD_RANGE_SIZE:
        {
            objCBoard.range.length = value;
            return S3E_RESULT_SUCCESS;
        }
        case S3E_IOSGAMECENTER_LEADERBOARD_TIME_SCOPE:
        {
            if (value == (int32)S3E_IOSGAMECENTER_TIME_SCOPE_TODAY)
            {
                objCBoard.playerScope = GKLeaderboardTimeScopeToday;
                return S3E_RESULT_SUCCESS;
            }
            else if (value == (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_WEEK)
            {
                objCBoard.playerScope = GKLeaderboardTimeScopeWeek;
                return S3E_RESULT_SUCCESS;
            }
            else if (value == (int32)S3E_IOSGAMECENTER_PLAYER_SCOPE_ALL_TIME)
            {
                objCBoard.playerScope = GKLeaderboardTimeScopeAllTime;
                return S3E_RESULT_SUCCESS;
            }
            else
                break;
        }
        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return S3E_RESULT_ERROR;
}

const char* s3eIOSGameCenterLeaderboardGetString(s3eIOSGameCenterLeaderboard* leaderboard, s3eIOSGameCenterLeaderboardProperty property)
{
    if (!leaderboard)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return "";
    }

    char* buf = g_StringPropertyBuffer;

    GKLeaderboard* objCBoard = (GKLeaderboard*)leaderboard;

    switch (property)
    {
        case S3E_IOSGAMECENTER_LEADERBOARD_CATEGORY:
            strlcpy(buf, [objCBoard.category UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            return buf;
        case S3E_IOSGAMECENTER_LEADERBOARD_TITLE:
            strlcpy(buf, [objCBoard.title UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            return buf;
        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return "";
}

s3eResult s3eIOSGameCenterLeaderboardSetString(s3eIOSGameCenterLeaderboard* leaderboard, s3eIOSGameCenterLeaderboardProperty property, const char* value)
{
    if (!leaderboard || (!value && property != S3E_IOSGAMECENTER_LEADERBOARD_CATEGORY))
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GKLeaderboard* objCBoard = (GKLeaderboard*)leaderboard;

    switch (property)
    {
        case S3E_IOSGAMECENTER_LEADERBOARD_CATEGORY:
        {
            // Can use null or empty string to set back to default of "no category"
            if (!value || !value[0])
                objCBoard.category = nil;
            else
                objCBoard.category = [NSString stringWithUTF8String:value];
            return S3E_RESULT_SUCCESS;
        }
        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return S3E_RESULT_ERROR;
}

// Asynchronously Request scores that match the requirements of a given leaderboard.
s3eResult s3eIOSGameCenterLeaderboardLoadScores(s3eIOSGameCenterLeaderboard* leaderboard, s3eIOSGameCenterLoadScoresCallbackFn loadScoresCB)
{
    if (!s3eLocalPlayerIsAuthenticated())
        return S3E_RESULT_ERROR;

    if (!leaderboard || !loadScoresCB)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GAMECENTER_CALLBACK_CHECK(loadScoresCB, LEADERBOARD_LOAD_SCORES)

    GKLeaderboard* objCBoard = (GKLeaderboard*)leaderboard;
    IwTrace(GAMECENTER, ("LoadScores for board (%p) with category (%s)", objCBoard, objCBoard.category ? [objCBoard.category UTF8String] : "none"));

    EDK_CALLBACK_REG(IOSGAMECENTER, LEADERBOARD_LOAD_SCORES, (s3eCallback)loadScoresCB, NULL, true);
    [objCBoard loadScoresWithCompletionHandler:s3eLoadScoresCompletionHandler];
    return S3E_RESULT_SUCCESS;
}

// Release a leaderboard. Should be called for every board created with s3eIOSGameCenterCreateLeaderboard when finished with.
s3eResult s3eIOSGameCenterLeaderboardRelease(s3eIOSGameCenterLeaderboard* leaderboard)
{
    if (!leaderboard)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    GKLeaderboard* objCBoard = (GKLeaderboard*)leaderboard;
    [objCBoard release];
    return S3E_RESULT_SUCCESS;
}

/**
 * Report/submit a score to the Game Center servers. scoreReport indicates
 * whether the asynchronous submission is successful.
 */
s3eResult s3eIOSGameCenterReportScore(int64 score, const char* category, s3eIOSGameCenterOperationCompleteCallbackFn scoreReportCB)
{
    GAMECENTER_CALLBACK_CHECK(scoreReportCB, REPORT_SCORE);
    CHECK_AUTH(S3E_RESULT_ERROR);

    if (!scoreReportCB || !category)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    IwTrace(GAMECENTER, ("ReportScore: %lld %s", score, category));
    NSString* cat = [NSString stringWithUTF8String: category];
    GKScore* objCScore = [[[GKScore alloc] initWithCategory:cat] autorelease];
    objCScore.value = score;

    EDK_CALLBACK_REG(IOSGAMECENTER, REPORT_SCORE, (s3eCallback)scoreReportCB, NULL, true);
    [objCScore reportScoreWithCompletionHandler:s3eReportScoreCompletionHandler];
    return S3E_RESULT_SUCCESS;
}

// ---------- Achievements ----------

void s3eIOSGameCenterAchievementsShowGUI_real()
{
    GKAchievementViewController* controller = [[s3eIOSGameKitAchievementsViewController alloc] init];
    controller.achievementDelegate = [[s3eIOSGameKitAchievementsDelegate alloc] init];

    g_DummyController = [[DummyController alloc] init];
    UIView* dummyView = [[UIView alloc] init];
    g_DummyController.view = dummyView;
    [s3eEdkGetUIView() addSubview:g_DummyController.view];
    [g_DummyController presentModalViewController:controller animated:YES];
    [controller release];
}

// Display default GUI (only category and time limits supported natively)
s3eResult s3eIOSGameCenterAchievementsShowGUI()
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterAchievementsShowGUI"));

    // Ban display while other GUIs are in use for simplicity
    if (g_InGUI)
    {
        S3E_EXT_ERROR(MATCHMAKING_IN_PROGRESS, ("Another GUI currently displayed"));
        return S3E_RESULT_ERROR;
    }

    g_InGUI = 1;
    s3eEdkThreadRunOnOS((s3eEdkThreadFunc)s3eIOSGameCenterAchievementsShowGUI_real, 0);

    while (g_InGUI)
    {
        usleep(10000);
        IwTrace(GAMECENTER, ("waiting for achievements GUI ..."));
    }

    return S3E_RESULT_SUCCESS;
}

void(^loadAchievementInfoHandler)(NSArray*, NSError*) = ^(NSArray *achievements, NSError *error)
{
    int num = [achievements count];
    IwTrace(GAMECENTER, ("loadAchievementInfoHandler: %d", num));
    s3eIOSGameCenterAchievementInfoList* res = (s3eIOSGameCenterAchievementInfoList*)s3eEdkMallocOS(sizeof(s3eIOSGameCenterAchievementInfoList));
    memset(res, 0, sizeof(*res));
    if (error)
    {
        res->m_Error = ObjcToS3EError(error);
    }
    else
    {
        res->m_AchievementCount = num;
        res->m_Achievements = (s3eIOSGameCenterAchievementInfo*)s3eEdkMallocOS(sizeof(s3eIOSGameCenterAchievementInfo)*num);
        for (int i = 0; i < num; i++)
        {
            GKAchievementDescription* desc = [achievements objectAtIndex:i];
            IwTrace(GAMECENTER, ("%s %s", [desc.identifier UTF8String], [desc.title UTF8String]));

            s3eIOSGameCenterAchievementInfo& info = res->m_Achievements[i];
            strlcpy(info.m_Identifier, [desc.identifier UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            strlcpy(info.m_Title, [desc.title UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            strlcpy(info.m_AchievedDescription, [desc.achievedDescription UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            strlcpy(info.m_UnachievedDescription, [desc.unachievedDescription UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            info.m_MaxPoints = desc.maximumPoints;
        }
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_LOAD_ACHIEVEMENT_INFO,
                           res,
                           sizeof(*res),
                           NULL,
                           S3E_TRUE,
                           s3eGCReleaseAcheivementInfo,
                           NULL);
};

s3eResult s3eIOSGameCenterLoadAchievementInfo(s3eIOSGameCenterLoadAchievementInfoCallbackFn callback)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterLoadAchievementInfo"));
    GAMECENTER_CALLBACK_CHECK(callback, LOAD_ACHIEVEMENT_INFO);
    CHECK_AUTH(S3E_RESULT_ERROR);
    EDK_CALLBACK_REG(IOSGAMECENTER, LOAD_ACHIEVEMENT_INFO, (s3eCallback)callback, NULL, true);
    [GKAchievementDescription loadAchievementDescriptionsWithCompletionHandler: loadAchievementInfoHandler];
    return S3E_RESULT_SUCCESS;
}

void(^loadAchievementsHandler)(NSArray*, NSError*) = ^(NSArray *achievements, NSError *error)
{
    int num = [achievements count];
    IwTrace(GAMECENTER, ("loadAchievementHandler: %d", num));
    s3eIOSGameCenterAchievementList* res = (s3eIOSGameCenterAchievementList*)s3eEdkMallocOS(sizeof(s3eIOSGameCenterAchievementList));
    memset(res, 0, sizeof(*res));
    if (error)
    {
        res->m_Error = ObjcToS3EError(error);
    }
    else
    {
        res->m_AchievementCount = num;
        res->m_Achievements = (s3eIOSGameCenterAchievement*)s3eEdkMallocOS(sizeof(s3eIOSGameCenterAchievement)*num);
        for (int i = 0; i < num; i++)
        {
            s3eIOSGameCenterAchievement& achievement = res->m_Achievements[i];
            GKAchievement* gkAchievement = [achievements objectAtIndex:i];
            IwTrace(GAMECENTER, ("%s", [gkAchievement.identifier UTF8String]));
            strlcpy(achievement.m_Identifier, [gkAchievement.identifier UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
            achievement.m_PercentComplete = gkAchievement.percentComplete;
        }
    }

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_LOAD_ACHIEVEMENTS,
                           res,
                           sizeof(*res),
                           NULL,
                           S3E_TRUE,
                           s3eGCReleaseAcheivements,
                           NULL);
};

void(^resetAchievementsHandler)(NSError*) = ^(NSError *error)
{
    IwTrace(GAMECENTER, ("resetAchievementsHandler"));
};

s3eResult s3eIOSGameCenterLoadAchievements(s3eIOSGameCenterLoadAchievementsCallbackFn callback)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterLoadAchievements"));
    CHECK_AUTH(S3E_RESULT_ERROR);
    GAMECENTER_CALLBACK_CHECK(callback, LOAD_ACHIEVEMENTS);
    EDK_CALLBACK_REG(IOSGAMECENTER, LOAD_ACHIEVEMENTS, (s3eCallback)callback, NULL, true);
    [GKAchievement loadAchievementsWithCompletionHandler: loadAchievementsHandler];
    return S3E_RESULT_SUCCESS;
}

s3eResult s3eIOSGameCenterAchievementsReset()
{
    CHECK_AUTH(S3E_RESULT_ERROR);
    [GKAchievement resetAchievementsWithCompletionHandler: resetAchievementsHandler];
    return S3E_RESULT_SUCCESS;
}

void(^reportAchievementCompleteHandler)(NSError*) = ^(NSError *error)
{
    IwTrace(GAMECENTER, ("reportAchievementCompleteHandler: %p", error));
    void* res = NULL;
    int resLen = 0;

    s3eIOSGameCenterError err = S3E_IOSGAMECENTER_ERR_NONE;
    if (error)
        err = ObjcToS3EError(error);

    res = &err;
    resLen = sizeof(err);    
    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_REPORT_ACHIEVEMENT,
                           res,
                           resLen,
                           NULL,
                           S3E_TRUE,
                           NULL,
                           NULL);
};

s3eResult s3eIOSGameCenterReportAchievement(const char* name, int percentComplete, s3eIOSGameCenterOperationCompleteCallbackFn callback)
{
    IwTrace(GAMECENTER, ("s3eIOSGameCenterReportAchievement: %s %d", name, percentComplete));
    CHECK_AUTH(S3E_RESULT_ERROR);
    GAMECENTER_CALLBACK_CHECK(callback, REPORT_ACHIEVEMENT);
    GKAchievement* achievement = [[GKAchievement alloc] initWithIdentifier: [NSString stringWithUTF8String:name]];
    achievement.percentComplete = percentComplete;
    EDK_CALLBACK_REG(IOSGAMECENTER, REPORT_ACHIEVEMENT, (s3eCallback)callback, NULL, true);
    [achievement reportAchievementWithCompletionHandler: reportAchievementCompleteHandler];
    return S3E_RESULT_SUCCESS;
}


// ---------- Voice chat ----------

s3eBool s3eGameCentreVoiceChatIsAllowed()
{
    BOOL isAllowed = [GKVoiceChat isVoIPAllowed];
    return isAllowed;
}

s3eResult s3eIOSGameCenterSetVoiceChatUpdateHandler(s3eIOSGameCenterVoiceChatUpdateCallbackFn voiceChatUpdateCB)
{
    GAMECENTER_CALLBACK_CHECK(voiceChatUpdateCB, VOICE_CHAT_UPDATE)
    EDK_CALLBACK_REG(IOSGAMECENTER, VOICE_CHAT_UPDATE, (s3eCallback)voiceChatUpdateCB, NULL, true);
    return S3E_RESULT_SUCCESS;
}

void(^playerStateUpdateHandler)(NSString*, GKVoiceChatPlayerState) = ^(NSString *playerID, GKVoiceChatPlayerState state)
{
    IwTrace(GAMECENTER, ("playerStateUpdateHandler"));

    s3eIOSGameCenterVoiceChatPlayerState playerState;
    memset(&playerState, 0, sizeof(playerState));

    strlcpy(playerState.m_PlayerID, [playerID UTF8String], S3E_IOSGAMECENTER_STRING_MAX);
    playerState.m_State = (s3eIOSGameCenterVoiceChatState) state;

    s3eEdkCallbacksEnqueue(S3E_EXT_IOSGAMECENTER_HASH,
                           S3E_IOSGAMECENTER_CALLBACK_VOICE_CHAT_UPDATE,
                           &playerState,
                           sizeof(playerState));
};

// Join a voice chat channel by match and name. This will create a voice chat connection using
// the current match parameters so that connected players in that match can also join it.
// Will return nil if parental controls are turned on.
s3eIOSGameCenterVoiceChat* s3eIOSGameCenterVoiceChatOpenChannel(const char* channelName)
{
    CHECK_MATCH(NULL);
    if (!channelName || channelName[0] == '\0')
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return NULL;
    }

    IwTrace(GAMECENTER, ("VoidChatOpenChannel: %s", channelName));

    // Audio session needs to be using PlayAndRecord, mixing and speaker.
    // These are the defaults except for audio input ("Record") which must be
    // enabaled.
    if (s3eEdkIPhoneSetAudioInputEnabled(S3E_TRUE) == S3E_RESULT_ERROR)
    {
        S3E_EXT_ERROR(DEVICE, "Audio device failed to enable input");
        return NULL;
    }

    // Create or open (if already exists) channel
    NSString* name = [NSString stringWithUTF8String:channelName];
    GKVoiceChat* voiceChat = [g_Match voiceChatWithName:name];
    if (!voiceChat)
    {
        S3E_EXT_ERROR(DEVICE, ("unable to create voice chat channel"));
        return NULL;
    }

    // "Your application should retain the voice chat object returned by this method."
    [voiceChat retain];
    voiceChat.playerStateUpdateHandler = playerStateUpdateHandler;

    s3eIOSGameCenterVoiceChat* gcVoiceChat =
        (s3eIOSGameCenterVoiceChat*)s3eEdkMallocOS(sizeof(s3eIOSGameCenterVoiceChat));
    memset(gcVoiceChat, 0, sizeof(*gcVoiceChat));

    gcVoiceChat->m_VoiceChat = voiceChat;

    // TODO: Store this with g_Match so we can ensure channels are closed.
    return gcVoiceChat;
}

s3eResult s3eIOSGameCenterVoiceChatCloseChannel(s3eIOSGameCenterVoiceChat* channel)
{
    CHECK_MATCH(S3E_RESULT_ERROR);

    if (!channel)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    // TODO Remove from global match list
    [channel->m_VoiceChat release];
    s3eEdkFreeOS(channel);

    return S3E_RESULT_SUCCESS;
}

int32 s3eIOSGameCenterVoiceChatGetInt(s3eIOSGameCenterVoiceChat* channel, s3eIOSGameCenterVoiceChatProperty property)
{
    if (!channel)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return 0;
    }

    switch (property)
    {
        case S3E_IOSGAMECENTER_VOICE_CHAT_START:
            return channel->m_Started;

        case S3E_IOSGAMECENTER_VOICE_CHAT_ACTIVE:
            return channel->m_VoiceChat.active ? 1 : 0;

        case S3E_IOSGAMECENTER_VOICE_CHAT_VOLUME:
            return (int32)(255 * channel->m_VoiceChat.volume);

        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return -1;
}

s3eResult s3eIOSGameCenterVoiceChatSetInt(s3eIOSGameCenterVoiceChat* channel, s3eIOSGameCenterVoiceChatProperty property, int32 value)
{
    if (!channel)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    switch (property)
    {
        case S3E_IOSGAMECENTER_VOICE_CHAT_START:
        {
            s3eBool startNotStop = value ? S3E_TRUE : S3E_FALSE;
            if (channel->m_Started != startNotStop)
            {
                channel->m_Started = startNotStop;
                if (startNotStop)
                {
                    IwTrace(GAMECENTER, ("starting voice chat"));
                    [channel->m_VoiceChat start];
                }
                else
                {
                    IwTrace(GAMECENTER, ("stopping voice chat"));
                    [channel->m_VoiceChat stop];
                }
            }
            return S3E_RESULT_SUCCESS;
        }

        case S3E_IOSGAMECENTER_VOICE_CHAT_ACTIVE:
            channel->m_VoiceChat.active = value != 0;
            return S3E_RESULT_SUCCESS;  

        case S3E_IOSGAMECENTER_VOICE_CHAT_VOLUME:
            channel->m_VoiceChat.volume = (float) value / 255.;
            return S3E_RESULT_SUCCESS;

        default:
            break;
    }

    S3E_EXT_ERROR_SIMPLE(PARAM);
    return S3E_RESULT_ERROR;
}

s3eResult s3eIOSGameCenterVoiceChatSetMute(s3eIOSGameCenterVoiceChat* channel, const char* playerID, s3eBool mute)
{
    if (!channel || !playerID)
    {
        S3E_EXT_ERROR_SIMPLE(PARAM);
        return S3E_RESULT_ERROR;
    }

    [channel->m_VoiceChat setMute:mute forPlayer:[NSString stringWithUTF8String:playerID]];

    return S3E_RESULT_SUCCESS;
}
