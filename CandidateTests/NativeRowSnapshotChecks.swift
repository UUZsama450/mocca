// Appended to the production transcript and existing controller regression host.
@MainActor private extension NativeChatTranscriptController {
    var installedSnapshotForTest: UUID { installedRowsSnapshotID }
    var snapshotRowsForTest: [NativeChatRow] { rows }
    func lookupForTest(_ id: UUID) -> NativeChatRow? { rowByID[id] }
}

extension RowConfigurationApp {
    func rowSnapshotChecks() async {
        let firstCheck = checks
        let driver = NativeChatScrollDriver()
        let initial = NativeChatTranscript(rows: (1...3).map { row($0) },
            configuration: .init(top: 20, bottom: 20, gap: 0),
            publicationID: AnyHashable(0), sessionID: AnyHashable("snapshot"), driver: driver,
            hasEarlier: false, hasLater: false)
        var geometry = initial
        geometry.configuration.bottom = 80
        expect(geometry.rowsSnapshotID == initial.rowsSnapshotID, "geometry copy retains snapshot")
        var assigned = initial
        assigned.rows = initial.rows
        expect(assigned.rowsSnapshotID != initial.rowsSnapshotID, "array assignment replaces snapshot")
        var edited = initial
        edited.rows[1] = row(2, height: 100, revision: 1)
        expect(edited.rowsSnapshotID != initial.rowsSnapshotID, "subscript mutation replaces snapshot")
        var appended = initial
        appended.rows.append(row(4))
        expect(appended.rowsSnapshotID != initial.rowsSnapshotID, "append replaces snapshot")
        let beforeRemove = appended.rowsSnapshotID
        appended.rows.removeLast()
        expect(appended.rowsSnapshotID != beforeRemove, "remove replaces snapshot")
        let beforeReverse = appended.rowsSnapshotID
        appended.rows.reverse()
        expect(appended.rowsSnapshotID != beforeReverse, "in-place reorder replaces snapshot")
        var secondCopy = initial
        secondCopy.rows[1] = row(2, height: 140, revision: 2)
        expect(secondCopy.rowsSnapshotID != edited.rowsSnapshotID, "independent copy edits cannot share identity")
        expect(initial.rows[1].revision == row(2).revision, "copy edits preserve original rows")

        let controller = NativeChatTranscriptController(input: initial)
        window!.rootViewController = controller; window!.makeKeyAndVisible()
        await wait(); controller.collection.layoutIfNeeded()
        controller.update(geometry)
        expect(controller.installedSnapshotForTest == initial.rowsSnapshotID, "footer reuses installed rows")
        controller.update(edited)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.lookupForTest(id(2))?.revision == edited.rows[1].revision, "in-place revision adopted")
        expect(abs(controller.testedLayout.frame(for: id(2))!.height - 100) < 1, "in-place edit measured")
        controller.update(secondCopy)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.lookupForTest(id(2))?.revision == secondCopy.rows[1].revision, "divergent copy adopted")
        expect(abs(controller.testedLayout.frame(for: id(2))!.height - 140) < 1, "divergent copy measured")

        var context = secondCopy
        context.publicationID = AnyHashable(10)
        controller.update(context)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.installedSnapshotForTest == secondCopy.rowsSnapshotID, "publication keeps row snapshot")
        for case let cell as NativeChatCell in controller.collection.visibleCells {
            expect(cell.configuredPublication == AnyHashable(10), "same-snapshot publication refreshes visible content")
        }

        // Preserve the existing contract: a same-revision no-op updates input,
        // but rows are installed only once a subsequent update requires work.
        var deferred = context
        deferred.rows[0].isMessage = false
        controller.update(deferred)
        controller.update(deferred)
        expect(controller.installedSnapshotForTest == context.rowsSnapshotID, "no-op does not claim unapplied rows")
        deferred.configuration.bottom += 6
        controller.update(deferred)
        expect(controller.installedSnapshotForTest == deferred.rowsSnapshotID, "later footer installs pending row snapshot")
        expect(controller.lookupForTest(id(1))?.isMessage == false, "later footer refreshes lookup metadata")

        // A validated no-op must stop matching after another snapshot changes
        // the installed keys, even if the old snapshot is presented again.
        var replacement = deferred
        replacement.rows[1] = row(2, height: 160, revision: 3)
        controller.update(replacement)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.lookupForTest(id(2))?.revision == replacement.rows[1].revision,
               "changed revision retires earlier validation")
        controller.update(deferred)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.lookupForTest(id(2))?.revision == deferred.rows[1].revision,
               "earlier validated snapshot can restore its revision")
        expect(abs(controller.testedLayout.frame(for: id(2))!.height - 140) < 1,
               "restored revision restores measured content")

        var duplicate = deferred
        duplicate.rows = [row(1), row(1)]
        controller.update(duplicate)
        expect(controller.installedSnapshotForTest == deferred.rowsSnapshotID, "duplicate identities rejected")
        var otherSession = deferred
        otherSession.sessionID = AnyHashable("other-session")
        otherSession.configuration.bottom += 30
        controller.update(otherSession)
        expect(controller.testedLayout.configuration.bottom == deferred.configuration.bottom, "foreign session rejected")

        var empty = deferred
        empty.rows.removeAll()
        controller.update(empty)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.snapshotRowsForTest.isEmpty, "empty snapshot removes rows")
        controller.update(initial)
        await wait(); controller.collection.layoutIfNeeded()
        expect(controller.snapshotRowsForTest.map(\.id) == initial.rows.map(\.id), "original snapshot can be restored")
        controller.detach()
        controller.update(secondCopy)
        expect(controller.installedSnapshotForTest == initial.rowsSnapshotID, "detached controller rejects updates")
        cases.append(["name": "snapshot-identities-and-adoption", "checks": checks - firstCheck])
    }
}
