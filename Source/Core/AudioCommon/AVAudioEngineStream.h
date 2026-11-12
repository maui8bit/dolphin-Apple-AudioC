// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <memory>
#include "AudioCommon/SoundStream.h"

class AVAudioEngineStream : public SoundStream
{
public:
  AVAudioEngineStream();
  ~AVAudioEngineStream() override;

  bool Init() override;
  bool SetRunning(bool running) override;
  void SetVolume(int volume) override;

  static bool IsValid();

private:
  void* m_impl = nullptr; // Objective-C++ bridge pointer
};