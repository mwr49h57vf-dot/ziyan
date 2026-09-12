#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

// The destination is only changed by the final same-directory POSIX rename.
static BOOL ZiYanImportScript(NSURL *source, NSString *directory, NSFileManager *fm, NSError **error) {
  NSString *name = source.lastPathComponent;
  if (!source.isFileURL || name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
    if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInvalidFileNameError userInfo:nil];
    return NO;
  }
  NSString *dest = [directory stringByAppendingPathComponent:name];
  if ([source.URLByResolvingSymlinksInPath.path isEqualToString:[[NSURL fileURLWithPath:dest] URLByResolvingSymlinksInPath].path]) return YES;
  NSString *temp = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".import-%@.tmp", NSUUID.UUID.UUIDString]];
  __block BOOL success = NO;
  __block NSError *failure = nil;
  NSError *coordinationError = nil;
  NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
  [coordinator coordinateReadingItemAtURL:source options:0 error:&coordinationError byAccessor:^(NSURL *readURL) {
    NSNumber *regular = nil;
    if (![readURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:&failure] || !regular.boolValue) {
      if (!failure) failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError userInfo:nil];
      return;
    }
    if (![fm copyItemAtURL:readURL toURL:[NSURL fileURLWithPath:temp] error:&failure]) return;
    if (![fm contentsEqualAtPath:readURL.path andPath:temp]) {
      failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
      return;
    }
    int fd = open(temp.fileSystemRepresentation, O_RDONLY);
    int saved = fd < 0 ? errno : 0;
    if (fd >= 0) {
      if (fsync(fd) != 0) saved = errno;
      if (close(fd) != 0 && saved == 0) saved = errno;
    }
    if (saved == 0 && rename(temp.fileSystemRepresentation, dest.fileSystemRepresentation) == 0) {
      success = YES;
    } else {
      if (saved == 0) saved = errno;
      failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil];
    }
  }];
  [fm removeItemAtPath:temp error:nil];
  if (!success && error) *error = failure ?: coordinationError ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
  return success;
}
