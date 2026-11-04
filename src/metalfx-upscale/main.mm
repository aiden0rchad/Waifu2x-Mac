// metalfx-upscale: image upscaler on Apple's MetalFX spatial scaler.
// Drop-in for the waifu2x-ncnn-vulkan command line used by Waifu2x-mac GUI:
//   metalfx-upscale -i <file|dir> -o <file|dir> [-s 2] [-f png|jpg]
// AI-engine flags (-n -t -m -j -g -x -v) are accepted and ignored.
// Alpha is scaled separately, so transparent images keep their transparency.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <vector>

static id<MTLDevice> gDevice;
static id<MTLCommandQueue> gQueue;

// One scaler plus its textures, reused while consecutive frames have the same size.
// Creating a scaler is the expensive part; the GPU pass itself takes milliseconds.
struct ScalerSet {
    int w = 0, h = 0, ow = 0, oh = 0;
    id<MTLFXSpatialScaler> scaler;
    id<MTLTexture> tin, tout;
    id<MTLBuffer> buf;
};
static ScalerSet gScaler;
static std::mutex gGpuMutex;   // guards gScaler and all GPU work
static std::mutex gLogMutex;

static bool prepareScaler(int w, int h, int ow, int oh)
{
    if (gScaler.scaler && gScaler.w == w && gScaler.h == h && gScaler.ow == ow && gScaler.oh == oh) return true;
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.inputWidth = w;   d.inputHeight = h;
    d.outputWidth = ow; d.outputHeight = oh;
    d.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
    d.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    id<MTLFXSpatialScaler> scaler = [d newSpatialScalerWithDevice:gDevice];
    if (!scaler) { fprintf(stderr, "MetalFX: cannot create scaler for %dx%d -> %dx%d\n", w, h, ow, oh); return false; }

    MTLTextureDescriptor *in = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    in.storageMode = MTLStorageModeShared;
    in.usage = scaler.colorTextureUsage;
    MTLTextureDescriptor *out = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:ow height:oh mipmapped:NO];
    out.storageMode = MTLStorageModePrivate;
    out.usage = scaler.outputTextureUsage;
    gScaler = {w, h, ow, oh, scaler, [gDevice newTextureWithDescriptor:in], [gDevice newTextureWithDescriptor:out],
               [gDevice newBufferWithLength:(NSUInteger)ow * oh * 4 options:MTLResourceStorageModeShared]};
    return true;
}

// Scales a tightly packed RGBA8 buffer from w x h to ow x oh in one MetalFX pass.
static std::vector<uint8_t> scaleRGBA(const uint8_t *src, int w, int h, int ow, int oh)
{
    std::lock_guard<std::mutex> lock(gGpuMutex);
    if (!prepareScaler(w, h, ow, oh)) return {};
    id<MTLFXSpatialScaler> scaler = gScaler.scaler;
    id<MTLTexture> tin = gScaler.tin, tout = gScaler.tout;
    id<MTLBuffer> buf = gScaler.buf;
    [tin replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:src bytesPerRow:(NSUInteger)w * 4];

    std::vector<uint8_t> result((size_t)ow * oh * 4);
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    scaler.colorTexture = tin;
    scaler.outputTexture = tout;
    [scaler encodeToCommandBuffer:cb];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tout sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(ow, oh, 1)
                 toBuffer:buf destinationOffset:0 destinationBytesPerRow:(NSUInteger)ow * 4 destinationBytesPerImage:result.size()];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "MetalFX: %s\n", cb.error.localizedDescription.UTF8String); return {}; }
    memcpy(result.data(), buf.contents, result.size());
    return result;
}

