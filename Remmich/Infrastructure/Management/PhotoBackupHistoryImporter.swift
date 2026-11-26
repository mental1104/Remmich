import Foundation
import SQLite3

/// 只读官方SQLite的最小标识/摘要字段；不执行迁移、不写源文件、不读取token或私人媒体。
nonisolated enum PhotoBackupHistoryImporter {
    /// url为用户明确选择的SQLite，scope为认证账号，now记录本次导入边界；后台读取并返回有限完整快照。
    @concurrent static func read(_ url: URL, scope: MediaAccountScope, now: Date = Date()) async throws -> PhotoBackupHistory {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            sqlite3_close(database); throw PhotoBackupContinuityError.invalidDatabase
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        let users = try rows(database, sql: "SELECT id FROM auth_user_entity NOT INDEXED", limit: 16)
        guard users.count == 1, users[0].count == 1, let user = users[0][0],
              UUID(uuidString: user) == UUID(uuidString: scope.userID), UUID(uuidString: user) != nil
        else {
            throw PhotoBackupContinuityError.wrongAccount
        }
        // 绕开导出文件可能失效的二级索引；不把远端旧关联当作当前存在证明，当前状态必须在线查询。
        let values = try rows(database, sql: "SELECT id,i_cloud_id,checksum,updated_at FROM local_asset_entity NOT INDEXED", limit: 200_000)
        let records = try values.map { row -> PhotoBackupHistoryRecord in
            try Task.checkCancellation()
            guard row.count == 4, let id = row[0], !id.isEmpty else { throw PhotoBackupContinuityError.invalidHistory }
            let date: Date? = row[3].flatMap { text in
                (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                    ?? (try? Date.ISO8601FormatStyle().parse(text))
            }
            return .init(localID: id, cloudID: row[1], checksum: row[2], modifiedAt: date)
        }
        let history = PhotoBackupHistory(version: 1, namespace: scope.cacheNamespace, userID: scope.userID, importedAt: now, records: records)
        try history.validate(scope: scope)
        try Task.checkCancellation()
        return history
    }

    /// database为本函数独占的只读句柄；sql只来自固定语句，limit限制行数，每行取消检查且拒绝异常SQLite结果。
    private static func rows(_ database: OpaquePointer, sql: String, limit: Int) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement); throw PhotoBackupContinuityError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard result.count < limit else { throw PhotoBackupContinuityError.invalidHistory }
                var row: [String?] = []
                for column in 0 ..< sqlite3_column_count(statement) {
                    guard sqlite3_column_bytes(statement, column) <= 4096 else { throw PhotoBackupContinuityError.invalidHistory }
                    row.append(sqlite3_column_text(statement, column).map { String(cString: $0) })
                }
                result.append(row)
            case SQLITE_DONE: return result
            default: throw PhotoBackupContinuityError.invalidDatabase
            }
        }
    }
}
