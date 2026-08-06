#import <Foundation/Foundation.h>
#import "ceshiAppDelegate.h"
#import <UIKit/UIKit.h>

static void ZiYanUncaughtException(NSException *e) {
  NSString *msg = [NSString
      stringWithFormat:@"ts=%@ name=%@ reason=%@\ncallStack=%@\n",
                       [NSDate date], e.name, e.reason,
                       [e.callStackSymbols componentsJoinedByString:@"\n"]];
  [msg writeToFile:@"/var/mobile/Media/ZiYan/.ziyan_app_exc.txt"
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
  [msg writeToFile:@"/usr/lib/ziyan/var/.ziyan_app_exc.txt"
        atomically:YES
          encoding:NSUTF8StringEncoding
             error:nil];
}

int main(int argc, char *argv[]) {
	@autoreleasepool {
		NSSetUncaughtExceptionHandler(&ZiYanUncaughtException);
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(ceshiAppDelegate.class));
	}
}
