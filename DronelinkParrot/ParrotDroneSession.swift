//
//  ParrotDroneSession.swift
//  DronelinkParrot
//
//  Created by Jim McAndrew on 11/20/19.
//  Copyright © 2019 Dronelink. All rights reserved.
//
import Foundation
import os
import DronelinkCore
import GroundSdk
import CoreLocation

public class ParrotDroneSession: NSObject {
    internal let log = OSLog(subsystem: "DronelinkParrot", category: "ParrotDroneSession")
    
    public let telemetryProvider: ParrotTelemetryProvider
    public let adapter: ParrotDroneAdapter
    
    private let _opened = Date()
    private var _closed = false
    private var _id = UUID().uuidString
    private var _initialized = false
    private var _located = false
    private var _lastKnownGroundLocation: CLLocation?
    
    private let delegates = MulticastDelegate<DroneSessionDelegate>()
    private let droneCommands = CommandQueue()
    private let cameraCommands = MultiChannelCommandQueue()
    private let gimbalCommands = MultiChannelCommandQueue()
    
    private var flyingIndicatorsRef: Ref<FlyingIndicators>?
    private var alarmsRef: Ref<Alarms>?
    private var gpsRef: Ref<Gps>?
    private var radioRef: Ref<Radio>?
    private var pilotingStateRef: Ref<ManualCopterPilotingItf>?
    private var batteryInfoRef: Ref<BatteryInfo>?
    
    private var _flyingIndicators: DatedValue<FlyingIndicators>?
    private var _alarms: DatedValue<Alarms>?
    private var _gps: DatedValue<Gps>?
    private var _radio: DatedValue<Radio>?
    private var _batteryInfo: DatedValue<BatteryInfo>?
    
    public var flyingIndicators: DatedValue<FlyingIndicators>? { _flyingIndicators }
    public var batteryInfo: DatedValue<BatteryInfo>? { _batteryInfo }
    
    public init(drone: Drone, remoteControl: RemoteControl?, telemetryProvider: ParrotTelemetryProvider) {
        self.telemetryProvider = telemetryProvider
        adapter = ParrotDroneAdapter(drone: drone, remoteControl: remoteControl, telemetryProvider: telemetryProvider)
        super.init()
        initDrone()
        Thread.detachNewThread(self.execute)
    }
    
