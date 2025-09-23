//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerIntegration
import BuildServerProtocol
import LanguageServerProtocol
import LanguageServerProtocolExtensions
import SKTestSupport
import SwiftExtensions
import TSCExtensions
import ToolchainRegistry
import XCTest

import struct TSCBasic.RelativePath

final class CompilationDatabaseTests: XCTestCase {
  func testEncodeCompDBCommand() throws {
    // Requires JSONEncoder.OutputFormatting.sortedKeys
    func check(
      _ cmd: CompilationDatabaseCompileCommand,
      _ expected: String,
      file: StaticString = #filePath,
      line: UInt = #line
    ) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting.insert(.sortedKeys)
      let encodedString = try String(data: encoder.encode(cmd), encoding: .utf8)
      XCTAssertEqual(encodedString, expected, file: file, line: line)
    }

    try check(
      .init(directory: "a", filename: "b", commandLine: [], output: "c"),
      """
      {"arguments":[],"directory":"a","file":"b","output":"c"}
      """
    )
    try check(
      .init(directory: "a", filename: "b", commandLine: ["c", "d"], output: nil),
      """
      {"arguments":["c","d"],"directory":"a","file":"b"}
      """
    )
  }

  func testDecodeCompDBCommand() throws {
    func check(
      _ str: String,
      _ expected: CompilationDatabaseCompileCommand,
      file: StaticString = #filePath,
      line: UInt = #line
    ) throws {
      let cmd = try JSONDecoder().decode(CompilationDatabaseCompileCommand.self, from: str.data(using: .utf8)!)
      XCTAssertEqual(cmd, expected, file: file, line: line)
    }

    try check(
      """
      {
        "arguments" : [

        ],
        "directory" : "a",
        "file" : "b",
        "output" : "c"
      }
      """,
      .init(directory: "a", filename: "b", commandLine: [], output: "c")
    )
    try check(
      """
      {
        "arguments" : [
          "c",
          "d"
        ],
        "directory" : "a",
        "file" : "b"
      }
      """,
      .init(directory: "a", filename: "b", commandLine: ["c", "d"], output: nil)
    )

    try check(
      """
      {
        "directory":"a",
        "file":"b.cpp",
        "command": "/usr/bin/clang++ -std=c++11 -DFOO b.cpp"
      }
      """,
      .init(
        directory: "a",
        filename: "b.cpp",
        commandLine: [
          "/usr/bin/clang++",
          "-std=c++11",
          "-DFOO",
          "b.cpp",
        ],
        output: nil
      )
    )

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        CompilationDatabaseCompileCommand.self,
        from: """
            {"directory":"a","file":"b"}
          """.data(using: .utf8)!
      )
    )
  }

  func testJSONCompilationDatabaseCoding() {
    checkCoding(
      JSONCompilationDatabase([]),
      json: """
        [

        ]
        """
    )
    let db = JSONCompilationDatabase([
      .init(directory: "a", filename: "b", commandLine: [], output: nil),
      .init(directory: "c", filename: "b", commandLine: [], output: nil),
    ])
    checkCoding(
      db,
      json: """
        [
          {
            "arguments" : [

            ],
            "directory" : "a",
            "file" : "b"
          },
          {
            "arguments" : [

            ],
            "directory" : "c",
            "file" : "b"
          }
        ]
        """
    )
  }

  func testJSONCompilationDatabaseLookup() throws {
    #if os(Windows)
    let fileSystemRoot = "c:/"
    #else
    let fileSystemRoot = "/"
    #endif

    let cmd1 = CompilationDatabaseCompileCommand(directory: "a", filename: "b", commandLine: [], output: nil)
    let cmd2 = CompilationDatabaseCompileCommand(
      directory: "\(fileSystemRoot)c",
      filename: "b",
      commandLine: [],
      output: nil
    )
    let cmd3 = CompilationDatabaseCompileCommand(
      directory: "\(fileSystemRoot)c",
      filename: "\(fileSystemRoot)b",
      commandLine: [],
      output: nil
    )

    let db = JSONCompilationDatabase([cmd1, cmd2, cmd3])

    XCTAssertEqual(db[DocumentURI(filePath: "b", isDirectory: false)], [cmd1])
    XCTAssertEqual(db[DocumentURI(filePath: "\(fileSystemRoot)c/b", isDirectory: false)], [cmd2])
    XCTAssertEqual(db[DocumentURI(filePath: "\(fileSystemRoot)b", isDirectory: false)], [cmd3])
  }

  func testJSONCompilationDatabaseFromDirectory() async throws {
    try await withTestScratchDir { tempDir in
      let dbFile = tempDir.appending(component: JSONCompilationDatabaseBuildServer.dbName)

      XCTAssertThrowsError(try JSONCompilationDatabase(file: dbFile))

      try """
      [
        {
          "file": "/a/a.swift",
          "directory": "/a",
          "arguments": ["swiftc", "/a/a.swift"]
        }
      ]
      """.write(to: dbFile, atomically: true, encoding: .utf8)

      XCTAssertNotNil(try JSONCompilationDatabase(file: dbFile))
    }
  }

  func testFixedCompilationDatabase() async throws {
    try await withTestScratchDir { tempDir in
      let dbFile = tempDir.appending(component: FixedCompilationDatabaseBuildServer.dbName)

      XCTAssertThrowsError(
        try FixedCompilationDatabaseBuildServer(
          configPath: dbFile,
          connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
        )
      )

      try """
      -xc++
      -I
      libwidget/include/
      """.write(to: dbFile, atomically: true, encoding: .utf8)

      let buildServer = try XCTUnwrap(
        try FixedCompilationDatabaseBuildServer(
          configPath: dbFile,
          connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
        )
      )

      let dummyFile = tempDir.appending(component: "a.c")
      let buildSettings = try await buildServer.sourceKitOptions(
        request: TextDocumentSourceKitOptionsRequest(
          textDocument: TextDocumentIdentifier(URI(dummyFile)),
          target: .dummy,
          language: .c
        )
      )
      XCTAssertEqual(
        buildSettings,
        TextDocumentSourceKitOptionsResponse(
          compilerArguments: ["-xc++", "-I", "libwidget/include/", try dummyFile.filePath],
          workingDirectory: try tempDir.filePath
        )
      )
    }
  }

  func testInvalidCompilationDatabase() async throws {
    try await withTestScratchDir { tempDir in
      let dbFile = tempDir.appending(component: JSONCompilationDatabaseBuildServer.dbName)

      try "".write(to: dbFile, atomically: true, encoding: .utf8)
      XCTAssertThrowsError(try JSONCompilationDatabase(file: dbFile))
    }
  }

  func testCompilationDatabaseBuildServer() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "/a/a.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-swift-version", "4", "/a/a.swift"]
        }
      ]
      """
    ) { buildServer in
      let settings = try await buildServer.sourceKitOptions(
        request: TextDocumentSourceKitOptionsRequest(
          textDocument: TextDocumentIdentifier(DocumentURI(URL(fileURLWithPath: "/a/a.swift"))),
          target: BuildTargetIdentifier.createCompileCommands(compiler: "swiftc"),
          language: .swift
        )
      )

      XCTAssertNotNil(settings)
      XCTAssertEqual(settings?.workingDirectory, "/a")
      XCTAssertEqual(settings?.compilerArguments, ["-swift-version", "4", "/a/a.swift"])
      assertNil(await buildServer.indexStorePath)
      assertNil(await buildServer.indexDatabasePath)
    }
  }

  func testCompilationDatabaseBuildServerIndexStoreSwift0() async throws {
    try await checkCompilationDatabaseBuildServer("[]") { buildServer in
      assertNil(await buildServer.indexStorePath)
    }
  }

  func testCompilationDatabaseBuildServerIndexStoreSwift1() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "/a/a.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-swift-version", "4", "/a/a.swift", "-index-store-path", "/b"]
        }
      ]
      """
    ) { buildServer in
      assertEqual(
        try await buildServer.indexStorePath?.filePath,
        "\(pathSeparator)b"
      )
      assertEqual(
        try await buildServer.indexDatabasePath?.filePath,
        "\(pathSeparator)IndexDatabase"
      )
    }
  }

  func testCompilationDatabaseBuildServerIndexStoreSwift2() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "/a/a.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-swift-version", "4", "/a/a.swift"]
        },
        {
          "file": "/a/b.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-swift-version", "4", "/a/b.swift"]
        },
        {
          "file": "/a/c.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-swift-version", "4", "/a/c.swift", "-index-store-path", "/b"]
        }
      ]
      """
    ) { buildServer in
      await assertEqual(buildServer.indexStorePath, URL(fileURLWithPath: "/b"))
    }
  }

  func testCompilationDatabaseBuildServerIndexStoreSwift3() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "/a/a.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-index-store-path", "/b", "-swift-version", "4", "/a/a.swift"]
        }
      ]
      """
    ) { buildServer in
      assertEqual(await buildServer.indexStorePath, URL(fileURLWithPath: "/b"))
    }
  }

  func testCompilationDatabaseBuildServerIndexStoreSwift4() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "/a/a.swift",
          "directory": "/a",
          "arguments": ["swiftc", "-swift-version", "4", "/a/c.swift", "-index-store-path"]
        }
      ]
      """
    ) { buildServer in
      assertNil(await buildServer.indexStorePath)
    }
  }

  func testCompilationDatabaseBuildServerIndexStoreClang() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "/a/a.cpp",
          "directory": "/a",
          "arguments": ["clang", "/a/a.cpp"]
        },
        {
          "file": "/a/b.cpp",
          "directory": "/a",
          "arguments": ["clang", "/a/b.cpp"]
        },
        {
          "file": "/a/c.cpp",
          "directory": "/a",
          "arguments": ["clang", "/a/c.cpp", "-index-store-path", "/b"]
        }
      ]
      """
    ) { buildServer in
      assertEqual(
        try await buildServer.indexStorePath?.filePath,
        "\(pathSeparator)b"
      )
      assertEqual(
        try await buildServer.indexDatabasePath?.filePath,
        "\(pathSeparator)IndexDatabase"
      )
    }
  }

  func testIndexStorePathRelativeToWorkingDirectory() async throws {
    try await checkCompilationDatabaseBuildServer(
      """
      [
        {
          "file": "a.swift",
          "directory": "/a",
          "arguments": ["swift", "a.swift", "-index-store-path", "index-store"]
        }
      ]
      """
    ) { buildServer in
      assertEqual(
        try await buildServer.indexStorePath?.filePath,
        "\(pathSeparator)a\(pathSeparator)index-store"
      )
    }
  }
}

private var pathSeparator: String {
  #if os(Windows)
  return #"\"#
  #else
  return "/"
  #endif
}

private func checkCompilationDatabaseBuildServer(
  _ compdb: String,
  block: @Sendable (JSONCompilationDatabaseBuildServer) async throws -> Void
) async throws {
  try await withTestScratchDir { tempDir in
    let configPath = tempDir.appending(component: JSONCompilationDatabaseBuildServer.dbName)
    try compdb.write(to: configPath, atomically: true, encoding: .utf8)
    let buildServer = try JSONCompilationDatabaseBuildServer(
      configPath: configPath,
      toolchainRegistry: .forTesting,
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    try await block(XCTUnwrap(buildServer))
  }
}
