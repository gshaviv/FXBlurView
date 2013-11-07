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


#import <Availability.h>
#if !__has_feature(objc_arc)
#error This class requires automatic reference counting
#endif

static BOOL renderLayer = YES;

@implementation UIImage (FXBlurView)

#define scaleDownFactor 4


- (UIImage *)applyBlurWithCrop:(CGRect) bounds resize:(CGSize) size blurRadius:(CGFloat) blurRadius tintColor:(UIColor *) tintColor saturationDeltaFactor:(CGFloat) saturationDeltaFactor maskImage:(UIImage *) maskImage {

    if (self.size.width < 1 || self.size.height < 1) {
        NSLog (@"*** error: invalid size: (%.2f x %.2f). Both dimensions must be >= 1: %@", self.size.width, self.size.height, self);
        return nil;
    }

    if (!self.CGImage) {
        NSLog (@"*** error: image must be backed by a CGImage: %@", self);
        return nil;
    }

    if (maskImage && !maskImage.CGImage) {
        NSLog (@"*** error: maskImage must be backed by a CGImage: %@", maskImage);
        return nil;
    }

    //Crop
    UIImage *outputImage = nil;

    CGImageRef imageRef = CGImageCreateWithImageInRect([self CGImage], bounds);
    outputImage = [UIImage imageWithCGImage:imageRef];

    CGImageRelease(imageRef);

    //Re-Size
    CGImageRef sourceRef = [outputImage CGImage];
    NSUInteger sourceWidth = CGImageGetWidth(sourceRef);
    NSUInteger sourceHeight = CGImageGetHeight(sourceRef);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    unsigned char *sourceData = (unsigned char*) calloc(sourceHeight * sourceWidth * 4, sizeof(unsigned char));

    NSUInteger bytesPerPixel = 4;
    NSUInteger sourceBytesPerRow = bytesPerPixel * sourceWidth;
    NSUInteger bitsPerComponent = 8;

    CGContextRef context = CGBitmapContextCreate(sourceData, sourceWidth, sourceHeight, bitsPerComponent, sourceBytesPerRow, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);

    CGContextDrawImage(context, CGRectMake(0, 0, sourceWidth, sourceHeight), sourceRef);
    CGContextRelease(context);

    NSUInteger destWidth = (NSUInteger) size.width / scaleDownFactor;
    NSUInteger destHeight = (NSUInteger) size.height / scaleDownFactor;
    NSUInteger destBytesPerRow = bytesPerPixel * destWidth;

    unsigned char *destData = (unsigned char*) calloc(destHeight * destWidth * 4, sizeof(unsigned char));

    vImage_Buffer src = {
        .data = sourceData,
        .height = sourceHeight,
        .width = sourceWidth,
        .rowBytes = sourceBytesPerRow
    };

    vImage_Buffer dest = {
        .data = destData,
        .height = destHeight,
        .width = destWidth,
        .rowBytes = destBytesPerRow
    };

    vImageScale_ARGB8888 (&src, &dest, NULL, kvImageNoInterpolation);

    free(sourceData);

    CGContextRef destContext = CGBitmapContextCreate(destData, destWidth, destHeight, bitsPerComponent, destBytesPerRow, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);

    CGImageRef destRef = CGBitmapContextCreateImage(destContext);

    outputImage = [UIImage imageWithCGImage:destRef];

    CGImageRelease(destRef);

    CGColorSpaceRelease(colorSpace);
    CGContextRelease(destContext);

    free(destData);

    //Blur
    CGRect imageRect = { CGPointZero, outputImage.size };

    BOOL hasBlur = blurRadius > __FLT_EPSILON__;
    BOOL hasSaturationChange = fabs(saturationDeltaFactor - 1.) > __FLT_EPSILON__;

    if (hasBlur || hasSaturationChange) {

        UIGraphicsBeginImageContextWithOptions(outputImage.size, NO, 1);

        CGContextRef effectInContext = UIGraphicsGetCurrentContext();

        CGContextScaleCTM(effectInContext, 1.0, -1.0);
        CGContextTranslateCTM(effectInContext, 0, -outputImage.size.height);
        CGContextDrawImage(effectInContext, imageRect, outputImage.CGImage);

        vImage_Buffer effectInBuffer;

        effectInBuffer.data     = CGBitmapContextGetData(effectInContext);
        effectInBuffer.width    = CGBitmapContextGetWidth(effectInContext);
        effectInBuffer.height   = CGBitmapContextGetHeight(effectInContext);
        effectInBuffer.rowBytes = CGBitmapContextGetBytesPerRow(effectInContext);

        UIGraphicsBeginImageContextWithOptions(outputImage.size, NO, 1);

        CGContextRef effectOutContext = UIGraphicsGetCurrentContext();
        vImage_Buffer effectOutBuffer;

        effectOutBuffer.data     = CGBitmapContextGetData(effectOutContext);
        effectOutBuffer.width    = CGBitmapContextGetWidth(effectOutContext);
        effectOutBuffer.height   = CGBitmapContextGetHeight(effectOutContext);
        effectOutBuffer.rowBytes = CGBitmapContextGetBytesPerRow(effectOutContext);

        if (hasBlur) {
            CGFloat inputRadius = blurRadius * 1;
            NSUInteger radius = floor(inputRadius * 3. * sqrt(2 * M_PI) / 4 + 0.5);

            if (radius % 2 != 1) {
                radius += 1;
            }

            vImageBoxConvolve_ARGB8888(&effectInBuffer, &effectOutBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
            vImageBoxConvolve_ARGB8888(&effectOutBuffer, &effectInBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
            vImageBoxConvolve_ARGB8888(&effectInBuffer, &effectOutBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
        }

        BOOL effectImageBuffersAreSwapped = NO;

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

            if (hasBlur) {
                vImageMatrixMultiply_ARGB8888(&effectOutBuffer, &effectInBuffer, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
                effectImageBuffersAreSwapped = YES;
            } else {
                vImageMatrixMultiply_ARGB8888(&effectInBuffer, &effectOutBuffer, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
            }
        }

        if (!effectImageBuffersAreSwapped)
            outputImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (effectImageBuffersAreSwapped)
            outputImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    UIGraphicsBeginImageContextWithOptions(outputImage.size, NO, 1);
    CGContextRef outputContext = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(outputContext, 1.0, -1.0);
    CGContextTranslateCTM(outputContext, 0, -outputImage.size.height);
    if (!hasBlur)
        CGContextDrawImage(outputContext, imageRect, outputImage.CGImage);

    if (hasBlur) {
        CGContextSaveGState(outputContext);
        if (maskImage) {
            CGContextClipToMask(outputContext, imageRect, maskImage.CGImage);
        }
        CGContextDrawImage(outputContext, imageRect, outputImage.CGImage);
        CGContextRestoreGState(outputContext);
    }

    if (tintColor) {
        CGContextSaveGState(outputContext);
        CGFloat alpha = [tintColor alphaComponent];
        if (alpha > .999) {
            tintColor = [tintColor colorWithAlphaComponent:.5];
        }
        CGContextSetFillColorWithColor(outputContext, tintColor.CGColor);
        CGContextFillRect(outputContext, imageRect);
        CGContextRestoreGState(outputContext);
    }

    outputImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return outputImage;
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
    if (!_blurRadiusSet) _blurRadius = 7.0f;
    if (!_dynamicSet) _dynamic = YES;
    _tintBlendMode = kCGBlendModePlusLighter;
    _saturationDeltaFactor = 1.;
    self.clipsToBounds = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAsynchronously)
                                                 name:FXBlurViewUpdatesEnabledNotification
                                               object:nil];

    self.layer.magnificationFilter = kCAFilterNearest;
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
        UIImage *snapshot = [self snapshotOfSuperview:self.superview];
        [self restoreSuperviewAfterSnapshot:hiddenViews];
        dispatch_to_background(^{
            UIImage *blurredImage = [snapshot applyBlurWithCrop:self.frame resize:self.frame.size blurRadius:self.blurRadius tintColor:self.blurTintColor saturationDeltaFactor:self.saturationDeltaFactor maskImage:nil];
            dispatch_async_main(^{
                self.layer.contents = (id)blurredImage.CGImage;
                self.layer.contentsScale = 1./scaleDownFactor;
            });
        });
    }
}

+ (void) initialize {
    if (self == [FXBlurView class]) {
        if ([[UIView new] respondsToSelector:@selector(drawViewHierarchyInRect:afterScreenUpdates:)]) {
            renderLayer = NO;
        }
    }
}
- (UIImage *)snapshotOfSuperview:(UIView *)superview
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(CGRectGetWidth(superview.frame), CGRectGetHeight(superview.frame)), NO, 1);
    [superview drawViewHierarchyInRect:CGRectMake(0, 0, CGRectGetWidth(superview.frame), CGRectGetHeight(superview.frame)) afterScreenUpdates:NO];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

- (void) blurRect:(CGRect)rect inView:(UIView*)sourceView {
    self.hidden = YES;
    _dynamic = NO;
    if (sourceView) {
        UIImage *snapshot = [self snapshotOfSuperview:sourceView];
        dispatch_to_background(^{
            UIImage *blurredImage = [snapshot applyBlurWithCrop:rect resize:rect.size blurRadius:self.blurRadius tintColor:self.blurTintColor saturationDeltaFactor:self.saturationDeltaFactor maskImage:nil];
            dispatch_async_main(^{
                self.layer.contents = (id)blurredImage.CGImage;
                self.layer.contentsScale = 1./scaleDownFactor;
            });
        });

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
        UIImage *snapshot = [self snapshotOfSuperview:self.superview ];
        [self restoreSuperviewAfterSnapshot:hiddenViews];

        self.updating = YES;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{

            UIImage *blurredImage = [snapshot applyBlurWithCrop:self.bounds resize:self.bounds.size blurRadius:self.blurRadius tintColor:self.blurTintColor saturationDeltaFactor:self.saturationDeltaFactor maskImage:nil];;
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
