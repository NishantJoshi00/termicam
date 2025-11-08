#import "camera_wrapper.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@interface CameraCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    AVCaptureSession* session;
    AVCaptureDevice* device;
    AVCaptureDeviceInput* input;
    AVCaptureVideoDataOutput* output;
    dispatch_queue_t captureQueue;
    dispatch_semaphore_t frameSemaphore;

    uint8_t* imageData;
    uint32_t imageWidth;
    uint32_t imageHeight;
    uint32_t imageBytesPerRow;
    bool hasNewFrame;
    bool isOpen;
}

- (id)init;
- (void)dealloc;
- (CameraError)open;
- (void)close;
- (CameraError)captureFrame:(CameraImage*)outImage;
- (bool)isSessionOpen;

@end

@implementation CameraCapture

- (id)init {
    self = [super init];
    if (self) {
        session = nil;
        device = nil;
        input = nil;
        output = nil;
        captureQueue = nil;
        frameSemaphore = nil;
        imageData = nullptr;
        imageWidth = 0;
        imageHeight = 0;
        imageBytesPerRow = 0;
        hasNewFrame = false;
        isOpen = false;
    }
    return self;
}

- (void)dealloc {
    [self close];
    if (imageData) {
        free(imageData);
        imageData = nullptr;
    }
}

- (CameraError)open {
    if (isOpen) {
        return CAMERA_ERROR_ALREADY_OPEN;
    }

    // Create capture session
    session = [[AVCaptureSession alloc] init];
    if (!session) {
        return CAMERA_ERROR_SESSION;
    }

    // Set session preset for quality
    [session setSessionPreset:AVCaptureSessionPreset640x480];

    // Get default video device
    if (@available(macOS 10.15, *)) {
        device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                    mediaType:AVMediaTypeVideo
                                                     position:AVCaptureDevicePositionUnspecified];
    } else {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }

    if (!device) {
        session = nil;
        return CAMERA_ERROR_NO_DEVICE;
    }

    // Create device input
    NSError* error = nil;
    input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || error) {
        session = nil;
        device = nil;
        return CAMERA_ERROR_INIT;
    }

    // Add input to session
    if ([session canAddInput:input]) {
        [session addInput:input];
    } else {
        session = nil;
        device = nil;
        input = nil;
        return CAMERA_ERROR_SESSION;
    }

    // Create output
    output = [[AVCaptureVideoDataOutput alloc] init];
    if (!output) {
        session = nil;
        device = nil;
        input = nil;
        return CAMERA_ERROR_INIT;
    }

    // Configure output for grayscale (Y only from YUV)
    NSDictionary* videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };
    [output setVideoSettings:videoSettings];

    // Create dispatch queue for frame processing
    captureQueue = dispatch_queue_create("camera.capture.queue", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:captureQueue];

    // Discard frames if processing is slow
    [output setAlwaysDiscardsLateVideoFrames:YES];

    // Add output to session
    if ([session canAddOutput:output]) {
        [session addOutput:output];
    } else {
        session = nil;
        device = nil;
        input = nil;
        output = nil;
        captureQueue = nil;
        return CAMERA_ERROR_SESSION;
    }

    // Create semaphore for frame synchronization
    frameSemaphore = dispatch_semaphore_create(0);

    // Start the session
    [session startRunning];
    isOpen = true;

    return CAMERA_OK;
}

- (void)close {
    if (!isOpen) {
        return;
    }

    if (session) {
        [session stopRunning];
    }

    if (output) {
        [output setSampleBufferDelegate:nil queue:nil];
    }

    session = nil;
    device = nil;
    input = nil;
    output = nil;

    if (captureQueue) {
        captureQueue = nil;
    }

    if (frameSemaphore) {
        frameSemaphore = nil;
    }

    isOpen = false;
}

- (CameraError)captureFrame:(CameraImage*)outImage {
    if (!isOpen) {
        return CAMERA_ERROR_NOT_OPEN;
    }

    hasNewFrame = false;

    // Wait for a new frame (with timeout of 5 seconds)
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(frameSemaphore, timeout) != 0) {
        return CAMERA_ERROR_CAPTURE;
    }

    if (!hasNewFrame || !imageData) {
        return CAMERA_ERROR_CAPTURE;
    }

    outImage->data = imageData;
    outImage->width = imageWidth;
    outImage->height = imageHeight;
    outImage->bytes_per_row = imageBytesPerRow;

    return CAMERA_OK;
}

- (bool)isSessionOpen {
    return isOpen;
}

// AVCaptureVideoDataOutputSampleBufferDelegate method
- (void)captureOutput:(AVCaptureOutput*)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        return;
    }

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    // Get Y plane (grayscale) from YUV format
    uint8_t* baseAddress = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    size_t width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0);
    size_t height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
    size_t dataSize = bytesPerRow * height;

    // Allocate or reallocate buffer if needed
    if (!imageData || imageWidth != width || imageHeight != height) {
        if (imageData) {
            free(imageData);
        }
        imageData = (uint8_t*)malloc(dataSize);
        imageWidth = (uint32_t)width;
        imageHeight = (uint32_t)height;
        imageBytesPerRow = (uint32_t)bytesPerRow;
    }

    if (imageData) {
        memcpy(imageData, baseAddress, dataSize);
        hasNewFrame = true;
        dispatch_semaphore_signal(frameSemaphore);
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

@end

// C API implementation

CameraHandle camera_create(void) {
    @autoreleasepool {
        CameraCapture* camera = [[CameraCapture alloc] init];
        return (__bridge_retained void*)camera;
    }
}

void camera_destroy(CameraHandle handle) {
    if (!handle) {
        return;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge_transfer CameraCapture*)handle;
        camera = nil;
    }
}

CameraError camera_open(CameraHandle handle) {
    if (!handle) {
        return CAMERA_ERROR_INIT;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        return [camera open];
    }
}

void camera_close(CameraHandle handle) {
    if (!handle) {
        return;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        [camera close];
    }
}

CameraError camera_capture_frame(CameraHandle handle, CameraImage* out_image) {
    if (!handle || !out_image) {
        return CAMERA_ERROR_INIT;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        return [camera captureFrame:out_image];
    }
}

bool camera_is_open(CameraHandle handle) {
    if (!handle) {
        return false;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        return [camera isSessionOpen];
    }
}
