// MACOSX_DEPLOYMENT_TARGET=10.6 clang $filename -dynamiclib -framework AppKit -framework Foundation ZKSwizzle.m -o /Applications/Firefox.app/Contents/Frameworks/FirefoxModifier.dylib
// MACOSX_DEPLOYMENT_TARGET=10.6 clang $filename -dynamiclib -DSSB_MODE -framework AppKit -framework Foundation ZKSwizzle.m -o ~/Desktop/wat/Web\ App\ Template.app/Contents/Frameworks/FirefoxModifier.dylib && ~/Desktop/WAT/Extras/Update\ Existing\ Apps.command --update-apps-folder

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <sys/time.h>
#import "ZKSwizzle.h"

#define DISPATCH_AFTER(delayInSeconds, block) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block)

void sendKeyboardEvent(CGEventFlags flags, CGKeyCode keyCode) {
	static BOOL isSendingKeyboardEvent = NO;
	if (isSendingKeyboardEvent) {
		return;
	}
	isSendingKeyboardEvent = YES;

	CGEventRef keydown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
	CGEventRef keyup = CGEventCreateKeyboardEvent(NULL, keyCode, false);
	
	// Set a custom field to mark these events as synthetic
	CGEventSetIntegerValueField(keydown, kCGEventSourceUserData, 0xFFFFFFFF);
	CGEventSetIntegerValueField(keyup, kCGEventSourceUserData, 0xFFFFFFFF);
	
	CGEventSetFlags(keydown, flags);
	CGEventSetFlags(keyup, flags);
	
	CGEventPost(kCGAnnotatedSessionEventTap, keydown);
	CGEventPost(kCGAnnotatedSessionEventTap, keyup);
	
	CFRelease(keydown);
	CFRelease(keyup);
	
	DISPATCH_AFTER(0.1, ^{
		isSendingKeyboardEvent = NO;
	});
}




@interface NSMenu (mine)
- (void)initializeSubmenus;
- (void)removeItemWithTitle:(NSString *)title;
- (void)fixupMenuItems;
@end


@interface FFM_NSApplication : NSApplication
@end


@implementation FFM_NSApplication

