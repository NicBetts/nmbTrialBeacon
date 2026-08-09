# TrialBeacon (iOS)

Privacy-first, **fully offline** clinical-trial discovery for iPhone. Bundles a ClinicalTrials.gov–derived SQLite database; user data stays in on-device SwiftData. No account required.

**Repo:** [NicBetts/nmbTrialBeacon](https://github.com/NicBetts/nmbTrialBeacon)  
**Companion generator:** macOS `nmbTrialBeaconDB` (separate project) produces `trialbeacon.sqlite`.

## Docs

| Document | What’s in it |
|---|---|
| **[APPLICATION_STATUS.md](APPLICATION_STATUS.md)** | What shipped, what we skipped, and why |
| **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** | Current shipping schema (**v14**) overview |
| [TRIALBEACON_APP.md](TRIALBEACON_APP.md) | Full product / UX / architecture spec |
| [TRIALBEACON_DATABASE.md](TRIALBEACON_DATABASE.md) | Deep DB integration guide |
| [IOS_CHANGES_schema_v14.md](IOS_CHANGES_schema_v14.md) | Latest schema delta (see also v10–v13) |
| [CONVERSATION_HANDOFF.md](CONVERSATION_HANDOFF.md) | Recent product decisions handoff |

## Requirements

- Xcode targeting **iOS 26+**
- Bundled **`nmbTrialBeacon/trialbeacon.sqlite`** (schema **13–14**; prefer **14**) — **not** in this git repo (too large). Build with the generator and place per `nmbTrialBeacon/README_DATABASE.md`.

## Tabs

Home · Discover · Watchlist · Analytics · Settings

## License / attribution

Clinical trial records originate from [ClinicalTrials.gov](https://clinicaltrials.gov/). The app is an independent browser of a derived offline dataset.
