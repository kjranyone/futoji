#import "GeneratedPluginRegistrant.h"

// PaperNet 用 ONNX Runtime C API (Podfile の onnxruntime-c)
#if __has_include(<onnxruntime/onnxruntime_c_api.h>)
#import <onnxruntime/onnxruntime_c_api.h>
#else
#import "onnxruntime_c_api.h"
#endif