    private func initDrone() {
        os_log(.info, log: log, "Drone session opened")
        
        flyingIndicatorsRef = adapter.drone.getInstrument(Instruments.flyingIndicators) { value in
            guard let value = value else { return }
            let motorsOnPrevious = self._flyingIndicators?.value.areMotorsOn ?? false
            self._flyingIndicators = DatedValue<FlyingIndicators>(value: value)
            if (motorsOnPrevious != value.areMotorsOn) {
                DispatchQueue.global().async {
                    self.delegates.invoke { $0.onMotorsChanged(session: self, value: value.areMotorsOn) }
                }
            }
        }
        
        alarmsRef = adapter.drone.getInstrument(Instruments.alarms) { value in
            guard let value = value else { return }
            self._alarms = DatedValue<Alarms>(value: value)
        }
        
        gpsRef = adapter.drone.getInstrument(Instruments.gps) { value in
            guard let value = value else { return }
            self._gps = DatedValue<Gps>(value: value)
        }
        
        radioRef = adapter.drone.getInstrument(Instruments.radio) { value in
            guard let value = value else { return }
            self._radio = DatedValue<Radio>(value: value)
        }
        
        batteryInfoRef = adapter.drone.getInstrument(Instruments.batteryInfo) { value in
            guard let value = value else { return }
            self._batteryInfo = DatedValue<BatteryInfo>(value: value)
        }
        
        _initialized = true
        delegates.invoke { $0.onInitialized(session: self) }
    }
    
    
    private func execute() {
        while !_closed {
            if let location = telemetryProvider.telemetry?.value.location {
                if (!_located) {
                    _located = true
                    DispatchQueue.global().async {
                        self.delegates.invoke { $0.onLocated(session: self) }
                    }
                }

                if !isFlying {
                    _lastKnownGroundLocation = location
                }
            }
            
            droneCommands.process()
            cameraCommands.process()
            gimbalCommands.process()
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        flyingIndicatorsRef = nil
        gpsRef = nil
        radioRef = nil
        batteryInfoRef = nil
        
        os_log(.info, log: log, "Drone session closed")
    }
    
    internal func sendResetVelocityCommand() {
        adapter.sendResetVelocityCommand()
    }
    
    internal func sendResetGimbalCommands() {
        adapter.gimbals?.forEach {
            if let adapter = $0 as? ParrotGimbalAdapter {
                adapter.gimbal.control(mode: .position, yaw: 0, pitch:  -12, roll: 0)
            }
        }
    }
    
    internal func sendResetCameraCommands() {
        adapter.cameras?.forEach {
            if let adapter = $0 as? ParrotCameraAdapter {
                if adapter.camera.canStopPhotoCapture {
                    adapter.camera.stopPhotoCapture()
                }
                else if adapter.camera.canStopRecord {
                    adapter.camera.stopRecording()
                }
            }
        }
    }
    
    public var status: Mission.Message {
        guard let state = state?.value, let _ = telemetryProvider.telemetry?.value else {
            return Mission.Message(title: "ParrotDroneSession.telemetry.unavailable".localized, level: .danger)
        }
        
        if state.location == nil {
            return Mission.Message(title: "ParrotDroneSession.location.unavailable".localized, level: .warning)
        }
        
        if let alarms = _alarms?.value {
            for kind in Alarm.Kind.allCases {
                let alarm = alarms.getAlarm(kind: kind)
                switch alarm.level {
                case .notAvailable, .off:
                    break
                    
                case .warning:
                    return Mission.Message(title: alarm.description, level: .warning)
                    
                case .critical:
                    return Mission.Message(title: alarm.description, level: .danger)
                }
            }
        }
        
        return Mission.Message(title: "ParrotDroneSession.ready".localized, level: .info)
    }
}

extension ParrotDroneSession: DroneSession {
    public var drone: DroneAdapter { adapter }
    public var state: DatedValue<DroneStateAdapter>? { DatedValue(value: self, date: telemetryProvider.telemetry?.date ?? Date()) }
    public var opened: Date { _opened }
    public var id: String { _id }
    public var manufacturer: String { "Parrot" }
    public var serialNumber: String? { adapter.drone.uid }
    public var name: String? { adapter.drone.name }
    public var model: String? { adapter.drone.model.description }
    public var firmwarePackageVersion: String? { nil }
    public var initialized: Bool { _initialized }
    public var located: Bool { _located }
    public var telemetryDelayed: Bool { -(telemetryProvider.telemetry?.date.timeIntervalSinceNow ?? 0) > 10.0 }
    public var disengageReason: Mission.Message? {
        if adapter.flightController == nil {
            return Mission.Message(title: "MissionDisengageReason.drone.control.unavailable.title".localized)
        }
        
        if telemetryProvider.telemetry == nil {
            return Mission.Message(title: "MissionDisengageReason.telemetry.unavailable.title".localized)
        }
        
        if telemetryDelayed {
            return Mission.Message(title: "MissionDisengageReason.telemetry.delayed.title".localized)
        }
        
        return nil
    }
    
    public func identify(id: String) { _id = id }
    
    public func add(delegate: DroneSessionDelegate) {
        delegates.add(delegate)
        
        if _initialized {
            delegate.onInitialized(session: self)
        }
        
        if _located {
            delegate.onLocated(session: self)
        }
    }
    
    public func remove(delegate: DroneSessionDelegate) {
        delegates.remove(delegate)
    }
    
    public func add(command: MissionCommand) throws {
        if let command = command as? MissionDroneCommand {
            droneCommands.add(command: Command(
                id: command.id,
                name: command.type.rawValue,
                execute: { finished in
                    self.commandExecuted(command: command)
                    return self.execute(droneCommand: command, finished: finished)
                },
                finished: { error in
                    self.commandFinished(command: command, error: error)
                },
                config: command.config
            ))
            return
        }

        if let command = command as? MissionCameraCommand {
            cameraCommands.add(channel: command.channel, command: Command(
                id: command.id,
                name: command.type.rawValue,
                execute: {
                    self.commandExecuted(command: command)
                    return self.execute(cameraCommand: command, finished: $0)
                },
                finished: { error in
                    self.commandFinished(command: command, error: error)
                },
                config: command.config
            ))
            return
        }

        if let command = command as? MissionGimbalCommand {
            gimbalCommands.add(channel: command.channel, command: Command(
                id: command.id,
                name: command.type.rawValue,
                execute: {
                    self.commandExecuted(command: command)
                    return self.execute(gimbalCommand: command, finished: $0)
                },
                finished: { error in
                    self.commandFinished(command: command, error: error)
                },
                config: command.config
            ))
            return
        }
        
        throw DroneSessionError.commandTypeUnhandled
    }
    