- (void)sendEvent:(NSEvent *)event {
	// Firefox does not handle user-defined key equivalents properly
	// https://bugzilla.mozilla.org/show_bug.cgi?id=1333781
	
	// Check if the event is a key down event with a modifier key. (Otherwise, it can't be a keyboard shortcut.)
	if (
		[event type] == NSKeyDown &&
		[event modifierFlags] & (NSCommandKeyMask | NSAlternateKeyMask | NSControlKeyMask)
		//We don't check NSShiftKeyMask because shortcuts aren't allowed to use Shift as the only modifier key.
	) {
		if ([event CGEvent] && CGEventGetIntegerValueField([event CGEvent], kCGEventSourceUserData) == 0xFFFFFFFF) {
			// This is our synthetic event from sendKeyboardEvent
			return ZKOrig(void, event);
		}

#ifdef SSB_MODE		
		// Special handling for cmd-= to trigger Zoom In
		if ([self event:event matchesShortcut:@"@="]) {
			// Only intercept if Zoom In menu item exists
			if ([self performActionForItemWithTitle:@"Zoom In" inMenu:[NSApp mainMenu]]) {
				return;
			}
		}
#endif
		
		// Query user-defined key equivalents
		NSDictionary *userKeyEquivalents = [[NSUserDefaults standardUserDefaults] objectForKey:@"NSUserKeyEquivalents"];

		if (userKeyEquivalents) {
			// Check if the event matches any user-defined key equivalents
			for (NSString *menuItemTitle in userKeyEquivalents) {
				NSString *shortcut = [userKeyEquivalents objectForKey:menuItemTitle];;
				if ([self event:event matchesShortcut:shortcut]) {
					[self performKeyEquivalent:event];
					[self performActionForItemWithTitle:menuItemTitle inMenu:[NSApp mainMenu]];
					return;
				}
			}
		}
		
#ifdef SSB_MODE
		NSArray *shortcutBlacklist = @[
			@"@t",		// new tab
			@"$@p",		// new private window
			@"@d",		// bookmark current tab
			@"$@d",		// bookmarks all tabs
			@"@j",		// downloads
			@"$@a",		// add-ons and themes
			@"@s",		// save page as
			@"$@j",		// browser console
			@"~@m",		// responsive design mode
			@"@u",		// page source
			@"@i",		// page info
			@"@y",		// history
			@"$@h",		// history sidebar
			@"@o",		// open file
			@"@b",		// bookmarks sidebar
			@"$@o",		// manage bookmarks
			@"@l",		// focus address bar
			@"@k",		// focus search bar
		];
		NSNumber *infoPlistSaysAllowDeveloperTools = [
			[NSBundle mainBundle] objectForInfoDictionaryKey:@"AllowDeveloperTools"
		];
		if (!infoPlistSaysAllowDeveloperTools || !infoPlistSaysAllowDeveloperTools.boolValue) {
			shortcutBlacklist = [shortcutBlacklist arrayByAddingObjectsFromArray:@[
				@"~@i",		// web developer tools
				@"$~@i",	// browser toolbox
			]];
		}
		
		NSNumber *infoPlistSaysPrintMenuItemEnabled = [
			[NSBundle mainBundle] objectForInfoDictionaryKey:@"EnablePrintMenuItem"
		];
		if (!infoPlistSaysPrintMenuItemEnabled || !infoPlistSaysPrintMenuItemEnabled.boolValue) {
			shortcutBlacklist = [shortcutBlacklist arrayByAddingObjectsFromArray:@[
				@"@p",		// print
			]];
		}
		
		if (![[NSApp mainMenu] itemWithTitle:NSLocalizedString(@"View", nil)]) {
			shortcutBlacklist = [shortcutBlacklist arrayByAddingObjectsFromArray:@[
				@"@r",		// reload
			]];
		}

		for (NSString *shortcut in shortcutBlacklist) {
			if ([self event:event matchesShortcut:shortcut]) {
				return;
			}
		}
#endif
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

- (void)setWindowsMenu:(NSMenu *)menu {
	ZKOrig(void, menu);
	DISPATCH_AFTER(1, ^{
		[[NSApp mainMenu] initializeSubmenus];
	});
}


// Fix: Downloaded files sometimes won't appear in stacks in the Dock.
- (void)finishLaunching {
	ZKOrig(void);
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self
		selector:@selector(downloadFileFinished:)
		name:@"com.apple.DownloadFileFinished"
		object:nil];
}

- (void)downloadFileFinished:(NSNotification *)notification {
	NSString *originalFileName = [notification.object lastPathComponent];
	NSString *hiddenFilePath = [
		[notification.object stringByDeletingLastPathComponent] stringByAppendingPathComponent:
		[NSString stringWithFormat:@".%@-%u", originalFileName, arc4random() % 10000]
	];
	DISPATCH_AFTER(0.1, ^{
		// Multiple instances of Firefox may all have this code attached to `com.apple.DownloadFileFinished`.
		// We need to handle locking so they don't interfere with each other.
		int fd = open([notification.object UTF8String], O_RDONLY);
		if (fd == -1) {
			return;
		}
		if (flock(fd, LOCK_EX | LOCK_NB) == -1) {
			// If we can't get a lock, it's hopefully because another Firefox process is already fixing this file.
			// Stop and let that other process take care of it.
			close(fd);
			return;
		}
		// Rename the original file to a hidden file
		if (rename([notification.object UTF8String], [hiddenFilePath UTF8String]) == -1) {
			flock(fd, LOCK_UN);
			close(fd);
			return;
		}
		DISPATCH_AFTER(0.1, ^{
			// Create a hard link from the hidden file to the original name
			if (link([hiddenFilePath UTF8String], [notification.object UTF8String]) == -1) {
				rename([hiddenFilePath UTF8String], [notification.object UTF8String]);
				flock(fd, LOCK_UN);
				close(fd);
				return;
			}
			DISPATCH_AFTER(0.2, ^{
				// Remove the hidden file
				unlink([hiddenFilePath UTF8String]);

				// Change modification and access time of the final renamed file.
				// If we don't do this, the file will appear in the Dock but may not appear in Finder!
				struct timeval times[2];
				gettimeofday(&times[0], NULL); // Current time for access
				gettimeofday(&times[1], NULL); // Current time for modification
				utimes([notification.object UTF8String], times);

				flock(fd, LOCK_UN);
				close(fd);
			});
		});
	}); 
}


#ifdef SSB_MODE
- (void)_checkForTerminateAfterLastWindowClosed:(id)arg1 saveWindows:(BOOL)arg2 {
	NSNumber *infoPlistSaysTerminateAfterLastWindowClosed = [
		[NSBundle mainBundle] objectForInfoDictionaryKey:@"TerminateAfterLastWindowClosed"
	];
	if ([infoPlistSaysTerminateAfterLastWindowClosed boolValue]) {
		// Making applicationShouldTerminateAfterLastWindowClosed return YES causes Firefox to freeze,
		// so we do it this way instead.
		[self handleQuitScriptCommand:arg1];
	}
}

- (void)handleQuitScriptCommand:(id)arg1 {
	ZKOrig(void, arg1);
}

- (struct __CFArray *)_createDockMenu:(BOOL)arg1 { 
	NSMutableArray *menuArray = [(__bridge NSArray *)ZKOrig(struct __CFArray *, arg1) mutableCopy];
	for (NSDictionary *menuItem in [menuArray reverseObjectEnumerator]) {
		if ([[menuItem objectForKey:@"name"] isEqualToString:@"New Private Window"]) {
			[menuArray removeObject:menuItem];
			break;
		}
	}
	return (__bridge struct __CFArray *)[menuArray copy];
}
#endif

@end




@interface FFM_NSWindow : NSWindow
@end


@implementation FFM_NSWindow

#ifdef SSB_MODE

- (void)setTitle:(NSString*) title {
	NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
	if ([title isEqualToString:@"Mozilla Firefox"]) {
		ZKOrig(void, appName);
	} else if (
		[title hasSuffix:[NSString stringWithFormat:@"- %@", appName]] ||
		[title hasSuffix:[NSString stringWithFormat:@"| %@", appName]]
	) {
		// Firefox's SSB helper will take care of removing the unwanted suffix.
		// To avoid a flash, we must avoid setting the title until after SSB helper does its magic.
		return;
	}
	else {
		return ZKOrig(void, title);
	}
}

- (void)setCollectionBehavior:(NSWindowCollectionBehavior)behavior {
	// Disable fullscreen if a maximum window width or height are set.
	NSString *maxWidth = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MaximumWindowWidth"];
	NSString *maxHeight = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MaximumWindowHeight"];
	if ((maxWidth && [maxWidth length] > 0) || (maxHeight && [maxHeight length] > 0)) {
		behavior = behavior & ~NSWindowCollectionBehaviorFullScreenPrimary;
		behavior = behavior & ~NSWindowCollectionBehaviorFullScreenAuxiliary;
	}
	
	ZKOrig(void, behavior);
}

- (NSWindowCollectionBehavior)collectionBehavior {
	NSWindowCollectionBehavior behavior = ZKOrig(NSWindowCollectionBehavior);
	
	// Check if MaximumWindowWidth or MaximumWindowHeight are set
	NSString *maxWidth = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MaximumWindowWidth"];
	NSString *maxHeight = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MaximumWindowHeight"];
	
	if ((maxWidth && [maxWidth length] > 0) || (maxHeight && [maxHeight length] > 0)) {
		// Remove fullscreen capability from the behavior mask
		behavior = behavior & ~NSWindowCollectionBehaviorFullScreenPrimary;
		behavior = behavior & ~NSWindowCollectionBehaviorFullScreenAuxiliary;
	}
	
	return behavior;
}
#endif

- (void)close {
	ZKOrig(void);
	[[NSApp mainMenu] initializeSubmenus];
}

@end




@interface MenuDelegateProxy : NSObject {
	id _originalDelegate;
}
@end

@implementation MenuDelegateProxy

- (id)initWithDelegate:(id)delegate {
	self = [super init];
	if (self) {
		_originalDelegate = delegate;
	}
	return self;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
	return [_originalDelegate respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
	[invocation invokeWithTarget:_originalDelegate];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
	return [_originalDelegate methodSignatureForSelector:sel];
}

- (void)menuWillOpen:(NSMenu *)menu {
	// Call original delegate's menuWillOpen if it has one
	if ([_originalDelegate respondsToSelector:@selector(menuWillOpen:)]) {
		[_originalDelegate menuWillOpen:menu];
	}
	// Then fix up menu items
	[menu fixupMenuItems];
}

@end




@interface FFM_NSMenu : NSMenu
@end


@implementation FFM_NSMenu

- (void)setDelegate:(id<NSMenuDelegate>)delegate {
	if (delegate) {
		Class delegateClass = [delegate class];
		NSString *className = NSStringFromClass(delegateClass);
		
		// Wrap MenuDelegate and ApplicationMenuDelegate with our proxy
		if ([className isEqualToString:@"MenuDelegate"] || [className isEqualToString:@"ApplicationMenuDelegate"]) {
			MenuDelegateProxy *proxy = [[MenuDelegateProxy alloc] initWithDelegate:delegate];
			ZKOrig(void, proxy);
			return;
		}
	}
	ZKOrig(void, delegate);
}

- (void)initializeSubmenus{
	// Initializing menus ensures that that:
	// 1. Every item can be triggerred by its key equivalents
	// 2. Every item can appear in the search results of the `Help` search box.
	
	if ([[self delegate] respondsToSelector:@selector(menuWillOpen:)]) {
		//Guard is needed for Lion.
		[[self delegate] menuWillOpen: self];
		[[self delegate] menuDidClose: self];
	}
	
	[self fixupMenuItems];
	
	for (NSMenuItem *menuItem in [self itemArray]) {
		if ([menuItem hasSubmenu]) {
			[[menuItem submenu] initializeSubmenus];
		}
	}
}

- (void)fixupMenuItems {
#ifndef SSB_MODE
if ([[self title] isEqualToString:@"MozillaProject"]) {
		[self renameItemWithTitle:@"Preferences" to:@"Preferences…"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"File", nil)]) {
		[self renameItemWithTitle:@"Save Page As…" to:@"Save As…"];
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
		[self addItemWithTitle:@"Find Previous" atIndex:12 action:@selector(findPrev:) keyEquivalent:@"$@g"];
		
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
		[self removeItemWithTitle:@"Synced Tabs"];
		[self removeItemWithTitle:@"Hidden Tabs"];
		
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
		[self renameItemWithTitle:@"Browser Tools" to:@"Developer"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Window", nil)]) {
		//Find position of last seperator
		int index = [self numberOfItems] - 1;
		while (index > 0) {
			if ([[self itemAtIndex:index] isSeparatorItem]) {
				break;
			}
			index--;
		}
		[self addItemWithTitle:@"Bring All to Front" atIndex:index action:@selector(bringAllToFront:) keyEquivalent:@""];
		[self addSeperatorAtIndex:index];
		[self addItemWithTitle:@"Cycle Through Windows" atIndex:index action:@selector(cycleWindows:) keyEquivalent:@"`"];
		
		NSWindow *currentWindow = [NSApp mainWindow] ?: [NSApp keyWindow];
		BOOL isCurrentWindowFullScreen = currentWindow && (currentWindow.styleMask & NSFullScreenWindowMask) == NSFullScreenWindowMask;
		
		NSMenuItem *cycleWindowsItem = [self itemWithTitle:@"Cycle Through Windows"];
		[cycleWindowsItem setEnabled:!isCurrentWindowFullScreen];
	}
	else {
		// Context menu
		[self removeItemWithPrefix:@"Add a Keyword"];
		[self removeItemWithTitle:@"Undo"];
		[self removeItemWithTitle:@"Redo"];
		[self removeItemWithTitle:@"Delete"];
		[self removeItemWithTitle:@"Select All"];
		[self removeItemWithTitle:@"Manage Passwords"];
		[self removeItemWithTitle:@"Send Page to Device"];
		[self removeItemWithPrefix:@"Translate Selection to"];
		[self removeItemWithTitle:@"View Selection Source"];
		[self removeItemWithTitle:@"Inspect Accessibility Properties"];
		[self removeItemWithTitle:@"Save Page As…"];
	}
#else
	if ([[self title] isEqualToString:@"MozillaProject"]) {
		[self removeItemWithTitle:@"About Firefox"];
		[self removeItemWithTitle:@"Preferences"];
		[self renameItemWithTitle:@"Hide Firefox" to:[
			NSString stringWithFormat:@"Hide %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"]
		]];
		[self renameItemWithTitle:@"Quit Firefox" to:[
			NSString stringWithFormat:@"Quit %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"]
		]];
		
		[self addCustomMenuItemsFromPlist:@"AppMenuItems" toMenuAtIndex:0];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"File", nil)]) {
		[self removeItemWithTitle:@"New Tab"];
		[self removeItemWithTitle:@"New Private Window"];
		[self removeItemWithTitle:@"Open File…"];
		[self removeItemWithTitle:@"Open Location…"];
		[self removeItemWithTitle:@"Close Tab"];
		[self removeItemWithTitle:@"Save Page As…"];
		[self removeItemWithTitle:@"Work Offline"];
		[self removeItemWithTitle:@"Import From Another Browser…"];
		[self removeItemWithTitle:@"Restart (Developer)"];
		
		[[self itemWithTitle:NSLocalizedString(@"Close Window", nil)] setKeyEquivalent:@"w"];
		[[self itemWithTitle:NSLocalizedString(@"Close Window", nil)] setKeyEquivalentModifierMask:NSCommandKeyMask];

		NSNumber *infoPlistSaysShareMenuEnabled = [
			[NSBundle mainBundle] objectForInfoDictionaryKey:@"EnableShareMenuItem"
		];
		if (!infoPlistSaysShareMenuEnabled || !infoPlistSaysShareMenuEnabled.boolValue) {
			[self removeItemWithTitle:@"Share"];
		}
		
		NSNumber *infoPlistSaysPrintMenuItemEnabled = [
			[NSBundle mainBundle] objectForInfoDictionaryKey:@"EnablePrintMenuItem"
		];
		if (!infoPlistSaysPrintMenuItemEnabled || !infoPlistSaysPrintMenuItemEnabled.boolValue) {
			[self removeItemWithTitle:@"Print…"];
		}
		
		[self addCustomMenuItemsFromPlist:@"FileMenuItems" toMenuAtIndex:1];
		if ([self numberOfItems] > 2) {
			[self addSeperatorAtIndex: [self numberOfItems] - 1];
		}
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Edit", nil)]) {
		// `Select All` will sometimes be disabled for no reason. Always enable it.
		NSMenuItem *selectAllItem = [self itemWithTitle:NSLocalizedString(@"Select All", nil)];
		[selectAllItem setEnabled:YES];
		
		// Some web apps will override the default find keyboard shortcuts with their own UI.
		// We want the menu items themselves to bring up that same UI.
		[self removeItemWithTitle:@"Find in Page…"];
		[self removeItemWithTitle:@"Find Again"];
		[self addItemWithTitle:@"Find…" atIndex:10 action:@selector(find:) keyEquivalent:@"f"];
		[self addItemWithTitle:@"Find Next" atIndex:11 action:@selector(findNext:) keyEquivalent:@"g"];
		[self addItemWithTitle:@"Find Previous" atIndex:12 action:@selector(findPrev:) keyEquivalent:@"$@g"];

		// Similar to above, some web apps override the default undo/redo keyboard shortcuts with their own handlers.
		// We want the menu items themselves to use the same handlers.
		[self removeItemWithTitle:@"Undo"];
		[self removeItemWithTitle:@"Redo"];
		[self addItemWithTitle:@"Undo" atIndex:0 action:@selector(undo:) keyEquivalent:@"z"];
		[self addItemWithTitle:@"Redo" atIndex:1 action:@selector(redo:) keyEquivalent:@"$@z"];

	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"View", nil)]) {
		[self removeItemWithTitle:@"Toolbars"];
		[self removeItemWithTitle:@"Sidebar"];
		[self removeItemWithTitle:@"Zoom"];
		[self removeItemWithTitle:@"Page Style"];
		[self removeItemWithTitle:@"Repair Text Encoding"];
		
		[self addCustomMenuItemsFromPlist:@"ViewMenuItems" toMenuAtIndex:0];
		
		// Remove enter fullscreen menu item if window doesn't support fullscreen
		if (!([[NSApp keyWindow] collectionBehavior] & NSWindowCollectionBehaviorFullScreenPrimary)) {
			[self removeItemWithTitle:@"Enter Full Screen"];
		} else {
			// Sometimes, Firefox will randomly give Enter/Exit Full Screen a checkbox.
			[[self itemWithTitle:@"Enter Full Screen"] setState: NSOffState];
			[[self itemWithTitle:@"Exit Full Screen"] setState: NSOffState];
		}
		
		if ([self numberOfItems] > 1) {
			// This isn't worth having if it would end up being the only item in the View menu.
			[self addItemWithTitle:@"Refresh" atIndex:0 action:@selector(reloadPage:) keyEquivalent:@"r"];
		} else {
			[[NSApp mainMenu] removeItemWithTitle:@"View"];
		}

	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"History", nil)]) {
		// Replace first two menu items with "Back" and "Forward".
		// Modifying existing items instead of removing and replacing them avoids visual glitches.
		NSMenuItem *showAllHistoryItem = [self itemWithTitle:@"Show All History"];
		if (showAllHistoryItem) {
			[showAllHistoryItem setTitle:@"Back"];
			[showAllHistoryItem setAction:@selector(back:)];
			[showAllHistoryItem setTarget:self];
			[showAllHistoryItem setKeyEquivalent:@"["];
			[showAllHistoryItem setKeyEquivalentModifierMask:NSCommandKeyMask];
		}
		NSMenuItem *clearRecentHistoryItem = [self itemWithTitle:@"Clear Recent History…"];
		if (clearRecentHistoryItem) {
			[clearRecentHistoryItem setTitle:@"Forward"];
			[clearRecentHistoryItem setAction:@selector(forward:)];
			[clearRecentHistoryItem setTarget:self];
			[clearRecentHistoryItem setKeyEquivalent:@"]"];
			[clearRecentHistoryItem setKeyEquivalentModifierMask:NSCommandKeyMask];
		}
		
		[self removeItemWithTitle:@"Restore Previous Session"];
		[self removeItemWithTitle:@"Search History"];
		[self removeItemWithTitle:@"Recently Closed Tabs"];
		[self removeItemWithTitle:@"Recently Closed Windows"];
		[self removeItemWithTitle:@"Firefox Privacy Notice — Mozilla"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Bookmarks", nil)]) {
		[[NSApp mainMenu] removeItemWithTitle:@"Bookmarks"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Tools", nil)]) {
		[[NSApp mainMenu] removeItemWithTitle:@"Tools"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Window", nil)]) {
		//Find position of last seperator
		int index = [self numberOfItems] - 1;
		while (index > 0) {
			if ([[self itemAtIndex:index] isSeparatorItem]) {
				break;
			}
			index--;
		}
		[self addItemWithTitle:@"Bring All to Front" atIndex:index action:@selector(bringAllToFront:) keyEquivalent:@""];
		[self addSeperatorAtIndex:index];
		[self addItemWithTitle:@"Cycle Through Windows" atIndex:index action:@selector(cycleWindows:) keyEquivalent:@"`"];
		
		BOOL isCurrentWindowFullScreen = [NSApp keyWindow] && (
			[NSApp keyWindow].styleMask & NSFullScreenWindowMask
		) == NSFullScreenWindowMask;
		
		NSMenuItem *cycleWindowsItem = [self itemWithTitle:@"Cycle Through Windows"];
		[cycleWindowsItem setEnabled:!isCurrentWindowFullScreen];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Help", nil)]) {
		NSString *HelpURL = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"HelpURL"];
		if (HelpURL && [HelpURL length] > 0) {
			NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
			NSMenuItem *getHelpItem = [self itemWithTitle:@"Get Help"];
			if (getHelpItem) {
				[getHelpItem setTitle:[NSString stringWithFormat:@"%@ Help", appName]];
				[getHelpItem setAction:@selector(openCustomURL:)];
				[getHelpItem setTarget:self];
				[getHelpItem setRepresentedObject:HelpURL];
			}
		} else {
			[self removeItemWithTitle:@"Get Help"];
		}
		[self removeItemWithTitle:@"Report Broken Site"];
		[self removeItemWithTitle:@"Share Ideas and Feedback…"];
		[self removeItemWithTitle:@"Troubleshoot Mode…"];
		[self removeItemWithTitle:@"More Troubleshooting Information"];
		[self removeItemWithTitle:@"Report Deceptive Site…"];
		[self removeItemWithTitle:@"Switching to a New Device"];
	}
	else {
		//Context menu(s)
		[self removeItemWithTitle:@"Back"];
		[self removeItemWithTitle:@"Forward"];
		[self removeItemWithTitle:@"Reload"];
		[self removeItemWithTitle:@"Stop"];
		[self removeItemWithTitle:@"Bookmark Page…"];
		[self removeItemWithTitle:@"Save Page As…"];
		[self removeItemWithTitle:@"Select All"];
		[self removeItemWithTitle:@"Take Screenshot"];
		[self removeItemWithTitle:@"View Page Source"];
		[self removeItemWithTitle:@"Inspect Accessibility Properties"];
		[self removeItemWithTitle:@"Inspect"];
		
		[self removeItemWithPrefix:@"Search"];
		[self removeItemWithPrefix:@"Translate"];
		[self removeItemWithTitle:@"View Selection Source"];
		[self removeItemWithTitle:@"Print Selection…"];
		
		[self removeItemWithTitle:@"Copy Image Link"];
		[self removeItemWithTitle:@"Save Image As…"];
		[self removeItemWithTitle:@"Email Image…"];
		[self removeItemWithTitle:@"Set Image as Desktop Background…"];
		
		NSMenuItem *copyLinkItem = [self itemWithTitle:@"Copy Link"];
		if (copyLinkItem && ![copyLinkItem image]) [self removeItem:copyLinkItem];
		[self removeItemWithTitle:@"Copy Clean Link"];
		[self removeItemWithTitle:@"Save Link As…"];
		[self removeItemWithPrefix:@"Bookmark"];
		[self removeItemWithSuffix:@"in New Tab"];
		[self removeItemWithSuffix:@"in New Window"];
		[self removeItemWithSuffix:@"in New Private Window"];
		
		[self removeItemWithTitle:@"Check Spelling"];
		[self removeItemWithTitle:@"Languages"];
		[self removeItemWithPrefix:@"Add a Keyword"];
		[self removeItemWithTitle:@"Undo"];
		[self removeItemWithTitle:@"Redo"];
		[self removeItemWithTitle:@"Delete"];
		[self removeItemWithTitle:@"Manage Passwords"];
		
		[self removeItemWithTitle:@"Save Page As…"];
		[self removeItemWithTitle:@"This Frame"];
		
		// App-specific hack. I'm sorry!
		if ([[[NSApp keyWindow] title] isEqualToString:@"Bitwarden"]) {
			[self removeItemWithTitle:@"Bitwarden"];
		}
	}
#endif

	[self cleanUpSeperators];
	[self update];
}

- (void)addItemWithTitle:(NSString *)title
				atIndex:(NSInteger)index
				action:(SEL)action
				keyEquivalent:(NSString *)keyEquivalent
{   
	NSInteger menuCount = [self numberOfItems];
	if (index < 0 || index > menuCount) {
		index = menuCount;
	}
	
	NSInteger existingIndex = [self indexOfItemWithTitle:NSLocalizedString(title, nil)];
	if (existingIndex != -1) {
		// Menu item already exists - move it to the desired position if needed
		if (existingIndex != index) {
			NSMenuItem *existingItem = [self itemAtIndex:existingIndex];
			[self removeItemAtIndex:existingIndex];
			if (index > existingIndex) {
				index--; // Adjust index after removal
			}
			[self insertItem:existingItem atIndex:index];
		}
		// Update the action and target
		NSMenuItem *item = [self itemAtIndex:index];
		[item setAction:action];
		[item setTarget:self];
		[item setKeyEquivalent:keyEquivalent];
		return;
	}
	
	NSUInteger keyModifiers = 0;
	if ([keyEquivalent length] > 1) {
		for (NSUInteger i = 0; i < [keyEquivalent length]; i++) {
			switch ([keyEquivalent characterAtIndex:i]) {
				case '$':
					keyModifiers |= NSShiftKeyMask;
					break;
				case '@':
					keyModifiers |= NSCommandKeyMask;
					break;
				case '^':
					keyModifiers |= NSControlKeyMask;
					break;
				case '~':
					keyModifiers |= NSAlternateKeyMask;
					break;
				default:
					// Assume the last non-modifier character is the key
					keyEquivalent = [keyEquivalent substringWithRange:NSMakeRange(i, 1)];
					break;
			}
		}
	}
	
	NSMenuItem *newMenuItem = [
		[NSMenuItem alloc]
		initWithTitle:NSLocalizedString(title, nil)
		action:action
		keyEquivalent:keyEquivalent
	];
	if (keyModifiers != 0) {
		[newMenuItem setKeyEquivalentModifierMask:keyModifiers];
	}
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

- (void)cleanUpSeperators {
	// Remove leading separators
	while ([self numberOfItems] > 0 && [[self itemAtIndex:0] isSeparatorItem]) {
		 [self removeItemAtIndex:0];
	}
	// Remove trailing separators
	while ([self numberOfItems] > 0 && [[self itemAtIndex:[self numberOfItems]-1] isSeparatorItem]) {
		[self removeItemAtIndex:[self numberOfItems]-1];
	}
	// Remove consecutive separators
	NSInteger i = 0;
	while (i < [self numberOfItems] - 1) {
		if ([[self itemAtIndex:i] isSeparatorItem] && [[self itemAtIndex:i+1] isSeparatorItem]) {
			// Remove the second separator and don't increment i
			[self removeItemAtIndex:i+1];
		} else {
			i++;
		}
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

- (void)find:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_F);
}

- (void)findNext:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_G);
}