static bool processFile(NSString *inPath, NSString *outPath, int scale, bool jpg)
{
    CGImageSourceRef srcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:inPath], NULL);
    CGImageRef img = srcRef ? CGImageSourceCreateImageAtIndex(srcRef, 0, NULL) : NULL;
    if (srcRef) CFRelease(srcRef);
    if (!img) { fprintf(stderr, "decode failed: %s\n", inPath.UTF8String); return false; }

    int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
    int ow = w * scale, oh = h * scale;

    // Premultiplied RGBA from CoreGraphics, converted to straight alpha.
    std::vector<uint8_t> px((size_t)w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, (size_t)w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGImageRelease(img);

    bool hasAlpha = false;
    std::vector<uint8_t> alpha((size_t)w * h * 4, 255);
    for (size_t i = 0; i < (size_t)w * h; i++) {
        uint8_t *p = &px[i * 4];
        uint8_t a = p[3];
        if (a != 255) hasAlpha = true;
        if (a != 0 && a != 255) for (int c = 0; c < 3; c++) p[c] = (uint8_t)std::min(255, (p[c] * 255 + a / 2) / a);
        alpha[i * 4] = alpha[i * 4 + 1] = alpha[i * 4 + 2] = a;
        p[3] = 255;
    }

    std::vector<uint8_t> color = scaleRGBA(px.data(), w, h, ow, oh);
    if (color.empty()) { CGColorSpaceRelease(cs); return false; }
    if (hasAlpha && !jpg) {
        std::vector<uint8_t> a2 = scaleRGBA(alpha.data(), w, h, ow, oh);
        if (a2.empty()) { CGColorSpaceRelease(cs); return false; }
        for (size_t i = 0; i < (size_t)ow * oh; i++) color[i * 4 + 3] = a2[i * 4];
    }

    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, color.data(), color.size(), NULL);
    CGImageRef outImg = CGImageCreate(ow, oh, 8, 32, (size_t)ow * 4, cs,
                                      (hasAlpha && !jpg) ? (kCGImageAlphaLast | kCGBitmapByteOrder32Big) : (kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big),
                                      prov, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(prov);
    CGColorSpaceRelease(cs);

    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:outPath],
                                                                (__bridge CFStringRef)(jpg ? UTTypeJPEG.identifier : UTTypePNG.identifier), 1, NULL);
    NSDictionary *opts = jpg ? @{(__bridge id)kCGImageDestinationLossyCompressionQuality: @0.95} : @{};
    CGImageDestinationAddImage(dst, outImg, (__bridge CFDictionaryRef)opts);
    bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(outImg);
    if (!ok) fprintf(stderr, "write failed: %s\n", outPath.UTF8String);
    return ok;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *in = nil, *out = nil, *fmt = nil;
        int scale = 2;
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            bool hasNext = i + 1 < argc;
            if ([a isEqualToString:@"-i"] && hasNext) in = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"-o"] && hasNext) out = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"-s"] && hasNext) scale = atoi(argv[++i]);
            else if ([a isEqualToString:@"-f"] && hasNext) fmt = [[NSString stringWithUTF8String:argv[++i]] lowercaseString];
            else if (hasNext && ([a isEqualToString:@"-n"] || [a isEqualToString:@"-t"] || [a isEqualToString:@"-m"] ||
                                 [a isEqualToString:@"-j"] || [a isEqualToString:@"-g"])) i++;
        }
        if (!in || !out || scale < 1) {
            fprintf(stderr, "usage: metalfx-upscale -i infile|dir -o outfile|dir [-s scale] [-f png|jpg]\n");
            return 1;
        }
        gDevice = MTLCreateSystemDefaultDevice();
        if (!gDevice || ![MTLFXSpatialScalerDescriptor supportsDevice:gDevice]) {
            fprintf(stderr, "MetalFX spatial scaling is not supported on this GPU\n");
            return 2;
        }
        gQueue = [gDevice newCommandQueue];
        printf("[0 %s]  MetalFX spatial scaler\n", gDevice.name.UTF8String);

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        [fm fileExistsAtPath:in isDirectory:&isDir];
        std::atomic<int> failures{0};
        if (isDir) {
            [fm createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
            NSSet *exts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"bmp", @"tif", @"tiff", @"webp", @"heic", nil];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSString *name in [[fm contentsOfDirectoryAtPath:in error:nil] sortedArrayUsingSelector:@selector(compare:)])
                if ([exts containsObject:name.pathExtension.lowercaseString]) [names addObject:name];
            bool jpg = [fmt isEqualToString:@"jpg"] || [fmt isEqualToString:@"jpeg"];
            // Decoding and PNG encoding dominate the run time, so frames are processed in parallel;
            // the GPU step is serialized in scaleRGBA. Worker count bounds memory (two full frames each).
            std::atomic<NSUInteger> next{0};
            std::atomic<NSUInteger> *nextp = &next;   // blocks capture C++ objects by const copy
            std::atomic<int> *failuresp = &failures;
            NSUInteger workers = std::min<NSUInteger>(std::max<NSUInteger>(NSProcessInfo.processInfo.activeProcessorCount / 2, 2), 8);
            dispatch_apply(workers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t) {
                for (NSUInteger k = (*nextp)++; k < names.count; k = (*nextp)++) {
                    @autoreleasepool {
                        NSString *name = names[k];
                        NSString *dstName = [[name stringByDeletingPathExtension] stringByAppendingPathExtension:(jpg ? @"jpg" : @"png")];
                        bool ok = processFile([in stringByAppendingPathComponent:name], [out stringByAppendingPathComponent:dstName], scale, jpg);
                        std::lock_guard<std::mutex> lock(gLogMutex);
                        if (ok) printf("%s -> %s done\n", name.UTF8String, dstName.UTF8String);
                        else (*failuresp)++;
                    }
                }
            });
        } else {
            NSString *ext = out.pathExtension.lowercaseString;
            bool jpg = [fmt isEqualToString:@"jpg"] || [fmt isEqualToString:@"jpeg"] || (!fmt && ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]));
            if (processFile(in, out, scale, jpg)) printf("%s -> %s done\n", in.UTF8String, out.UTF8String);
            else failures++;
        }
        return failures ? 1 : 0;
    }
}
