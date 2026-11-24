import Foundation

/// 保存/恢复失败必须明确，不用部分条件替代用户登记的完整查询。
nonisolated enum NativeSearchPresetConversionError: LocalizedError {
    case empty, unsupported, invalid

    var errorDescription: String? {
        switch self {
        case .empty: "Choose at least one search condition before saving."
        case .unsupported: "This saved search contains filters this app cannot apply yet. Its conditions have been preserved."
        case .invalid: "Some saved search conditions are invalid. Check dates, people, and numeric values."
        }
    }
}

/// 在原生查询与服务端原子登记之间转换；不包含分页、账号范围或网络副作用。
nonisolated enum NativeSearchPresetCodec {
    /// query为当前完整查询；返回无分页/身份字段的登记，空查询或非法值拒绝。
    static func capture(_ query: NativeSearchQuery) throws -> NativeSearchPresetConditions {
        var result = NativeSearchPresetConditions()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reference = query.queryAssetID {
            guard query.mode == .smart, text.isEmpty else { throw NativeSearchPresetConversionError.invalid }
            result.queryAssetId = reference
        }
        if !text.isEmpty {
            guard text.utf16.count <= 2000 else { throw NativeSearchPresetConversionError.invalid }
            let kind: NativeSearchPresetConditions.TextQuery.Kind = switch query.mode {
            case .fileName: .metadata
            case .description: .description
            case .fullPath: .fullPath
            case .ocr: .ocr
            case .smart: .smart
            }
            result.query = .init(value: text, type: kind)
        }
        result.city = query.city.isEmpty ? nil : query.city
        result.country = query.country.isEmpty ? nil : query.country
        result.state = query.state.isEmpty ? nil : query.state
        result.isFavorite = query.favoritesOnly ? true : nil
        result.isArchive = query.archivedOnly ? true : nil
        result.rating = switch query.rating { case .any: .missing; case .unrated: .null; case let .stars(value): .value(value) }
        result.make = query.cameraMake.isEmpty ? nil : query.cameraMake
        result.model = query.cameraModel.isEmpty ? nil : query.cameraModel
        result.deviceModels = query.deviceModels.isEmpty ? nil : query.deviceModels
        result.lensModel = query.lensModel.isEmpty ? nil : query.lensModel
        result.tagIds = switch query.tags { case .any: .missing; case .untagged: .null; case let .anyOf(ids): .value(ids) }
        result.personIds = query.personIDs.isEmpty ? nil : query.personIDs
        result.mediaType = switch query.media { case .all: nil; case .image: .image; case .video: .video }
        result.albumStatus = query.hasAlbums.map { $0 ? .inAlbum : .notInAlbum }
        result.orientation = query.orientation
        result.isPanorama = query.panoramasOnly ? true : nil
        result.mediaCategory = query.mediaCategory
        result.resolution = query.resolution
        result.exifConditions = query.exifConditions.isEmpty ? nil : query.exifConditions
        result.takenAfter = query.takenAfter.map { formatter(timeZone: query.timeZone).string(from: $0) }
        result.takenBefore = query.takenBefore.map { formatter(timeZone: query.timeZone).string(from: $0) }
        guard result.query != nil || result.queryAssetId != nil || result.city != nil || result.country != nil || result.state != nil || result.make != nil || result.model != nil
            || result.personIds != nil || result.mediaType != nil || result.albumStatus != nil
            || result.orientation != nil || result.exifConditions != nil || result.takenAfter != nil || result.takenBefore != nil
            || result.isFavorite != nil || result.isArchive != nil
            || result.lensModel != nil || result.rating != .missing || result.tagIds != .missing || result.deviceModels != nil
            || result.isPanorama != nil || result.mediaCategory != nil || result.resolution != nil
        else { throw NativeSearchPresetConversionError.empty }
        _ = try restore(result, timeZone: query.timeZone)
        return result
    }

    /// conditions为完整登记，timeZone为使用者的日历时区；返回独立查询，调用方一次性替换。
    /// 当前未支持的已知字段一律拒绝应用，不能在改名/预览时自动删掉它们。
    static func restore(_ conditions: NativeSearchPresetConditions, timeZone: TimeZone) throws -> NativeSearchQuery {
        var query = NativeSearchQuery()
        guard conditions.isArchive != false, conditions.isFavorite != false, conditions.isPanorama != false else { throw NativeSearchPresetConversionError.invalid }
        query.archivedOnly = conditions.isArchive == true
        query.favoritesOnly = conditions.isFavorite == true
        switch conditions.tagIds {
        case .missing: query.tags = .any
        case .null: query.tags = .untagged
        case let .value(ids):
            guard (1 ... 100).contains(ids.count), ids.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(ids.map { $0.lowercased() }).count == ids.count else { throw NativeSearchPresetConversionError.invalid }
            query.tags = .anyOf(ids)
        }
        switch conditions.rating {
        case .missing: query.rating = .any
        case .null: query.rating = .unrated
        case let .value(value):
            guard (0 ... 5).contains(value) else { throw NativeSearchPresetConversionError.invalid }
            query.rating = .stars(value)
        }
        query.timeZone = timeZone
        if let reference = conditions.queryAssetId {
            // 登记允许参考图，但不能把文字/参考图冲突或服务器不接受的UUID变成部分复用。
            guard conditions.query == nil, let uuid = UUID(uuidString: reference),
                  uuid.uuid.6 & 0xF0 == 0x40, uuid.uuid.8 & 0xC0 == 0x80 else { throw NativeSearchPresetConversionError.invalid }
            query.useReferenceAsset(reference)
        }
        if let text = conditions.query {
            guard !text.value.isEmpty, text.value.utf16.count <= 2000 else { throw NativeSearchPresetConversionError.invalid }
            query.text = text.value
            query.mode = switch text.type {
            case .metadata: .fileName
            case .description: .description
            case .fullPath: .fullPath
            case .ocr: .ocr
            case .smart: .smart
            }
        }
        for value in [conditions.country, conditions.state, conditions.city, conditions.make, conditions.model, conditions.lensModel].compactMap(\.self) {
            guard !value.isEmpty, value.utf16.count <= 256 else { throw NativeSearchPresetConversionError.invalid }
        }
        query.city = conditions.city ?? ""
        query.country = conditions.country ?? ""
        query.state = conditions.state ?? ""
        query.cameraMake = conditions.make ?? ""
        query.cameraModel = conditions.model ?? ""
        if let models = conditions.deviceModels {
            guard (1 ... 50).contains(models.count),
                  models.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 256 })
            else { throw NativeSearchPresetConversionError.invalid }
            query.deviceModels = models
        }
        query.lensModel = conditions.lensModel ?? ""
        if let people = conditions.personIds {
            guard (1 ... 100).contains(people.count), people.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw NativeSearchPresetConversionError.invalid }
            query.personIDs = people
        }
        query.media = switch conditions.mediaType { case .image?: .image; case .video?: .video; case nil: .all }
        query.hasAlbums = conditions.albumStatus.map { $0 == .inAlbum }
        query.orientation = conditions.orientation
        query.panoramasOnly = conditions.isPanorama == true
        query.mediaCategory = conditions.mediaCategory
        query.resolution = conditions.resolution
        if let exif = conditions.exifConditions {
            guard (1 ... 20).contains(exif.count), Set(exif.map(\.id)).count == exif.count,
                  exif.allSatisfy({ $0.value.isFinite && $0.value >= 0 }) else { throw NativeSearchPresetConversionError.invalid }
            query.exifConditions = exif
        }
        query.takenAfter = try conditions.takenAfter.map { try day($0, timeZone: timeZone) }
        query.takenBefore = try conditions.takenBefore.map { try day($0, timeZone: timeZone) }
        if let start = query.takenAfter, let end = query.takenBefore, start > end {
            throw NativeSearchPresetConversionError.invalid
        }
        return query
    }

    /// value必须是ISO日历日，timeZone决定本地午夜；拒绝宽松解析的无效日期。
    private static func day(_ value: String, timeZone: TimeZone) throws -> Date {
        let format = formatter(timeZone: timeZone)
        guard let result = format.date(from: value), format.string(from: result) == value else { throw NativeSearchPresetConversionError.invalid }
        return result
    }

    /// 返回独立的Gregorian/POSIX日期格式器，不跨线程共享可变Formatter。
    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        return format
    }
}
