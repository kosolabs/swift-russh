use std::sync::LazyLock;

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .thread_name("russh-ffi")
        .enable_all()
        .build()
        .expect("failed to start the tokio runtime")
});

struct AbortOnDrop<T>(JoinHandle<T>);

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Runs `future` on the shared runtime. Dropping the returned future, which is
/// what a cancelled Swift task does, aborts the work.
pub(crate) async fn run<F>(future: F) -> F::Output
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    let mut task = AbortOnDrop(RUNTIME.spawn(future));
    match (&mut task.0).await {
        Ok(output) => output,
        Err(error) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
        Err(error) => panic!("russh-ffi task ended unexpectedly: {error}"),
    }
}

pub(crate) fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    RUNTIME.spawn(future)
}
