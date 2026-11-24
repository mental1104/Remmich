# Remmich downstream development

- `upstream` is Ender-Wang/Remmich. `main` tracks upstream/main with fast-forward merges only. Personal changes and builds live on `dev`; merge main into dev, never dev into main. Preserve history; stop on conflicts.
- Parent repository is mental1104/immich, NAS integration branch `dev`. Pin this repository as submodule `clients/remmich`, tracking `dev`. Push the child commit before the parent gitlink.
- Keep official Immich clients compatible. Never change existing server API paths, authorization, DTO fields or semantics for this client. Use separate authenticated `/api/fork/...` routes for incompatible requirements; absence must degrade safely. Do not deploy NAS changes implicitly.
- This fork is a full client: backup, edits and management are explicitly authorized. Implement narrowly scoped writes with permission-aware contracts, account/endpoint generation checks, cancellation and visible confirmation for destructive actions. Never permanently delete assets or overwrite originals implicitly. Never log credentials or private media.
- Use existing Swift patterns, focused tests and one build at a time. On the 8 GB Mac prefer `-jobs 1`; preserve build caches and monitor free space. Do not skip global plugin/security checks.
- Update `change.log` and `docs/fork-compatibility.md` with actual checks and explicitly unverified features. Never claim API compatibility proves real-device acceptance.
