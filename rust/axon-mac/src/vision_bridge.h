#pragma once
#include <stddef.h>

typedef struct {
    char *text;
    double x;
    double y;
    double width;
    double height;
    double confidence;
} AxonVisionItem;

typedef struct {
    AxonVisionItem *items;
    size_t count;
    char *error;
} AxonVisionResult;

AxonVisionResult axon_vision_recognize(void *cg_image);
void axon_vision_result_destroy(AxonVisionResult result);