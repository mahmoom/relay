//
//  RelayTests.swift
//  RelayTests
//
//  Created by Evan Kimia on 12/20/16.
//  Copyright © 2016 zero. All rights reserved.
//

import XCTest
import CocoaLumberjack
import CocoaLumberjackSwift
import GRDB

@testable import Relay

class RelayTests: XCTestCase, RelayTestingDelegate {

    private var relay: Relay?
    private var successBlock: ((_ record: LogRecord) -> Void)?
    private var recordDeletionBlock: ((_ record: LogRecord) -> Void)?
    private var failureBlock: ((_ record: LogRecord, _ error: Error?,_ response: HTTPURLResponse?) -> Void)?
    
    override class func setUp() {
        RelayTests.deleteRelayDirectory()
    }
    
    override func setUp() {
        super.setUp()
        
        DDLog.removeAllLoggers()
        DDLog.add(relay)
        
        successBlock = nil
        failureBlock = nil
    }
    
    // Esure a log message is correctly inserted in the logger database
    func testLogger() {
        relay = Relay(identifier:"testLogger",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!))
        setupLogger()
        
        let exp = expectation(description: "A log should be present in the log database.")
        
        DDLogInfo("hello")
        DDLog.flushLog()
        
        relay?.dbQueue?.inDatabase({ db in
            let request = LogRecord.all()
            let count = try! request.fetchCount(db)
            XCTAssert(count == 1, "1 log entry should be present, got \(count) instead.")
            exp.fulfill()
        })
        
