#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <sys/time.h>
#import "ZKSwizzle.h"

#define DISPATCH_AFTER(delayInSeconds, block) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block)

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
	
	DISPATCH_AFTER(0.1, ^{
		isSendingKeyboardEvent = NO;
	});
}




@interface NSMenu (mine)
- (void)initializeSubmenus;
- (void)removeItemWithTitle:(NSString *)title;
@end


@interface FFM_NSApplication : NSApplication
#ifdef SSB_MODE
- (void)handleQuitScriptCommand:(id)arg1;
#endif
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
		
#ifdef SSB_MODE
		NSArray *shortcutBlacklist = @[
			@"@t",		// new tab
			@"$@p",		// new private window
			@"@d",		// bookmark current tab
			@"@j",		// downloads
			@"$@a",		// add-ons and themes
			@"@s",		// save page as
			@"@,",		// settings
			@"~@i",		// web developer tools
			@"$~@i",	// browser toolbox
			@"$@j",		// browser console
			@"~@m",		// responsive design mode
			@"@u",		// page source
			// Switching Tabs
			@"@1",
			@"@2",
			@"@3",
			@"@4",
			@"@5",
			@"@6",
			@"@7",
			@"@8",
			@"@9",
		];
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
	DISPATCH_AFTER(0.001, ^{
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
			DISPATCH_AFTER(0.1, ^{
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
	// We'd like to make applicationShouldTerminateAfterLastWindowClosed return YES, but that causes Firefox to freeze.
	// So we'll do this instead.
	[self handleQuitScriptCommand:arg1];
}

- (struct __CFArray *)_createDockMenu:(BOOL)arg1 { 
	NSMutableArray *menuArray = [(__bridge NSArray *)ZKOrig(struct __CFArray *, arg1) mutableCopy];
	for (NSDictionary *menuItem in [menuArray reverseObjectEnumerator]) {
		if ([menuItem[@"name"] isEqualToString:@"New Private Window"]) {
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
	if ([title isEqualToString:@"Mozilla Firefox"]) {
		ZKOrig(void, [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"]);
	} else {
		ZKOrig(void, title);
	}
}
#endif

@end




@interface FFM_NSMenu : NSMenu
@end


@implementation FFM_NSMenu

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
#ifndef SSB_MODE
	if ([[self title] isEqualToString:NSLocalizedString(@"File", nil)]) {
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
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"File", nil)]) {
		[self removeItemWithTitle:@"New Tab"];
		[self removeItemWithTitle:@"New Private Window"];
		[self removeItemWithTitle:@"Open File…"];
		[self removeItemWithTitle:@"Close Tab"];
		[self removeItemWithTitle:@"Save Page As…"];
		[self removeItemWithTitle:@"Work Offline"];
		[self removeItemWithTitle:@"Import From Another Browser…"];
		[self removeItemWithTitle:@"Restart (Developer)"];
		
		[self addItemWithTitle:@"Open In Browser…" atIndex:4 action:@selector(openInBrowser:) keyEquivalent:@""];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Edit", nil)]) {     
		[self renameItemWithTitle:@"Find in Page…" to:@"Find…"];
		[self renameItemWithTitle:@"Find Again" to:@"Find Next"];
		
		// `Select All` will sometimes be disabled for no reason. Always enable it.
		NSMenuItem *selectAllItem = [self itemWithTitle:NSLocalizedString(@"Select All", nil)];
		[selectAllItem setEnabled:YES];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"View", nil)]) {
		[self removeItemWithTitle:@"Toolbars"];
		[self removeItemWithTitle:@"Sidebar"];
		[self removeItemWithTitle:@"Page Style"];
		[self removeItemWithTitle:@"Repair Text Encoding"];
		[self addItemWithTitle:@"Reload" atIndex:0 action:@selector(reloadPage:) keyEquivalent:@"r"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"History", nil)]) {
		[self removeItemWithTitle:@"Show All History"];
		[self removeItemWithTitle:@"Clear Recent History…"];
		[self removeItemWithTitle:@"Restore Previous Session"];
		[self removeItemWithTitle:@"Search History"];
		[self removeItemWithTitle:@"Recently Closed Tabs"];
		[self removeItemWithTitle:@"Recently Closed Windows"];
		[self removeItemWithTitle:@"Firefox Privacy Notice — Mozilla"];
		[self addItemWithTitle:@"Back" atIndex:1 action:@selector(back:) keyEquivalent:@"["];
		[self addItemWithTitle:@"Forward" atIndex:2 action:@selector(forward:) keyEquivalent:@"]"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Bookmarks", nil)]) {
		[[NSApp mainMenu] removeItemWithTitle:@"Bookmarks"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Tools", nil)]) {
		[[NSApp mainMenu] removeItemWithTitle:@"Tools"];
	}
	else if ([[self title] isEqualToString:NSLocalizedString(@"Help", nil)]) {
		//Delete the existing help menu and create a new one.
		[[NSApp mainMenu] removeItemWithTitle:NSLocalizedString(@"Help", nil)];
		NSMenuItem *helpMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Help", nil)
														action:nil
														keyEquivalent:@""];
		NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Help", nil)];
		[helpMenuItem setSubmenu:helpMenu];
		[[NSApp mainMenu] addItem:helpMenuItem];
		[NSApp setHelpMenu:helpMenu];
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
		
		[self removeItemWithTitle:@"Copy Link"];
		[self removeItemWithTitle:@"Copy Link Without Site Tracking"];
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
	}
#endif

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

#ifdef SSB_MODE
- (void)openInBrowser:(id)sender {
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	
	// Save the current contents of the pasteboard
	NSArray *types = [pasteboard types];
	NSMutableDictionary *savedPasteboardItems = [NSMutableDictionary dictionary];
	for (NSString *type in types) {
		NSData *data = [pasteboard dataForType:type];
		if (data) {
			[savedPasteboardItems setObject:data forKey:type];
		}
	}
	
	[pasteboard clearContents];
	
	sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_L);
	DISPATCH_AFTER(0.2, ^{
		sendKeyboardEvent(kCGEventFlagMaskCommand, kVK_ANSI_C);
		DISPATCH_AFTER(0.2, ^{
			NSString *url = [pasteboard stringForType:NSPasteboardTypeString];
			
			// Restore the saved pasteboard contents
			[pasteboard clearContents];
			if (savedPasteboardItems.count > 0) {
				[pasteboard declareTypes:[savedPasteboardItems allKeys] owner:nil];
				for (NSString *type in savedPasteboardItems) {
					NSData *data = savedPasteboardItems[type];
					[pasteboard setData:data forType:type];
				}
			}
			
			NSTask *task = [[NSTask alloc] init];
			task.launchPath = @"/usr/bin/open";
			task.arguments = @[url];
			[task launch];
		});
	});
}
#endif

@end




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
	ZKSwizzle(FFM_NSWindow, NSWindow);
	ZKSwizzle(FFM_NSMenu, NSMenu);
	ZKSwizzle(FFM___myNSArrayM, __NSArrayM);
#ifdef SSB_MODE
	ZKSwizzle(FFM_UserNotificationCenter, _NSConcreteUserNotificationCenter);
#endif
}

@end


int main() {}