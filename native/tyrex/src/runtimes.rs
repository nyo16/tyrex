use slab::Slab;
use std::sync::{Mutex, MutexGuard, OnceLock};

pub fn get() -> &'static Mutex<Slab<rustler::LocalPid>> {
    static RUNTIMES: OnceLock<Mutex<Slab<rustler::LocalPid>>> = OnceLock::new();
    RUNTIMES.get_or_init(|| Mutex::new(Slab::new()))
}

/// Acquire the runtimes slab mutex, recovering the inner guard if a previous
/// holder panicked while holding the lock. Poisoning here is non-fatal: the
/// slab is a simple map of `runtime_id -> LocalPid` and any partial mutation
/// is safe to observe (an insert that didn't return a key just leaks the
/// slot temporarily; a remove that didn't complete leaves a stale pid that
/// will be overwritten or never used).
pub fn lock_or_recover() -> MutexGuard<'static, Slab<rustler::LocalPid>> {
    match get().lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}
