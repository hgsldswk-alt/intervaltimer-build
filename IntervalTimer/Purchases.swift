import Combine
import Foundation
import Security
import StoreKit

private actor EntitlementDisk {
    private let defaultsKey = "interval.entitlement"
    private var savedRevision = 0
    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.hgsldswk.intervaltimer",
         kSecAttrAccount as String: "interval.entitlement"]
    }

    func load(at now: Date) -> Entitlement {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let keychain = status == errSecSuccess ? item as? Data : nil
        let mirror = UserDefaults.standard.data(forKey: defaultsKey)
        let entries = [mirror, keychain].compactMap { bytes in
            bytes.flatMap { try? JSONDecoder().decode(Entitlement.self, from: $0) }
        }
        var value = entries.first ?? Entitlement(firstOpen: now)
        value.firstOpen = entries.map(\.firstOpen).min() ?? now
        value.proStartedAt = entries.compactMap(\.proStartedAt).min()
        value.trialClaimedAt = entries.compactMap(\.trialClaimedAt).min()
        if !Launch.isFree { value.startPaidPeriod(at: now) }
        save(value, revision: 0)
        return value
    }

    func save(_ value: Entitlement, revision: Int) {
        guard revision >= savedRevision, let data = try? JSONEncoder().encode(value) else { return }
        savedRevision = revision
        UserDefaults.standard.set(data, forKey: defaultsKey)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = key
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

@MainActor
final class Purchases: ObservableObject {
    private let disk = EntitlementDisk()
    private var transactionTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var loadingProducts = false
    @Published var message: String?
    let proID = Bundle.main.object(forInfoDictionaryKey: "IntervalProProductID") as? String
        ?? "com.hgsldswk.intervaltimer.pro"
    let trialID = Bundle.main.object(forInfoDictionaryKey: "IntervalTrialProductID") as? String
        ?? "com.hgsldswk.intervaltimer.trial"

    var hasPro: Bool { Launch.isFree || (entitlement?.hasPro(at: Date()) ?? false) }
    var trialDays: Int {
        guard let entitlement else { return 0 }
        return max(0, Int(ceil(entitlement.trialEnd.timeIntervalSinceNow / 86_400)))
    }

    func initialize() async {
        guard entitlement == nil else { return }
        let now = Date()
        if Launch.testing {
            var value = Entitlement(firstOpen: now)
            value.startPaidPeriod(at: Launch.flag("-expired") ? now.addingTimeInterval(-31 * 86_400) : now)
            set(value)
            return
        }
        set(await disk.load(at: now))
        guard !Launch.isFree else { return }
        transactionTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                if case .verified(let transaction) = result,
                   transaction.productID == self.proID || transaction.productID == self.trialID {
                    await self.accept(transaction)
                    await transaction.finish()
                    await self.refresh()
                }
            }
        }
        Task { await refresh() }
    }

    private func set(_ value: Entitlement) {
        entitlement = value
        boundaryTask?.cancel()
        let delay = value.trialEnd.timeIntervalSinceNow
        guard !Launch.isFree, !value.purchasedPro, delay > 0 else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.objectWillChange.send()
        }
    }

    private func accept(_ transaction: StoreKit.Transaction) async {
        guard var value = entitlement else { return }
        refreshGeneration += 1
        if transaction.productID == proID {
            value.purchasedPro = transaction.revocationDate == nil && !transaction.isUpgraded
        } else if transaction.productID == trialID && transaction.revocationDate == nil {
            value.recognizeTrial(at: transaction.originalPurchaseDate)
        }
        set(value)
        await disk.save(value, revision: refreshGeneration)
    }

    func refresh(clearMissingPro: Bool = false) async {
        guard !Launch.testing, !Launch.isFree, entitlement != nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        var verifiedPro = false
        var trialDate: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == proID && !transaction.isUpgraded { verifiedPro = true }
            if transaction.productID == trialID {
                trialDate = min(trialDate ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate)
            }
        }
        var proState: Bool? = verifiedPro ? true : (clearMissingPro ? false : nil)
        if !verifiedPro, let latest = await StoreKit.Transaction.latest(for: proID),
           case .verified(let transaction) = latest {
            proState = transaction.revocationDate == nil && !transaction.isUpgraded
        }
        guard generation == refreshGeneration, var value = entitlement else { return }
        if let proState { value.purchasedPro = proState }
        if let trialDate { value.recognizeTrial(at: trialDate) }
        set(value)
        await disk.save(value, revision: generation)
    }

    func loadProducts() async {
        guard !Launch.isFree, !Launch.testing, !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            products = try await Product.products(for: [proID, trialID])
        } catch {
        }
    }

    func purchase(_ id: String) async {
        guard !Launch.testing, !busy, let product = products.first(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = "purchase.unverified"
                    return
                }
                await accept(transaction)
                await transaction.finish()
                await refresh()
            case .pending: message = "purchase.pending"
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = "purchase.failed" }
    }

    func restore() async {
        guard !Launch.testing, !Launch.isFree, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh(clearMissingPro: true)
            if entitlement?.purchasedPro == true || entitlement?.trialClaimedAt != nil {
                message = "purchase.restored"
            } else {
                message = "purchase.nothing"
            }
        } catch { message = "purchase.restoreFailed" }
    }
}