- (void)findPrev:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand | kCGEventFlagMaskShift, kVK_ANSI_G);
}

- (void)undo:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_Z);
}

- (void)redo:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand | kCGEventFlagMaskShift, kVK_ANSI_Z);
}

- (void)bringAllToFront:(id)sender {
	[[NSRunningApplication currentApplication] activateWithOptions:(
		NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps
	)];
}

- (void)cycleWindows:(id)sender {
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_Grave);
}

#ifdef SSB_MODE

- (void)addCustomMenuItemsFromPlist:(NSString *)plistKey toMenuAtIndex:(NSInteger)insertIndex {
	NSArray *customMenuItems = [[NSBundle mainBundle] objectForInfoDictionaryKey:plistKey];
	if (customMenuItems && [customMenuItems isKindOfClass:[NSArray class]] && [customMenuItems count] > 0) {
		// Add each custom menu item
		for (NSDictionary *menuItem in customMenuItems) {
			// Each dictionary has one key-value pair: title -> URL
			for (NSString *title in menuItem) {
				NSString *urlString = [menuItem objectForKey:title];
				
				NSString *keyEquiv = @"";
				if ([title hasPrefix:@"Preferences"]) {
					keyEquiv = @",";
				}		
				if ([title isEqualToString:@"Zoom In"]) {
					keyEquiv = @"+";
				}
				if ([title isEqualToString:@"Zoom Out"]) {
					keyEquiv = @"-";
				}
				
				[self addItemWithTitle:title atIndex:insertIndex action:@selector(openCustomURL:) keyEquivalent:keyEquiv];
				NSMenuItem *item = [self itemAtIndex:insertIndex];
				[item setRepresentedObject:urlString];
				insertIndex++;
				
				// Add separator after About menu items
				if ([title hasPrefix:@"About"]) {
					[self addSeperatorAtIndex:insertIndex];
					insertIndex++;
				}
			}
		}
	}
}

