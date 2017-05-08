//
//  DeviceDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CarbKit
import CoreData
import GlucoseKit
import HealthKit
import InsulinKit
import LoopKit
import LoopUI
import MinimedKit
import NightscoutUploadKit
import RileyLinkKit


final class DeviceDataManager: CarbStoreDelegate, DoseStoreDelegate {

    // MARK: - Utilities

    let logger = DiagnosticLogger()

    /// Remember the launch date of the app for diagnostic reporting
    fileprivate let launchDate = Date()

    /// Manages all the RileyLinks
    let rileyLinkManager: RileyLinkDeviceManager

    /// Manages authentication for remote services
    let remoteDataManager = RemoteDataManager()

    private var nightscoutDataManager: NightscoutDataManager!

    var latestPumpStatus: RileyLinkKit.PumpStatus?

    // Returns a value in the range 0 - 1
    var pumpBatteryChargeRemaining: Double? {
        get {
            if let status = latestPumpStatusFromMySentry {
                return Double(status.batteryRemainingPercent) / 100
            } else if let status = latestPumpStatus {
                return batteryChemistry.chargeRemaining(voltage: status.batteryVolts)
            } else {
                return statusExtensionManager.context?.batteryPercentage
            }
        }
    }

    // Battery monitor
    func observeBatteryDuring(_ block: () -> Void) {
        let oldVal = pumpBatteryChargeRemaining
        block()
        if let newVal = pumpBatteryChargeRemaining {
            if newVal == 0 {
                NotificationManager.sendPumpBatteryLowNotification()
            }

            if let oldVal = oldVal, newVal - oldVal >= 0.5 {
                AnalyticsManager.sharedManager.pumpBatteryWasReplaced()
            }
        }
    }

    // MARK: - RileyLink

    @objc private func receivedRileyLinkManagerNotification(_ note: Notification) {
        NotificationCenter.default.post(name: note.name, object: self, userInfo: note.userInfo)
    }

    /**
     Called when a new idle message is received by the RileyLink.

     Only MySentryPumpStatus messages are handled.

     - parameter note: The notification object
     */
    @objc private func receivedRileyLinkPacketNotification(_ note: Notification) {
        if let
            device = note.object as? RileyLinkDevice,
            let data = note.userInfo?[RileyLinkDevice.IdleMessageDataKey] as? Data,
            let message = PumpMessage(rxData: data)
        {
            switch message.packetType {
            case .mySentry:
                switch message.messageBody {
                case let body as MySentryPumpStatusMessageBody:
                    updatePumpStatus(body, from: device)
                case is MySentryAlertMessageBody, is MySentryAlertClearedMessageBody:
                    break
                case let body:
                    logger.addMessage(["messageType": Int(message.messageType.rawValue), "messageBody": body.txData.hexadecimalString], toCollection: "sentryOther")
                }
            default:
                break
            }
        }
    }

    @objc private func receivedRileyLinkTimerTickNotification(_: Notification) {
        cgmManager?.fetchNewDataIfNeeded(with: self) { (result) in
            self.cgmManager(self.cgmManager!, didUpdateWith: result)
        }
    }

    func connectToRileyLink(_ device: RileyLinkDevice) {
        connectedPeripheralIDs.insert(device.peripheral.identifier.uuidString)

        rileyLinkManager.connectDevice(device)

        AnalyticsManager.sharedManager.didChangeRileyLinkConnectionState()
    }

    func disconnectFromRileyLink(_ device: RileyLinkDevice) {
        connectedPeripheralIDs.remove(device.peripheral.identifier.uuidString)

        rileyLinkManager.disconnectDevice(device)

        AnalyticsManager.sharedManager.didChangeRileyLinkConnectionState()

        if connectedPeripheralIDs.count == 0 {
            NotificationManager.clearPendingNotificationRequests()
        }
    }

    // MARK: Pump data

    var latestPumpStatusFromMySentry: MySentryPumpStatusMessageBody?

