//
//  AIMBArtHandler.m
//  LibOrange
//
//  Created by Alex Nichol on 6/10/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "AIMBArtHandler.h"
#import "AIMSessionManager.h"

@interface AIMBArtHandler (Private)

- (void)_delegateInformConnectionFailed;
- (void)_delegateInformConnected;
- (void)_delegateInformDisconnected;

- (void)_handleConnectInfo:(NSArray *)tlvs;
- (BOOL)_openConnection:(NSString *)hostWPort;
- (BOOL)_bartSignon:(NSData *)cookie;

- (SNAC *)waitOnConnectionForSnacID:(SNAC_ID)snacID;

@end

@implementation AIMBArtHandler

@synthesize delegate;

- (id)initWithSession:(AIMSession *)aSession {
	if ((self = [super init])) {
		bossSession = aSession;
		[bossSession addHandler:self];
	}
	return self;
}
- (BOOL)startupBArt {
	NSAssert([NSThread currentThread] == [bossSession backgroundThread], @"Running on incorrect thread");
	UInt16 foodgroup = flipUInt16(SNAC_BART);
	SNAC * serviceRequest = [[SNAC alloc] initWithID:SNAC_ID_NEW(SNAC_OSERVICE, OSERVICE__SERVICE_REQUEST) flags:0 requestID:[bossSession generateReqID] data:[NSData dataWithBytes:&foodgroup length:2]];
	
	BOOL success = [bossSession writeSnac:serviceRequest];
	[serviceRequest release];
	return success;
}

- (void)handleIncomingSnac:(SNAC *)aSnac {
	NSAssert([NSThread currentThread] == [bossSession backgroundThread], @"Running on incorrect thread");
	if (SNAC_ID_IS_EQUAL(SNAC_ID_NEW(SNAC_OSERVICE, OSERVICE__SERVICE_RESPONSE), [aSnac snac_id])) {
		NSArray * connectInfo = [TLV decodeTLVArray:[aSnac innerContents]];
		if (connectInfo) [self _handleConnectInfo:connectInfo];
	}
}

#pragma mark Private

- (void)_delegateInformConnectionFailed {
	NSAssert([NSThread currentThread] == [bossSession mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimBArtHandlerConnectFailed:)]) {
		[delegate aimBArtHandlerConnectFailed:self];
	}
}

- (void)_delegateInformConnected {
	NSAssert([NSThread currentThread] == [bossSession mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimBArtHandlerConnectedToBArt:)]) {
		[delegate aimBArtHandlerConnectedToBArt:self];
	}
}

- (void)_delegateInformDisconnected {
	NSAssert([NSThread currentThread] == [bossSession mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimBArtHandlerDisconnected:)]) {
		[delegate aimBArtHandlerDisconnected:self];
	}
}

- (void)_handleConnectInfo:(NSArray *)tlvs {
	NSAssert([NSThread currentThread] == [bossSession backgroundThread], @"Running on incorrect thread");
	NSString * connectHere = nil;
	NSData * cookie = nil;
	UInt16 foodgroup = 0;
	for (TLV * tag in tlvs) {
		if ([tag type] == TLV_RECONNECT_HERE) {
			connectHere = [[[NSString alloc] initWithData:[tag tlvData] encoding:NSASCIIStringEncoding] autorelease];
		} else if ([tag type] == TLV_LOGIN_COOKIE) {
			cookie = [tag tlvData];
		} else if ([tag type] == TLV_GROUP_ID) {
			if ([[tag tlvData] length] == 2) {
				foodgroup = flipUInt16(*(const UInt16 *)[[tag tlvData] bytes]);
			}
		}
	}
	if (foodgroup == SNAC_BART) {
		if (connectHere) {
			[bartHost release];
			bartHost = [connectHere retain];
		}
		if (cookie) {
			[bartCookie release];
			bartCookie = [cookie retain];
		}
		BOOL success = [self _openConnection:bartHost];
		if (!success) {
			[currentConnection disconnect];
			[currentConnection release];
			currentConnection = nil;
			[self performSelector:@selector(_delegateInformConnectionFailed) onThread:[bossSession mainThread] withObject:nil waitUntilDone:NO];
		} else {
			if (![self _bartSignon:bartCookie]) {
				[currentConnection disconnect];
				[currentConnection release];
				currentConnection = nil;
				[self performSelector:@selector(_delegateInformConnectionFailed) onThread:[bossSession mainThread] withObject:nil waitUntilDone:NO];
			} else {
				[self performSelector:@selector(_delegateInformConnected) onThread:[bossSession mainThread] withObject:nil waitUntilDone:NO];
			}
		}
	}

}

- (BOOL)_openConnection:(NSString *)hostWPort {
	NSAssert([NSThread currentThread] == [bossSession backgroundThread], @"Running on incorrect thread");
	if (!hostWPort) {
		return NO;
	}
	NSArray * comps = [hostWPort componentsSeparatedByString:@":"];
	NSString * host = hostWPort;
	int port = 5901;
	if ([comps count] == 2) {
		host = [comps objectAtIndex:0];
		port = [[comps objectAtIndex:1] intValue];
	} else if ([comps count] != 1) {
		return NO;
	}
	currentConnection = [[OSCARConnection alloc] initWithHost:host port:port];
	return [currentConnection connectToHost:nil];
}

- (BOOL)_bartSignon:(NSData *)cookie {
	NSAssert([NSThread currentThread] == [bossSession backgroundThread], @"Running on incorrect thread");
	if (!cookie) return NO;
	UInt32 version = flipUInt32(1);
	TLV * signonCookie = [[TLV alloc] initWithType:TLV_LOGIN_COOKIE data:cookie];
	NSMutableData * signonFrameData = [[NSMutableData alloc] init];
	[signonFrameData appendBytes:&version length:4];
	[signonFrameData appendData:[signonCookie encodePacket]];
	[signonCookie release];
	FLAPFrame * signon = [currentConnection createFlapChannel:1 data:signonFrameData];
	[signonFrameData release];
	if (![currentConnection writeFlap:signon]) {
		return NO;
	}
	if (![self waitOnConnectionForSnacID:SNAC_ID_NEW(SNAC_OSERVICE, OSERVICE__HOST_ONLINE)]) {
		return NO;
	}
	if (![AIMSessionManager signonClientOnline:currentConnection]) {
		return NO;
	}
	[currentConnection setIsNonBlocking:YES];
	[currentConnection setDelegate:self];
	return YES;
}

#pragma mark Network

- (SNAC *)waitOnConnectionForSnacID:(SNAC_ID)snacID {
	while (YES) {
		FLAPFrame * flap = [currentConnection readFlap];
		if (![currentConnection isOpen]) return nil;
		SNAC * snac = [[SNAC alloc] initWithData:[flap frameData]];
		if (SNAC_ID_IS_EQUAL([snac snac_id], snacID)) return [snac autorelease];
		[snac release];
	}
}

- (void)oscarConnectionClosed:(OSCARConnection *)connection {
	[currentConnection autorelease];
	currentConnection = nil;
	[self performSelector:@selector(_delegateInformDisconnected) onThread:[bossSession mainThread] withObject:nil waitUntilDone:NO];
}

- (void)oscarConnectionPacketWaiting:(OSCARConnection *)connection {
	
}

- (void)dealloc {
	if (currentConnection) {
		[currentConnection setDelegate:nil];
		[currentConnection disconnect];
	}
	[currentConnection release];
	[bartHost release];
	[bartCookie release];
	[super dealloc];
}

@end
