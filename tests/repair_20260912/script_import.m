#import <Foundation/Foundation.h>
#import "../../objc/app/ZiYanScriptImport.h"

@interface FailingImportManager : NSFileManager
@end
@implementation FailingImportManager
- (BOOL)copyItemAtURL:(NSURL *)src toURL:(NSURL *)dst error:(NSError **)error {
  [@"partial" writeToURL:dst atomically:NO encoding:NSUTF8StringEncoding error:nil];
  if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
  return NO;
}
@end

static void Check(BOOL condition, NSString *message) {
  if (!condition) { fprintf(stderr, "FAIL %s\n", message.UTF8String); exit(1); }
}
int main(void) {
  @autoreleasepool {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ziyan-import-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *input=[root stringByAppendingPathComponent:@"input"], *dest=[root stringByAppendingPathComponent:@"scripts"];
    [fm createDirectoryAtPath:input withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *source=[NSURL fileURLWithPath:[input stringByAppendingPathComponent:@"test.lua"]];
    NSString *target=[dest stringByAppendingPathComponent:@"test.lua"];
    [@"old-user-script" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"new-complete-script" writeToURL:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *error=nil;
    Check(!ZiYanImportScript(source,dest,[FailingImportManager new],&error),@"partial copy fails");
    Check([[NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"old-user-script"],@"old bytes survive copy failure");
    Check([fm contentsOfDirectoryAtPath:dest error:nil].count==1,@"failed temp cleaned");
    Check(ZiYanImportScript(source,dest,fm,&error),@"valid replacement succeeds");
    Check([fm contentsEqualAtPath:source.path andPath:target],@"new bytes match source");
    Check(ZiYanImportScript([NSURL fileURLWithPath:target],dest,fm,&error),@"same source does not delete itself");
    Check(!ZiYanImportScript([NSURL fileURLWithPath:[input stringByAppendingPathComponent:@"missing.lua"]],dest,fm,&error),@"unreadable source fails");
    Check(!ZiYanImportScript([NSURL fileURLWithPath:input],dest,fm,&error),@"directories rejected");
    Check([fm contentsOfDirectoryAtPath:dest error:nil].count==1,@"only imported file remains");
    // Only remove the fresh UUID directory created above.
    Check([root hasPrefix:NSTemporaryDirectory()] && [root.lastPathComponent hasPrefix:@"ziyan-import-test-"],@"test cleanup boundary");
    [fm removeItemAtPath:root error:nil];
    puts("PASS Foundation import failure, replacement, same-source, cleanup");
  }
  return 0;
}
