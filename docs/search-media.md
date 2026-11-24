# Media search conditions

Native advanced filters now expose the existing Fork categories: phone videos, screenshots, Delta, Steam, Nintendo Switch and Nintendo 3DS screenshots. Panorama-only and 720p/1080p/2k/4k resolution tiers remain independent of the Photos/Videos selector. The server owns detection and resolution thresholds; the client sends the selected category's true-only boolean, `isPanorama.eq:true` and `resolution.eq`. No choice omits the corresponding field instead of sending false or a default tier.

Metadata search uses its existing cursor route. Smart text combined with any media extension uses the existing authenticated `POST /api/fork/search/smart`, complete structured filters and a separate Fork cursor on every page. A missing Fork route remains an explicit unsupported state; metadata validation errors remain visible. No condition is silently removed and there is no alternate-route retry.

The native saved-condition codec restores the existing Web `mediaCategory`, `resolution` and true-only `isPanorama` fields, including searches with only one such condition. Their JSON values are unchanged; false panorama conditions are rejected instead of dropped. Account/endpoint invalidation and generation checks use the existing search lifecycle.

Schema input remains pinned to Fork941aa1ca. Only eight properties in SearchFilter/SearchFilterBranch and MediaResolutionFilter/MediaResolution are copied, with exact owning-source equality. The raw upstream document and unrelated schema values remain unchanged. Preparation is byte-idempotent and generated Swift is produced by the existing plugin.

Added synthetic SDK requests cover every category/resolution pair in metadata and advanced smart, two pages, independent panorama/resolution, and omission of unselected fields. Native tests cover complete encoded saved-condition round trips and standalone conditions. NAS verification: source equality, whole-document comparison, preparation idempotence, Python syntax, scoped SwiftFormat0.64.5 lint and diff checks passed. Swift compilation, test execution, iPhone/iPad UI and physical-device acceptance are pending; no private media or production server was used.

Rollback: revert this client feature and its schema-input additions. Existing server presets and media remain intact. This does not implement special media viewers or complete the overall search stage.
