// `AmuxSessionSwitcherSnapshot` was removed together with the coordinator's
// `changes()` AsyncStream. The session switcher now observes the coordinator's
// `@Observable` state directly (`items`, `loadingHosts`, `failedHosts`,
// `hostCount`, `revision`), so there is no separate immutable snapshot payload
// to carry over a stream — production and tests read the one observable path.
//
// This file is intentionally left with no declarations because it is still
// referenced by the Xcode project; removing the reference is a separate change.
