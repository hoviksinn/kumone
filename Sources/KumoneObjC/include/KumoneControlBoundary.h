#import <AVFoundation/AVFoundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Commands are published only by the existing serial engine control queue.
/// The recent-running gate budget is in the negotiated FINAL output frames.
typedef NS_ENUM(uint32_t, KumoneControlBoundaryCommand) {
    KumoneControlBoundaryCommandPause = 1,
    KumoneControlBoundaryCommandResume = 2,
    KumoneControlBoundaryCommandStart = 3,
};

typedef struct {
    BOOL available;
    BOOL prepared;
    double inputSampleRate;
    double outputSampleRate;
    uint32_t channelCount;
    uint32_t delayFrames;
    uint32_t envelopeFrames;
    double silenceDetectionFloor;
    BOOL rawCaptureOverflow;
    BOOL rawCaptureTimestampFault;
    uint64_t resourceGeneration;
    uint64_t modifiedOutputFrames;
    uint64_t silenceEntriesSmoothed;
    uint64_t silenceExitsSmoothed;
    uint64_t inputFrames;
    uint64_t outputFrames;
    uint64_t transportCommands;
    uint64_t hostResetRequests;
    uint64_t appliedHostResetRequests;
    uint32_t lastGateBudgetFrames;
    uint32_t componentFlags;
} KumoneControlBoundarySnapshot;

/// Process-local custom AU; no plugin installation or app identity change.
/// Returns nil with an explicit error if synchronous AVAudioUnit wrapping is
/// unsupported. Never wait on an asynchronous callback from the main thread.
FOUNDATION_EXPORT AVAudioUnitEffect *_Nullable
KumoneCreateControlBoundaryEffect(NSError *_Nullable *_Nullable error) NS_SWIFT_NOTHROW;

/// Requires prepared render resources; publish after engine start succeeds.
FOUNDATION_EXPORT BOOL
KumoneArmControlBoundary(AVAudioUnitEffect *effect, uint32_t command,
                         uint32_t gateBudgetFinalFrames);

/// Configure before render resources are allocated. This instrumentation is
/// off by default and never installed by the ordinary production player.
/// Samples plus timestamp/epoch storage are bounded to 64 MiB; allocation
/// rechecks the request against the final negotiated channel count.
FOUNDATION_EXPORT BOOL
KumonePrepareControlBoundaryRawCapture(AVAudioUnitEffect *effect,
                                      uint32_t capacityFrames,
                                      NSError *_Nullable *_Nullable error) NS_SWIFT_NOTHROW;

/// Raw is from the SAME actual processor FIFO BEFORE the envelope and has the
/// SAME fixed latency. Copy only between synchronous offline pulls or with
/// rendering quiesced and resources still allocated; deallocation/reset
/// invalidates old epochs. This is NOT a concurrent live tap API.
/// A missing/overwritten timestamp fails explicitly, never produces fake zero.
FOUNDATION_EXPORT AVAudioPCMBuffer *_Nullable
KumoneCopyControlBoundaryRawOutput(AVAudioUnitEffect *effect,
                                  int64_t startingAtSampleTime,
                                  uint32_t frameCount,
                                  NSError *_Nullable *_Nullable error) NS_SWIFT_NOTHROW;

/// Metadata/counters are atomically published outside the render kernel's
/// mutable fields. Safe for diagnostics while real-time audio is running.
FOUNDATION_EXPORT BOOL
KumoneReadControlBoundarySnapshot(AVAudioUnitEffect *effect,
                                 KumoneControlBoundarySnapshot *snapshot);

NS_ASSUME_NONNULL_END
