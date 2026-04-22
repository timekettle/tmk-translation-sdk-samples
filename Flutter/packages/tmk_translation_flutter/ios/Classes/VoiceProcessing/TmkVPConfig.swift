//
//  TmkVPConfig.swift
//  TmkTranslationSDKDemo
//
//  VoiceProcessingIO 配置
//  说明：该配置用于音频单元的输入/输出格式设置
//

import Foundation
import AudioToolbox

struct TmkVPConfig {
    // 采样率
    var sampleRate: Double = 16_000
    // 声道数
    var channels: UInt32 = 1
    // 位深
    var bitsPerChannel: UInt32 = 16
    // 每次回调的帧数
    var framesPerBuffer: UInt32 = 1024
    // 单帧字节数
    var bytesPerFrame: UInt32 {
        return (bitsPerChannel / 8) * channels
    }

    // 生成 PCM AudioStreamBasicDescription
    var streamDescription: AudioStreamBasicDescription {
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
    }
}
