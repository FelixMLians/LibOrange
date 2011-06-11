//
//  MyTest.h
//  LibOrange
//
//  Created by Alex Nichol on 6/1/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "LibOrange.h"
#import "CommandTokenizer.h"

@interface MyTest : NSObject <AIMLoginDelegate, AIMSessionManagerDelegate, AIMFeedbagHandlerDelegate, AIMICBMHandlerDelegate, AIMStatusHandlerDelegate> {
    AIMLogin * login;
	AIMSessionManager * theSession;
	NSThread * mainThread;
}

- (void)beginTest;
- (void)blockingCheck;
- (void)checkThreading;

- (NSString *)removeBuddy:(NSString *)username;
- (NSString *)addBuddy:(NSString *)username toGroup:(NSString *)groupName;
- (NSString *)deleteGroup:(NSString *)groupName;
- (NSString *)addGroup:(NSString *)groupName;

@end
