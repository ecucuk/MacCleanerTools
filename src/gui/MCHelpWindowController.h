// MacCleaner Help (⌘?): topics on the left, the topic on the right. The
// content is HTML in the bundle (Resources/Help), so Help works offline.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCHelpWindowController : NSWindowController
+ (instancetype)shared;
/// A file name in Resources/Help without ".html" ("uninstaller"); nil keeps
/// the current topic. Shows the window.
- (void)showTopic:(nullable NSString *)topic;
/// A bundled HTML file as text in label colors (so dark mode works), or
/// "This page is missing." when the file is absent.
+ (NSAttributedString *)attributedStringForHTMLAtPath:(nullable NSString *)path;
@end

NS_ASSUME_NONNULL_END
