//
//  Engine.swift
//  eqMac
//
//  Created by Roman Kisil on 10/01/2018.
//  Copyright © 2018 Roman Kisil. All rights reserved.
//

import Cocoa
import AMCoreAudio
//import EventKit
import AVFoundation
import Foundation
import AudioToolbox
import EmitterKit
import Shared

class Engine {

  let engine: AVAudioEngine
  let sources: Sources
  let equalizers: Equalizers
  let format: AVAudioFormat
  // Expose the main output mixer from PerApplicationVolumeManager if it exists
  // This allows connecting eqMac's effects chain *after* per-app volumes.
  var perAppVolumeOutputMixer: AVAudioMixerNode? {
    return Application.perAppVolumeManager?.outputMixer
  }

  var lastSampleTime: Double = -1
  var buffer: CircularBuffer<Float>
  
  init () {
    Console.log("Creating Engine")
    engine = AVAudioEngine()
    sources = Sources()
    equalizers = Equalizers()

    // Sink audio into void - This might change if perAppVolumeOutputMixer is the true output
    // engine.mainMixerNode.outputVolume = 0
    // If per-app volume is active, the mainMixerNode might not be directly used for final output in the same way.
    // The PerApplicationVolumeManager.outputMixer will feed into the effects chain.

    // Setup Buffer
    let framesPerSample = Driver.device!.bufferFrameSize(direction: .playback)
    buffer = CircularBuffer<Float>(channelCount: 2, capacity: Int(framesPerSample) * 2048)

    // Attach Source
    engine.setInputDevice(sources.system.device)
    format = engine.inputNode.inputFormat(forBus: 0)
    Console.log("Set Input Engine format to: \(format.description)")

    // Attach Effects
    engine.attach(equalizers.active!.eq)

    // Chain
    // If PerApplicationVolumeManager is active and provides its outputMixer,
    // that mixer becomes the input to the equalizers.
    // Otherwise, the original engine.inputNode is used.

    if let perAppMixer = perAppVolumeOutputMixer {
        Console.log("Connecting PerAppVolumeManager output to Equalizers")
        // Ensure perAppMixer is attached to this engine instance
        // This should have been done in PerApplicationVolumeManager's init with this engine.
        // engine.attach(perAppMixer) // Already attached in PerApplicationVolumeManager
        
        // The format from perAppMixer to equalizer might need to be explicit
        // and should match what perAppMixer is outputting.
        let perAppOutputFormat = perAppMixer.outputFormat(forBus: 0)
        if perAppOutputFormat.sampleRate > 0 {
            engine.connect(perAppMixer, to: equalizers.active!.eq, format: perAppOutputFormat)
            Console.log("Connected perAppMixer to EQ with format: \(perAppOutputFormat)")
        } else {
            // Fallback or error
            Console.log("Warning: perAppMixer output format is invalid. Attempting with engine format.")
            engine.connect(perAppMixer, to: equalizers.active!.eq, format: format) 
        }
        
    } else {
        Console.log("Connecting System Input directly to Equalizers")
        engine.connect(engine.inputNode, to: equalizers.active!.eq, format: format)
    }
    engine.connect(equalizers.active!.eq, to: engine.mainMixerNode, format: format)
    // The mainMixerNode is now the final output of the processed audio (after EQ).
    // This mainMixerNode is what the Output class will tap from.
    // Ensure its volume is not 0 if it's the final stage before Output taps it.
    // Output class taps engine.mainMixerNode by default.
    engine.mainMixerNode.outputVolume = 1.0 // Ensure it passes audio through


    // Render callback
    let lastAVUnit = equalizers.active!.eq as AVAudioUnit
    if let err = checkErr(AudioUnitAddRenderNotify(lastAVUnit.audioUnit,
                                                   renderCallback,
                                                   nil)) {
      Console.log(err)
      return
    }

    // Start Engine
    engine.prepare()
    Console.log(engine)
    try! engine.start()
  }

  let renderCallback: AURenderCallback = {
    (inRefCon: UnsafeMutableRawPointer,
     ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
     inTimeStamp:  UnsafePointer<AudioTimeStamp>,
     inBusNumber: UInt32,
     inNumberFrames: UInt32,
     ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in

    if ioActionFlags.pointee == AudioUnitRenderActionFlags.unitRenderAction_PostRender {
      if Application.engine == nil { return noErr }

      let sampleTime = inTimeStamp.pointee.mSampleTime

      let start = sampleTime.int64Value
      let end = start + Int64(inNumberFrames)
      if Application.engine?.buffer.write(from: ioData!, start: start, end: end) != .noError {
        return noErr
      }
      Application.engine?.lastSampleTime = sampleTime
    }

    return noErr
  }
  
  func stop () {
    self.engine.stop()
  }

  deinit {
  }
}
