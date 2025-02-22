#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>

@interface MyPrefPane : NSPreferencePane
@end

@implementation MyPrefPane

- (void)mainViewDidLoad {}

- (void)willSelect {
	NSString *scriptPath = [NSString stringWithFormat:@"%@%@", [[NSBundle bundleForClass:[self class]] resourcePath], @"/Main.py"];
	[self runPython:scriptPath];
	
	[self performSelector:@selector(runApplescript:) withObject:[NSMutableString stringWithString:@"tell application \"System Preferences\" to set show all to true"] afterDelay:0.1];
}

- (void)runApplescript:(NSMutableString *)scriptSource {
	NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
	NSDictionary *error;
	[[script executeAndReturnError:&error] stringValue];
}

- (void)runPython:(NSString *)scriptPath {
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath:@"/usr/bin/python"];
	[task setArguments:@[scriptPath]];

	NSPipe *pipe = [NSPipe pipe];
	[task setStandardOutput:pipe];
	[task setStandardError:pipe];

	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	
	NSData *data = [file readDataToEndOfFile];
	NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	NSLog(@"Firefox Dynasty Downloader: %@", output);
}

@end

int main(){}