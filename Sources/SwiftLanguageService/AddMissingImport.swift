//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
@preconcurrency import IndexStoreDB
@_spi(SourceKitLSP) import LanguageServerProtocol
import SemanticIndex
import SourceKitD
import SourceKitLSP
import SwiftSyntax

import struct SourceKitLSP.Diagnostic

private let missingImportDiagnosticIDs: Set<String> = [
  "cannot_find_type_in_scope",
  "cannot_find_in_scope",
  "use_of_unresolved_identifier",
]

extension SwiftLanguageService {
  func retrieveAddMissingImportCodeActions(_ request: CodeActionRequest) async throws -> [CodeAction] {
    let snapshot = try await self.latestSnapshot(for: request.textDocument.uri)

    guard let compileCommand = await self.compileCommand(
      for: request.textDocument.uri,
      fallbackAfterTimeout: true
    ) else {
      return []
    }

    let diagnosticResponse = try await self.send(
      sourcekitdRequest: \.diagnostics,
      sourcekitd.dictionary([
        keys.sourceFile: snapshot.uri.pseudoPath,
        keys.compilerArgs: compileCommand.compilerArgs as [any SKDRequestValue],
      ]),
      snapshot: snapshot
    )

    guard let diagnostics = diagnosticResponse[keys.diagnostics] as SKDResponseArray? else {
      return []
    }

    let documentManager = try self.documentManager
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let existingImports = syntaxTree.statements.compactMap { $0.item.as(ImportDeclSyntax.self) }

    var missingImportDiagnostics: [(diagnostic: Diagnostic, missingSymbol: String)] = []

    diagnostics.forEach { _, rawDiagnostic in
      guard
        let diagnosticID: String = rawDiagnostic[keys.id],
        missingImportDiagnosticIDs.contains(diagnosticID),
        let diagnostic = Diagnostic(
          rawDiagnostic,
          in: snapshot,
          documentManager: documentManager,
          useEducationalNoteAsCode: false
        ),
        request.range.overlapsIncludingEmptyRanges(other: diagnostic.range),
        let missingSymbol = missingSymbolName(from: diagnostic.message)
      else {
        return true
      }

      missingImportDiagnostics.append((diagnostic, missingSymbol))
      return true
    }

    var result: [CodeAction] = []
    var suggestedModuleNames = Set<String>()

    for (diagnostic, missingSymbol) in missingImportDiagnostics {
      guard
        let moduleName = try? await self.uniqueModuleProvidingSymbol(
          named: missingSymbol,
          for: request.textDocument.uri
        ),
        !suggestedModuleNames.contains(moduleName),
        !existingImports.imports(moduleName),
        let edit = addImportEdit(
          moduleName,
          existingImports: existingImports,
          syntaxTree: syntaxTree,
          snapshot: snapshot
        )
      else {
        continue
      }

      suggestedModuleNames.insert(moduleName)

      result.append(
        CodeAction(
          title: "Add import \(moduleName)",
          kind: .quickFix,
          diagnostics: [diagnostic],
          edit: WorkspaceEdit(changes: [snapshot.uri: [edit]])
        )
      )
    }

    return result
  }

  private func uniqueModuleProvidingSymbol(named symbolName: String, for document: DocumentURI) async throws -> String? {
    guard
      let sourceKitLSPServer,
      let workspace = await sourceKitLSPServer.workspaceForDocument(uri: document.buildSettingsFile),
      let uncheckedIndex = await workspace.uncheckedIndex
    else {
      return nil
    }

    let index = uncheckedIndex.checked(for: .deletedFiles)
    var moduleNames = Set<String>()

    try index.forEachCanonicalSymbolOccurrence(byName: symbolName) { occurrence in
      guard occurrence.roles.contains(.definition) || occurrence.roles.contains(.declaration) else {
        return true
      }

      if let moduleName = try? index.containerNames(of: occurrence).first {
        moduleNames.insert(moduleName)
      }

      return moduleNames.count <= 1
    }

    guard moduleNames.count == 1 else {
      return nil
    }

    return moduleNames.first
  }
}

private func missingSymbolName(from diagnosticMessage: String) -> String? {
  let components = diagnosticMessage.split(separator: "'", omittingEmptySubsequences: false)
  guard components.count >= 3 else {
    return nil
  }
  return String(components[1])
}

private func addImportEdit(
  _ moduleName: String,
  existingImports: [ImportDeclSyntax],
  syntaxTree: SourceFileSyntax,
  snapshot: DocumentSnapshot
) -> TextEdit? {
  if let lastImport = existingImports.last {
    let insertionPosition = snapshot.position(of: lastImport.endPosition)
    return TextEdit(
      range: insertionPosition..<insertionPosition,
      newText: "\nimport \(moduleName)"
    )
  } else if let firstStatement = syntaxTree.statements.first {
    let insertionPosition = snapshot.position(of: firstStatement.positionAfterSkippingLeadingTrivia)
    return TextEdit(
      range: insertionPosition..<insertionPosition,
      newText: "import \(moduleName)\n\n"
    )
  } else {
    let startOfFile = Position(line: 0, utf16index: 0)
    return TextEdit(
      range: startOfFile..<startOfFile,
      newText: "import \(moduleName)\n\n"
    )
  }
}

private extension Array where Element == ImportDeclSyntax {
  func imports(_ moduleName: String) -> Bool {
    return contains { importDecl in
      let text = importDecl.description.trimmingCharacters(in: .whitespacesAndNewlines)
      return text == "import \(moduleName)"
        || text == "@testable import \(moduleName)"
        || text.hasPrefix("import \(moduleName).")
        || text.hasPrefix("@testable import \(moduleName).")
    }
  }
}

private extension Range where Bound == Position {
  func overlapsIncludingEmptyRanges(other: Range<Position>) -> Bool {
    switch (self.isEmpty, other.isEmpty) {
    case (true, true):
      return self.lowerBound == other.lowerBound
    case (true, false):
      return other.contains(self.lowerBound)
    case (false, true):
      return self.contains(other.lowerBound)
    case (false, false):
      return self.overlaps(other)
    }
  }
}
