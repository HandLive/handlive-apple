import Testing
@testable import HLTransport

/// `PinAttemptCounter` (PAIR-01 C3, E7): the wrong-PIN budget shared by reference between the LAN exchange
/// (`PairingExchange`) and the Bluetooth search (`BtPinPairingSearch`) racing for the same code
/// (`BluetoothFallbackPairingSearch`), so a guess spent on either transport is never lost to the other side's
/// cancellation (Trang's finding, #3932).
@Suite("Shared PIN attempt counter (PAIR-01 C3)")
struct PinAttemptCounterTests {
    @Test("Spending counts down and clamps at zero, never going negative")
    func spendClampsAtZero() async {
        let counter = PinAttemptCounter(left: 2)
        #expect(await counter.spend() == 1)
        #expect(await counter.spend() == 0)
        #expect(await counter.spend() == 0)
        #expect(await counter.left == 0)
    }

    @Test("Spends from two transports racing at the same time never add up to more than the starting budget")
    func concurrentSpendsStayWithinBudget() async {
        let counter = PinAttemptCounter(left: 3)
        async let lan: [Int] = {
            var results: [Int] = []
            for _ in 0..<2 { results.append(await counter.spend()) }
            return results
        }()
        async let bluetooth: [Int] = {
            var results: [Int] = []
            for _ in 0..<2 { results.append(await counter.spend()) }
            return results
        }()
        let (lanResults, bluetoothResults) = await (lan, bluetooth)
        let all = (lanResults + bluetoothResults).sorted(by: >)
        // 4 spends against a budget of 3: the actor serializes them, so the fourth always finds nothing left.
        #expect(all == [2, 1, 0, 0])
        #expect(await counter.left == 0)
    }
}
