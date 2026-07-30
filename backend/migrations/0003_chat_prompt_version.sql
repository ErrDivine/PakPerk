ALTER TABLE chat_messages
    ADD COLUMN prompt_version text;

-- Existing assistant rows predate prompt provenance, so validate this
-- constraint only for new writes. The repository always supplies a prompt
-- version for assistant messages and leaves it null for user messages.
ALTER TABLE chat_messages
    ADD CONSTRAINT chat_messages_prompt_version_role_check
    CHECK (
        (role = 'user' AND prompt_version IS NULL)
        OR (
            role = 'assistant'
            AND prompt_version IS NOT NULL
            AND btrim(prompt_version) <> ''
        )
    ) NOT VALID;
