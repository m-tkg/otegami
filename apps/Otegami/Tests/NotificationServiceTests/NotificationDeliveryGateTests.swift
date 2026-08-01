import Testing

@Suite("NotificationDeliveryGate")
struct NotificationDeliveryGateTests {
    @Test("delivery is claimed once and late enrichment cannot mutate delivered content")
    func oneShotDeliveryRejectsLateMutation() {
        let gate = NotificationDeliveryGate()
        var mutationCount = 0

        #expect(gate.withPending { mutationCount += 1 })
        #expect(gate.claimDelivery())
        #expect(!gate.claimDelivery())
        #expect(!gate.withPending { mutationCount += 1 })
        #expect(mutationCount == 1)
    }
}
