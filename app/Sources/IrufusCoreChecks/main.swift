import Foundation

@MainActor func main() {
    let e = EligibilityTests()
    run("eligibility: plain USB stick", e.plainUSBStickIsSelectable)
    run("eligibility: internal and boot disks", e.internalAndBootDisksAreNeverSelectable)
    run("eligibility: source image disk", e.sourceImageDiskIsExcluded)
    run("eligibility: incomplete identification", e.incompleteIdentificationIsRejected)
    run("eligibility: optional categories", e.optionalCategoriesNeedSettings)
    let c = ConfirmationTests()
    run("confirmation: standard", c.smallWellIdentifiedStickNeedsStandardConfirmation)
    run("confirmation: typed identifier", c.largeOrAmbiguousDisksNeedTypedIdentifier)
    run("identity: swapped device", c.identityDetectsSwappedDevice)
    run("broker: path validation", c.brokerAcceptsOnlyWholeRawDisks)
    let l = LogTests()
    run("log: redaction", l.homeUserAndSecretsAreRemoved)
    run("log: store secrets and export", l.storeAppliesSecretsAndExports)
    let b = EngineBridgeTests()
    run("engine: ABI and version", b.abiAndVersion)
    run("engine: analyze disk image", b.analyzeDiskImage)
    run("engine: typed errors", b.analyzeErrorsAreTyped)
    run("engine: hashes", b.hashesMatchKnownVectors)
    run("engine: cancelled hash", b.cancelledHashReportsCancellation)
    run("engine: DD write + verify via fd", b.deviceFromPlainFileWritesAndVerifies)
    run("engine: answer file preview", b.answerFilePreviewAndAccountNames)
    run("engine: FAT32 options", b.fat32OptionsForStick)
    let p = PlannerTests()
    run("planner: inconsistent configurations", p.issuesBlockInconsistentConfigurations)
    run("planner: Windows request", p.windowsRequestOnlyContainsApplicableOptions)
    let u = UpdateTests()
    run("updates: version ordering", u.versionsCompareNumerically)
    run("updates: release feed", u.releaseFeedIsParsedStrictly)
    run("updates: signature", u.onlyPackagesSignedWithTheKeyAreAccepted)
    run("updates: staged bundle", u.stagedBundleIsValidated)
    let d = DownloadTests()
    run("downloads: pinned keys", d.pinnedKeysMatchTheirFingerprints)
    run("downloads: Ubuntu signature", d.realUbuntuSignatureVerifies)
    run("downloads: rejected signatures", d.tamperedOrForeignSignaturesAreRejected)
    run("downloads: Ubuntu metadata", d.ubuntuMetadataIsParsed)
    run("downloads: SystemRescue metadata", d.systemRescueMetadataIsParsed)
    runAsync("downloads: resolution") { try await DownloadTests().resolutionUsesOnlyVerifiedMetadata() }
    if failures.isEmpty {
        print("All IrufusCore checks passed")
        exit(0)
    }
    print("\(failures.count) failure(s):")
    failures.forEach { print("  - \($0)") }
    exit(1)
}

MainActor.assumeIsolated { main() }
