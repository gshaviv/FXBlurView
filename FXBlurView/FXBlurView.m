//
//  FXBlurView.m
//
//  Version 1.3.1
//
//  Created by Nick Lockwood on 25/08/2013.
//  Copyright (c) 2013 Charcoal Design
//
//  Distributed under the permissive zlib License
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/FXBlurView
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//


#import "FXBlurView.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "UIImage+ImageEffects.h"


#import <Availability.h>
#if !__has_feature(objc_arc)
#error This class requires automatic reference counting
#endif

static BOOL renderLayer = YES;

@implementation UIImage (FXBlurView)

- (UIImage *)blurredImageWithRadius:(CGFloat)radius iterations:(NSUInteger)iterations tintColor:(UIColor *)tintColor tintBlendMode:(CGBlendMode)blendMode saturationFactor:(CGFloat)saturationDeltaFactor
{
    //image must be nonzero size
    if (floorf(self.size.width) * floorf(self.size.height) <= 0.0f) return self;
    
    //boxsize must be an odd integer
    int boxSize = radius * self.scale;
    if (boxSize % 2 == 0) boxSize ++;
    
    //create image buffers
    CGImageRef imageRef = self.CGImage;
    vImage_Buffer buffer1, buffer2;
    buffer1.width = buffer2.width = CGImageGetWidth(imageRef);
    buffer1.height = buffer2.height = CGImageGetHeight(imageRef);
    buffer1.rowBytes = buffer2.rowBytes = CGImageGetBytesPerRow(imageRef);
    CFIndex bytes = buffer1.rowBytes * buffer1.height;
    buffer1.data = malloc(bytes);
    buffer2.data = malloc(bytes);
    
    //create temp buffer
    void *tempBuffer = malloc(vImageBoxConvolve_ARGB8888(&buffer1, &buffer2, NULL, 0, 0, boxSize, boxSize,
                                                         NULL, kvImageEdgeExtend + kvImageGetTempBufferSize));
    
    //copy image data
    CFDataRef dataSource = CGDataProviderCopyData(CGImageGetDataProvider(imageRef));
    memcpy(buffer1.data, CFDataGetBytePtr(dataSource), bytes);
    CFRelease(dataSource);
    
    for (int i = 0; i < iterations; i++)
    {
        //perform blur
        vImageBoxConvolve_ARGB8888(&buffer1, &buffer2, tempBuffer, 0, 0, boxSize, boxSize, NULL, kvImageEdgeExtend);
        
        //swap buffers
        void *temp = buffer1.data;
        buffer1.data = buffer2.data;
        buffer2.data = temp;
    }
    BOOL hasSaturationChange = fabs(saturationDeltaFactor - 1.) > __FLT_EPSILON__;

    if (hasSaturationChange) {
        CGFloat s = saturationDeltaFactor;
        CGFloat floatingPointSaturationMatrix[] = {
            0.0722 + 0.9278 * s,  0.0722 - 0.0722 * s,  0.0722 - 0.0722 * s,  0,
            0.7152 - 0.7152 * s,  0.7152 + 0.2848 * s,  0.7152 - 0.7152 * s,  0,
            0.2126 - 0.2126 * s,  0.2126 - 0.2126 * s,  0.2126 + 0.7873 * s,  0,
            0,                    0,                    0,  1,
        };
        const int32_t divisor = 256;
        NSUInteger matrixSize = sizeof(floatingPointSaturationMatrix)/sizeof(floatingPointSaturationMatrix[0]);
        int16_t saturationMatrix[matrixSize];
        for (NSUInteger i = 0; i < matrixSize; ++i) {
            saturationMatrix[i] = (int16_t)roundf(floatingPointSaturationMatrix[i] * divisor);
        }
        vImageMatrixMultiply_ARGB8888(&buffer1, &buffer2, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
        //swap buffers
        void *temp = buffer1.data;
        buffer1.data = buffer2.data;
        buffer2.data = temp;
    }

    //free buffers
    free(buffer2.data);
    free(tempBuffer);



    //create image context from buffer
    CGContextRef ctx = CGBitmapContextCreate(buffer1.data, buffer1.width, buffer1.height,
                                             8, buffer1.rowBytes, CGImageGetColorSpace(imageRef),
                                             CGImageGetBitmapInfo(imageRef));
    
    //apply tint
    if (tintColor && ![tintColor isEqual:[UIColor clearColor]])
    {
        CGContextSetFillColorWithColor(ctx, [tintColor colorWithAlphaComponent:0.25].CGColor);
        CGContextSetBlendMode(ctx, blendMode);
        CGContextFillRect(ctx, CGRectMake(0, 0, buffer1.width, buffer1.height));
    }
    
    //create image from context
    imageRef = CGBitmapContextCreateImage(ctx);
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:self.scale orientation:self.imageOrientation];
    CGImageRelease(imageRef);
    CGContextRelease(ctx);
    free(buffer1.data);
    return image;
}

