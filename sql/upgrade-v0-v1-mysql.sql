/* Upgrade a CellCC database from version 0 to version 1 */

ALTER TABLE jobs ADD COLUMN errorlimit_mtime DATETIME AFTER mtime;
ALTER TABLE jobshist ADD COLUMN errorlimit_mtime DATETIME AFTER mtime;

INSERT INTO versions (version) VALUES (1);
