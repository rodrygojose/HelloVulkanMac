
#import "AppDelegate.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSWindow *window = [[NSApplication sharedApplication] mainWindow];
    MTKView *view = (MTKView *)[window contentView];
    
    _renderer = [[Renderer alloc] initWithMTKView:view];
    view.delegate = _renderer;
}

@end

int main(int argc, const char * argv[]) {
    return NSApplicationMain(argc, argv);
}

