#import "vision_bridge.h"
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#include <stdlib.h>
#include <string.h>

static char *axon_copy_string(NSString *value) {
    const char *utf8 = value.UTF8String;
    return utf8 ? strdup(utf8) : NULL;
}

AxonVisionResult axon_vision_recognize(void *raw_image) {
    AxonVisionResult result = {0};
    @autoreleasepool {
        @try {
            if (raw_image == NULL) {
                result.error = strdup("Vision received a null CGImage");
                return result;
            }
            VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = YES;
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCGImage:(CGImageRef)raw_image options:@{}];
            NSError *error = nil;
            if (![handler performRequests:@[request] error:&error]) {
                result.error = axon_copy_string(error.localizedDescription ?: @"Vision request failed");
                return result;
            }
            NSArray<VNRecognizedTextObservation *> *observations = request.results ?: @[];
            result.count = observations.count;
            result.items = calloc(result.count, sizeof(AxonVisionItem));
            if (result.count != 0 && result.items == NULL) {
                result.count = 0;
                result.error = strdup("could not allocate Vision results");
                return result;
            }
            size_t output = 0;
            for (VNRecognizedTextObservation *observation in observations) {
                VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
                if (candidate == nil || candidate.string.length == 0) continue;
                CGRect box = observation.boundingBox;
                result.items[output++] = (AxonVisionItem) {
                    .text = axon_copy_string(candidate.string),
                    .x = box.origin.x,
                    .y = box.origin.y,
                    .width = box.size.width,
                    .height = box.size.height,
                    .confidence = candidate.confidence,
                };
            }
            result.count = output;
        } @catch (NSException *exception) {
            axon_vision_result_destroy(result);
            result = (AxonVisionResult){0};
            result.error = axon_copy_string(exception.reason ?: exception.name);
        }
    }
    return result;
}

void axon_vision_result_destroy(AxonVisionResult result) {
    for (size_t index = 0; index < result.count; index++) free(result.items[index].text);
    free(result.items);
    free(result.error);
}