@end


NSString *const FXBlurViewUpdatesEnabledNotification = @"FXBlurViewUpdatesEnabledNotification";


@interface FXBlurView ()

@property (nonatomic, assign) BOOL updating;
@property (nonatomic, assign) BOOL iterationsSet;
@property (nonatomic, assign) BOOL blurRadiusSet;
@property (nonatomic, assign) BOOL dynamicSet;
@property (nonatomic, assign) BOOL usingStaticImage;

@end


@implementation FXBlurView

static NSInteger updatesEnabled = 1;

+ (void)setUpdatesEnabled
{
    updatesEnabled ++;
    if (updatesEnabled > 0)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:FXBlurViewUpdatesEnabledNotification object:nil];
    }
}

+ (void)setUpdatesDisabled
{
    updatesEnabled --;
}

- (void)setUp
{
    if (!_iterationsSet) _iterations = 3;
    if (!_blurRadiusSet) _blurRadius = 40.0f;
    if (!_dynamicSet) _dynamic = YES;
    _tintBlendMode = kCGBlendModePlusLighter;
    _saturationDeltaFactor = 1.;
    self.clipsToBounds = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAsynchronously)
                                                 name:FXBlurViewUpdatesEnabledNotification
                                               object:nil];
}

- (id)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        [self setUp];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder]))
    {
        [self setUp];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setIterations:(NSUInteger)iterations
{
    _iterationsSet = YES;
    _iterations = iterations;
    [self setNeedsDisplay];
}

- (void)setBlurRadius:(CGFloat)blurRadius
{
    _blurRadiusSet = YES;
    _blurRadius = blurRadius;
    [self setNeedsDisplay];
}

- (void)setDynamic:(BOOL)dynamic
{
    _dynamicSet = YES;
    _dynamic = dynamic;
    if (dynamic)
    {
        _usingStaticImage = NO;
        [self updateAsynchronously];
    }
    else
    {
        [self setNeedsDisplay];
    }
}

- (void)setBlurTintColor:(UIColor *)tintColor
{
    _blurTintColor = tintColor;
    [self setNeedsDisplay];
}

- (void)didMoveToSuperview
{
    [super didMoveToSuperview];
    [self.layer displayIfNeeded];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self updateAsynchronously];
}

- (void)setNeedsDisplay
{
    [super setNeedsDisplay];
    [self.layer setNeedsDisplay];
}

- (void)displayLayer:(CALayer *)layer
{
    if (self.superview && !_usingStaticImage)
    {
        NSArray *hiddenViews = [self prepareSuperviewForSnapshot:self.superview];
        UIImage *snapshot = [self snapshotOfSuperview:self.superview rect:self.frame];
        [self restoreSuperviewAfterSnapshot:hiddenViews];
//        NSUInteger iterations = MAX(0, (NSInteger)self.iterations - 1);
//        UIImage *blurredImage = [snapshot blurredImageWithRadius:self.blurRadius
//                                                      iterations:iterations
//                                                       tintColor:self.blurTintColor
//                                                   tintBlendMode:_tintBlendMode
//                                                saturationFactor:_saturationDeltaFactor];
        UIImage *blurredImage = [snapshot applyBlurWithRadius:self.blurRadius tintColor:self.blurTintColor saturationDeltaFactor:_saturationDeltaFactor maskImage:nil];
        self.layer.contents = (id)blurredImage.CGImage;
        self.layer.contentsScale = blurredImage.scale;
    }
}

