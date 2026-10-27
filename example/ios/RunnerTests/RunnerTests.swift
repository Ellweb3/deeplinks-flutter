import Flutter
import UIKit
import XCTest

@testable import new_deeplinks

class RunnerTests: XCTestCase {

  func testUnknownMethodIsNotImplemented() {
    let plugin = DeepLinksPlugin()
    let call = FlutterMethodCall(methodName: "unknown", arguments: nil)
    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertTrue((result as AnyObject) === FlutterMethodNotImplemented)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

}
