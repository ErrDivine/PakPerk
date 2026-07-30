use std::{future::Future, sync::OnceLock, time::Duration};

use tokio::{
    sync::Mutex,
    time::{Instant, sleep_until},
};

/// Serializes operations and spaces their start times. The client uses
/// [`RateGate::global`] so constructing multiple clients cannot bypass the
/// process-wide arXiv limit. This is intentionally not a cross-process lock;
/// multi-process deployments also need a database-backed reservation.
#[derive(Debug, Default)]
pub struct RateGate {
    last_started: Mutex<Option<Instant>>,
}

impl RateGate {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn global() -> &'static Self {
        static GATE: OnceLock<RateGate> = OnceLock::new();
        GATE.get_or_init(Self::new)
    }

    /// Space operation start times. The mutex is released immediately after
    /// recording the start; slow responses may overlap and cannot delay a
    /// later operation past a separately coordinated cross-process permit.
    pub async fn run<T, F, Fut>(&self, minimum_interval: Duration, operation: F) -> T
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = T>,
    {
        let queued_at = Instant::now();
        {
            let mut last_started = self.last_started.lock().await;
            if let Some(previous) = *last_started {
                let next_allowed = previous + minimum_interval;
                if next_allowed > Instant::now() {
                    sleep_until(next_allowed).await;
                }
            }
            *last_started = Some(Instant::now());
        }
        tracing::info!(
            metric.name = "arxiv_rate_gate",
            arxiv.request_count = 1_u64,
            arxiv.wait_ms = queued_at.elapsed().as_millis(),
            gate.scope = "process",
            "process arXiv request permit granted"
        );
        operation().await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };

    use tokio::sync::{Mutex as TokioMutex, Notify};

    use super::*;

    #[tokio::test]
    async fn spaces_operation_starts() {
        let gate = Arc::new(RateGate::new());
        let starts = Arc::new(TokioMutex::new(Vec::new()));
        let mut tasks = Vec::new();
        for _ in 0..3 {
            let gate = Arc::clone(&gate);
            let starts = Arc::clone(&starts);
            tasks.push(tokio::spawn(async move {
                gate.run(Duration::from_millis(15), || async {
                    starts.lock().await.push(Instant::now());
                })
                .await;
            }));
        }
        for task in tasks {
            task.await.unwrap();
        }
        let starts = starts.lock().await;
        assert_eq!(starts.len(), 3);
        assert!(starts[1].duration_since(starts[0]) >= Duration::from_millis(15));
        assert!(starts[2].duration_since(starts[1]) >= Duration::from_millis(15));
    }

    #[tokio::test]
    async fn slow_response_does_not_hold_the_start_time_gate() {
        let gate = Arc::new(RateGate::new());
        let first_started = Arc::new(Notify::new());
        let first_finished = Arc::new(AtomicBool::new(false));
        let task = {
            let gate = Arc::clone(&gate);
            let first_started = Arc::clone(&first_started);
            let first_finished = Arc::clone(&first_finished);
            tokio::spawn(async move {
                gate.run(Duration::ZERO, || async {
                    first_started.notify_one();
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    first_finished.store(true, Ordering::SeqCst);
                })
                .await;
            })
        };
        first_started.notified().await;
        gate.run(Duration::ZERO, || async {
            assert!(!first_finished.load(Ordering::SeqCst));
        })
        .await;
        task.await.unwrap();
    }
}
