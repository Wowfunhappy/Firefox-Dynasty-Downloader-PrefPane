#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#import "ZKSwizzle.h"




void sendKeyboardEvent(CGEventFlags flags, CGKeyCode keyCode) {
	// Conveniently, this will NOT retrigger our swizzled sendEvent method!
	// So if we send, for example, ⌘R, that will always make Firefox reload the page,
	// even if the user set `Reload` to a different keyboard shortcut in System Preferences.
		
	// Make sure the event we send does not re-trigger the same menu item and cause an infinite loop.
	static BOOL isSendingKeyboardEvent = NO;
	if (isSendingKeyboardEvent) {
		return;
	}
	isSendingKeyboardEvent = YES;

	// Create key down and key up events
	CGEventRef keydown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
	CGEventRef keyup = CGEventCreateKeyboardEvent(NULL, keyCode, false);

	// Set the modifier flags
	CGEventSetFlags(keydown, flags);
	CGEventSetFlags(keyup, flags);
	
	// Post the events
	CGEventPost(kCGAnnotatedSessionEventTap, keydown);
	CGEventPost(kCGAnnotatedSessionEventTap, keyup);

	// Release the events
	CFRelease(keydown);
	CFRelease(keyup);
	
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		isSendingKeyboardEvent = NO;
	});
}




@interface NSMenu (mine)
- (void)initializeSubmenus;
- (void)removeItemWithTitle:(NSString *)title;
@end


@interface myNSApplication_ : NSApplication
@end


@implementation myNSApplication_

- (void)sendEvent:(NSEvent *)event {
	// Firefox does not handle user-defined key equivalents properly
	// https://bugzilla.mozilla.org/show_bug.cgi?id=1333781
	
	// Check if the event is a key down event with a modifier key. (Otherwise, it can't be a keyboard shortcut.)
	if (
		[event type] == NSKeyDown &&
		[event modifierFlags] & (NSCommandKeyMask | NSAlternateKeyMask | NSControlKeyMask)
		//We don't check NSShiftKeyMask because shortcuts aren't allowed to use Shift as the only modifier key.
	) {	
		// Query user-defined key equivalents
		NSDictionary *userKeyEquivalents = [[NSUserDefaults standardUserDefaults] objectForKey:@"NSUserKeyEquivalents"];

		if (userKeyEquivalents) {
			// Check if the event matches any user-defined key equivalents
			for (NSString *menuItemTitle in userKeyEquivalents) {
				NSString *shortcut = userKeyEquivalents[menuItemTitle];
				if ([self event:event matchesShortcut:shortcut]) {
					[self performKeyEquivalent:event];
					[self performActionForItemWithTitle:menuItemTitle inMenu:[NSApp mainMenu]];
					return;
				}
			}
		}
	}
	// Pass event to Firefox to handle normally.
	ZKOrig(void, event);
}

- (BOOL)event:(NSEvent *)event matchesShortcut:(NSString *)shortcut {
	// Convert the shortcut string to a key equivalent and modifier mask
	NSString *characterKey = [shortcut substringFromIndex:[shortcut length] - 1];
	NSString *modifierString = [shortcut substringToIndex:[shortcut length] - 1];
	NSUInteger modifierMask = 0;
	for (int i = 0; i < [modifierString length]; i++) {
		switch ([modifierString characterAtIndex:i]) {
			case '@':
				modifierMask |= NSCommandKeyMask;
				break;
			case '~':
				modifierMask |= NSAlternateKeyMask;
				break;
			case '^':
				modifierMask |= NSControlKeyMask;
				break;
			case '$':
				modifierMask |= NSShiftKeyMask;
				break;
		}
	}
	// Compare with the event
	return (
		[[[event charactersIgnoringModifiers] lowercaseString] isEqualToString:characterKey] &&
		([event modifierFlags] & NSDeviceIndependentModifierFlagsMask) == modifierMask
	);
}

