//! Locks that survive a panic.
//!
//! `std`'s `Mutex` and `RwLock` poison themselves when a thread panics while holding the lock,
//! and every later `lock()`/`write()` returns `Err`. The worker used `.unwrap()` and
//! `.expect("… lock poisoned")` at every one of those call sites, so a single panic inside an
//! adapter task turned a recoverable failure into a permanently dead worker: every subsequent
//! job panicked on acquire.
//!
//! Poisoning is a warning about the *data*, not a reason to stop. The state behind these locks
//! is a model catalog, a request counter and a usage rollup — a torn write costs one wrong
//! number, which is strictly better than refusing to run anything ever again. So these take the
//! inner value back and carry on.

use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// `RwLock`, ignoring poison.
pub trait RwLockExt<T> {
    fn read_recover(&self) -> RwLockReadGuard<'_, T>;
    fn write_recover(&self) -> RwLockWriteGuard<'_, T>;
}

impl<T> RwLockExt<T> for RwLock<T> {
    fn read_recover(&self) -> RwLockReadGuard<'_, T> {
        self.read().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write_recover(&self) -> RwLockWriteGuard<'_, T> {
        self.write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// `Mutex`, ignoring poison.
pub trait MutexExt<T> {
    fn lock_recover(&self) -> MutexGuard<'_, T>;
}

impl<T> MutexExt<T> for Mutex<T> {
    fn lock_recover(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn a_panic_while_holding_a_lock_does_not_disable_it() {
        let lock = Arc::new(Mutex::new(vec![1, 2, 3]));

        let poisoner = Arc::clone(&lock);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.lock().unwrap();
            panic!("adapter task blew up");
        })
        .join();

        assert!(lock.lock().is_err(), "the lock really is poisoned");

        // …and the worker can still use it. `.unwrap()` here is what turned one adapter panic
        // into a worker that failed every subsequent job.
        assert_eq!(*lock.lock_recover(), vec![1, 2, 3]);
    }

    #[test]
    fn an_rwlock_recovers_for_both_kinds_of_access() {
        let lock = Arc::new(RwLock::new(String::from("catalog")));

        let poisoner = Arc::clone(&lock);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.write().unwrap();
            panic!("catalog refresh blew up");
        })
        .join();

        assert_eq!(&*lock.read_recover(), "catalog");
        lock.write_recover().push_str("-refreshed");
        assert_eq!(&*lock.read_recover(), "catalog-refreshed");
    }
}