- (NSString *)getAppTempDirectory {
	NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

	NSString *safeAppName = [
		[appName componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]]
		componentsJoinedByString:@""
	];
	
	// In theory, there should only be one temporary directory per app.
	// However, if an old directory was not cleaned up properly, it is possible there will be more than one.
	// In this case, the temporary directory which was most recently modified is almost certainly the correct one.
	NSArray *tempDirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
	NSString *mostRecentPath = nil;
	NSDate *mostRecentDate = nil;
	for (NSString *dir in tempDirs) {
		// mktemp -dt creates directories like "AppName.XXXXXX"
		NSString *expectedPrefix = [safeAppName stringByAppendingString:@"."];
		if ([dir hasPrefix:expectedPrefix]) {
			NSString *fullPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dir];
			BOOL isDirectory;
			if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDirectory] && isDirectory) {
				// Check if ssb-helper.py exists in this directory
				NSString *helperPath = [fullPath stringByAppendingPathComponent:@"ssb-helper.py"];
				if ([[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
					// Get modification date of this directory
					NSDictionary *attributes = [
						[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil
					];
					NSDate *modificationDate = [attributes fileModificationDate];
					
					// Keep track of the most recently modified directory
					if (!mostRecentDate || [modificationDate compare:mostRecentDate] == NSOrderedDescending) {
						mostRecentDate = modificationDate;
						mostRecentPath = fullPath;
					}
				}
			}
		}
	}
	return mostRecentPath;
}

