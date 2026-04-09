-- ScienceDaily MVP core schema
-- Source of truth: docs/PRD.md sections 7.2 and 7.3

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role_enum') THEN
        CREATE TYPE user_role_enum AS ENUM ('guest', 'user', 'operator', 'admin');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subject_enum') THEN
        CREATE TYPE subject_enum AS ENUM (
            'ai',
            'life_health',
            'brain_psychology',
            'society_behavior',
            'economy_finance',
            'environment_climate'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'content_type_enum') THEN
        CREATE TYPE content_type_enum AS ENUM ('article');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'rights_mode_enum') THEN
        CREATE TYPE rights_mode_enum AS ENUM ('link_only', 'excerpt_only', 'fulltext_authorized');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'article_status_enum') THEN
        CREATE TYPE article_status_enum AS ENUM (
            'draft',
            'pending_review',
            'published',
            'archived',
            'removed'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'reaction_type_enum') THEN
        CREATE TYPE reaction_type_enum AS ENUM ('like', 'favorite');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type_enum') THEN
        CREATE TYPE notification_type_enum AS ENUM (
            'system',
            'comment_reply',
            'comment_like',
            'report_update'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_context_type_enum') THEN
        CREATE TYPE ai_context_type_enum AS ENUM ('article', 'general');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'comment_status_enum') THEN
        CREATE TYPE comment_status_enum AS ENUM (
            'pending_review',
            'visible',
            'hidden',
            'blocked'
        );
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role user_role_enum NOT NULL DEFAULT 'guest',
    status text NOT NULL DEFAULT 'active',
    display_name text,
    avatar_url text,
    bio text,
    last_active_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_role_status
    ON users (role, status);

CREATE TABLE IF NOT EXISTS auth_identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    provider text NOT NULL,
    provider_uid text NOT NULL,
    phone text,
    email text,
    is_primary boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT auth_identities_provider_uid_key UNIQUE (provider, provider_uid)
);

CREATE INDEX IF NOT EXISTS idx_auth_identities_user_id
    ON auth_identities (user_id);

CREATE TABLE IF NOT EXISTS content_sources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    source_type text NOT NULL,
    base_url text NOT NULL,
    crawl_strategy text NOT NULL,
    copyright_mode rights_mode_enum NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    CONSTRAINT content_sources_base_url_key UNIQUE (base_url)
);

CREATE TABLE IF NOT EXISTS ingest_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid NOT NULL REFERENCES content_sources (id),
    status text NOT NULL DEFAULT 'pending',
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    fetched_count integer NOT NULL DEFAULT 0 CHECK (fetched_count >= 0),
    published_count integer NOT NULL DEFAULT 0 CHECK (published_count >= 0),
    error_payload jsonb
);

CREATE INDEX IF NOT EXISTS idx_ingest_jobs_source_started_at
    ON ingest_jobs (source_id, started_at DESC);

CREATE TABLE IF NOT EXISTS authors (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    author_type text NOT NULL,
    profile_url text,
    bio text,
    avatar_url text
);

CREATE INDEX IF NOT EXISTS idx_authors_name
    ON authors (name);

CREATE TABLE IF NOT EXISTS source_articles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid NOT NULL REFERENCES content_sources (id),
    source_url text NOT NULL,
    source_hash text NOT NULL,
    raw_title text NOT NULL,
    raw_html_path text,
    extracted_text text,
    published_at timestamptz,
    CONSTRAINT source_articles_source_url_key UNIQUE (source_url),
    CONSTRAINT source_articles_source_hash_key UNIQUE (source_hash)
);

CREATE INDEX IF NOT EXISTS idx_source_articles_source_id
    ON source_articles (source_id);

CREATE TABLE IF NOT EXISTS articles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug text NOT NULL,
    title text NOT NULL,
    summary text NOT NULL,
    author_id uuid REFERENCES authors (id) ON DELETE SET NULL,
    source_article_id uuid NOT NULL REFERENCES source_articles (id),
    subject subject_enum NOT NULL,
    content_type content_type_enum NOT NULL DEFAULT 'article',
    difficulty_level text,
    rights_mode rights_mode_enum NOT NULL,
    status article_status_enum NOT NULL DEFAULT 'draft',
    published_at timestamptz,
    reading_minutes integer CHECK (reading_minutes IS NULL OR reading_minutes > 0),
    canonical_url text,
    cover_image_url text,
    CONSTRAINT articles_slug_key UNIQUE (slug),
    CONSTRAINT articles_source_article_id_key UNIQUE (source_article_id)
);

CREATE INDEX IF NOT EXISTS idx_articles_status_subject_published_at
    ON articles (status, subject, published_at DESC);

