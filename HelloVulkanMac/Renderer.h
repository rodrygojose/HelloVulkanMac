
//#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
//#import <simd/simd.h>

@interface Renderer : NSObject <MTKViewDelegate>

@property (nonatomic, strong) MTKView *view;

- (instancetype)initWithMTKView:(MTKView *)mtkView;

@end
