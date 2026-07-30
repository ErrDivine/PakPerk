use unicode_normalization::UnicodeNormalization;

const MAX_CORE_TERMS: usize = 20;
const MAX_QUERY_TERMS: usize = 48;
const MAX_TERM_CHARACTERS: usize = 48;

/// Builds a bounded OR query suitable for `PostgreSQL`'s
/// `websearch_to_tsquery`.
///
/// User-supplied operators and punctuation are discarded: every emitted
/// operand is a normalized alphanumeric term, and the only operator this
/// function introduces is `OR`. The original content terms are followed by
/// small intent-specific expansions so that method and experiment passages
/// can compete in hybrid retrieval even when the embedding signal is weak.
pub fn keyword_websearch_query(question: &str) -> String {
    let words = normalized_words(question);
    let mut query = QueryTerms::default();

    for word in words
        .iter()
        .filter(|word| !is_stop_word(word))
        .take(MAX_CORE_TERMS)
    {
        query.push(word);
    }

    add_architecture_expansion(&words, &mut query);
    add_pretraining_expansion(&words, &mut query);
    add_downstream_expansion(&words, &mut query);
    add_training_choices_expansion(&words, &mut query);
    add_task_format_expansion(&words, &mut query);
    add_corpus_expansion(&words, &mut query);
    add_retrieval_memory_expansion(&words, &mut query);

    query.finish()
}

fn add_architecture_expansion(words: &[String], query: &mut QueryTerms) {
    if has_prefix(words, &["architect", "design", "recurr", "parallel"])
        || has_any(words, &["encoder", "decoder", "attention"])
    {
        query.extend(&[
            "architecture",
            "model",
            "network",
            "encoder",
            "decoder",
            "attention",
            "recurrence",
            "recurrent",
            "sequential",
            "computation",
            "parallel",
            "parallelization",
            "convolution",
        ]);
    }
}

fn add_pretraining_expansion(words: &[String], query: &mut QueryTerms) {
    if has_prefix(words, &["pretrain"])
        || (has_any(words, &["pre"]) && has_prefix(words, &["train"]))
    {
        query.extend(&[
            "pretraining",
            "pretrained",
            "objective",
            "masked",
            "masking",
            "language",
            "sentence",
            "prediction",
            "bidirectional",
            "representation",
            "training",
        ]);
    }
}

fn add_downstream_expansion(words: &[String], query: &mut QueryTerms) {
    let discusses_downstream_evaluation =
        has_prefix(words, &["downstream", "evaluat", "benchmark"])
            || (has_any(words, &["task", "tasks"])
                && has_prefix(words, &["classif", "perform", "result", "scor", "test"]));
    if discusses_downstream_evaluation {
        query.extend(&[
            "downstream",
            "evaluation",
            "benchmark",
            "task",
            "classification",
            "entailment",
            "question",
            "answering",
            "glue",
            "squad",
            "swag",
        ]);
    }
}

fn add_training_choices_expansion(words: &[String], query: &mut QueryTerms) {
    let discusses_training_choices = has_prefix(words, &["ablat"])
        || (has_prefix(words, &["train"]) && has_prefix(words, &["choice", "chang", "differ"]));
    if discusses_training_choices {
        query.extend(&[
            "training",
            "choice",
            "ablation",
            "masking",
            "dynamic",
            "sentence",
            "prediction",
            "nsp",
            "batch",
            "large",
            "larger",
            "data",
            "hyperparameter",
            "optimization",
            "duration",
            "undertrained",
            "performance",
            "scale",
            "sequence",
        ]);
    }
}

fn add_task_format_expansion(words: &[String], query: &mut QueryTerms) {
    let discusses_task_format = has_prefix(words, &["format", "cast", "unif"])
        || (has_any(words, &["task", "tasks"])
            && has_any(words, &["input", "target", "output", "text"]));
    if discusses_task_format {
        query.extend(&[
            "format", "task", "text", "input", "target", "output", "sequence", "prefix", "unified",
        ]);
    }
}

fn add_corpus_expansion(words: &[String], query: &mut QueryTerms) {
    if has_prefix(words, &["corpus", "corpora", "crawl", "dataset"]) {
        query.extend(&[
            "corpus",
            "dataset",
            "crawl",
            "crawled",
            "common",
            "clean",
            "cleaning",
            "filtering",
            "deduplication",
            "pretraining",
        ]);
    }
}

fn add_retrieval_memory_expansion(words: &[String], query: &mut QueryTerms) {
    let discusses_retrieval_memory = has_any(words, &["rag"])
        || has_prefix(words, &["retriev", "parametric", "nonparametric"])
        || (has_prefix(words, &["memory"]) && has_prefix(words, &["formulat", "combin", "differ"]));
    if discusses_retrieval_memory {
        query.extend(&[
            "rag",
            "retrieval",
            "retriever",
            "generator",
            "parametric",
            "nonparametric",
            "memory",
            "index",
            "dense",
            "vector",
            "neural",
            "passage",
            "document",
            "latent",
            "marginalization",
            "token",
            "sequence",
            "seq2seq",
        ]);
    }
}

#[derive(Default)]
struct QueryTerms {
    terms: Vec<String>,
}

impl QueryTerms {
    fn push(&mut self, term: &str) {
        if self.terms.len() >= MAX_QUERY_TERMS || self.terms.iter().any(|existing| existing == term)
        {
            return;
        }
        self.terms.push(term.to_owned());
    }