- (void)openCustomURL:(id)sender {
	NSString *navigationFile = [[self getAppTempDirectory] stringByAppendingPathComponent:@"navigate.txt"];
	
	// We need there to be at least one existing Firefox window for the SSB Helper extension to run in.
	BOOL hasSeenWindow = false;
	for (NSWindow *window in [NSApp windows]) {
		if ([NSStringFromClass([window class]) isEqualToString:@"ToolbarWindow"]) {
			hasSeenWindow = YES;
			break;
		}
	}
	if (!hasSeenWindow) {
		NSMenuItem *fileMenuItem = [[NSApp mainMenu] itemWithTitle:NSLocalizedString(@"File", nil)];
		NSMenuItem *newWindowItem = [[fileMenuItem submenu] itemWithTitle:@"New Window"];
		NSDisableScreenUpdates();
		[[newWindowItem target] performSelector:[newWindowItem action] withObject:newWindowItem];
		DISPATCH_AFTER(0.01, ^{ // >= 0.001
			// Find the window that just opened
			NSWindow *newWindow = nil;
			for (NSWindow *window in [NSApp windows]) {
				if ([NSStringFromClass([window class]) isEqualToString:@"ToolbarWindow"]) {
					newWindow = window;
					break;
				}
			}
			[newWindow setAlphaValue: 0];
			DISPATCH_AFTER(0.01, ^{ // >= 0.001
				// By now, `setAlphaValue: 0` will have taken effect
				// so we can safely re-enable screen updates without the new window becoming visible.
				NSEnableScreenUpdates();
			});
			
			__block void (^checkNavigationFile)(void);
			checkNavigationFile = ^{
				BOOL fileExists = navigationFile && [[NSFileManager defaultManager] fileExistsAtPath:navigationFile];
				
				if (!fileExists) {
					// If the URL opened in its own window, we must get rid of the first one we made.
					// Otherwise, keep it.
					if (! [newWindow isKeyWindow]) {
						// Closing the window in a normal way will make Firefox freeze sometimes.
						[[NSApplication sharedApplication] sendAction:@selector(performClose:) to:newWindow from:nil];
					} else {
						[newWindow setAlphaValue: 1];
					}
				} else {
					// File still exists, check again after a short delay
					DISPATCH_AFTER(0.01, checkNavigationFile);
				}
			};
			DISPATCH_AFTER(1, checkNavigationFile);
			
			[self openCustomURL:sender];
			return;
		});
	}
	
	NSMenuItem *menuItem = (NSMenuItem *)sender;
	NSString *urlString = [menuItem representedObject];			
	
	// Write the URL to the navigation file
	[urlString writeToFile:navigationFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
	
	// Send the special keyboard combination to trigger navigation check: Cmd+Shift+F12
	sendKeyboardEvent(kCGEventFlagMaskCommand | kCGEventFlagMaskShift, kVK_F12);
}
#endif

@end




#ifdef SSB_MODE
@interface FFM_NSMenuItem : NSMenuItem
@end


@implementation FFM_NSMenuItem

- (void)setImage:(NSImage *)image {	
	if ([self menu] && ![[[self menu] title] isEqualToString:NSLocalizedString(@"History", nil)]) {
		// Don't put favicons in the history menu in SSB mode; every item would have the same favicon in most cases.
		ZKOrig(void, image);
	} else {
		// Change the behavior of history menu items:
		for (NSWindow *window in [NSApp windows]) {
			if ([[self title] isEqualToString:[window title]]) {
				if (window == [NSApp keyWindow]) {
					[self setState:NSOnState];
				}
				// When clicked, switch to the window where this page is already open.
				objc_setAssociatedObject(self, @selector(targetWindow), window, OBJC_ASSOCIATION_ASSIGN);
				[self setTarget:self];
				[self setAction:@selector(activateWindow:)];
			}
		}
	}
}

- (void)activateWindow:(id)sender {
	NSWindow *targetWindow = objc_getAssociatedObject(self, @selector(targetWindow));
	if (targetWindow) {
		[targetWindow makeKeyAndOrderFront:nil];
	}
}

@end
#endif




@interface FFM___myNSArrayM : NSMutableArray
@end


@implementation FFM___myNSArrayM

- (void)removeObjectAtIndex:(NSUInteger)index {
	if (index < [self count]) {
		ZKOrig(void, index);
	}
}

@end




#ifdef SSB_MODE
@interface FFM_UserNotificationCenter : NSObject
@end

@implementation FFM_UserNotificationCenter

- (void)deliverNotification:(NSUserNotification *)notification {
	NSUserNotification *modifiedNotification = [notification copy];
	
	// We don't need to know what website this notification comes from.
	[modifiedNotification setValue:@"" forKey:@"subtitle"];
	
	// Remove the ... button from notifications, which would let the user break into Firefox's standard settings menu.
	[modifiedNotification setValue:@(NO) forKey:@"hasActionButton"];
	
	// Remove default sound. If sound is desired, websites will play their own.
	[modifiedNotification setValue:nil forKey:@"soundName"];
	
	ZKOrig(void, modifiedNotification);
}

@end
#endif




@implementation NSObject (main)

+ (void)load {
	ZKSwizzle(FFM_NSApplication, NSApplication);
	ZKSwizzle(FFM_NSMenu, NSMenu);
	ZKSwizzle(FFM___myNSArrayM, __NSArrayM);
	ZKSwizzle(FFM_NSWindow, NSWindow);
#ifdef SSB_MODE
	ZKSwizzle(FFM_NSMenuItem, NSMenuItem);
	ZKSwizzle(FFM_UserNotificationCenter, _NSConcreteUserNotificationCenter);
#endif
}

@end


int main() {}