#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AgentArtifactKind) {
  AgentArtifactNone = 0,
  AgentArtifactLearnDraft,
  AgentArtifactSelfDraft,
  AgentArtifactStable,
};

@interface AgentVersionInfo : NSObject
@property (nonatomic, copy) NSString *gameName;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *stem;
@property (nonatomic, assign) NSInteger version;
@property (nonatomic, assign) AgentArtifactKind kind;
@property (nonatomic, copy) NSString *luaPath;
@property (nonatomic, copy) NSString *jsonPath;
@property (nonatomic, copy) NSString *kindLabel;
@end

@interface AgentVersionStore : NSObject
+ (NSString *)agentRoot;
+ (NSString *)learnDataDir;
+ (NSString *)runLogDir;
+ (NSString *)genScriptDir;
+ (void)ensureDirs;
+ (NSString *)pinyinStemForName:(NSString *)name;
+ (nullable AgentVersionInfo *)latestForBundleId:(NSString *)bid
                                            name:(NSString *)name;
+ (BOOL)isUserHandwrittenPath:(NSString *)path;
+ (NSString *)unusedLearnLuaPathForStem:(NSString *)stem;
+ (NSString *)unusedSelfLuaPathForStem:(NSString *)stem
                               version:(NSInteger)ver;
+ (void)writeCopyOnWrite:(NSString *)path body:(NSString *)body;
+ (void)quarantineSimArtifacts;
+ (BOOL)isQuarantinedPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
