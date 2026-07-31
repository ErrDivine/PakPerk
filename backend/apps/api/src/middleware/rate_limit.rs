use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use tokio::sync::Mutex;

#[derive(Debug, Clone, Default)]
pub(crate) struct RateLimiter {
    buckets: Arc<Mutex<HashMap<(String, String), WindowBucket>>>,
}

#[derive(Debug, Clone, Copy)]
struct WindowBucket {
    started: Instant,
    count: u32,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct RateLimited;

impl RateLimiter {
    pub(crate) async fn check_all(
        &self,
        action: &str,
        keys: Vec<String>,
        limit: u32,
        window: Duration,
    ) -> Result<(), RateLimited> {
        for key in keys {
            self.check(action, key, limit, window).await?;
        }
        Ok(())
    }

    pub(crate) async fn check(
        &self,
        action: &str,
        key: String,
        limit: u32,
        window: Duration,
    ) -> Result<(), RateLimited> {
        let now = Instant::now();
        let mut buckets = self.buckets.lock().await;
        if buckets.len() > 10_000 {
            buckets.retain(|_, bucket| now.duration_since(bucket.started) < window);
        }
        let bucket = buckets
            .entry((action.to_owned(), key))
            .or_insert(WindowBucket {
                started: now,
                count: 0,
            });
        if now.duration_since(bucket.started) >= window {
            *bucket = WindowBucket {
                started: now,
                count: 0,
            };
        }
        if bucket.count >= limit {
            return Err(RateLimited);
        }
        bucket.count += 1;
        Ok(())
    }
}
