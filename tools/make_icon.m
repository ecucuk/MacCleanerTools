// Renders the MacCleaner app icon from scratch with Core Graphics -- no
// external artwork, so there is nothing to license. Produces a 1024x1024
// PNG in the macOS Big Sur+ icon shape (an 824pt rounded square centred on
// the canvas); build_icon.sh turns it into the .icns the bundle ships.
//
//   cc -fobjc-arc -framework AppKit tools/make_icon.m -o make_icon
//   ./make_icon /path/to/icon_1024.png
//
// Design: a blue-to-teal tile with a large four-point sparkle and two small
// companions -- "sparkling clean" -- which stays legible down to the 16pt
// menu-bar size where a detailed broom would turn to mush. Plain
// Objective-C rather than Swift so it builds with nothing but clang.

#import <AppKit/AppKit.h>

static const CGFloat kCanvas = 1024;
static const CGFloat kTile = 824;              // Apple's icon-grid tile within a 1024 canvas
static const CGFloat kCornerRatio = 0.2237;    // Big Sur squircle approximation

// A four-point sparkle: four quadratic curves tip-to-tip with the control
// point at the centre, which pulls every side inward into the classic
// concave star.
static CGPathRef CreateSparkle(CGPoint c, CGFloat r) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x, c.y + r);
    CGPathAddQuadCurveToPoint(p, NULL, c.x, c.y, c.x + r, c.y);
    CGPathAddQuadCurveToPoint(p, NULL, c.x, c.y, c.x, c.y - r);
    CGPathAddQuadCurveToPoint(p, NULL, c.x, c.y, c.x - r, c.y);
    CGPathAddQuadCurveToPoint(p, NULL, c.x, c.y, c.x, c.y + r);
    CGPathCloseSubpath(p);
    return p;
}

static void DrawSparkle(CGContextRef ctx, CGPoint c, CGFloat r) {
    CGContextSaveGState(ctx);
    CGColorRef shadow = CGColorCreateGenericRGB(0, 0.15, 0.4, 0.35);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -r * 0.06), r * 0.18, shadow);
    CGPathRef path = CreateSparkle(c, r);
    CGContextAddPath(ctx, path);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillPath(ctx);
    CGPathRelease(path);
    CGColorRelease(shadow);
    CGContextRestoreGState(ctx);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: make_icon <out.png>\n");
            return 2;
        }

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)kCanvas, (size_t)kCanvas, 8, 0, space,
                                                  (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        if (ctx == NULL) {
            fprintf(stderr, "could not create bitmap context\n");
            return 1;
        }

        const CGFloat origin = (kCanvas - kTile) / 2;
        const CGRect tileRect = CGRectMake(origin, origin, kTile, kTile);
        const CGFloat radius = kTile * kCornerRatio;
        CGPathRef tilePath = CGPathCreateWithRoundedRect(tileRect, radius, radius, NULL);

        // --- tile: diagonal gradient, deep blue to teal --------------------
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, tilePath);
        CGContextClip(ctx);

        const CGFloat gradientComponents[] = {
            0.11, 0.36, 0.93, 1.0, // deep blue (top-left)
            0.13, 0.71, 0.87, 1.0, // teal (bottom-right)
        };
        const CGFloat stops[] = {0, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, gradientComponents, stops, 2);
        CGContextDrawLinearGradient(ctx, gradient,
                                    CGPointMake(CGRectGetMinX(tileRect), CGRectGetMaxY(tileRect)),
                                    CGPointMake(CGRectGetMaxX(tileRect), CGRectGetMinY(tileRect)), 0);
        CGGradientRelease(gradient);

        // A soft radial highlight in the upper-left gives the flat gradient
        // some depth without resorting to skeuomorphic gloss.
        const CGFloat highlightComponents[] = {1, 1, 1, 0.22, 1, 1, 1, 0};
        CGGradientRef highlight = CGGradientCreateWithColorComponents(space, highlightComponents, stops, 2);
        const CGPoint hc = CGPointMake(CGRectGetMinX(tileRect) + kTile * 0.3, CGRectGetMaxY(tileRect) - kTile * 0.25);
        CGContextDrawRadialGradient(ctx, highlight, hc, 0, hc, kTile * 0.7, 0);
        CGGradientRelease(highlight);
        CGContextRestoreGState(ctx);

        // --- sparkles ----------------------------------------------------
        const CGPoint centre = CGPointMake(kCanvas / 2, kCanvas / 2);
        DrawSparkle(ctx, CGPointMake(centre.x - kTile * 0.04, centre.y - kTile * 0.03), kTile * 0.30);
        DrawSparkle(ctx, CGPointMake(centre.x + kTile * 0.25, centre.y + kTile * 0.24), kTile * 0.11);
        DrawSparkle(ctx, CGPointMake(centre.x + kTile * 0.30, centre.y - kTile * 0.20), kTile * 0.065);

        // --- write PNG ---------------------------------------------------
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error = nil;
        const BOOL ok = [png writeToFile:[NSString stringWithUTF8String:argv[1]]
                                 options:NSDataWritingAtomic
                                   error:&error];

        CGImageRelease(image);
        CGPathRelease(tilePath);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);

        if (!ok) {
            fprintf(stderr, "write failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("wrote %s\n", argv[1]);
        return 0;
    }
}
