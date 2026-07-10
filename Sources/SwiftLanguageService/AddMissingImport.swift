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

private let missingImportDiagnosticIDs: Set<String> = [
  "cannot_find_type_in_scope",
  "cannot_find_in_scope",
  "use_of_unresolved_identifier",
]

struct MissingImportCodeActionContext {
  let index: CheckedIndex
  let existingImports: [ImportDeclSyntax]
}

func isMissingImportDiagnosticID(_ diagnosticID: String) -> Bool {
  return missingImportDiagnosticIDs.contains(diagnosticID)
}

func missingSymbolName(from diagnosticDescription: String) -> String? {
  let components = diagnosticDescription.split(separator: "'", omittingEmptySubsequences: false)
  guard components.count >= 3 else {
    return nil
  }

  let symbolName = String(components[1])
  return symbolName.isEmpty ? nil : symbolName
}

func missingImportCodeAction(
  for symbolName: String,
  context: MissingImportCodeActionContext,
  snapshot: DocumentSnapshot
) throws -> CodeAction? {
  guard let moduleName = try uniqueModuleProvidingSymbol(named: symbolName, using: context.index) else {
    return nil
  }

  let edit = addImportEdit(
    moduleName,
    existingImports: context.existingImports,
    snapshot: snapshot
  )

  return CodeAction(
    title: "Add import \(moduleName)",
    kind: .quickFix,
    diagnostics: nil,
    edit: WorkspaceEdit(changes: [snapshot.uri: [edit]])
  )
}

private func uniqueModuleProvidingSymbol(named symbolName: String, using index: CheckedIndex) throws -> String? {
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

private func addImportEdit(
  _ moduleName: String,
  existingImports: [ImportDeclSyntax],
  snapshot: DocumentSnapshot
) -> TextEdit {
  if let lastImport = existingImports.last {
    let insertionPosition = snapshot.position(of: lastImport.endPosition)
    return TextEdit(
      range: insertionPosition..<insertionPosition,
      newText: "\nimport \(moduleName)"
    )
  }

  let startOfFile = Position(line: 0, utf16index: 0)
  return TextEdit(
    range: startOfFile..<startOfFile,
    newText: "import \(moduleName)\n\n"
  )
}
