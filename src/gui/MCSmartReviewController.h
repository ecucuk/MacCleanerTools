// The one review of a Smart Optimize run, shown as a sheet over Home.
// Storage categories and process candidates are checkboxes (the
// optimizer's defaults: recommended categories and processes checked);
// Large Files, Photos, Updater and Antivirus are report rows that open
// their tool. Nothing changes until the user presses the apply button.

#import <AppKit/AppKit.h>

#import "MCSmartOptimizer.h"
#import "MCTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface MCSmartReviewController : NSViewController

- (instancetype)initWithOptimizer:(MCSmartOptimizer *)optimizer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)nibNameOrNil
                         bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// After the sheet closes: the user asked to open this tool.
@property(nonatomic, copy, nullable) void (^openTool)(MCTool tool);
/// After the sheet closes: the apply finished with this one-line summary.
@property(nonatomic, copy, nullable) void (^didApply)(NSString *summary);

@end

NS_ASSUME_NONNULL_END