+ (void) initialize {
    if (self == [FXBlurView class]) {
        if ([[UIView new] respondsToSelector:@selector(drawViewHierarchyInRect:afterScreenUpdates:)]) {
            renderLayer = NO;
        }
    }
}
- (UIImage *)snapshotOfSuperview:(UIView *)superview rect:(CGRect)rect
{
    CGFloat scale = (self.iterations > 0)? 8.0f/MAX(8, floor(self.blurRadius)): 1.0f;
    UIGraphicsBeginImageContextWithOptions(rect.size, YES, scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, -rect.origin.x, -rect.origin.y);
    if (renderLayer) {
        [superview.layer renderInContext:context];
    } else {
        [superview drawViewHierarchyInRect:superview.bounds afterScreenUpdates:YES];
    }
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

- (void) blurRect:(CGRect)rect inView:(UIView*)sourceView {
    self.hidden = YES;
    _dynamic = NO;
    if (sourceView) {
    UIImage *snapshot = [self snapshotOfSuperview:sourceView rect:rect];
    NSUInteger iterations = MAX(0, (NSInteger)self.iterations - 1);
    UIImage *blurredImage = [snapshot blurredImageWithRadius:self.blurRadius
                                                  iterations:iterations
                                                   tintColor:self.blurTintColor
                                               tintBlendMode:_tintBlendMode
                                            saturationFactor:_saturationDeltaFactor];
    self.layer.contents = (id)blurredImage.CGImage;
    self.layer.contentsScale = blurredImage.scale;
    }
    _usingStaticImage = YES;
    self.hidden = NO;
}

- (NSArray *)prepareSuperviewForSnapshot:(UIView *)superview
{
    NSMutableArray *views = [NSMutableArray array];
    NSInteger index = [superview.subviews indexOfObject:self];
    if (index != NSNotFound)
    {
        for (UIView *view in superview.subviews) {
            if (!view.hidden)
            {
                view.hidden = YES;
                [views addObject:view];
            }
        }
    }
    self.hidden = YES;
    return views;
}

- (void)restoreSuperviewAfterSnapshot:(NSArray *)hiddenViews
{
    for (UIView *view in hiddenViews)
    {
        view.hidden = NO;
    }
    self.hidden = NO;
}

- (void)updateAsynchronously
{
    if (self.dynamic && !self.updating  && self.window && updatesEnabled > 0)
    {
        NSArray *hiddenViews = [self prepareSuperviewForSnapshot:self.superview];
        UIImage *snapshot = [self snapshotOfSuperview:self.superview rect:self.bounds];
        [self restoreSuperviewAfterSnapshot:hiddenViews];
        
        self.updating = YES;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            
            NSUInteger iterations = MAX(0, (NSInteger)self.iterations - 1);
            UIImage *blurredImage = [snapshot blurredImageWithRadius:self.blurRadius
                                                          iterations:iterations
                                                           tintColor:self.blurTintColor
                                                       tintBlendMode:_tintBlendMode
                                                    saturationFactor:_saturationDeltaFactor];
            dispatch_sync(dispatch_get_main_queue(), ^{
                
                self.updating = NO;
                if (self.dynamic)
                {
                    self.layer.contents = (id)blurredImage.CGImage;
                    self.layer.contentsScale = blurredImage.scale;
                    if (self.updateInterval)
                    {
                        [self performSelector:@selector(updateAsynchronously) withObject:nil
                                   afterDelay:self.updateInterval inModes:@[NSDefaultRunLoopMode, UITrackingRunLoopMode]];
                    }
                    else
                    {
                        [self performSelectorOnMainThread:@selector(updateAsynchronously) withObject:nil
                                            waitUntilDone:NO modes:@[NSDefaultRunLoopMode, UITrackingRunLoopMode]];
                    }
                }
            });
        });
    }
}

@end
