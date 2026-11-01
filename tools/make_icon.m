// Renders the MacCleaner app icon from scratch with Core Graphics -- no
// external artwork, so there is nothing to license. Produces a 1024x1024
// PNG in the macOS Big Sur+ icon shape (an 824pt rounded square centred on
// the canvas); build_icon.sh turns it into the .icns the bundle ships.
//
//   cc -fobjc-arc -framework AppKit tools/make_icon.m -o make_icon
//   ./make_icon /path/to/icon_1024.png
//
// Design: an indigo-to-cyan tile with a large four-point sparkle and two
// small companions -- "sparkling clean" -- which stays legible down to the
// 16pt menu-bar size where a detailed broom would turn to mush. Layered in
// the macOS 26 manner: a soft drop shadow under the tile, an aurora glow
// and a glass reflection on it, a bright inner rim, and sparkles that sit
// above the tile as frosted glass (ice-blue gradient, specular edge,
// coloured shadow). Plain Objective-C rather than Swift so it builds with
// nothing but clang.

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

static void DrawSparkle(CGContextRef ctx, CGColorSpaceRef space, CGPoint c, CGFloat r) {
    CGPathRef path = CreateSparkle(c, r);

    // Body with a deep-blue shadow, so it floats above the tile.
    CGContextSaveGState(ctx);
    CGColorRef shadow = CGColorCreateGenericRGB(0x1e / 255.0, 0x3a / 255.0, 0x8a / 255.0, 0.45);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -r * 0.08), r * 0.22, shadow);
    CGContextAddPath(ctx, path);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillPath(ctx);
    CGColorRelease(shadow);
    CGContextRestoreGState(ctx);

    // Frosted fill: white at the top to ice blue (#dbeafe) at the bottom.
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    const CGFloat ice[] = {1, 1, 1, 1, 0xdb / 255.0, 0xea / 255.0, 0xfe / 255.0, 1};
    const CGFloat stops[] = {0, 1};
    CGGradientRef fill = CGGradientCreateWithColorComponents(space, ice, stops, 2);
    CGContextDrawLinearGradient(ctx, fill, CGPointMake(c.x, c.y + r), CGPointMake(c.x, c.y - r), 0);
    CGGradientRelease(fill);
    CGContextRestoreGState(ctx);

    // Specular edge.
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.8);
    CGContextSetLineWidth(ctx, MAX(2, r * 0.02));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    CGPathRelease(path);
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

        const CGFloat stops2[] = {0, 1};

        // --- drop shadow under the tile, inside the canvas -----------------
        CGContextSaveGState(ctx);
        CGColorRef tileShadow = CGColorCreateGenericRGB(0, 0, 0, 0.35);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -kTile * 0.012), kTile * 0.03, tileShadow);
        CGContextAddPath(ctx, tilePath);
        CGContextSetRGBFillColor(ctx, 0.26, 0.22, 0.79, 1);
        CGContextFillPath(ctx);
        CGColorRelease(tileShadow);
        CGContextRestoreGState(ctx);

        // --- tile: diagonal gradient, indigo -> blue -> cyan ---------------
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, tilePath);
        CGContextClip(ctx);

        const CGFloat gradientComponents[] = {
            0x43 / 255.0, 0x38 / 255.0, 0xca / 255.0, 1.0, // indigo (top-left)
            0x25 / 255.0, 0x63 / 255.0, 0xeb / 255.0, 1.0, // blue
            0x08 / 255.0, 0x91 / 255.0, 0xb2 / 255.0, 1.0, // cyan (bottom-right)
        };
        const CGFloat stops3[] = {0, 0.5, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, gradientComponents, stops3, 3);
        CGContextDrawLinearGradient(ctx, gradient,
                                    CGPointMake(CGRectGetMinX(tileRect), CGRectGetMaxY(tileRect)),
                                    CGPointMake(CGRectGetMaxX(tileRect), CGRectGetMinY(tileRect)), 0);
        CGGradientRelease(gradient);

        // Aurora: a cyan glow top-left and a violet one bottom-right, the
        // same drifting blobs the app draws behind its screens.
        typedef struct {
            CGFloat x, y, r, g, b;
        } Blob;
        const Blob blobs[] = {{0.25, 0.80, 0.13, 0.83, 0.93}, {0.85, 0.15, 0.66, 0.33, 0.97}};
        for (size_t i = 0; i < sizeof blobs / sizeof blobs[0]; ++i) {
            const Blob blob = blobs[i];
            const CGFloat components[] = {blob.r, blob.g, blob.b, 0.45, blob.r, blob.g, blob.b, 0};
            CGGradientRef glow = CGGradientCreateWithColorComponents(space, components, stops2, 2);
            const CGPoint bc = CGPointMake(CGRectGetMinX(tileRect) + kTile * blob.x,
                                           CGRectGetMinY(tileRect) + kTile * blob.y);
            CGContextDrawRadialGradient(ctx, glow, bc, 0, bc, kTile * 0.55, 0);
            CGGradientRelease(glow);
        }

        // Glass reflection over the top half.
        const CGFloat shine[] = {1, 1, 1, 0.22, 1, 1, 1, 0};
        CGGradientRef reflection = CGGradientCreateWithColorComponents(space, shine, stops2, 2);
        CGContextDrawLinearGradient(ctx, reflection, CGPointMake(0, CGRectGetMaxY(tileRect)),
                                    CGPointMake(0, CGRectGetMidY(tileRect)), 0);
        CGGradientRelease(reflection);
        CGContextRestoreGState(ctx);

        // Inner rim: bright at the top, faint at the bottom.
        CGContextSaveGState(ctx);
        const CGFloat rimWidth = kTile * 0.0035;
        CGPathRef rimPath = CGPathCreateWithRoundedRect(CGRectInset(tileRect, rimWidth / 2, rimWidth / 2),
                                                        radius - rimWidth / 2, radius - rimWidth / 2, NULL);
        CGContextAddPath(ctx, rimPath);
        CGContextSetLineWidth(ctx, rimWidth);
        CGContextReplacePathWithStrokedPath(ctx);
        CGContextClip(ctx);
        const CGFloat rim[] = {1, 1, 1, 0.5, 1, 1, 1, 0.1};
        CGGradientRef rimGradient = CGGradientCreateWithColorComponents(space, rim, stops2, 2);
        CGContextDrawLinearGradient(ctx, rimGradient, CGPointMake(0, CGRectGetMaxY(tileRect)),
                                    CGPointMake(0, CGRectGetMinY(tileRect)), 0);
        CGGradientRelease(rimGradient);
        CGPathRelease(rimPath);
        CGContextRestoreGState(ctx);

        // --- sparkles ----------------------------------------------------
        const CGPoint centre = CGPointMake(kCanvas / 2, kCanvas / 2);
        DrawSparkle(ctx, space, CGPointMake(centre.x - kTile * 0.04, centre.y - kTile * 0.03), kTile * 0.30);
        DrawSparkle(ctx, space, CGPointMake(centre.x + kTile * 0.25, centre.y + kTile * 0.24), kTile * 0.11);
        DrawSparkle(ctx, space, CGPointMake(centre.x + kTile * 0.30, centre.y - kTile * 0.20), kTile * 0.065);

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