    /**
     Handles receiving a MySentry status message, which are only posted by MM x23 pumps.

     This message has two important pieces of info about the pump: reservoir volume and battery.

     Because the RileyLink must actively listen for these packets, they are not a reliable heartbeat. However, we can still use them to assert glucose data is current.

     - parameter status: The status message body
     - parameter device: The RileyLink that received the message
     */
    private func updatePumpStatus(_ status: MySentryPumpStatusMessageBody, from device: RileyLinkDevice) {
        var pumpDateComponents = status.pumpDateComponents
        var glucoseDateComponents = status.glucoseDateComponents

        pumpDateComponents.timeZone = pumpState?.timeZone
        glucoseDateComponents?.timeZone = pumpState?.timeZone

        // The pump sends the same message 3x, so ignore it if we've already seen it.
        guard status != latestPumpStatusFromMySentry, let pumpDate = pumpDateComponents.date else {
            return
        }

        observeBatteryDuring {
            latestPumpStatusFromMySentry = status
        }

        // Gather PumpStatus from MySentry packet
        let pumpStatus: NightscoutUploadKit.PumpStatus?
        if let pumpDate = pumpDateComponents.date, let pumpID = pumpID {

            let batteryStatus = BatteryStatus(percent: status.batteryRemainingPercent)
            let iobStatus = IOBStatus(timestamp: pumpDate, iob: status.iob)

            pumpStatus = NightscoutUploadKit.PumpStatus(clock: pumpDate, pumpID: pumpID, iob: iobStatus, battery: batteryStatus, reservoir: status.reservoirRemainingUnits)
        } else {
            pumpStatus = nil
            self.logger.addError("Could not interpret pump clock: \(pumpDateComponents)", fromSource: "RileyLink")
        }

        // Trigger device status upload, even if something is wrong with pumpStatus
        nightscoutDataManager.uploadDeviceStatus(pumpStatus, rileylinkDevice: device)

        switch status.glucose {
        case .active(glucose: let glucose):
            // Enlite data is included
            if let date = glucoseDateComponents?.date {
                glucoseStore?.addGlucose(
                    HKQuantity(unit: HKUnit.milligramsPerDeciliterUnit(), doubleValue: Double(glucose)),
                    date: date,
                    isDisplayOnly: false,
                    device: nil
                ) { (success, _, _) in
                    if success {
                        NotificationCenter.default.post(name: .GlucoseUpdated, object: self)
                    }
                }
            }
        case .off:
            // Enlite is disabled, so assert glucose from another source
            cgmManager?.fetchNewDataIfNeeded(with: self) { (result) in
                switch result {
                case .newData(let values):
                    self.glucoseStore?.addGlucoseValues(values, device: self.cgmManager?.device) { (success, _, _) in
                        if success {
                            NotificationCenter.default.post(name: .GlucoseUpdated, object: self)
                        }
                    }
                case .noData, .error:
                    break
                }
            }
        default:
            break
        }

        // Upload sensor glucose to Nightscout
        remoteDataManager.nightscoutService.uploader?.uploadSGVFromMySentryPumpStatus(status, device: device.deviceURI)

        // Sentry packets are sent in groups of 3, 5s apart. Wait 11s before allowing the loop data to continue to avoid conflicting comms.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(11)) {
            self.updateReservoirVolume(status.reservoirRemainingUnits, at: pumpDate, withTimeLeft: TimeInterval(minutes: Double(status.reservoirRemainingMinutes)))
        }
    }

    /**
     Store a new reservoir volume and notify observers of new pump data.

     - parameter units:    The number of units remaining
     - parameter date:     The date the reservoir was read
     - parameter timeLeft: The approximate time before the reservoir is empty
     */
    private func updateReservoirVolume(_ units: Double, at date: Date, withTimeLeft timeLeft: TimeInterval?) {
        doseStore.addReservoirValue(units, atDate: date) { (newValue, previousValue, areStoredValuesContinuous, error) -> Void in
            if let error = error {
                self.logger.addError(error, fromSource: "DoseStore")
                return
            }

            if self.preferredInsulinDataSource == .pumpHistory || !areStoredValuesContinuous {
                self.fetchPumpHistory { (error) in
                    // Notify and trigger a loop as long as we have fresh, reliable pump data.
                    if error == nil || areStoredValuesContinuous {
                        NotificationCenter.default.post(name: .PumpStatusUpdated, object: self)
                    }
                }
            } else {
                NotificationCenter.default.post(name: .PumpStatusUpdated, object: self)
            }

            // Send notifications for low reservoir if necessary
            if let newVolume = newValue?.unitVolume, let previousVolume = previousValue?.unitVolume {
                guard newVolume > 0 else {
                    NotificationManager.sendPumpReservoirEmptyNotification()
                    return
                }

                let warningThresholds: [Double] = [10, 20, 30]

                for threshold in warningThresholds {
                    if newVolume <= threshold && previousVolume > threshold {
                        NotificationManager.sendPumpReservoirLowNotificationForAmount(newVolume, andTimeRemaining: timeLeft)
                    }
                }

                if newVolume > previousVolume + 1 {
                    AnalyticsManager.sharedManager.reservoirWasRewound()
                }
            }
        }
    }

    /**
     Polls the pump for new history events and stores them.
     
     - parameter completion: A closure called after the fetch is complete. This closure takes a single argument:
        - error: An error describing why the fetch and/or store failed
     */
    private func fetchPumpHistory(_ completionHandler: @escaping (_ error: Error?) -> Void) {
        guard let device = rileyLinkManager.firstConnectedDevice else {
            return
        }

        let startDate = doseStore.pumpEventQueryAfterDate

        device.ops?.getHistoryEvents(since: startDate) { (result) in
            switch result {
            case let .success(events, _):
                self.doseStore.add(events) { (error) in
                    if let error = error {
                        self.logger.addError("Failed to store history: \(error)", fromSource: "DoseStore")
                    }

                    completionHandler(error)
                }
            case .failure(let error):
                self.rileyLinkManager.deprioritizeDevice(device: device)
                self.logger.addError("Failed to fetch history: \(error)", fromSource: "RileyLink")

                completionHandler(error)
            }
        }
    }

    /**
     Read the pump's current state, including reservoir and clock

     - parameter completion: A closure called after the command is complete. This closure takes a single Result argument:
        - Success(status, date): The pump status, and the resolved date according to the pump's clock
        - Failure(error): An error describing why the command failed
     */
    private func readPumpData(_ completion: @escaping (RileyLinkKit.Either<(status: RileyLinkKit.PumpStatus, date: Date), Error>) -> Void) {
        guard let device = rileyLinkManager.firstConnectedDevice, let ops = device.ops else {
            completion(.failure(LoopError.connectionError))
            return
        }

        ops.readPumpStatus { (result) in
            switch result {
            case .success(let status):
                var clock = status.clock
                clock.timeZone = ops.pumpState.timeZone

                guard let date = clock.date else {
                    let errorStr = "Could not interpret pump clock: \(clock)"
                    self.logger.addError(errorStr, fromSource: "RileyLink")
                    completion(.failure(LoopError.invalidData(details: errorStr)))
                    return
                }
        let battery = BatteryStatus(voltage: status.batteryVolts, status: BatteryIndicator(batteryStatus: status.batteryStatus))
                
                if let sentrySupported = self.pumpState?.pumpModel?.larger , !sentrySupported {
                    self.setBatteryDataforNonMySentryPumps(voltage: status.batteryVolts)
                    }
                
                let nsPumpStatus = NightscoutUploadKit.PumpStatus(clock: date, pumpID: ops.pumpState.pumpID, iob: nil, battery: battery, suspended: status.suspended, bolusing: status.bolusing, reservoir: status.reservoir)
                self.nightscoutDataManager.uploadDeviceStatus(nsPumpStatus)
                completion(.success(status: status, date: date))
            case .failure(let error):
                self.logger.addError("Failed to fetch pump status: \(error)", fromSource: "RileyLink")
                completion(.failure(error))
            }
        }
    }
    
    /**
     jlucasvt
     x22 Battery Voltage, Lithium Decay Display, and Notifications.
     Code added here to store battery voltage, broacast battery percentage, and notify of battery status for x22 pumps.
     Broadcast Remaining Percentage is based on the pumps ability to continue to broadcast to RileyLink using a Lithium Battery.
     This is NOT the actual pump battery % status that is shown on pump.  The ability to broadcast stops hours before the pump battery
     staus shows battery low status.
     */
    
    // Local Variable to store Battery Broadcast Remaining Percentage.
    var x22BatteryBroadcastRemaining: Double = -1
    
    // Local Variable to store Battery Voltage Reading from Pump
    var batteryVoltage: Double = -1
    
    //x22 pump Lithium Ion Decay Schedule (Approximately 7 day's of 100% Loop Usage)
    private func setBatteryDataforNonMySentryPumps(voltage : Double){
        
        var percentage: Double
        
        if voltage >= 1.56{                             //100%
            percentage = 1
        }else if voltage < 1.56 && voltage >= 1.53{     //75%
            percentage = 0.75
        }else if voltage < 1.53 && voltage >= 1.50{     //50%
            percentage = 0.50
        }else if voltage < 1.50 && voltage >= 1.47{     //25%
            percentage = 0.25
        }else if voltage < 1.47{                        //0%
            percentage = 0
            NotificationManager.sendPumpBatteryLowNotification()
        }else{
            percentage = -1
        }
        
        self.batteryVoltage = voltage
        self.x22BatteryBroadcastRemaining = percentage
        
    }

    private func pumpDataIsStale() -> Bool {
        // How long should we wait before we poll for new pump data?
        let pumpStatusAgeTolerance = rileyLinkManager.idleListeningEnabled ? TimeInterval(minutes: 11) : TimeInterval(minutes: 4)

        return doseStore.lastReservoirValue == nil
            || doseStore.lastReservoirValue!.startDate.timeIntervalSinceNow <= -pumpStatusAgeTolerance
    }

    /**
     Ensures pump data is current by either waking and polling, or ensuring we're listening to sentry packets.
     */
    fileprivate func assertCurrentPumpData() {
        guard let device = rileyLinkManager.firstConnectedDevice, pumpDataIsStale() else {
            return
        }

        device.assertIdleListening()

        readPumpData { (result) in
            let nsPumpStatus: NightscoutUploadKit.PumpStatus?
            switch result {
            case .success(let (status, date)):
                self.observeBatteryDuring {
                    self.latestPumpStatus = status
                }

                self.updateReservoirVolume(status.reservoir, at: date, withTimeLeft: nil)
                let battery = BatteryStatus(voltage: status.batteryVolts, status: BatteryIndicator(batteryStatus: status.batteryStatus))


                nsPumpStatus = NightscoutUploadKit.PumpStatus(clock: date, pumpID: status.pumpID, iob: nil, battery: battery, suspended: status.suspended, bolusing: status.bolusing, reservoir: status.reservoir)
            case .failure(let error):
                self.troubleshootPumpComms(using: device)
                self.nightscoutDataManager.uploadLoopStatus(loopError: error)
                nsPumpStatus = nil
            }
            self.nightscoutDataManager.uploadDeviceStatus(nsPumpStatus, rileylinkDevice: device)
        }
    }

    /// Send a bolus command and handle the result
    ///
    /// - parameter units:      The number of units to deliver
    /// - parameter completion: A clsure called after the command is complete. This closure takes a single argument:
    ///     - error: An error describing why the command failed
    func enactBolus(units: Double, completion: @escaping (_ error: Error?) -> Void) {
        guard units > 0 else {
            completion(nil)
            return
        }

        guard let device = rileyLinkManager.firstConnectedDevice else {
            completion(LoopError.connectionError)
            return
        }

        guard let ops = device.ops else {
            completion(LoopError.configurationError("PumpOps"))
            return
        }

        let setBolus = {
            ops.setNormalBolus(units: units) { (error) in
                if let error = error {
                    self.logger.addError(error, fromSource: "Bolus")
                    completion(LoopError.communicationError)
                } else {
                    self.loopManager.recordBolus(units, at: Date())
                     completion(nil)
                }
            }
        }

        // If we don't have recent pump data, or the pump was recently rewound, read new pump data before bolusing.
        if  doseStore.lastReservoirValue == nil ||
            doseStore.lastReservoirVolumeDrop < 0 ||
            doseStore.lastReservoirValue!.startDate.timeIntervalSinceNow <= TimeInterval(minutes: -6)
        {
            readPumpData { (result) in
                switch result {
                case .success(let (status, date)):
                    self.doseStore.addReservoirValue(status.reservoir, atDate: date) { (newValue, _, _, error) in
                        if let error = error {
                            self.logger.addError(error, fromSource: "Bolus")
                            completion(error)
                        } else {
                            setBolus()
                        }
                    }
                case .failure(let error):
                    completion(error)
                }
            }
        } else {
            setBolus()
        }
    }

    /**
     Attempts to fix an extended communication failure between a RileyLink device and the pump

     - parameter device: The RileyLink device
     */
    private func troubleshootPumpComms(using device: RileyLinkDevice) {
        // How long we should wait before we re-tune the RileyLink
        let tuneTolerance = TimeInterval(minutes: 14)

        if device.lastTuned == nil || device.lastTuned!.timeIntervalSinceNow <= -tuneTolerance {
            device.tunePump { (result) in
                switch result {
                case .success(let scanResult):
                    self.logger.addError("Device \(device.name ?? "") auto-tuned to \(scanResult.bestFrequency) MHz", fromSource: "RileyLink")
                case .failure(let error):
                    self.logger.addError("Device \(device.name ?? "") auto-tune failed with error: \(error)", fromSource: "RileyLink")
                    self.rileyLinkManager.deprioritizeDevice(device: device)
                }
            }
        } else {
            rileyLinkManager.deprioritizeDevice(device: device)
        }
    }

    // MARK: - CGM

    var cgm: CGM? = UserDefaults.standard.cgm {
        didSet {
            if cgm != oldValue {
                setupCGM()
            }

            UserDefaults.standard.cgm = cgm
        }
    }

    private(set) var cgmManager: CGMManager?

    private func setupCGM() {
        cgmManager = cgm?.createManager()
        cgmManager?.delegate = self

        /// Controls the management of the RileyLink timer tick, which is a reliably-changing BLE
        /// characteristic which can cause the app to wake. For most users, the G5 Transmitter and
        /// G4 Receiver are reliable as hearbeats, but users who find their resources extremely constrained
        /// due to greedy apps or older devices may choose to always enable the timer by always setting `true`
        rileyLinkManager.timerTickEnabled = !(cgmManager?.providesBLEHeartbeat == true)
    }

    var sensorInfo: SensorDisplayable? {
        return cgmManager?.sensorState ?? latestPumpStatusFromMySentry
    }

    // MARK: - Configuration

    // MARK: Pump

    private var connectedPeripheralIDs: Set<String> = Set(UserDefaults.standard.connectedPeripheralIDs) {
        didSet {
            UserDefaults.standard.connectedPeripheralIDs = Array(connectedPeripheralIDs)
        }
    }

    var pumpID: String? {
        get {
            return pumpState?.pumpID
        }
        set {
            guard newValue != pumpState?.pumpID else {
                return
            }

            var pumpID = newValue

            if let pumpID = pumpID, pumpID.characters.count == 6 {
                let pumpState = PumpState(pumpID: pumpID, pumpRegion: self.pumpState?.pumpRegion ?? .northAmerica)

                if let timeZone = self.pumpState?.timeZone {
                    pumpState.timeZone = timeZone
                }

                self.pumpState = pumpState
            } else {
                pumpID = nil
                self.pumpState = nil
            }

            remoteDataManager.nightscoutService.uploader?.reset()
            doseStore.pumpID = pumpID

            UserDefaults.standard.pumpID = pumpID
        }
    }

    var pumpState: PumpState? {
        didSet {
            rileyLinkManager.pumpState = pumpState

            if let oldValue = oldValue {
                NotificationCenter.default.removeObserver(self, name: .PumpStateValuesDidChange, object: oldValue)
            }

            if let pumpState = pumpState {
                NotificationCenter.default.addObserver(self, selector: #selector(pumpStateValuesDidChange(_:)), name: .PumpStateValuesDidChange, object: pumpState)
            }
        }
    }

    @objc private func pumpStateValuesDidChange(_ note: Notification) {
        switch note.userInfo?[PumpState.PropertyKey] as? String {
        case "timeZone"?:
            UserDefaults.standard.pumpTimeZone = pumpState?.timeZone

            if let pumpTimeZone = pumpState?.timeZone {
                if let basalRateSchedule = basalRateSchedule {
                    self.basalRateSchedule = BasalRateSchedule(dailyItems: basalRateSchedule.items, timeZone: pumpTimeZone)
                }

                if let carbRatioSchedule = carbRatioSchedule {
                    self.carbRatioSchedule = CarbRatioSchedule(unit: carbRatioSchedule.unit, dailyItems: carbRatioSchedule.items, timeZone: pumpTimeZone)
                }

                if let insulinSensitivitySchedule = insulinSensitivitySchedule {
                    self.insulinSensitivitySchedule = InsulinSensitivitySchedule(unit: insulinSensitivitySchedule.unit, dailyItems: insulinSensitivitySchedule.items, timeZone: pumpTimeZone)
                }

                if let glucoseTargetRangeSchedule = glucoseTargetRangeSchedule {
                    self.glucoseTargetRangeSchedule = GlucoseRangeSchedule(unit: glucoseTargetRangeSchedule.unit, dailyItems: glucoseTargetRangeSchedule.items, workoutRange: glucoseTargetRangeSchedule.workoutRange, timeZone: pumpTimeZone)
                }
            }
        case "pumpModel"?:
            if let sentrySupported = pumpState?.pumpModel?.hasMySentry, !sentrySupported {
                rileyLinkManager.idleListeningEnabled = false
            }

            UserDefaults.standard.pumpModelNumber = pumpState?.pumpModel?.rawValue
        case "pumpRegion"?:
            UserDefaults.standard.pumpRegion = pumpState?.pumpRegion
        case "lastHistoryDump"?, "awakeUntil"?:
            break
        default:
            break
        }
    }

    /// The user's preferred method of fetching insulin data from the pump
    var preferredInsulinDataSource = UserDefaults.standard.preferredInsulinDataSource ?? .pumpHistory {
        didSet {
            UserDefaults.standard.preferredInsulinDataSource = preferredInsulinDataSource
        }
    }
    
    /// The pump battery chemistry, for voltage -> percentage calculation
    var batteryChemistry = UserDefaults.standard.batteryChemistry ?? .alkaline {
        didSet {
            UserDefaults.standard.batteryChemistry = batteryChemistry
        }
    }

    // MARK: Loop model inputs

    var basalRateSchedule: BasalRateSchedule? = UserDefaults.standard.basalRateSchedule {
        didSet {
            doseStore.basalProfile = basalRateSchedule

            UserDefaults.standard.basalRateSchedule = basalRateSchedule

            AnalyticsManager.sharedManager.didChangeBasalRateSchedule()
        }
    }

    var carbRatioSchedule: CarbRatioSchedule? = UserDefaults.standard.carbRatioSchedule {
        didSet {
            carbStore?.carbRatioSchedule = carbRatioSchedule

            UserDefaults.standard.carbRatioSchedule = carbRatioSchedule

            AnalyticsManager.sharedManager.didChangeCarbRatioSchedule()
        }
    }

    var insulinActionDuration: TimeInterval? = UserDefaults.standard.insulinActionDuration {
        didSet {
            doseStore.insulinActionDuration = insulinActionDuration

            UserDefaults.standard.insulinActionDuration = insulinActionDuration

            if oldValue != insulinActionDuration {
                AnalyticsManager.sharedManager.didChangeInsulinActionDuration()
            }
        }
    }

    var insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.standard.insulinSensitivitySchedule {
        didSet {
            carbStore?.insulinSensitivitySchedule = insulinSensitivitySchedule
            doseStore.insulinSensitivitySchedule = insulinSensitivitySchedule

            UserDefaults.standard.insulinSensitivitySchedule = insulinSensitivitySchedule

            AnalyticsManager.sharedManager.didChangeInsulinSensitivitySchedule()
        }
    }

    var glucoseTargetRangeSchedule: GlucoseRangeSchedule? = UserDefaults.standard.glucoseTargetRangeSchedule {
        didSet {
            UserDefaults.standard.glucoseTargetRangeSchedule = glucoseTargetRangeSchedule

            NotificationCenter.default.post(name: .LoopSettingsUpdated, object: self)

            AnalyticsManager.sharedManager.didChangeGlucoseTargetRangeSchedule()
        }
    }
    
    var minimumBGGuard: GlucoseThreshold? = UserDefaults.standard.minimumBGGuard {
        didSet {
            UserDefaults.standard.minimumBGGuard = minimumBGGuard
            AnalyticsManager.sharedManager.didChangeMinimumBGGuard()
        }
    }

    var workoutModeEnabled: Bool? {
        guard let range = glucoseTargetRangeSchedule else {
            return nil
        }

        guard let override = range.temporaryOverride else {
            return false
        }

        return override.endDate.timeIntervalSinceNow > 0
    }

    /// Attempts to enable workout glucose targets until the given date, and returns true if successful.
    /// TODO: This can live on the schedule itself once its a value type, since didSet would invoke when mutated.
    @discardableResult
    func enableWorkoutMode(until endDate: Date) -> Bool {
        guard let glucoseTargetRangeSchedule = glucoseTargetRangeSchedule else {
            return false
        }

        _ = glucoseTargetRangeSchedule.setWorkoutOverride(until: endDate)

        NotificationCenter.default.post(name: .LoopSettingsUpdated, object: self)

        return true
    }

    func disableWorkoutMode() {
        glucoseTargetRangeSchedule?.clearOverride()

        NotificationCenter.default.post(name: .LoopSettingsUpdated, object: self)
    }

    var maximumBasalRatePerHour: Double? = UserDefaults.standard.maximumBasalRatePerHour {
        didSet {
            UserDefaults.standard.maximumBasalRatePerHour = maximumBasalRatePerHour

            AnalyticsManager.sharedManager.didChangeMaximumBasalRate()
        }
    }

    var maximumBolus: Double? = UserDefaults.standard.maximumBolus {
        didSet {
            UserDefaults.standard.maximumBolus = maximumBolus

            AnalyticsManager.sharedManager.didChangeMaximumBolus()
        }
    }

    // MARK: - CarbKit

    let carbStore: CarbStore?

    // MARK: CarbStoreDelegate

    func carbStore(_: CarbStore, didError error: CarbStore.CarbStoreError) {
        logger.addError(error, fromSource: "CarbStore")
    }

    // MARK: - GlucoseKit

    let glucoseStore = GlucoseStore()

    // MARK: - InsulinKit

    let doseStore: DoseStore

    // MARK: DoseStoreDelegate

    func doseStore(_ doseStore: DoseStore, hasEventsNeedingUpload pumpEvents: [PersistedPumpEvent], fromPumpID pumpID: String, withCompletion completionHandler: @escaping (_ uploadedObjects: [NSManagedObjectID]) -> Void) {
        guard let uploader = remoteDataManager.nightscoutService.uploader, let pumpModel = pumpState?.pumpModel else {
            completionHandler(pumpEvents.map({ $0.objectID }))
            return
        }

        uploader.upload(pumpEvents, from: pumpModel) { (result) in
            switch result {
            case .success(let objects):
                completionHandler(objects)
            case .failure(let error):
                self.logger.addError(error, fromSource: "NightscoutUploadKit")
                completionHandler([])
            }
        }
    }

    // MARK: - WatchKit

    fileprivate var watchManager: WatchDataManager!
    
    // MARK: - Status Extension
    
    fileprivate var statusExtensionManager: StatusExtensionDataManager!

    // MARK: - Initialization

    private(set) var loopManager: LoopDataManager!

    init() {
        let pumpID = UserDefaults.standard.pumpID

        doseStore = DoseStore(
            pumpID: pumpID,
            insulinActionDuration: insulinActionDuration,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

         carbStore = CarbStore(
            defaultAbsorptionTimes: (fast: TimeInterval(hours: 2), medium: TimeInterval(hours: 3), slow: TimeInterval(hours: 4)),
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

        var idleListeningEnabled = true

        if let pumpID = pumpID {
            let pumpState = PumpState(pumpID: pumpID, pumpRegion: UserDefaults.standard.pumpRegion ?? .northAmerica)

            if let timeZone = UserDefaults.standard.pumpTimeZone {
                pumpState.timeZone = timeZone
            }

            if let pumpModelNumber = UserDefaults.standard.pumpModelNumber {
                if let model = PumpModel(rawValue: pumpModelNumber) {
                    pumpState.pumpModel = model

                    idleListeningEnabled = model.hasMySentry
                }
            }

            self.pumpState = pumpState
        }

        rileyLinkManager = RileyLinkDeviceManager(
            pumpState: self.pumpState,
            autoConnectIDs: connectedPeripheralIDs
        )
        rileyLinkManager.idleListeningEnabled = idleListeningEnabled

        NotificationCenter.default.addObserver(self, selector: #selector(receivedRileyLinkManagerNotification(_:)), name: nil, object: rileyLinkManager)
        NotificationCenter.default.addObserver(self, selector: #selector(receivedRileyLinkPacketNotification(_:)), name: .RileyLinkDeviceDidReceiveIdleMessage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(receivedRileyLinkTimerTickNotification(_:)), name: .RileyLinkDeviceDidUpdateTimerTick, object: nil)

        if let pumpState = pumpState {
            NotificationCenter.default.addObserver(self, selector: #selector(pumpStateValuesDidChange(_:)), name: .PumpStateValuesDidChange, object: pumpState)
        }

        remoteDataManager.delegate = self
        statusExtensionManager = StatusExtensionDataManager(deviceDataManager: self)
        loopManager = LoopDataManager(
            deviceDataManager: self,
            lastLoopCompleted: statusExtensionManager.context?.loop?.lastCompleted
        )
        watchManager = WatchDataManager(deviceDataManager: self)
        nightscoutDataManager = NightscoutDataManager(deviceDataManager: self)

        carbStore?.delegate = self
        carbStore?.syncDelegate = remoteDataManager.nightscoutService.uploader
        doseStore.delegate = self

        setupCGM()
    }
}


extension DeviceDataManager: RemoteDataManagerDelegate {
    func remoteDataManagerDidUpdateServices(_ dataManager: RemoteDataManager) {
        carbStore?.syncDelegate = dataManager.nightscoutService.uploader
    }
}


extension DeviceDataManager: CGMManagerDelegate {
    func cgmManager(_ manager: CGMManager, didUpdateWith result: CGMResult) {
        switch result {
        case .newData(let values):
            glucoseStore?.addGlucoseValues(values, device: manager.device) { (success, _, _) in
                if success {
                    NotificationCenter.default.post(name: .GlucoseUpdated, object: self)
                }

                self.assertCurrentPumpData()
            }
        case .noData, .error:
            self.assertCurrentPumpData()
        }
    }

    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        return glucoseStore?.latestGlucose?.startDate
    }
}


extension DeviceDataManager: CustomDebugStringConvertible {
    var debugDescription: String {
        return [
            Bundle.main.localizedNameAndVersion,
            "## DeviceDataManager",
            "launchDate: \(launchDate)",
            "cgm: \(String(describing: cgm))",
            "latestPumpStatusFromMySentry: \(String(describing:latestPumpStatusFromMySentry))",
            "pumpState: \(String(reflecting: pumpState))",
            "preferredInsulinDataSource: \(preferredInsulinDataSource)",
            "glucoseTargetRangeSchedule: \(String(describing: glucoseTargetRangeSchedule))",
            "workoutModeEnabled: \(String(describing: workoutModeEnabled))",
            "maximumBasalRatePerHour: \(String(describing: maximumBasalRatePerHour))",
            "maximumBolus: \(String(describing: maximumBolus))",
            cgmManager != nil ? String(reflecting: cgmManager!) : "",
            String(reflecting: rileyLinkManager),
            String(reflecting: statusExtensionManager!),
            "",
            "## NSUserDefaults",
            String(reflecting: UserDefaults.standard.dictionaryRepresentation())
        ].joined(separator: "\n")
    }
}


extension Notification.Name {
    /// Notification posted by the instance when new glucose data was processed
    static let GlucoseUpdated = Notification.Name(rawValue:  "com.loudnate.Naterade.notification.GlucoseUpdated")

    /// Notification posted by the instance when new pump data was processed
    static let PumpStatusUpdated = Notification.Name(rawValue: "com.loudnate.Naterade.notification.PumpStatusUpdated")

    /// Notification posted by the instance when loop configuration was changed
    static let LoopSettingsUpdated = Notification.Name(rawValue: "com.loudnate.Naterade.notification.LoopSettingsUpdated")
}
