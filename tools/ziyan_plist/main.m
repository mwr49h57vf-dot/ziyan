#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 4 || (strcmp(argv[1], "read") && strcmp(argv[1], "write"))) {
      return 64;
    }
    BOOL reading = strcmp(argv[1], "read") == 0;
    NSString *input = [NSString stringWithUTF8String:argv[2]];
    NSString *output = [NSString stringWithUTF8String:argv[3]];
    NSError *error = nil;
    NSData *source = [NSData dataWithContentsOfFile:input options:0 error:&error];
    id object = nil;
    NSData *data = nil;
    if (source) {
      if (reading) {
        object = [NSPropertyListSerialization propertyListWithData:source
            options:NSPropertyListImmutable format:NULL error:&error];
        if (object && [NSJSONSerialization isValidJSONObject:object]) {
          data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
        }
      } else {
        object = [NSJSONSerialization JSONObjectWithData:source options:0 error:&error];
        if (object && [NSPropertyListSerialization propertyList:object
                                           isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
          data = [NSPropertyListSerialization dataWithPropertyList:object
              format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
        }
      }
    }
    if (!data) {
      fprintf(stderr, "PLIST_CONVERSION_FAILED: %s\n",
              error.localizedDescription.UTF8String ?: "unsupported value");
      return 1;
    }
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *parent = output.stringByDeletingLastPathComponent;
    if (!parent.length) parent = @".";
    if (![files createDirectoryAtPath:parent
          withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![data writeToFile:output options:NSDataWritingAtomic error:&error]) {
      fprintf(stderr, "PLIST_WRITE_FAILED: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    return 0;
  }
}
