# qui automations: retention policy

Automation rules for qBittorrent, managed by [qui](https://github.com/autobrr/qui).

Requires **qui >= v1.34.0**: earlier versions do not find a cross-seed's original when the two have different titles, so `CROSS_SEED_TAGS` sees nothing and rule 11 deletes cross-seeds whose original still exists.

## Model

Only **original** torrents drive retention. Cross-seeds are "free": they follow their original and never carry retention tags.

- **Original**: category in `tv|movies|audio|comics|seedonly` (no `.cross` suffix).
- **Cross-seed**: category `<category>.cross`, always tagged `cross-seed`. Hardlinked to the original by qui's cross-seed.
- **`keep`** protects a torrent from tagging and deletion. On deletion rules it protects the whole group (`CROSS_SEED_TAGS`): a `keep` on any member keeps all of them.
- All durations use `SEEDING_TIME` (trackers count seeding time for H&R, not calendar time), except alert rules and rule 12, which use the age since added.
- No hardlink checks against the media library (media is remuxed before import).

## Policy

- **Goal**: `UPLOADED_OVER_SIZE >= 2` and seed >= 30d.
- **Hard cap**: seed >= 180d.

Thresholds in seconds: 3d = `259200`, 7d = `604800`, 8d = `691200`, 30d = `2592000`, 90d = `7776000`, 180d = `15552000`.

## Rules

### Alert tags (01-05)

| Rule | Tag | Applies to | Condition |
|---|---|---|---|
| 01 | `unregistered` | all (notifies) | tracker reports the torrent as unregistered |
| 02 | `stalled` | all (notifies) | not complete, not stopped, and either `stalled_downloading` for >= 3d since added or >= 7d since added |
| 03 | `stopped` | all | stopped, added >= 7d ago, no `keep`, and either complete or not a `.cross` category |
| 04 | `error` | all | missing files, or state `errored` / `missingFiles` |
| 05 | `no-policy` | all | category does not match `^(tv\|movies\|audio\|comics\|seedonly)(\.cross)?$` |

### Retention tags (06-08, originals only, mutually exclusive)

| Rule | Tag | Condition |
|---|---|---|
| 06 | `goal-pending` | seed < 90d and (seed < 30d or ratio < 2) |
| 07 | `goal-met` | seed >= 30d, ratio >= 2 and seed < 180d |
| 08 | `cap-only` | seed >= 90d, ratio < 2 and seed < 180d |

Rules 06-08 skip torrents tagged `keep`. Tags swap automatically (`full` mode). **Do not disable 06-08**: rule 11 relies on them to tell a live cross-seed from an orphan.

### Deletions (09-13)

Delete rules run hourly and are **first match wins**, in the order 09, 10, 11, 12, 13. All use `deleteWithFilesPreserveCrossSeeds`: deleting an original does not touch its cross-seeds, rule 11 removes them afterwards.

| Rule | Deletes | Condition |
|---|---|---|
| 09 | Original at end of life | no `keep` in group, and (seed >= 30d, ratio >= 2, inactive >= 3d) **or** (seed >= 90d and (ratio >= 2 or inactive >= 3d)) |
| 10 | Original at hard cap | no `keep` in group, seed >= 180d |
| 11 | Orphan cross-seed | managed `.cross` category, `cross-seed` tag, none of `goal-pending` / `goal-met` / `cap-only` / `keep` in its group, own seed >= 8d |
| 12 | Stuck partial cross-seed | any `.cross` category, stopped, progress < 100%, added >= 7d ago, no `keep` |
| 13 | `seedonly` buffer | category `seedonly`, tag `build-buffer`, no `keep` in group, seed >= 8d |

Consequences:

- Goal met: removed after 3d of inactivity (between 30d and 90d), or unconditionally at 90d.
- Goal not met: removed at 90d+ only if inactive for 3d, otherwise it lives until the hard cap.
- Cross-seeds disappear right after their original (usually within the next hourly run, as they are added 1-2d after it).
- The 8d seed guard on rule 11 protects against tracker H&R, since cross-seeds that download extra small files may report `completed`.
- Orphans (original removed by hand) are also caught by rule 11.
- Rule 13 deletes only the original; its `seedonly.cross` cross-seeds are then removed by rule 11.

Known limitation of rule 11: a cross-seed is linked to its original by name, title key or **exactly equal total size**. A cross-seed with a different title **and** a different total size (extra or missing files) is not recognized, looks orphaned, and is deleted after 8d of seed. Only that cross-seed is lost: the original and its files are untouched.

## Dry-run

All rules are live (`dryRun: false`). When adding or changing a delete rule, set `dryRun` to `true` first and check the preview in the UI before enabling it. To debug the matching, set the qui log level to `trace` and look for `crossseed: release metadata candidate evaluated`.