    fn extend(&mut self, terms: &[&str]) {
        for term in terms {
            self.push(term);
        }
    }

    fn finish(self) -> String {
        self.terms.join(" OR ")
    }
}

fn normalized_words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();

    for character in text.nfkc().flat_map(char::to_lowercase) {
        if character.is_alphanumeric() {
            if current.chars().count() < MAX_TERM_CHARACTERS {
                current.push(character);
            }
        } else if !current.is_empty() {
            words.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        words.push(current);
    }

    words
}

fn has_any(words: &[String], candidates: &[&str]) -> bool {
    words
        .iter()
        .any(|word| candidates.iter().any(|candidate| word == candidate))
}

fn has_prefix(words: &[String], prefixes: &[&str]) -> bool {
    words
        .iter()
        .any(|word| prefixes.iter().any(|prefix| word.starts_with(prefix)))
}

fn is_stop_word(word: &str) -> bool {
    const STOP_WORDS: &[&str] = &[
        "a", "about", "an", "and", "are", "as", "at", "be", "been", "by", "did", "do", "does",
        "for", "from", "had", "has", "have", "how", "in", "into", "is", "it", "its", "not", "of",
        "on", "one", "or", "paper", "study", "that", "the", "their", "these", "this", "those",
        "to", "two", "was", "were", "what", "when", "where", "which", "who", "why", "with",
    ];

    word.len() < 2 || STOP_WORDS.contains(&word)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terms(query: &str) -> Vec<&str> {
        if query.is_empty() {
            Vec::new()
        } else {
            query.split(" OR ").collect()
        }
    }

    fn assert_contains_all(query: &str, expected: &[&str]) {
        let actual = terms(query);
        for expected_term in expected {
            assert!(
                actual.contains(expected_term),
                "`{query}` should contain `{expected_term}`"
            );
        }
    }

    #[test]
    fn expands_architecture_and_recurrence_intent() {
        let query = keyword_websearch_query("Why does the architecture avoid recurrence?");

        assert_contains_all(
            &query,
            &[
                "architecture",
                "recurrence",
                "attention",
                "sequential",
                "parallelization",
            ],
        );
    }

    #[test]
    fn expands_pretraining_and_downstream_evaluation_intents() {
        let pretraining = keyword_websearch_query("How is the encoder pre-trained?");
        assert_contains_all(
            &pretraining,
            &["encoder", "pretraining", "masked", "sentence", "prediction"],
        );

        let downstream = keyword_websearch_query("What downstream tasks are evaluated?");
        assert_contains_all(
            &downstream,
            &["downstream", "evaluation", "benchmark", "glue", "squad"],
        );
    }

    #[test]
    fn expands_training_choice_and_ablation_intent() {
        let choices = keyword_websearch_query("Which training choices were changed?");
        assert_contains_all(
            &choices,
            &[
                "training",
                "ablation",
                "dynamic",
                "batch",
                "larger",
                "nsp",
                "hyperparameter",
                "undertrained",
                "performance",
            ],
        );

        let ablation = keyword_websearch_query("Summarize the ablation findings.");
        assert_contains_all(&ablation, &["ablation", "data", "optimization"]);
    }

    #[test]
    fn expands_task_format_and_corpus_intents() {
        let format = keyword_websearch_query("How are language tasks cast into one format?");
        assert_contains_all(&format, &["task", "format", "text", "input", "target"]);
        assert!(!terms(&format).contains(&"glue"));

        let corpus = keyword_websearch_query("How was the crawled corpus cleaned?");
        assert_contains_all(
            &corpus,
            &["corpus", "crawl", "common", "cleaning", "filtering"],
        );
    }

    #[test]
    fn expands_retrieval_memory_and_formulation_intents() {
        let memory =
            keyword_websearch_query("How are parametric and non-parametric memory combined?");
        assert_contains_all(
            &memory,
            &[
                "parametric",
                "nonparametric",
                "memory",
                "retriever",
                "dense",
                "vector",
                "neural",
                "seq2seq",
            ],
        );

        let formulations = keyword_websearch_query("How do the RAG formulations differ?");
        assert_contains_all(
            &formulations,
            &["rag", "marginalization", "token", "sequence"],
        );
    }

    #[test]
    fn strips_user_operators_and_bounds_the_safe_or_query() {
        let noisy = format!(
            r#""quoted phrase" -excluded OR (nested) <script> {}"#,
            (0..100)
                .map(|index| format!("term{index}"))
                .collect::<Vec<_>>()
                .join(" ")
        );
        let query = keyword_websearch_query(&noisy);
        let actual = terms(&query);

        assert!(actual.len() <= MAX_QUERY_TERMS);
        assert!(actual.iter().all(|term| !term.is_empty()));
        assert!(
            actual
                .iter()
                .all(|term| term.chars().all(char::is_alphanumeric))
        );
        assert!(!actual.contains(&"or"));
        assert!(!query.contains('"'));
        assert!(!query.contains('-'));
        assert_eq!(query, keyword_websearch_query(&noisy));
    }

    #[test]
    fn keeps_generic_content_terms_without_unrelated_expansion() {
        let query = keyword_websearch_query("Where is calibration uncertainty discussed?");

        assert_eq!(query, "calibration OR uncertainty OR discussed");
    }

    #[test]
    fn returns_an_empty_query_when_there_are_no_lexical_terms() {
        assert!(keyword_websearch_query("??? — !!!").is_empty());
    }
}
