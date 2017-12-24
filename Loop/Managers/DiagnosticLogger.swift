//
//  DiagnosticLogger.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/10/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import os.log


final class DiagnosticLogger {
    
    private let isSimulator: Bool = TARGET_OS_SIMULATOR != 0
    let subsystem: String
    let version: String
    let AzureAPIHost: String
    
    var mLabService: MLabService {
        didSet {
            try! KeychainManager().setMLabDatabaseName(mLabService.databaseName, APIKey: mLabService.APIKey)
        }
    }
    
    
    var logglyService: LogglyService {
        didSet {
            try! KeychainManager().setLogglyCustomerToken(logglyService.customerToken)
        }
    }
    
    let remoteLogLevel: OSLogType
    
    static var shared: DiagnosticLogger?
    
    init(subsystem: String, version: String) {
        let settings = Bundle.main.remoteSettings,
        AzureAPIHost = settings?["AzureAppServiceURL"]
        
        self.AzureAPIHost=AzureAPIHost!
        
        self.subsystem = subsystem
        self.version = version
        remoteLogLevel = isSimulator ? .fault : .info
        
        
        if let (databaseName, APIKey) = KeychainManager().getMLabCredentials() {
            mLabService = MLabService(databaseName: databaseName, APIKey: APIKey)
        } else {
            mLabService = MLabService(databaseName: nil, APIKey: nil)
        }
        
        let customerToken = KeychainManager().getLogglyCustomerToken()
        logglyService = LogglyService(customerToken: customerToken)
    }
    
    
    func forCategory(_ category: String) -> CategoryLogger {
        return CategoryLogger(logger: self, category: category)
    }
    func loopPushNotification(message: [String: AnyObject], loopAlert: Bool) {
        
        if !isSimulator,
            let messageData = try? JSONSerialization.data(withJSONObject: message, options: []),
            let URL = NSURL(string: AzureAPIHost),
            let components = NSURLComponents(url: URL as URL, resolvingAgainstBaseURL: true)
        {
            //components.query = "apiKey=\(APIKey)"
            
            if let URL = components.url {
                let request = NSMutableURLRequest(url: URL)
                
                request.httpMethod = "POST"
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                
                let task = URLSession.shared.uploadTask(with: request as URLRequest, from: messageData) { (_, _, error) -> Void in
                    if let error = error {
                        
                        NSLog("%s error: %@", error.localizedDescription)
                    }
                }
                
                task.resume()
            }
        }
        
    }
    
}


extension OSLogType {
    fileprivate var tagName: String {
        switch self {
        case let t where t == .info:
            return "info"
        case let t where t == .debug:
            return "debug"
        case let t where t == .error:
            return "error"
        case let t where t == .fault:
            return "fault"
        default:
            return "default"
        }
    }
}


final class CategoryLogger {
    private let logger: DiagnosticLogger
    let category: String
    
    private let systemLog: OSLog
    
    fileprivate init(logger: DiagnosticLogger, category: String) {
        self.logger = logger
        self.category = category
        
        systemLog = OSLog(subsystem: logger.subsystem, category: category)
    }
    
    private func remoteLog(_ type: OSLogType, message: String) {
        guard logger.remoteLogLevel.rawValue <= type.rawValue else {
            return
        }
        
        logger.logglyService.client?.send(message, tags: [type.tagName, category])
    }
    
    private func remoteLog(_ type: OSLogType, message: [String: Any]) {
        guard logger.remoteLogLevel.rawValue <= type.rawValue else {
            return
            
        }
        
        logger.logglyService.client?.send(message, tags: [type.tagName, category])
        
        // Legacy mLab logging. To be removed.
        if let messageData = try? JSONSerialization.data(withJSONObject: message, options: []) {
            logger.mLabService.uploadTaskWithData(messageData, inCollection: category)?.resume()
        }
    }
    
    func debug(_ message: [String: Any]) {
        systemLog.debug("%{public}@", String(describing: message))
        remoteLog(.debug, message: message)
    }
    
    func debug(_ message: String) {
        systemLog.debug("%{public}@", message)
        remoteLog(.debug, message: message)
    }
    
    func info(_ message: [String: Any]) {
        systemLog.info("%{public}@", String(describing: message))
        remoteLog(.info, message: message)
    }
    
    func info(_ message: String) {
        systemLog.info("%{public}@", message)
        remoteLog(.info, message: message)
    }
    
    func error(_ message: [String: Any]) {
        systemLog.error("%{public}@", String(reflecting: message))
        remoteLog(.error, message: message)
    }
    
    func error(_ message: String) {
        systemLog.error("%{public}@", message)
        remoteLog(.error, message: message)
    }
    
    func error(_ error: Error) {
        self.error(String(reflecting: error))
    }
    
    
}
