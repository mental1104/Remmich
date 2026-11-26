import Foundation
@testable import Remmich

/// 既有Worker/恢复/相簿组织用例的已许可合成输入边界；只隔离新增接续前置条件，原HTTP、回执与断言保持运行。
/// 真正接续门禁由PhotoBackupContinuityTests使用生产Checker和真实SQLite独立验证。
@MainActor struct SyntheticBackupPreflight: PhotoBackupPreflighting {
    /// jobs只含该例合成源；scope/client不用于访问真实服务器，progress/context仍按生产协议回调。
    func plan(jobs: [PhotoBackupJob], scope _: MediaAccountScope, client _: any PhotoBackupContinuityQuerying,
              progress: @MainActor (Int, Int) -> Void,
              validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
    {
        try Task.checkCancellation(); try validateContext()
        progress(jobs.count, jobs.count)
        return .init(allowed: Set(jobs.map(\.source)), existing: [], review: [])
    }
}
