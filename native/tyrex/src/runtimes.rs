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

/// Owns a runtime's slab entry and removes it exactly once, on drop.
///
/// Every path used to call `try_remove(runtime_id)` for itself — five sites in
/// `worker::run` plus three in `lib.rs` — and `slab::Slab` reuses vacated keys.
/// A panic during teardown therefore had a window in which the id had already
/// been surrendered and possibly reissued to a runtime started meanwhile, and
/// the unwind handler's unconditional `try_remove` would then unregister a
/// *different, healthy* runtime. Its `op_apply` would take the "could not find
/// pid" arm and every `Tyrex.apply` promise in that guest would hang forever,
/// silently and attributed to the wrong runtime.
///
/// Making the entry an owned value removes the class rather than narrowing the
/// window: drop order does the removal, once, on both the normal and the
/// unwinding path, and no caller has to remember.
pub struct Registration {
    id: usize,
}

impl Registration {
    pub fn insert(pid: rustler::LocalPid) -> Self {
        Registration {
            id: lock_or_recover().insert(pid),
        }
    }

    pub fn id(&self) -> usize {
        self.id
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        lock_or_recover().try_remove(self.id);
    }
}