CREATE INDEX IF NOT EXISTS idx_articles_search_fts
    ON articles
    USING GIN (
        (
            setweight(to_tsvector('simple', COALESCE(title, '')), 'A') ||
            setweight(to_tsvector('simple', COALESCE(summary, '')), 'B')
        )
    );

CREATE INDEX IF NOT EXISTS idx_articles_title_trgm
    ON articles
    USING GIN (title gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_articles_slug_trgm
    ON articles
    USING GIN (slug gin_trgm_ops);

CREATE TABLE IF NOT EXISTS article_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id uuid NOT NULL REFERENCES articles (id) ON DELETE CASCADE,
    version_no integer NOT NULL CHECK (version_no > 0),
    content_md text NOT NULL,
    content_html text,
    excerpt text,
    editor_note text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT article_versions_article_id_version_no_key UNIQUE (article_id, version_no)
);

CREATE TABLE IF NOT EXISTS tags (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    tag_type text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tags_name_tag_type_key UNIQUE (name, tag_type)
);

CREATE TABLE IF NOT EXISTS article_tags (
    article_id uuid NOT NULL REFERENCES articles (id) ON DELETE CASCADE,
    tag_id uuid NOT NULL REFERENCES tags (id) ON DELETE CASCADE,
    weight real NOT NULL DEFAULT 1.0 CHECK (weight >= 0),
    PRIMARY KEY (article_id, tag_id)
);

CREATE TABLE IF NOT EXISTS article_ai_assets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id uuid NOT NULL REFERENCES articles (id) ON DELETE CASCADE,
    asset_type text NOT NULL,
    prompt_version text NOT NULL,
    model_vendor text,
    model_name text,
    payload_json jsonb,
    status text NOT NULL DEFAULT 'pending',
    generated_at timestamptz,
    CONSTRAINT article_ai_assets_unique_version
        UNIQUE (article_id, asset_type, prompt_version)
);

CREATE TABLE IF NOT EXISTS user_reactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    reaction_type reaction_type_enum NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_reactions_unique_target
        UNIQUE (user_id, target_type, target_id, reaction_type)
);

CREATE TABLE IF NOT EXISTS comments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id uuid NOT NULL REFERENCES articles (id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    parent_id uuid REFERENCES comments (id) ON DELETE CASCADE,
    content text NOT NULL,
    status comment_status_enum NOT NULL DEFAULT 'pending_review',
    like_count integer NOT NULL DEFAULT 0 CHECK (like_count >= 0),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comments_article_created_at
    ON comments (article_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_comments_parent_id
    ON comments (parent_id);

CREATE TABLE IF NOT EXISTS feedback_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id uuid NOT NULL REFERENCES articles (id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    report_type text NOT NULL,
    reason_code text NOT NULL,
    description text,
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feedback_reports_article_status
    ON feedback_reports (article_id, status);

CREATE TABLE IF NOT EXISTS notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    type notification_type_enum NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    related_type text,
    related_id uuid,
    is_read boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_read_created_at
    ON notifications (user_id, is_read, created_at DESC);

CREATE TABLE IF NOT EXISTS ai_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    article_id uuid REFERENCES articles (id) ON DELETE SET NULL,
    context_type ai_context_type_enum NOT NULL,
    title text,
    model_vendor text,
    model_name text,
    last_message_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ai_sessions_context_article_check
        CHECK (
            (context_type = 'general' AND article_id IS NULL) OR
            (context_type = 'article' AND article_id IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS idx_ai_sessions_user_last_message_at
    ON ai_sessions (user_id, last_message_at DESC);

CREATE TABLE IF NOT EXISTS ai_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id uuid NOT NULL REFERENCES ai_sessions (id) ON DELETE CASCADE,
    role text NOT NULL,
    content text NOT NULL,
    citations_json jsonb,
    input_tokens integer CHECK (input_tokens IS NULL OR input_tokens >= 0),
    output_tokens integer CHECK (output_tokens IS NULL OR output_tokens >= 0),
    latency_ms integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_session_created_at
    ON ai_messages (session_id, created_at);

CREATE TABLE IF NOT EXISTS review_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id uuid NOT NULL REFERENCES articles (id),
    reviewer_id uuid NOT NULL REFERENCES users (id),
    action text NOT NULL,
    note text,
    before_payload jsonb,
    after_payload jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_review_records_article_created_at
    ON review_records (article_id, created_at DESC);

CREATE TABLE IF NOT EXISTS admin_audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operator_id uuid NOT NULL REFERENCES users (id),
    module text NOT NULL,
    action text NOT NULL,
    target_type text,
    target_id uuid,
    payload_json jsonb,
    ip inet,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_operator_created_at
    ON admin_audit_logs (operator_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_module_created_at
    ON admin_audit_logs (module, created_at DESC);
