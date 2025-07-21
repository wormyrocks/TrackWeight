//
//  WeighingViewModel.swift
//  TrackWeight
//

import OpenMultitouchSupport
import SwiftUI
import Combine

@MainActor
final class WeighingViewModel: ObservableObject {
    @Published var state: WeighingState = .welcome
    @Published var currentPressure: Float = 0.0
    @Published var maxPressure: Float = 0.0
    @Published var isListening = false
    @Published var fingerTimer: Float = 0.0 // 0.0 to 1.0 for animation
    
    private let manager = OMSManager.shared
    private var task: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var baselinePressure: Float = 0.0
    private var hasDetectedFinger = false
    private var hasDetectedItem = false
    private var finalWeight: Float = 0.0
    private let fingerHoldDuration: TimeInterval = 3.0
    private var pressureHistory: [Float] = []
    private let historySize = 10
    private let rateOfChangeThreshold: Float = 5
    
    func startWeighing() {
        state = .waitingForFinger
        hasDetectedFinger = false
        hasDetectedItem = false
        baselinePressure = 0.0
        currentPressure = 0.0
        maxPressure = 0.0
        finalWeight = 0.0
        fingerTimer = 0.0
        pressureHistory.removeAll()
        
        if manager.startListening() {
            isListening = true
        }
        
        task = Task { [weak self, manager] in
            for await touchData in manager.touchDataStream {
                await MainActor.run {
                    self?.processTouchData(touchData)
                }
            }
        }
    }
    
    func restart() {
        stopListening()
        state = .welcome
        fingerTimer = 0.0
    }
    
    private func stopListening() {
        task?.cancel()
        timerTask?.cancel()
        if manager.stopListening() {
            isListening = false
        }
    }
    
    private func startFingerTimer() {
        timerTask?.cancel()
        fingerTimer = 0.0
        
        timerTask = Task { [weak self] in
            let startTime = Date()
            
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / (self?.fingerHoldDuration ?? 3.0), 1.0)
                
                await MainActor.run {
                    self?.fingerTimer = Float(progress)
                }
                
                if progress >= 1.0 {
                    await MainActor.run {
                        self?.completeFingerTimer()
                    }
                    break
                }
                
                try? await Task.sleep(nanoseconds: 16_666_667) // ~60fps
            }
        }
    }
    
    private func resetFingerTimer() {
        timerTask?.cancel()
        fingerTimer = 0.0
    }
    
    private func completeFingerTimer() {
        hasDetectedFinger = true
        baselinePressure = currentPressure
        state = .waitingForItem
        timerTask?.cancel()
    }
    
    private func processTouchData(_ touchData: [OMSTouchData]) {
        guard !touchData.isEmpty else {
            // Reset timer if finger is lifted during waiting
            if state == .waitingForFinger && !hasDetectedFinger {
                resetFingerTimer()
            }
            
            if state == .weighing {
                if hasDetectedItem && finalWeight > 0 {
                    state = .result(weight: finalWeight)
                    stopListening()
                }
            }
            return
        }
        
        
        let mainTouch = touchData.first!
        currentPressure = mainTouch.pressure
        
        // Add current pressure to history
        pressureHistory.append(currentPressure)
        if pressureHistory.count > historySize {
            pressureHistory.removeFirst()
        }
        
        // log the average pressure (moving avg)
        let avgPressure = pressureHistory.reduce(0, +) / Float(pressureHistory.count)
        print("average pressure: \(avgPressure)")
        currentPressure = avgPressure
        
        
        switch state {
        case .waitingForFinger:
            if !hasDetectedFinger {
                currentPressure = mainTouch.pressure
                if fingerTimer == 0.0 {
                    startFingerTimer()
                }
            }
            
        case .waitingForItem:
            if hasDetectedFinger {
                
                // Calculate rate of change if we have enough history
                if pressureHistory.count == historySize && !hasDetectedItem {
                    let rateOfChange = pressureHistory.last! - pressureHistory.first!
                    if rateOfChange > rateOfChangeThreshold {
                        print("pressure before item: \(pressureHistory)")
                        print("Old baseline: \(baselinePressure)")
                        baselinePressure = pressureHistory.first!
                        print("New baseline: \(baselinePressure)")
                        hasDetectedItem = true
                        state = .weighing
                    }
                }
            } else {
                state = .waitingForFinger
                pressureHistory.removeAll()
            }
            
        case .weighing:
            if mainTouch.state == .touching {
//                print(mainTouch.pressure - baselinePressure)
                finalWeight = mainTouch.pressure
                maxPressure = max(maxPressure, mainTouch.pressure)
            } else if mainTouch.state == .breaking {
                // Use the last stored touching pressure value
                let diffPressure = maxPressure - baselinePressure
                print("Max presh method: \(diffPressure)")
                print("Finger release method: \(finalWeight)")
                let combinedFinalWeight = (diffPressure + finalWeight) / 2
                // We take the average between the max pressure method and the finger release method
                state = .result(weight: finalWeight)
                stopListening()
            }
            
        default:
            break
        }
    }
    
    deinit {
        task?.cancel()
        timerTask?.cancel()
        manager.stopListening()
    }
}
