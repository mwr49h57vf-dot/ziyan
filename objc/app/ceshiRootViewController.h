#import <UIKit/UIKit.h>
#import "ZiYanAppSelector.h"

NS_ASSUME_NONNULL_BEGIN

@interface ceshiRootViewController : UITableViewController

@property (nonatomic, copy, readonly, nullable) NSString *selectedFilePath;
@property (nonatomic, assign) BOOL embeddedInHome;

- (BOOL)ensureScriptsDirectory;
- (void)reloadScriptsFromDisk;
- (void)importFilesFromURLs:(NSArray<NSURL *> *)urls;
- (void)pollRunSuspendTrigs;
- (void)writeScriptListProbe;
- (void)addButtonTapped:(nullable id)sender;
- (void)importButtonTapped:(nullable id)sender;
- (void)runButtonTapped:(nullable id)sender;
- (void)runDumpForPick:(ZiYanAppPick *)pick;

@end

NS_ASSUME_NONNULL_END
