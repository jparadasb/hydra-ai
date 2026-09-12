//! Worker-side privacy enforcement. Defense in depth: the coordinator routes by these same
//! rules, but the worker re-checks before dispatching every leased job.

use crate::config::{PrivacyPrefs, RoutingPolicy};
use crate::types::PrivacyLevel;

/// Decision about whether a job may run on a given backend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny(&'static str),
}

/// Does this worker accept jobs at `privacy` at all?
///
/// `accepted_job_levels` is advertised to the coordinator at registration, and the coordinator
/// routes by it — but the coordinator's word was previously final. An operator who configured
/// their machine to take only `public` work got no enforcement on their own machine. This is
/// the re-check, applied before any backend is chosen.
pub fn accepts_level(privacy: PrivacyLevel, prefs: &PrivacyPrefs) -> Decision {
    if prefs.accepted_job_levels.contains(&privacy) {
        Decision::Allow
    } else {
        match privacy {
            PrivacyLevel::Public => Decision::Deny("worker does not accept public jobs"),
            PrivacyLevel::Private => Decision::Deny("worker does not accept private jobs"),
            PrivacyLevel::Sensitive => Decision::Deny("worker does not accept sensitive jobs"),
            PrivacyLevel::LocalOnly => Decision::Deny("worker does not accept local_only jobs"),
        }
    }
}

/// May a job of `privacy` (with `allow_external` set by the job owner) run on a backend
/// where `uses_external_provider` indicates whether the call leaves the machine?
///
/// Rules:
/// * `local_only`  → external forbidden, always. Not configurable: the name is the contract.
/// * `sensitive`   → external only if the job owner permits it AND the operator has explicitly
///   added `sensitive` to `external_provider_allowed_privacy_levels`. Not in the default
///   policy, so the default answer is still no.
/// * `private`     → external only if the job owner explicitly permits it AND the worker
///   policy allows external for that privacy level.
/// * `public`      → any backend the worker policy allows.
pub fn check(
    privacy: PrivacyLevel,
    allow_external: bool,
    uses_external_provider: bool,
    policy: &RoutingPolicy,
) -> Decision {
    if !uses_external_provider {
        // Local model: allowed for every privacy level.
        return Decision::Allow;
    }

    // From here on the backend is an external provider.
    match privacy {
        PrivacyLevel::LocalOnly => Decision::Deny("local_only job cannot use external provider"),
        PrivacyLevel::Sensitive => {
            if !allow_external {
                Decision::Deny("sensitive job did not permit external providers")
            } else if !policy_allows_external(policy, PrivacyLevel::Sensitive) {
                Decision::Deny("worker policy disallows external for sensitive jobs")
            } else {
                Decision::Allow
            }
        }
        PrivacyLevel::Private => {
            if !allow_external {
                Decision::Deny("private job did not permit external providers")
            } else if !policy_allows_external(policy, PrivacyLevel::Private) {
                Decision::Deny("worker policy disallows external for private jobs")
            } else {
                Decision::Allow
            }
        }
        PrivacyLevel::Public => {
            if policy_allows_external(policy, PrivacyLevel::Public) {
                Decision::Allow
            } else {
                Decision::Deny("worker policy disallows external for public jobs")
            }
        }
    }
}

fn policy_allows_external(policy: &RoutingPolicy, level: PrivacyLevel) -> bool {
    policy
        .external_provider_allowed_privacy_levels
        .contains(&level)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Preference, RoutingPolicy};

    fn policy(levels: Vec<PrivacyLevel>) -> RoutingPolicy {
        RoutingPolicy {
            preference: Preference::PreferLocal,
            fallback_to_external_provider: true,
            external_provider_allowed_privacy_levels: levels,
        }
    }

    #[test]
    fn local_backend_always_allowed() {
        let p = policy(vec![]);
        for lvl in [
            PrivacyLevel::Public,
            PrivacyLevel::Private,
            PrivacyLevel::Sensitive,
            PrivacyLevel::LocalOnly,
        ] {
            assert_eq!(check(lvl, false, false, &p), Decision::Allow);
        }
    }

    #[test]
    fn local_only_never_external() {
        let p = policy(vec![PrivacyLevel::Public, PrivacyLevel::Private]);
        assert!(matches!(
            check(PrivacyLevel::LocalOnly, true, true, &p),
            Decision::Deny(_)
        ));
    }

    #[test]
    fn sensitive_never_external_by_default() {
        let p = policy(vec![PrivacyLevel::Public, PrivacyLevel::Private]);
        assert!(matches!(
            check(PrivacyLevel::Sensitive, true, true, &p),
            Decision::Deny(_)
        ));
    }

    #[test]
    fn private_needs_owner_and_policy() {
        let allow = policy(vec![PrivacyLevel::Public, PrivacyLevel::Private]);
        // owner permits + policy allows
        assert_eq!(
            check(PrivacyLevel::Private, true, true, &allow),
            Decision::Allow
        );
        // owner forbids
        assert!(matches!(
            check(PrivacyLevel::Private, false, true, &allow),
            Decision::Deny(_)
        ));
        // policy forbids private external
        let pub_only = policy(vec![PrivacyLevel::Public]);
        assert!(matches!(
            check(PrivacyLevel::Private, true, true, &pub_only),
            Decision::Deny(_)
        ));
    }

    #[test]
    fn default_policy_keeps_commercial_keys_private() {
        // Compliance guarantee: out of the box, an external provider serves `private` jobs
        // (owner opted in) but never `public` ones — a paid key is never used to answer
        // arbitrary requesters. See config::RoutingPolicy::default.
        let p = RoutingPolicy::default();
        assert!(matches!(
            check(PrivacyLevel::Public, true, true, &p),
            Decision::Deny(_)
        ));
        assert_eq!(
            check(PrivacyLevel::Private, true, true, &p),
            Decision::Allow
        );
    }

    #[test]
    fn public_follows_policy() {
        assert_eq!(
            check(
                PrivacyLevel::Public,
                false,
                true,
                &policy(vec![PrivacyLevel::Public])
            ),
            Decision::Allow
        );
        assert!(matches!(
            check(PrivacyLevel::Public, false, true, &policy(vec![])),
            Decision::Deny(_)
        ));
    }
}
