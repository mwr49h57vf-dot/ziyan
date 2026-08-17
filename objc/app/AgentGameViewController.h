#import <UIKit/UIKit.h>

@class ceshiRootViewController;

NS_ASSUME_NONNULL_BEGIN

@interface AgentGameViewController : UIViewController
@property (nonatomic, assign) BOOL openPickerOnAppear;
@property (nonatomic, weak, nullable) ceshiRootViewController *dumpHost;
- (void)presentGamePicker;
- (void)selectTapped;
- (void)learnTapped;
- (void)aiTapped;
- (void)dumpTapped;
- (void)automationCancelPicker;
- (void)automationConfirmFirstApp;
- (void)automationLearnStart;
- (void)startRuntimeWithMode:(NSString *)mode;
- (void)requestAgentStop;
- (void)writeAgentPageProbe;
- (void)writeAppPickerProbeCancelled;
- (void)writeAppPickerProbeConfirmed;
+ (void)selectProfileId:(NSString *)pid;
+ (NSDictionary *)currentProfile;
+ (NSDictionary *)knownProfiles;
+ (void)clearCurrentTarget;
@end

NS_ASSUME_NONNULL_END
