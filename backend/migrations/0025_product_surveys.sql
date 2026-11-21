-- Voluntary product feedback. No account ID, device ID, name, or email is collected.
CREATE TABLE product_surveys (
    response_id uuid PRIMARY KEY,
    survey_version integer NOT NULL CHECK (survey_version = 1),
    locale text NOT NULL CHECK (locale IN ('en', 'zh')),
    ratings jsonb NOT NULL CHECK (jsonb_typeof(ratings) = 'object'),
    suggestions text NOT NULL DEFAULT '' CHECK (char_length(suggestions) <= 2000),
    submitted_at timestamptz NOT NULL DEFAULT now()
);
