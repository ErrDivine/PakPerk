use super::{
    ChatAnswer, ChatSession, ChatTurn, ChatTurnRow, DbError, PaperId, PaperRepository,
    ProcessingGeneration, Uuid,
};

impl PaperRepository {
    pub async fn open_chat(
        &self,
        anonymous_session_id: Uuid,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        requested_thread_id: Option<Uuid>,
    ) -> Result<ChatSession, DbError> {
        let mut transaction = self.pool.begin().await?;
        let thread_id = if let Some(thread_id) = requested_thread_id {
            sqlx::query_scalar::<_, Uuid>(
                r"
                SELECT id
                FROM chat_threads
                WHERE id = $1
                  AND anonymous_session_id = $2
                  AND paper_id = $3
                  AND generation = $4
                ",
            )
            .bind(thread_id)
            .bind(anonymous_session_id)
            .bind(paper_id)
            .bind(generation)
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(DbError::InvalidChatThread)?
        } else {
            sqlx::query_scalar::<_, Uuid>(
                r"
                INSERT INTO chat_threads (
                    anonymous_session_id, paper_id, generation
                )
                VALUES ($1, $2, $3)
                RETURNING id
                ",
            )
            .bind(anonymous_session_id)
            .bind(paper_id)
            .bind(generation)
            .fetch_one(&mut *transaction)
            .await?
        };

        let mut rows = sqlx::query_as::<_, ChatTurnRow>(
            r"
            SELECT role, content
            FROM chat_messages
            WHERE thread_id = $1
            ORDER BY created_at DESC, id DESC
            LIMIT 12
            ",
        )
        .bind(thread_id)
        .fetch_all(&mut *transaction)
        .await?;
        rows.reverse();
        let recent_turns = rows
            .into_iter()
            .map(ChatTurn::try_from)
            .collect::<Result<_, _>>()?;
        transaction.commit().await?;
        Ok(ChatSession {
            thread_id,
            recent_turns,
        })
    }

    pub async fn persist_chat_exchange(
        &self,
        anonymous_session_id: Uuid,
        paper_id: PaperId,
        thread_id: Uuid,
        question: &str,
        answer: &ChatAnswer,
    ) -> Result<(), DbError> {
        let evidence = serde_json::to_value(&answer.evidence)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let mut transaction = self.pool.begin().await?;
        let valid_thread = sqlx::query_scalar::<_, bool>(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM chat_threads
                WHERE id = $1
                  AND anonymous_session_id = $2
                  AND paper_id = $3
            )
            ",
        )
        .bind(thread_id)
        .bind(anonymous_session_id)
        .bind(paper_id)
        .fetch_one(&mut *transaction)
        .await?;
        if !valid_thread {
            return Err(DbError::InvalidChatThread);
        }
        sqlx::query(
            r"
            INSERT INTO chat_messages (thread_id, role, content)
            VALUES ($1, 'user', $2)
            ",
        )
        .bind(thread_id)
        .bind(question)
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            INSERT INTO chat_messages (
                thread_id,
                role,
                content,
                source_metadata,
                provider_request_id,
                model_id,
                prompt_version
            )
            VALUES ($1, 'assistant', $2, $3, $4, $5, $6)
            ",
        )
        .bind(thread_id)
        .bind(&answer.answer_markdown)
        .bind(evidence)
        .bind(&answer.provider_request_id)
        .bind(&answer.model_id)
        .bind(&answer.prompt_version)
        .execute(&mut *transaction)
        .await?;
        sqlx::query("UPDATE chat_threads SET updated_at = now() WHERE id = $1")
            .bind(thread_id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(())
    }
}