        waitForExpectations(timeout: 1, handler: nil)
    }
    
    func testDiskQuota() {
        relay = Relay(identifier:"testDiskQuota",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!))
        setupLogger()
        relay!.maxNumberOfLogs = 10
        
        let exp = expectation(description: "The database should have at most the value of the `maxNumberOfLogs` property.")
        
        for _ in 0...relay!.maxNumberOfLogs + 1 {
            DDLogInfo("hello hellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohellohello")
        }
        DDLog.flushLog()
        
        relay?.dbQueue?.inDatabase({ db in
            let request = LogRecord.all()
            let count = try! request.fetchCount(db)
            XCTAssert(count == relay!.maxNumberOfLogs, "\(relay!.maxNumberOfLogs) log entries should be present, got \(count) instead.")
            exp.fulfill()
        })
        
        waitForExpectations(timeout: 30, handler: nil)
    }
    
    func testSuccessfulLogFlush() {
        let response = HTTPURLResponse(url: URL(string: "http://doesntmatter.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
        let sessionMock = URLSessionMock(data: nil, response: response, error: nil)
        
        relay = Relay(identifier:"testSuccessfulLogFlush",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!),
                      testSession:sessionMock)
        sessionMock.delegate = relay
        setupLogger()
        
        DDLogInfo("This should successfully upload")
        DDLog.flushLog()
        
        let exp = expectation(description: "No network errors should occur when flushing logs.")
        
        successBlock = { record in
            exp.fulfill()
        }
        
        relay?.flushLogs()
        
        waitForExpectations(timeout: 1, handler: nil)
    }
    
    func testFailedLogFlush() {
        let response = HTTPURLResponse(url: URL(string: "http://doesntmatter.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)
        let error = NSError(domain: "loggerTest", code: 5, userInfo: nil)
        let sessionMock = URLSessionMock(data: nil, response: response, error: error)
        
        relay = Relay(identifier:"testFailedLogFlush",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!),
                      testSession:sessionMock)
        
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("This should fail to upload")
        DDLog.flushLog()
        
        let exp = expectation(description: "A bad response should have occured when uploading this log.")
        
        failureBlock = { [weak self] record, error, response in
            if let statusCode = response?.statusCode {
                XCTAssert(statusCode != 200)
                exp.fulfill()
                self?.failureBlock = nil
            }
        }
        relay?.flushLogs()
        
        waitForExpectations(timeout: 1, handler: nil)
    }
    
    func testFailedUploadRetries() {
        let exp = expectation(description: "A log past the number of upload retries should be deleted.")
        let response = HTTPURLResponse(url: URL(string: "http://doesntmatter.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)
        
        let sessionMock = URLSessionMock(data: nil, response: response, error: nil)
        
        relay = Relay(identifier:"testFailedUploadRetries",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!),
                      testSession:sessionMock)
        
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("Testing one two...")
        DDLog.flushLog()
        
        // The default number of retries is 3, so let's ensure our failureBlock is called 3 times.
        
        var failureCount = 0
        failureBlock = { record in
            failureCount += 1
            if failureCount == self.relay!.uploadRetries - 1 {
                // the database should be empty
                DispatchQueue.main.async {
                    self.relay?.dbQueue?.inDatabase({ db in
                        let request = LogRecord.all()
                        let count = try! request.fetchCount(db)
                        XCTAssert(count == 0, "No log entries should be present, got \(count) instead.")
                        exp.fulfill()
                    })
                }
            }
        }
        relay?.flushLogs()
        
        waitForExpectations(timeout: 1, handler: nil)
    }
    
    func testCancelledTask() {
        let exp = expectation(description: "A task cancelled should result in the log record being deleted.")
        
        let error = NSError(domain: "", code: NSURLErrorCancelled, userInfo: nil)
        let sessionMock = URLSessionMock(error: error)
        
        let configOne = RelayConfiguration(host: URL(string: "http://doesntmatter.com")!)
        
        relay = Relay(identifier:"testCancelledTask",
                      configuration: configOne,
                      testSession:sessionMock)
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("Testing one two...")
        DDLog.flushLog()
        
        recordDeletionBlock = { record in
            exp.fulfill()
        }

        waitForExpectations(timeout: 2, handler: nil)
    }
    
    func testReset() {
        let exp = expectation(description: "No logs should be present after a reset.")

        let sessionMock = URLSessionMock()
        sessionMock.taskResponseTime = 10 // Make it long enough so the network task is still present when we switch configs
        
        let configOne = RelayConfiguration(host: URL(string: "http://doesntmatter.com")!, additionalHttpHeaders: ["Hello": "You."])
        
        relay = Relay(identifier:"testReset",
                      configuration: configOne,
                      testSession:sessionMock)
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("Testing one two...")
        DDLog.flushLog()
        relay?.reset()

        relay?.dbQueue?.inDatabase({ db in
            // Grab the network task and verify it has the information from configTwo
            let count = try! LogRecord.fetchCount(db)
            XCTAssert(count == 0, "No log entries should be present, got \(count) instead.")
            exp.fulfill()
        })

        waitForExpectations(timeout: 1, handler: nil)
    }
    
    func testRemoteConfigurationUpdate() {
        let exp = expectation(description: "Should remake requests when the configuration changes.")
        
        let sessionMock = URLSessionMock()
        sessionMock.taskResponseTime = 10 // Make it long enough so the network task is still present when we switch configs
        
        let configOne = RelayConfiguration(host: URL(string: "http://doesntmatter.com")!, additionalHttpHeaders: ["Hello": "You."])
        
        relay = Relay(identifier:"testRemoteConfigurationUpdate",
                      configuration: configOne,
                      testSession:sessionMock)
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("Testing one two...")
        DDLog.flushLog()
        
        let configTwoHeaders = ["Goodbye": "See you later."]
        let configTwo = RelayConfiguration(host: URL(string: "http://doesntmatter.com")!, additionalHttpHeaders: configTwoHeaders)
        relay?.configuration = configTwo
        
        relay?.dbQueue?.inDatabase({ _ in
            // Grab the network task and verify it has the information from configTwo
            relay?.urlSession?.getAllTasks(completionHandler: { tasks in
                guard let task = tasks.last,
                    let currentRequest = task.currentRequest,
                    let requestHeaders = currentRequest.allHTTPHeaderFields,
                    let configTwoKey = configTwoHeaders.keys.first else {
                        XCTFail("Missing required objects!")
                        return
                }
                XCTAssertEqual(requestHeaders[configTwoKey], configTwoHeaders[configTwoKey])
            })
        })
        
        let configThreeHeaders = ["Hello Again": "It's been a while!"]
        let configThree = RelayConfiguration(host: URL(string: "http://doesntmatter.com")!, additionalHttpHeaders: configThreeHeaders)
        
        relay?.configuration = configThree
        relay?.dbQueue?.inDatabase({ db in
            // Grab the network task and verify it has the information from configThree
            relay?.urlSession?.getAllTasks(completionHandler: { tasks in
                guard let record = try! LogRecord.fetchOne(db),
                    let task = tasks.filter({ $0.taskIdentifier == record.uploadTaskID }).first,
                    let currentRequest = task.currentRequest,
                    let requestHeaders = currentRequest.allHTTPHeaderFields,
                    let configThreeKey = configThreeHeaders.keys.first else {
                        XCTFail("Missing required objects!")
                        return
                }
                XCTAssertEqual(requestHeaders[configThreeKey], configThreeHeaders[configThreeKey])
            })
        })
        
        // Test for changing the host.
        let configFour = RelayConfiguration(host: URL(string: "http://newhost.com")!, additionalHttpHeaders: configThreeHeaders)
        
        relay?.configuration = configFour
        relay?.dbQueue?.inDatabase({ db in
            // Grab the network task and verify it has the information from configFour
            relay?.urlSession?.getAllTasks(completionHandler: { tasks in
                guard let record = try! LogRecord.fetchOne(db),
                    let task = tasks.filter({ $0.taskIdentifier == record.uploadTaskID }).first,
                    let currentRequest = task.currentRequest,
                    let host = currentRequest.url else {
                        XCTFail("Missing required objects!")
                        return
                }
                XCTAssertEqual(host, configFour.host)
                exp.fulfill()
            })
        })
        
        waitForExpectations(timeout: 2, handler: nil)
    }

    
    func testCleanup() {
        let exp = expectation(description: "A log with a task ID no longer present in the session should be reuploaded.")
        let response = HTTPURLResponse(url: URL(string: "http://doesntmatter.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
        
        let sessionMock = URLSessionMock(data: nil, response: response, error: nil)
        sessionMock.taskResponseTime = 2 // We don't want the log upload immediately.
        
        relay = Relay(identifier:"testCleanup",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!),
                      testSession:sessionMock)
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("Testing one two...")
        DDLog.flushLog()
        
        // manually specify a nonexistent taskID
        let nonexistentTaskID = -12
        try! relay?.dbQueue?.inDatabase({ db in
            let record = try LogRecord.fetchOne(db)
            record?.uploadTaskID = nonexistentTaskID
            try record?.save(db)
            
        })
        relay?.cleanup()
        try! relay?.dbQueue?.inDatabase({ db in
            let record = try LogRecord.fetchOne(db)
            XCTAssertTrue(record?.uploadTaskID != nonexistentTaskID)
            exp.fulfill()
        })
        
        waitForExpectations(timeout: 1, handler: nil)
    }
    
    func testHandleRelayUrlSessionEvents() {
        relay = Relay(identifier:"testHandleRelayUrlSessionEvents",
                      configuration: RelayConfiguration(host: URL(string: "http://doesntmatter.com")!))
        
        XCTAssertNil(relay!.sessionCompletionHandler)
        
        relay?.handleRelayUrlSessionEvents(identifier: relay!.identifier,
                                           completionHandler: { })
        XCTAssertTrue(relay!.sessionCompletionHandler != nil)
    }
    
    func testRecreatePendingUploadTasksIfNeeded() {
        let exp = expectation(description: "Changing the relay configuration should cancel out and remake pending log upload tasks.")
        
        let response = HTTPURLResponse(url: URL(string: "http://doesntmatter.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
        
        let sessionMock = URLSessionMock(data: nil, response: response, error: nil)
        sessionMock.taskResponseTime = 2 // We don't want the log upload immediately.
        
        let firstRelayConfig = RelayConfiguration(host: URL(string: "http://doesntmatter.com")!)
        
        relay = Relay(identifier:"testRecreatePendingUploadTasksIfNeeded",
                      configuration: firstRelayConfig, testSession: sessionMock)
        sessionMock.delegate = relay
        
        setupLogger()
        
        DDLogInfo("'What we have here is a failure to communicate' - Paul Newman, Cool Hand Luke")
        DDLog.flushLog()
        
        relay?.dbQueue?.inDatabase({ db in
            relay?.urlSession?.getAllTasks(completionHandler: { tasks in
                let task = tasks.first!
                let taskRequest = task.currentRequest!
                XCTAssertEqual(taskRequest.url!, firstRelayConfig.host)
            })
        })
        
        let secondRelayConfig = RelayConfiguration(host: URL(string: "http://alsodoesntmatter.com")!)
        self.relay?.configuration = secondRelayConfig
        self.successBlock = { record in
            self.relay?.urlSession?.getAllTasks(completionHandler: { tasks in
                let task = tasks.first!
                let taskRequest = task.currentRequest!
                XCTAssertEqual(taskRequest.url!, secondRelayConfig.host)
                
                exp.fulfill()
            })
        }

        waitForExpectations(timeout: 10, handler: nil)
    }

    
    //MARK: RelayTestingDelegate methods
    
    public func relay(relay: Relay, didUploadLogMessage message: DDLogMessage) {
        // unused.
    }
    
    func relay(relay: Relay, didUploadLogRecord record: LogRecord) {
        successBlock?(record)
    }
    
    func relay(relay: Relay, didDeleteLogRecord record: LogRecord) {
        recordDeletionBlock?(record)
    }
    
    
    func relay(relay: Relay, didFailToUploadLogRecord record: LogRecord, error: Error?, response: HTTPURLResponse?) {
        failureBlock?(record, error, response)
    }
    
    func relay(relay: Relay, didFailToUploadLogMessage message: DDLogMessage, error: Error?, response: HTTPURLResponse?) {
        // unused.
    }
    
    // MARK: Helpers
    
    private func setupLogger() {
        DDLog.removeAllLoggers()
        DDLog.add(relay)
        relay?.delegate = self
    }
    
    private static func deleteRelayDirectory() {
        do {
            try FileManager.default.removeItem(at: relayPath())
        } catch {
            // According to the documentation, checks to see if the operation will succeed first are discouraged.
        }
    }
}