- (BOOL)performActionForItemWithTitle:(NSString *)title inMenu:(NSMenu *)menu {
	for (NSMenuItem *menuItem in [menu itemArray]) {
		if ([menuItem hasSubmenu]) {
			if ([self performActionForItemWithTitle:title inMenu:[menuItem submenu]]) {
				return YES;
			}
		} else {
			// Ensure three periods ("...") matches the ellipsis character ("…").
			title = [title stringByReplacingOccurrencesOfString:@"..." withString:@"…"];
			NSString *menuItemTitle = [[menuItem title] stringByReplacingOccurrencesOfString:@"..." withString:@"…"];
			
			if ([menuItemTitle isEqualToString:title]) {
				[[menuItem menu] update]; // Highlight menu
				[[menuItem menu] performActionForItemAtIndex:[[menuItem menu] indexOfItem:menuItem]];
				return YES;
			}
		}
	}
	return NO;
}

// Fix: Downloaded files sometimes won't appear in stacks in the Dock.
- (void) finishLaunching {
	ZKOrig(void);
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self
													selector:@selector(downloadFileFinished:)
													name:@"com.apple.DownloadFileFinished"
													object:nil];
}

- (void)downloadFileFinished:(NSNotification *)notification {
	//Coordinate a write operation on the file but don't make any actual changes.
	NSFileCoordinator *fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[fileCoordinator coordinateWritingItemAtURL:[NSURL fileURLWithPath:notification.object] options:0 error:nil byAccessor:^(NSURL *newURL) {}];
}

@end




@interface myNSWindow : NSWindow
@end


@implementation myNSWindow

- (BOOL)makeFirstResponder:(NSResponder *)responder {	
	[[NSApp mainMenu] initializeSubmenus];
	return ZKOrig(BOOL, responder);
}

@end




@interface myNSMenu : NSMenu
@end

@implementation myNSMenu

- (void)initializeSubmenus{
	// Initializing menus ensures that that:
	// 1. Every item can be triggerred by its key equivalents
	// 2. Every item can appear in the search results of the `Help` search box.
	
	[[self delegate] menuWillOpen: self];
	[[self delegate] menuDidClose: self];
	
	[self fixupMenuItems];
	
	for (NSMenuItem *menuItem in [self itemArray]) {
		if ([menuItem hasSubmenu]) {
			[[menuItem submenu] initializeSubmenus];
		}
	}
}

- (void)_sendMenuOpeningNotification {
	ZKOrig(void);
	[self fixupMenuItems];
}

