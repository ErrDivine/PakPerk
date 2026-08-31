//! Privacy-bounded research-profile policy and orchestration.
//!
//! This crate owns only future-discovery preferences and interests. Its store
//! contract deliberately has no library or reading-feed mutation, so profile
//! setup can never alter queue authority or unlock recommendations.

mod error;
mod model;
mod policy;
mod service;
mod store;

pub use error::{ResearchProfilePolicyError, ResearchProfileServiceError, StoreError};
pub use model::{
    AuthorFollowInput, DiscoveryMode, ExplicitCategoryInput, InterestGroup, InterestSource,
    MutationFingerprint, PreferredDiscoveryMode, ProfileAuthor, ProfileCategory, ProfileInterests,
    ProfileMutation, ProfileMutationKind, ProfileSettings, ProfileSettingsPatch, ProfileTopic,
    ResearchProfileSnapshot, ResetScope, Topic, TopicFollowInput, TopicPolarity,
};
pub use policy::{
    MAX_AUTHORS_PER_SOURCE, MAX_CATEGORIES_PER_SOURCE, MAX_CLEANUP_BATCH, MAX_TOPICS_PER_SOURCE,
    PROFILE_OPERATION_RETENTION, ResearchProfilePolicy,
};
pub use service::{
    DeleteAuthorCommand, DeleteTopicCommand, ResearchProfileService, ResetProfileCommand,
    UpdateProfileCommand, UpsertAuthorCommand, UpsertTopicCommand,
};
pub use store::{
    MutationRateDecision, ProfileMutationOutcome, ProfileOperationResolution, ProfileReadOutcome,
    ResearchProfileRateLimitStore, ResearchProfileStore,
};
