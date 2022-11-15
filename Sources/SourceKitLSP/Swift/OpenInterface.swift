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
import SourceKitD
import LanguageServerProtocol
import LSPLogging

struct InterfaceInfo {
  var contents: String?
}

private var textualInterfaces: [String:DocumentURI] = [:]

extension SwiftLanguageServer {

  public func openInterface(_ request: LanguageServerProtocol.Request<LanguageServerProtocol.OpenInterfaceRequest>) {
    let uri = request.params.textDocument.uri
    let moduleName = request.params.name
    let uuid = NSUUID().uuidString
        
    self.queue.async {
      
      if let uri = textualInterfaces[moduleName] {
        request.reply(.success(InterfaceDetails(uri: uri)))
        return
      }
      
      self._openInterface(request, uri, moduleName, uuid) { result in
        guard let interfaceInfo = result.success ?? nil else {
          if let error = result.failure {
            log("open interface failed: \(error)", level: .warning)
          }
          request.reply(.failure(ResponseError(result.failure!)))
          return
        }
        
        // FIXME: use some configurable path here
        let tempFolderURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let genFolder = tempFolderURL.appendingPathComponent("GeneratedInterfaces", isDirectory: true)
        let filePath = genFolder.appendingPathComponent("\(moduleName).swift")
        do {
          try FileManager.default.createDirectory(at: genFolder, withIntermediateDirectories: true)
          try interfaceInfo.contents?.write(to: filePath, atomically: true, encoding: String.Encoding.utf8)
        } catch {
          request.reply(.failure(ResponseError.unknown(error.localizedDescription)))
        }
        
        let uri = DocumentURI(filePath)
        textualInterfaces[moduleName] = uri
        request.reply(.success(InterfaceDetails(uri: uri)))
      }
    }
  }
  
  private func _openInterface(_ request: LanguageServerProtocol.Request<LanguageServerProtocol.OpenInterfaceRequest>,
                              _ uri: DocumentURI,
                              _ name: String,
                              _ uuid: String,
                              _ completion: @escaping (Swift.Result<InterfaceInfo?, SKDError>) -> Void) {
    let keys = self.keys
    let skreq = SKDRequestDictionary(sourcekitd: sourcekitd)
    skreq[keys.request] = requests.editor_open_interface
    skreq[keys.modulename] = name
    skreq[keys.name] = uuid
    skreq[keys.synthesizedextensions] = 1
    if let compileCommand = self.commandsByFile[uri] {
      skreq[keys.compilerargs] = compileCommand.compilerArgs
    }

    let handle = self.sourcekitd.send(skreq, self.queue) { result in
      guard let dict = result.success else {
        return completion(.failure(result.failure!))
      }
      
      return completion(.success(InterfaceInfo(contents: dict[keys.sourcetext])))
    }
    
    if let handle = handle {
      request.cancellationToken.addCancellationHandler { [weak self] in
        self?.sourcekitd.cancel(handle)
      }
    }
  }
}
