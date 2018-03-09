DROP TABLE IF EXISTS versions;
DROP TABLE IF EXISTS jobs;

CREATE TABLE versions (
    version INT UNSIGNED,
    PRIMARY KEY (version)
) ENGINE=InnoDB;

INSERT INTO versions (version) VALUES (0);

CREATE TABLE jobs (
    /* pkey */
    id BIGINT UNSIGNED AUTO_INCREMENT,
    PRIMARY KEY (id),
        
    /* The cell we're copying the volume from. */
    src_cell VARCHAR(255) NOT NULL,
    INDEX(src_cell),

    /* The cell we're copying to. */
    dst_cell VARCHAR(255) NOT NULL,
    INDEX(dst_cell),

    /* The name of the volume we're copying. */
    volname VARCHAR(255) NOT NULL,

    /* The 'Last Update' time for the volume in the destination cell, if we are
     * configured to use incremental dumps. */
    vol_lastupdate BIGINT NOT NULL DEFAULT 0,

    /* What queue this job is for. */
    qname VARCHAR(255) NOT NULL,
    
    /* dataversion for the row. this helps ensure that only one process will
     * handle a job at a time. */
    dv INT UNSIGNED NOT NULL,

    /* the number of times this job has encountered a fatal error. this can
     * happen multiple times, since a job can be retried after it has error'd
     * out (up to a limit). */
    errors INT UNSIGNED NOT NULL DEFAULT 0,

    /* state that the job is in, e.g. NEW, DUMPING, etc. */
    state VARCHAR(255) NOT NULL,
    INDEX(state),

    /* if this job has a reset pending (because a stage failed), we need to
     * keep track of the last 'good' state, so we know what state to reset
     * the job to. store that here. */
    last_good_state VARCHAR(255),

    /* Hostname holding a dump, when a dump host has finished dumping the vol */
    dump_fqdn VARCHAR(255),

    /* Method via which we can retrieve the dump from dump_fqdn (e.g. "remctl") */
    dump_method VARCHAR(255),

    /* Port to use with the above method. */
    dump_port INT UNSIGNED,

    /* filename the dump is in on the 'dump' host */
    dump_filename VARCHAR(255),

    /* filename the dump is in on the 'restore' host */
    restore_filename VARCHAR(255),

    /* checksum for the dump blob. this should be of the form e.g.
     * "MD5:ca425b88f047ce8ec45ee90e813ada91"
     * which could be more space-efficient, but who cares. note that this does
     * not need to be a cryptographically-secure hash; we just want to detect
     * errors and computation of this should be fast. */
    dump_checksum VARCHAR(255),

    /* Size of the dump */
    dump_filesize BIGINT UNSIGNED,

    /* The time this job was created. */
    ctime DATETIME NOT NULL,

    /* The last time this job was touched. */
    mtime DATETIME NOT NULL,

    /* How soon the current stage thinks it will provide an update, in X
     * seconds from now. If this amount of time has passed, this is flagged as
     * an error and the job is possibly dead or is hanging on something. A NULL
     * timeout means the last stage doesn't control the next update (it's
     * passing it off to the next stage), so we don't know what an applicable
     * timeout is. */
    timeout INT UNSIGNED,

    /* The hostname that last updated this job. */
    status_fqdn VARCHAR(255),

    /* Human-readable description of the status of what's going on with the
     * current stage in this job. */
    description TEXT NOT NULL,

    /* Only allow one job for per volume-sync. This means that if a volume
     * gets 'stuck' or errored while syncing, we won't try to start a new sync
     * until the old one is deleted or restarted/finished/etc. That is, we
     * won't have multiple syncs for the same volume in flight at once. */
    UNIQUE KEY dst_cell_volname_unique (dst_cell, volname)
) ENGINE=InnoDB;

/* Create a copy of the 'jobs' table that is used for archiving completed jobs.
 * This is identical to the jobs table, except we are allowed to have duplicate
 * pairs of (dst_cell, volname). */
CREATE TABLE jobshist LIKE jobs;
ALTER TABLE jobshist DROP INDEX dst_cell_volname_unique;
