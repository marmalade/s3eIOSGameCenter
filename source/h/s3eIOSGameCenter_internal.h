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
#ifndef S3E_IOSGAMECENTER_INTERNAL_H
#define S3E_IOSGAMECENTER_INTERNAL_H

#include "s3eTypes.h"
#include "s3eIOSGameCenter.h"
#include "s3eIOSGameCenter_autodefs.h"

// TODO internal callbacks here
typedef enum s3eIOSGameCenterCallback
{
	S3E_IOSGAMECENTER_CALLBACK_AUTHENTICATION, // todo: label these (pretty self explanitory)
	S3E_IOSGAMECENTER_CALLBACK_LOAD_FRIENDS,
	S3E_IOSGAMECENTER_CALLBACK_FIND_PLAYERS,
	S3E_IOSGAMECENTER_CALLBACK_QUERY_ACTIVITY,
	S3E_IOSGAMECENTER_CALLBACK_INVITE,
	S3E_IOSGAMECENTER_CALLBACK_CREATE_MATCH,
	S3E_IOSGAMECENTER_CALLBACK_ADD_PLAYERS_TO_MATCH,
	S3E_IOSGAMECENTER_CALLBACK_CONNECTION_FAILURE, // this event is used to report the application failing to connect with any players (starting the match failed)
	S3E_IOSGAMECENTER_CALLBACK_CONNECT_TO_PLAYER_FAILURE, // this event is used to report the application failing to transmit data to a specific player
	S3E_IOSGAMECENTER_CALLBACK_PLAYER_STATE_CHANGE, // this event is used to report a player connecting to or disconnecting from the match
	S3E_IOSGAMECENTER_CALLBACK_RECEIVE_DATA, // this event is used to report recieving data from another player in the match
	S3E_IOSGAMECENTER_CALLBACK_RECEIVE_PLAYERS, // this event is used to report recieving the list of players in the match
	S3E_IOSGAMECENTER_CALLBACK_LEADERBOARD_LOAD_CATEGORIES,
	S3E_IOSGAMECENTER_CALLBACK_LEADERBOARD_LOAD_SCORES,
	S3E_IOSGAMECENTER_CALLBACK_REPORT_SCORE,
	S3E_IOSGAMECENTER_CALLBACK_LOAD_ACHIEVEMENTS,
	S3E_IOSGAMECENTER_CALLBACK_LOAD_ACHIEVEMENT_INFO,
	S3E_IOSGAMECENTER_CALLBACK_REPORT_ACHIEVEMENT,
	S3E_IOSGAMECENTER_CALLBACK_VOICE_CHAT_UPDATE,
	S3E_IOSGAMECENTER_CALLBACK_MAX
} s3eIOSGameCenterCallback;

typedef int32 (*s3eIOSGameCenterCallbackFn)(struct s3eIOSGameCenterMatch* search, void* sysData, void* userData);

#endif // !S3E_IOSGAMECENTER_INTERNAL_H
