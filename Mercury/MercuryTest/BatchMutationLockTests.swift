import Testing
@testable import Mercury

@Suite("Batch Mutation Lock")
struct BatchMutationLockTests {
    @Test("All mutation domains are unlocked when no batch lifecycle is active")
    func domainsRemainUnlockedWhenBatchIsInactive() {
        let lock = BatchMutationLock(isTagBatchLifecycleActive: false)

        #expect(lock.blocksEntryMutations == false)
        #expect(lock.blocksFeedMutations == false)
        #expect(lock.blocksTagMutations == false)
    }

    @Test("All mutation domains are locked when batch lifecycle is active")
    func domainsLockWhenBatchIsActive() {
        let lock = BatchMutationLock(isTagBatchLifecycleActive: true)

        #expect(lock.blocksEntryMutations == true)
        #expect(lock.blocksFeedMutations == true)
        #expect(lock.blocksTagMutations == true)
    }
}
