#import <UIKit/UIKit.h>

@class ceshiRootViewController;

NS_ASSUME_NONNULL_BEGIN

@interface ZiYanHomeViewController : UIViewController
@property (nonatomic, strong, readonly) ceshiRootViewController *scriptListVC;
- (void)openAgentShowingPicker:(BOOL)showPicker;
- (void)reloadScripts;
- (void)writeHomeLayoutProbe;
@end

NS_ASSUME_NONNULL_END
