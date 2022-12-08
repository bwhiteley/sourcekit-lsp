//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LanguageServerProtocol
import LSPTestSupport
import SKTestSupport
import SourceKitLSP
import XCTest

final class SwiftInterfaceTests: XCTestCase {

  /// Connection and lifetime management for the service.
  var connection: TestSourceKitServer! = nil

  /// The primary interface to make requests to the SourceKitServer.
  var sk: TestClient! = nil

  var documentManager: DocumentManager! {
    connection.server!._documentManager
  }

  override func setUp() {
    connection = TestSourceKitServer()
    sk = connection.client
    _ = try! sk.sendSync(InitializeRequest(
      processId: nil,
      rootPath: nil,
      rootURI: nil,
      initializationOptions: nil,
      capabilities: ClientCapabilities(workspace: nil,
                                       textDocument: TextDocumentClientCapabilities(
                                        codeAction: .init(
                                          codeActionLiteralSupport: .init(
                                            codeActionKind: .init(valueSet: [.quickFix])
                                          )),
                                        publishDiagnostics: .init(codeDescriptionSupport: true)
                                       )),
      trace: .off,
      workspaceFolders: nil))
  }
  
  override func tearDown() {
    sk = nil
    connection = nil
  }
  
  func testSystemModuleInterface() throws {
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    sk.send(DidOpenTextDocumentNotification(textDocument: TextDocumentItem(
      uri: uri,
      language: .swift,
      version: 1,
      text: """
      import Foundation
      """)))
    
    let _resp = try sk.sendSync(DefinitionRequest(
      textDocument: TextDocumentIdentifier(url),
      position: Position(line: 0, utf16index: 10)))
    let resp = try XCTUnwrap(_resp)
    guard case .locations(let locations) = resp else {
      XCTFail("Unexpected response: \(resp)")
      return
    }
    XCTAssertEqual(locations.count, 1)
    let location = try XCTUnwrap(locations.first)
    XCTAssertTrue(location.uri.pseudoPath.hasSuffix("/Foundation.swiftinterface"))
    let fileContents = try XCTUnwrap(location.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) }))
    XCTAssertTrue(fileContents.hasPrefix("import "))
  }
  
  func testOpenInterface() throws {
    guard let ws = try staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage") else { return }
    try ws.buildAndIndex()
    let call = ws.testLoc("Lib.foo:call")
    try ws.openDocument(call.url, language: .swift)
    let workspace = try ws.testServer.server!.queue.sync {
      try XCTUnwrap(ws.testServer.server?.workspaceForDocument(uri: call.docUri))
    }
    let swiftLangServer = try XCTUnwrap(ws.testServer.server?._languageService(for: call.docUri,
                                                                               .swift,
                                                                               in: workspace))
    let expectation = expectation(description: "open interface request")
    let openInterface = OpenInterfaceRequest(textDocument: call.docIdentifier, name: "lib")
    let request = Request(openInterface, id: .number(1), clientID: ObjectIdentifier(swiftLangServer),
                          cancellation: CancellationToken(), reply: { (result: Result<OpenInterfaceRequest.Response, ResponseError>) in
      do {
        let interfaceDetails = try result.get()
        XCTAssertTrue(interfaceDetails.uri.pseudoPath.hasSuffix("/lib.swiftinterface"))
        let fileContents = try XCTUnwrap(interfaceDetails.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) }))
        XCTAssertTrue(fileContents.contains("""
          public struct Lib {
          
              public func foo()
          
              public init()
          }
          """))
      } catch {
        XCTFail(error.localizedDescription)
      }
      expectation.fulfill()
    })
    
    _ = try ws.sk.sendSync(DefinitionRequest(
      textDocument: call.docIdentifier,
      position: Position(line: 0, utf16index: 8)))
    swiftLangServer.openInterface(request)
    
    waitForExpectations(timeout: 15)
  }

  func testSwiftInterfaceAcrossModules() throws {
    guard let ws = try staticSourceKitSwiftPMWorkspace(name: "SwiftPMPackage") else { return }
    try ws.buildAndIndex()
    let call = ws.testLoc("Lib.foo:call")
    try ws.openDocument(call.url, language: .swift)
    let _resp = try withExtendedLifetime(ws) {
      try ws.sk.sendSync(DefinitionRequest(
        textDocument: call.docIdentifier,
        position: Position(line: 0, utf16index: 8)))
    }
    let resp = try XCTUnwrap(_resp)
    guard case .locations(let locations) = resp else {
      XCTFail("Unexpected response: \(resp)")
      return
    }
    XCTAssertEqual(locations.count, 1)
    let location = try XCTUnwrap(locations.first)
    XCTAssertTrue(location.uri.pseudoPath.hasSuffix("/lib.swiftinterface"))
    let fileContents = try XCTUnwrap(location.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) }))
    XCTAssertTrue(fileContents.contains("""
      public struct Lib {
      
          public func foo()
      
          public init()
      }
      """))
  }
}
