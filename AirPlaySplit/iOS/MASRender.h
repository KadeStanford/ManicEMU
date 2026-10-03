// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>

// Crop coordinates use Metal's top-left texture origin, normalized to [0,1].
BOOL MASDrawCrop(id<MTLCommandBuffer> buffer, id<MTLTexture> source,
                 id<MTLTexture> destination, CGRect crop);
CGRect MASFit(CGSize content, CGSize bounds);
