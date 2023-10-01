CREATE TABLE repos (
    repo_id    INTEGER      PRIMARY KEY NOT NULL,
    owner_name VARCHAR(39)              NOT NULL,
    repo_name  VARCHAR(100)             NOT NULL,

    UNIQUE (owner_name, repo_name)
);

CREATE TABLE branches (
    branch_id   INTEGER      PRIMARY KEY NOT NULL,
    branch_name VARCHAR(255)             NOT NULL,

    repo_id     INTEGER                  NOT NULL,
    FOREIGN KEY (repo_id) REFERENCES repos (repo_id),

    UNIQUE (branch_name, repo_id)
);

CREATE TABLE commits (
    commit_id   INTEGER     PRIMARY KEY NOT NULL,
    commit_hash VARCHAR(40)             NOT NULL,

    branch_id   INTEGER                 NOT NULL,
    FOREIGN KEY (branch_id) REFERENCES branches (branch_id),

    UNIQUE (commit_id, branch_id)
);

CREATE TABLE entries (
    entry_id      INTEGER     PRIMARY KEY                           NOT NULL,
    created_at    TIMESTAMP               DEFAULT CURRENT_TIMESTAMP NOT NULL,
    bucket_object VARCHAR(64)                                       NOT NULL,
    zig_version   VARCHAR(32)                                       NOT NULL,
    zls_version   VARCHAR(32)                                       NOT NULL,

    commit_id     INTEGER                                           NOT NULL,
    entry_set_id  INTEGER                                           NOT NULL,
    FOREIGN KEY (commit_id)    REFERENCES commits    (commit_id),
    FOREIGN KEY (entry_set_id) REFERENCES entry_sets (entry_set_id)
);

CREATE TABLE entry_sets (
    entry_set_id  INTEGER PRIMARY KEY NOT NULL,
    summary       TEXT                NOT NULL,

    UNIQUE (summary)
);