- (void)fixupMenuItems {
	if ([[self title] isEqualToString:NSLocalizedString(@"File", nil)]) {
		[self removeItemWithTitle:@"Work Offline"];
		[self removeItemWithTitle:@"Import From Another Browser…"];
		[self removeItemWithTitle:@"Restart (Developer)"];
		
		[self addSeperatorAtIndex:3];
		[self addItemWithTitle:@"Open Location…" atIndex:5 action:@selector(openLocation:) keyEquivalent:@"l"];
		[self addSeperatorAtIndex:6];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Edit", nil)]) {		
		[self renameItemWithTitle:@"Find in Page…" to:@"Find…"];
		[self renameItemWithTitle:@"Find Again" to:@"Find Next"];
		
		// `Select All` will sometimes be disabled for no reason. Always enable it.
		NSMenuItem *selectAllItem = [self itemWithTitle:NSLocalizedString(@"Select All", nil)];
		[selectAllItem setEnabled:YES];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"View", nil)]) {
		[self removeItemWithTitle:@"Page Style"];
		[self removeItemWithTitle:@"Repair Text Encoding"];
		[self addItemWithTitle:@"Reload Page" atIndex:5 action:@selector(reloadPage:) keyEquivalent:@"r"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"History", nil)]) {
		[self addItemWithTitle:@"Back" atIndex:0 action:@selector(back:) keyEquivalent:@"["];
		[self addItemWithTitle:@"Forward" atIndex:1 action:@selector(forward:) keyEquivalent:@"]"];
		[self addSeperatorAtIndex:2];

		[self renameItemWithTitle:@"Search History" to:@"Search History…"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Bookmarks", nil)]) {
		[self renameItemWithTitle:@"Manage Bookmarks" to:@"Manage Bookmarks…"];
		[self renameItemWithTitle:@"Search Bookmarks" to:@"Search Bookmarks…"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Tools", nil)]) {
		[self removeItemWithTitle:@"Add-ons and Themes"];
		[self removeItemWithTitle:@"Sign in"];
		[self renameItemWithTitle:@"Browser Tools" to:@"Developer"];
	}
	else {
		// Context menu
		[self removeItemWithPrefix:@"Add a Keyword"];
		[self removeItemWithTitle:@"Undo"];
		[self removeItemWithTitle:@"Redo"];
		[self removeItemWithTitle:@"Delete"];
		[self removeItemWithTitle:@"Select All"];
	}
	//Multiple Locations
	[self renameItemWithTitle:@"Save Page As…" to:@"Save As…"];
	
	[self removeLeadingAndTrailingSeperators];
	[self update];
}

- (void)addItemWithTitle:(NSString *)title
					atIndex:(NSInteger)index
					action:(SEL)action
					keyEquivalent:(NSString *)keyEquivalent
{	
	NSInteger menuCount = [self numberOfItems];
	if (index < 0 && index > menuCount) {
		index = menuCount;
	}
	
	NSMenuItem *existingItem = [self itemAtIndex:index];
	if ([existingItem.title isEqualToString:NSLocalizedString(title, nil)]) {
		//Menu item already exists at this index.
		return;
	}
	
	NSMenuItem *newMenuItem = [
		[NSMenuItem alloc]
		initWithTitle:NSLocalizedString(title, nil)
		action:action
		keyEquivalent:keyEquivalent
	];
	[newMenuItem setTarget:self];
	[self insertItem:newMenuItem atIndex:index];
}

- (void)addSeperatorAtIndex:(NSInteger)index {
	
	NSInteger menuCount = [self numberOfItems];
	if (index < 0 && index > menuCount) {
		index = menuCount;
	}

	NSMenuItem *existingItem = [self itemAtIndex:index];
	if ([existingItem isSeparatorItem]) {
		// Separator already exists at this index
		return;
	}
	
	[self insertItem:[NSMenuItem separatorItem] atIndex:index];
}

- (void)removeItemWithTitle:(NSString *)title {
	NSMenuItem *itemToRemove = [self itemWithTitle:NSLocalizedString(title, nil)];
	if (itemToRemove) {
		[self removeItem:itemToRemove];
	}
}

- (void)removeItemWithPrefix:(NSString *)prefix {
	for (NSMenuItem *menuItem in [self itemArray]) {
		if ([[menuItem title] hasPrefix: prefix]) {
			[self removeItem: menuItem];
		}
	}
}

- (void)removeItemWithSuffix:(NSString *)suffix {
	for (NSMenuItem *menuItem in [self itemArray]) {
		if ([[menuItem title] hasSuffix: suffix]) {
			[self removeItem: menuItem];
		}
	}
}

- (void)renameItemWithTitle:(NSString *)oldTitle to:(NSString *)newTitle {
	NSMenuItem *item = [self itemWithTitle:NSLocalizedString(oldTitle, nil)];
	[item setTitle:newTitle];
}

- (void)removeLeadingAndTrailingSeperators {
	while ([self numberOfItems] > 0 && [[self itemAtIndex:0] isSeparatorItem]) {
		 [self removeItemAtIndex:0];
	}
	while ([self numberOfItems] > 0 && [[self itemAtIndex:[self numberOfItems]-1] isSeparatorItem]) {
		[self removeItemAtIndex:[self numberOfItems]-1];
	}
}

- (void)openLocation:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_L);
}

- (void)reloadPage:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_R);
}

- (void)back:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_LeftBracket);
}

- (void)forward:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_RightBracket);
}

@end




@interface __myNSArrayM : NSMutableArray
@end


@implementation __myNSArrayM

- (void)removeObjectAtIndex:(NSUInteger)index {
	if (index < [self count]) {
		ZKOrig(void, index);
	}
}

@end




@implementation NSObject (main)

+ (void)load {
	ZKSwizzle(myNSApplication_, NSApplication);
	ZKSwizzle(myNSWindow, NSWindow);
	ZKSwizzle(myNSMenu, NSMenu);
	ZKSwizzle(__myNSArrayM, __NSArrayM);
}

@end


int main() {}