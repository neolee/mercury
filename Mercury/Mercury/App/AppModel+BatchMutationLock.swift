import Foundation

extension AppModel {
    var batchMutationLock: BatchMutationLock {
        BatchMutationLock(isTagBatchLifecycleActive: isTagBatchLifecycleActive)
    }
}
