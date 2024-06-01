//
//  AppDelegate.swift
//  Azayaka
//
//  Created by Martin Persson on 2022-12-25.
//

import AVFoundation
import AVFAudio
import Cocoa
import KeyboardShortcuts
import ScreenCaptureKit
import UserNotifications
import SwiftUI

let recorder = ScreenRecorder()

@main
struct Azayaka: App {
    
    init() {
        Task {
            await recorder.startRecording()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: {
                Task {
                    await recorder.stopRecording()
                }
            })
        }
    }
    var body: some Scene {
        Settings {
            EmptyView().onAppear(perform: {

            })
        }
    }
}
