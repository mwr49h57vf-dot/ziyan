#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ceshiRootViewController : UITableViewController

@property (nonatomic, copy, readonly, nullable) NSString *selectedFilePath;

- (BOOL)ensureScriptsDirectory;
- (void)reloadScriptsFromDisk;
- (void)importFilesFromURLs:(NSArray<NSURL *> *)urls;
- (void)pollRunSuspendTrigs;

@end

NS_ASSUME_NONNULL_END