    private func commandExecuted(command: MissionCommand) {
        self.delegates.invoke { $0.onCommandExecuted(session: self, command: command) }
    }
    
    private func commandFinished(command: MissionCommand, error: Error?) {
        self.delegates.invoke { $0.onCommandFinished(session: self, command: command, error: error) }
    }
    
    public func removeCommands() {
        droneCommands.removeAll()
        cameraCommands.removeAll()
        gimbalCommands.removeAll()
    }
    
    public func createControlSession() -> DroneControlSession { ParrotControlSession(droneSession: self) }
    
    public func cameraState(channel: UInt) -> DatedValue<CameraStateAdapter>? {
        guard let camera = adapter.camera(channel: channel) as? ParrotCameraAdapter else { return nil }
        return DatedValue<CameraStateAdapter>(value: camera)
    }
    
    public func gimbalState(channel: UInt) -> DatedValue<GimbalStateAdapter>? {
        guard let gimbal = adapter.gimbal(channel: channel) as? ParrotGimbalAdapter else { return nil }
        return DatedValue<GimbalStateAdapter>(value: gimbal)
    }
    
    public func remoteControllerState(channel: UInt) -> DatedValue<RemoteControllerStateAdapter>? {
        //FIXME
        return nil
    }
    
    public func resetPayloads() {
        sendResetGimbalCommands()
        sendResetCameraCommands()
    }
    
    public func close() {
        _closed = true
    }
}

extension ParrotDroneSession: DroneStateAdapter {
    public var isFlying: Bool { _flyingIndicators?.value.isFlying ?? false }
    public var location: CLLocation? {
        let instrumentLocation = _gps?.value.fixed ?? false ? _gps?.value.lastKnownLocation : nil
        if let location = telemetryProvider.telemetry?.value.location {
            if location.coordinate.latitude.isNaN || location.coordinate.longitude.isNaN || (location.coordinate.latitude == 0 && location.coordinate.longitude == 0) {
                return instrumentLocation
            }
            return location
        }
        return instrumentLocation
    }
    public var homeLocation: CLLocation? { adapter.returnHomeController?.homeLocation }
    public var lastKnownGroundLocation: CLLocation? { _lastKnownGroundLocation }
    public var takeoffLocation: CLLocation? { isFlying ? (lastKnownGroundLocation ?? homeLocation) : location }
    public var takeoffAltitude: Double? { telemetryProvider.telemetry?.value.takeoffAltitude }
    public var course: Double {
        guard let telemetry = telemetryProvider.telemetry?.value else {
            return 0
        }
        return atan2(telemetry.speedNorth, telemetry.speedEast)
    }
    public var horizontalSpeed: Double {
        guard let telemetry = telemetryProvider.telemetry?.value else {
            return 0
        }
        return sqrt(pow(telemetry.speedNorth, 2) + pow(telemetry.speedEast, 2))
    }
    public var verticalSpeed: Double {
        guard let telemetry = telemetryProvider.telemetry?.value else {
            return 0
        }
        return telemetry.speedDown == 0 ? 0 : -telemetry.speedDown
    }
    public var altitude: Double {
        if let altitude = telemetryProvider.telemetry?.value.altitude, !altitude.isNaN {
            return altitude
        }
        return 0
    }
    public var batteryPercent: Double? {
        if let batteryLevel = batteryInfo?.value.batteryLevel {
            return Double(batteryLevel) / 100
        }
        return nil
    }
    public var obstacleDistance: Double? { return nil }
    public var missionOrientation: Mission.Orientation3 { telemetryProvider.telemetry?.value.droneMissionOrientation ?? Mission.Orientation3() }
    public var gpsSatellites: Int? { _gps?.value.satelliteCount }
    public var signalStrength: Double? {
        guard let rssi = _radio?.value.rssi, rssi != 0 else {
            return nil
        }
        
        return min(1.0, max(0.0, 1.0 - ((Double(min(-30, max(-80, rssi))) + 30.0) / -50.0)))
    }
}
