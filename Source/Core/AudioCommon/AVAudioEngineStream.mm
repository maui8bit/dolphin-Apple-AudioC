// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "AudioCommon/AVAudioEngineStream.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudioTypes.h>

#include "AudioCommon/Mixer.h"
#include "Common/Logging/Log.h"

@interface AVAudioEngineBridge : NSObject
{
    AVAudioEngine* _engine;
    AVAudioSourceNode* _sourceNode;
    Mixer* _mixer;
    std::vector<float> _sampleBuffer;
}
- (instancetype)initWithMixer:(Mixer*)mixer;
- (BOOL)start;
- (void)stop;
--(void)setVolume:(float)volume;
@end

@implementation AVAudioEngineBridge
- (instancetype)initWithMixer:(Mixer*)mixer
{
    if ((self = [super init])) {
        _mixer = mixer;
        _engine = [[AVAudioEngine alloc] init];
        
        // Define 5.1 channel layout to trigger macOS spatial audio HRTF binaural rendering
        AudioChannelLayout channelLayout = {};
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A;
        
        AVAudioChannelLayout* avChannelLayout = [[AVAudioChannelLayout alloc] initWithLayout:&channelLayout];
        AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0
                                                                           channelLayout:avChannelLayout];
        
        // Create the source node that pulls samples from Dolphin's mixer
        __weak AVAudioEngineBridge* weakSelf = self;
        _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format
                                                    renderBlock:^OSStatus(BOOL *isSilence,
                                                                          const AudioTimeStamp *timestamp,
                                                                          AVAudioFrameCount frameCount,
                                                                          AudioBufferList *outputData) {
            AVAudioEngineBridge* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_mixer) {
                *isSilence = YES;
                return noErr;
            }
            
            // Ensure our internal buffer can hold the requested frames for 6 channels (5.1)
            size_t totalSamples = frameCount * 6;
            if (strongSelf->_sampleBuffer.size() < totalSamples) {
                strongSelf->_sampleBuffer.resize(totalSamples);
            }
            
            // Mix audio from Dolphin (interleaved floats or shorts depending on mixer configuration)
            unsigned int mixedSamples = strongSelf->_mixer->Mix(
                reinterpret_cast<short*>(strongSelf->_sampleBuffer.data()), 
                static_cast<unsigned int>(frameCount)
            );
            
            if (mixedSamples == 0) {
                *isSilence = YES;
                return noErr;
            }
            
            // De-interleave and map to the 5.1 channel buffers expected by CoreAudio
            float* const* bufs = (float* const*)outputData->mBuffers;
            // CoreAudio 5.1 layout order: L, R, C, LFE, Ls, Rs
            for (AVAudioFrameCount frame = 0; frame < frameCount; ++frame) {
                for (int ch = 0; ch < 6; ++ch) {
                    if (outputData->mNumberBuffers >= (UInt32)(ch + 1)) {
                        float* channelData = (float*)outputData->mBuffers[ch].mData;
                        if (channelData) {
                            channelData[frame] = strongSelf->_sampleBuffer[frame * 6 + ch];
                        }
                    }
                }
            }
            
            *isSilence = NO;
            return noErr;
        }];
        
        [_engine attachNode:_sourceNode];
        [_engine connect:_sourceNode to:_engine.mainMixerNode format:format];
    }
    return self;
}

- (BOOL)start
{
    NSError* error = nil;
    [_engine startAndReturnError:&error];
    if (error) {
        ERROR_LOG_FMT(AUDIO, "AVAudioEngine failed to start: %s", [[error localizedDescription] UTF8String]);
        return NO;
    }
    return YES;
}

- (void)stop
{
    [_engine stop];
}

- (void)setVolume:(float)volume
{
    [_engine.mainMixerNode setOutputVolume:volume];
}
@end

// --- AVAudioEngineStream C++ Wrapper Implementation ---

AVAudioEngineStream::AVAudioEngineStream() = default;

AVAudioEngineStream::~AVAudioEngineStream()
{
  Shutdown();
}

bool AVAudioEngineStream::IsValid()
{
  // Strictly restricted to macOS / Apple Silicon runtime environments
#if defined(__APPLE__)
  return true;
#else
  return false;
#endif
}

bool AVAudioEngineStream::Init()
{
  @autoreleasepool {
    AVAudioEngineBridge* bridge = [[AVAudioEngineBridge alloc] initWithMixer:m_mixer];
    m_impl = (__bridge_retained void*)bridge;
  }
  return m_impl != nullptr;
}

bool AVAudioEngineStream::SetRunning(bool running)
{
  if (!m_impl)
    return false;

  @autoreleasepool {
    AVAudioEngineBridge* bridge = (__bridge AVAudioEngineBridge*)m_impl;
    if (running) {
      return [bridge start] == YES;
    } else {
      [bridge stop];
      return true;
    }
  }
}

void AVAudioEngineStream::SetVolume(int volume)
{
  if (!m_impl)
    return;

  @autoreleasepool {
    AVAudioEngineBridge* bridge = (__bridge AVAudioEngineBridge*)m_impl;
    float normVolume = static_cast<float>(volume) / 100.0f;
    [bridge setVolume:normVolume];
  }
}