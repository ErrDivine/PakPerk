//! Deterministic metadata-only vectors for the inspectable semantic generator.
//!
//! This is deliberately a small, versioned feature-hashing contract rather
//! than an opaque model call. Only public paper metadata crosses this boundary;
//! full text, notes, annotations, account identity, and behavioral events
//! cannot be represented by [`MetadataEmbeddingInput`].

/// Persisted/audited algorithm identifier. Changing tokenization, field
/// weights, hashing, or dimensions requires a new version.
pub const METADATA_EMBEDDING_VERSION_V1: &str = "metadata_feature_hash_v1";

/// Bounded vector size used by the metadata-only semantic fallback.
pub const METADATA_EMBEDDING_DIMENSIONS_V1: usize = 128;

/// The complete public-metadata input allowed by the v1 embedding contract.
#[derive(Debug, Clone, Copy)]
pub struct MetadataEmbeddingInput<'a> {
    pub title: &'a str,
    pub abstract_text: &'a str,
    pub categories: &'a [String],
}

/// Produce a stable L2-normalized hashed bag-of-words vector.
///
/// Title and category terms receive explicit fixed weights so a long abstract
/// cannot erase the paper's primary metadata. FNV-1a is used as a stable index
/// function, not for security; the vector never serves as an identifier or
/// authentication primitive.
#[must_use]
pub fn metadata_embedding_v1(input: MetadataEmbeddingInput<'_>) -> Vec<f32> {
    let mut vector = vec![0.0; METADATA_EMBEDDING_DIMENSIONS_V1];
    add_tokens(&mut vector, input.title, 2.0);
    add_tokens(&mut vector, input.abstract_text, 1.0);
    for category in input.categories {
        add_tokens(&mut vector, category, 3.0);
    }
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    if norm > f32::EPSILON {
        for value in &mut vector {
            *value /= norm;
        }
    }
    vector
}

fn add_tokens(vector: &mut [f32], value: &str, weight: f32) {
    let mut token = String::new();
    for character in value.chars().flat_map(char::to_lowercase) {
        if character.is_alphanumeric() {
            token.push(character);
        } else {
            add_token(vector, &mut token, weight);
        }
    }
    add_token(vector, &mut token, weight);
}

fn add_token(vector: &mut [f32], token: &mut String, weight: f32) {
    if token.is_empty() {
        return;
    }
    let index = usize::try_from(stable_fnv1a(token.as_bytes()) % vector.len() as u64)
        .expect("the modulo result fits usize");
    vector[index] += weight;
    token.clear();
}

const fn stable_fnv1a(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    let mut index = 0;
    while index < bytes.len() {
        hash ^= bytes[index] as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        index += 1;
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_embedding_is_versioned_deterministic_and_normalized() {
        let categories = vec!["cs.AI".to_owned(), "cs.LG".to_owned()];
        let input = MetadataEmbeddingInput {
            title: "Auditable Semantic Retrieval",
            abstract_text: "Deterministic metadata vectors for research discovery.",
            categories: &categories,
        };
        let first = metadata_embedding_v1(input);
        let second = metadata_embedding_v1(input);

        assert_eq!(METADATA_EMBEDDING_VERSION_V1, "metadata_feature_hash_v1");
        assert_eq!(first, second);
        assert_eq!(first.len(), METADATA_EMBEDDING_DIMENSIONS_V1);
        assert!(first.iter().all(|value| value.is_finite()));
        assert!(first.iter().filter(|value| **value > 0.0).count() >= 8);
        let norm = first.iter().map(|value| value * value).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1.0e-6);
    }

    #[test]
    fn only_explicit_public_metadata_changes_the_vector() {
        let categories = vec!["cs.CL".to_owned()];
        let base = metadata_embedding_v1(MetadataEmbeddingInput {
            title: "Language Models",
            abstract_text: "A study of grounded generation.",
            categories: &categories,
        });
        let changed = metadata_embedding_v1(MetadataEmbeddingInput {
            title: "Language Models",
            abstract_text: "A study of retrieval augmented generation.",
            categories: &categories,
        });
        assert_ne!(base, changed);
    }
}
