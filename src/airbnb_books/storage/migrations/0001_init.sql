-- Placeholder so the migration runner is testable; replaced by the real schema.
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;
