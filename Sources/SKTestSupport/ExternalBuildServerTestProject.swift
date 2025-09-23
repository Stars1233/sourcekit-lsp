//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
package import SKOptions
import SwiftExtensions
import XCTest

private let sdkArgs =
  if let defaultSDKPath {
    """
    "-sdk", r"\(defaultSDKPath)",
    """
  } else {
    ""
  }

/// The path to the INPUTS directory of shared test projects.
private let skTestSupportInputsDirectory: URL = {
  #if os(macOS)
  var resources =
    productsDirectory
    .appending(components: "SourceKitLSP_SKTestSupport.bundle", "Contents", "Resources")
  if !FileManager.default.fileExists(at: resources) {
    // Xcode and command-line swiftpm differ about the path.
    resources.deleteLastPathComponent()
    resources.deleteLastPathComponent()
  }
  #else
  let resources =
    productsDirectory
    .appending(component: "SourceKitLSP_SKTestSupport.resources")
  #endif
  guard FileManager.default.fileExists(at: resources) else {
    fatalError("missing resources \(resources)")
  }
  return resources.appending(component: "INPUTS", directoryHint: .isDirectory).standardizedFileURL
}()

/// Creates a project that uses a BSP server to provide build settings.
///
/// The build server is implemented in Python on top of the code in `AbstractBuildServer.py`.
///
/// The build server can contain `$SDK_ARGS`, which will replaced by `"-sdk", "/path/to/sdk"` on macOS and by an empty
/// string on all other platforms.
package class ExternalBuildServerTestProject: MultiFileTestProject {
  package init(
    files: [RelativeFileLocation: String],
    buildServerConfigLocation: RelativeFileLocation = ".bsp/sourcekit-lsp.json",
    buildServer: String,
    options: SourceKitLSPOptions? = nil,
    enableBackgroundIndexing: Bool = false,
    testName: String = #function
  ) async throws {
    var files = files
    files[buildServerConfigLocation] = """
      {
        "name": "Test BSP-server",
        "version": "1",
        "bspVersion": "2.0",
        "languages": ["swift"],
        "argv": ["server.py"]
      }
      """
    files["server.py"] = """
      import sys
      from typing import Dict, List, Optional

      sys.path.append(r"\(try skTestSupportInputsDirectory.filePath)")

      from AbstractBuildServer import AbstractBuildServer, LegacyBuildServer

      \(buildServer)

      BuildServer().run()
      """.replacing("$SDK_ARGS", with: sdkArgs)
    try await super.init(
      files: files,
      options: options,
      enableBackgroundIndexing: enableBackgroundIndexing,
      testName: testName
    )
  }
}
