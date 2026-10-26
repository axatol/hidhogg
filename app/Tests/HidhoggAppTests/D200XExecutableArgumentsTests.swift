import Foundation
import MacOSActions
import XCTest
@testable import HidhoggApp
import HidhoggDomain

@MainActor
final class D200XExecutableArgumentsTests: XCTestCase {
    func testDraftLoadAndSavePreservesArgumentBoundariesAndLiteralValues() throws {
        let argumentVectors = [
            [],
            [""],
            ["a\nb"],
            ["", "a\nb", "  \tkeep  ", "naïve 🧪"]
        ]

        for arguments in argumentVectors {
            var savedConfiguration: D200XConfiguration?
            let model = makeModel(arguments: arguments) { savedConfiguration = $0 }
            let original = try XCTUnwrap(model.configuration?.actions[Self.actionID])
            let draft = ConfiguredExecutableArgumentsDraft(arguments: original.arguments)

            XCTAssertEqual(draft.arguments, arguments)
            try model.saveAction(
                id: Self.actionID,
                action: ConfiguredExecutable(
                    executable: original.executable,
                    arguments: draft.arguments,
                    workingDirectory: original.workingDirectory,
                    timeoutSeconds: original.timeoutSeconds
                )
            )

            XCTAssertEqual(savedConfiguration?.actions[Self.actionID]?.arguments, arguments)
        }
    }

    func testEditedRowsSaveThroughModelWithoutChangingArgumentBoundaries() throws {
        var savedConfiguration: D200XConfiguration?
        let model = makeModel(arguments: ["first", "second"]) { savedConfiguration = $0 }
        let original = try XCTUnwrap(model.configuration?.actions[Self.actionID])
        var draft = ConfiguredExecutableArgumentsDraft(arguments: original.arguments)
        let firstRowID = draft.rows[0].id
        let removedRowID = draft.rows[1].id

        draft.updateArgument(id: firstRowID, value: "first\nsecond")
        XCTAssertTrue(draft.addArgument())
        let addedRowID = try XCTUnwrap(draft.rows.last?.id)
        draft.removeArgument(id: removedRowID)
        XCTAssertEqual(draft.rows.map(\.id), [firstRowID, addedRowID])
        XCTAssertEqual(draft.arguments, ["first\nsecond", ""])

        try model.saveAction(
            id: Self.actionID,
            action: ConfiguredExecutable(
                executable: original.executable,
                arguments: draft.arguments,
                workingDirectory: original.workingDirectory,
                timeoutSeconds: original.timeoutSeconds
            )
        )

        XCTAssertEqual(savedConfiguration?.actions[Self.actionID]?.arguments, ["first\nsecond", ""])
    }

    func testTimeoutOnlyEditRetainsLoadedArguments() throws {
        let arguments = ["", "two\nlines", "  whitespace\t"]
        var savedConfiguration: D200XConfiguration?
        let model = makeModel(arguments: arguments) { savedConfiguration = $0 }
        let original = try XCTUnwrap(model.configuration?.actions[Self.actionID])
        let draft = ConfiguredExecutableArgumentsDraft(arguments: original.arguments)

        try model.saveAction(
            id: Self.actionID,
            action: ConfiguredExecutable(
                executable: original.executable,
                arguments: draft.arguments,
                workingDirectory: original.workingDirectory,
                timeoutSeconds: 42
            )
        )

        XCTAssertEqual(savedConfiguration?.actions[Self.actionID]?.arguments, arguments)
        XCTAssertEqual(savedConfiguration?.actions[Self.actionID]?.timeoutSeconds, 42)
    }

    func testArgumentRowsStopAtConfiguredMaximum() {
        var draft = ConfiguredExecutableArgumentsDraft(
            arguments: Array(repeating: "", count: ConfiguredExecutableArgumentsDraft.maximumArgumentCount - 1)
        )

        XCTAssertTrue(draft.addArgument())
        XCTAssertEqual(draft.rows.count, ConfiguredExecutableArgumentsDraft.maximumArgumentCount)
        XCTAssertFalse(draft.addArgument())
        XCTAssertEqual(draft.rows.count, ConfiguredExecutableArgumentsDraft.maximumArgumentCount)
    }

    private static let actionID = "synthetic-argv"

    private func makeModel(
        arguments: [String],
        onEdit: @escaping (D200XConfiguration) -> Void
    ) -> D200XModel {
        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in })
        )
        model.synchronize(
            D200XConfiguration(actions: [
                Self.actionID: ConfiguredExecutable(
                    executable: "/synthetic/argv",
                    arguments: arguments,
                    workingDirectory: "/synthetic",
                    timeoutSeconds: 12
                )
            ]),
            canEdit: true
        )
        model.onEdit = onEdit
        return model
    }
}
