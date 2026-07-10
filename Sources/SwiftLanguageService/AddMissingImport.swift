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
import SourceKitLSP
import SwiftSyntax

import struct SourceKitLSP.Diagnostic

private let missingImportDiagnosticMessagePrefixes = [
  "Cannot find type '",
  "Cannot find '",
  "Use of unresolved identifier '",
]

extension SwiftLanguageService {
  func diagnosticReportWithMissingImportCodeActions(
    _ diagnosticReport: RelatedFullDocumentDiagnosticReport,
    for snapshot: DocumentSnapshot,
    document: DocumentURI
  ) async throws -> RelatedFullDocumentDiagnosticReport {
    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)
    let existingImports = syntaxTree.statements.compactMap { $0.item.as(ImportDeclSyntax.self) }

    var result = diagnosticReport

    for index in result.items.indices {
      guard
        let missingSymbol = missingSymbolName(from: result.items[index]),
        let moduleName = try? await self.uniqueModuleProvidingSymbol(named: missingSymbol, for: document),
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

      let codeAction = CodeAction(
        title: "Add import \(moduleName)",
        kind: .quickFix,
        diagnostics: nil,
        edit: WorkspaceEdit(changes: [snapshot.uri: [edit]])
      )

      result.items[index].codeActions = (result.items[index].codeActions ?? []) + [codeAction]
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

      let moduleName = occurrence.location.moduleName
      guard !moduleName.isEmpty else {
        return true
      }

      moduleNames.insert(moduleName)

      return moduleNames.count <= 1
    }

    guard moduleNames.count == 1 else {
      return nil
    }

    return moduleNames.first
  }
}

private func missingSymbolName(from diagnostic: Diagnostic) -> String? {
  guard diagnostic.source == "SourceKit" else {
    return nil
  }

  for prefix in missingImportDiagnosticMessagePrefixes {
    guard diagnostic.message.hasPrefix(prefix) else {
      continue
    }

    let remainingMessage = diagnostic.message.dropFirst(prefix.count)
    guard let closingQuoteIndex = remainingMessage.firstIndex(of: "'") else {
      return nil
    }

    let symbolName = String(remainingMessage[..<closingQuoteIndex])
    return symbolName.isEmpty ? nil : symbolName
  }

  return nil
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
