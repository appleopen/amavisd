USING SQL FOR LOOKUPS, LOG/REPORTING AND QUARANTINE
===================================================

This text contains general SQL-related documentation. For aspects
specific to using SQL database for lookups, please see README.lookups .

Since amavisd-new-20020630 SQL is supported for lookups.
Since amavisd-new-2.3.0 SQL is also supported for storing information
about processed mail (logging/reporting) and optionally for quarantining
to a SQL database.

The amavisd.conf variables @storage_sql_dsn and @lookup_sql_dsn control
access to a SQL server and specify a database (dsn = data source name).
The @lookup_sql_dsn enables and specifies a database for lookups,
the @storage_sql_dsn enables and specifies a database for reporting
and quarantining. Both settings are independent.

Interpretation of @lookup_sql_dsn and @storage_sql_dsn lists is as follows:
- empty list disables the function and is a default;
- if both lists are empty no SQL support code will be compiled-in,
  reducing the amount of virtual memory needed for each child process;
- a list can contain one or more triples: [dsn,user,passw]; more than one
  triple may be specified to specify multiple (backup) SQL servers - the first
  that responds will be used as long as it works, then search is retried;
- if both lists contain refs to the _same_ triples (not just equal triples),
  only one connection to a SQL server will be used; otherwise two independent
  connections to databases will be used, possibly to different SQL servers,
  which may even be of different type (e.g. SQLlite for lookups (read-only),
  and PostgreSQL or MySQL for transactional reporting, offering fine lock
  granularity).

Example setting:
  @lookup_sql_dsn =
  ( ['DBI:mysql:database=mail;host=127.0.0.1;port=3306', 'user1', 'passwd1'],
    ['DBI:mysql:database=mail;host=host2', 'username2', 'password2'],
    ['DBI:Pg:database=mail;host=host1', 'amavis', '']
    ["DBI:SQLite:dbname=$MYHOME/sql/mail_prefs.sqlite", '', ''] );

  @storage_sql_dsn = @lookup_sql_dsn;  # none, same, or separate database

See man page for the Perl module DBI, and corresponding DBD modules
man pages (DBD::mysql, DBD::Pg, DBD::SQLite, ...) for syntax of the
first argument.

Since version 2.3.0 amavisd-new also offers quarantining to a SQL database,
along with a mechanism to release quarantined messages (either from SQL or
from normal files, possibly gzipped). To enable quarantining to SQL, the
@storage_sql_dsn must be enabled (facilitating quarantine management), and
some or all variables $virus_quarantine_method, $spam_quarantine_method,
$banned_files_quarantine_method and $bad_header_quarantine_method should
specify the value 'sql:'. Specifying 'sql:' as a quarantine method without
also specifying a database in @storage_sql_dsn is an error.

When setting up access controls to a database, keep in mind that amavisd-new
only needs read-only access to the database used for lookups, the permission
to do a SELECT suffices. For security reasons it is undesirable to permit
other operations such as INSERT, DELETE or UPDATE to a dataset used for
lookups. For managing the lookups database one should preferably use a
different username with more privileges.

The database specified in @storage_sql_dsn needs to provide read/write access
(SELECT, INSERT, UPDATE), and a database server offering transactions
must be used.


Below is an example that can be used with MySQL or PostgreSQL or SQLite.
The provided schema can be cut/pasted or fed directly into the client program
to create a database. The '--' introduces comments according to SQL specs.

-- MySQL notes:
--   - SERIAL can be used instead of INT UNSIGNED NOT NULL AUTO_INCREMENT
--     with databases which do not recognize AUTO_INCREMENT;
--     The attribute SERIAL was introduced with MySQL 4.1.0, but it
--     implicitly creates an additional UNIQUE index, which is redundant.
--   - instead of declaring a time_iso field in table msgs as a string:
--       time_iso char(16) NOT NULL,
--     one may want to declare is as:
--       time_iso TIMESTAMP NOT NULL DEFAULT 0,
--     in which case $timestamp_fmt_mysql *MUST* be set to 1 in amavisd.conf
--     to avoid MySQL inability to accept ISO 8601 timestamps with zone Z
--     and ISO date/time delimiter T; failing to set $timestamp_fmt_mysql
--     makes MySQL store zero time on INSERT and write current local time
--     on UPDATE if auto-update is allowed, which is different from the
--     intended mail timestamp (localtime vs. UTC, off by seconds)
--   - field quarantine.mail_text should be of data type 'blob' and not 'text'
--     as suggested in older documentation; this is to prevent it from being
--     unjustifiably associated with a character set, and to be able to
--     store any byte value; to convert existing field from type 'text'
--     to type 'blob' the following clause may be used:
--       ALTER TABLE quarantine CHANGE mail_text mail_text blob;

-- PostgreSQL notes (initially provided by Phil Regnauld):
--   - use SERIAL instead of INT UNSIGNED NOT NULL AUTO_INCREMENT
--   - remove the 'unsigned' throughout,
--   - remove the 'ENGINE=InnoDB' throughout,
--   - instead of declaring time_iso field in table msgs as a string:
--         time_iso char(16) NOT NULL,
--       it is more useful to declare it as:
--         time_iso TIMESTAMP WITH TIME ZONE NOT NULL,
--       if changing existing table from char to timestamp is desired,
--       the following clause may be used:
--         ALTER TABLE msgs ALTER time_iso
--           TYPE TIMESTAMP WITH TIME ZONE
--           USING to_timestamp(time_iso,'YYYYMMDDTHH24MMSSTZ');
--   - field quarantine.mail_text should be of data type 'bytea' and not 'text'
--     as suggested in older documentation; this is to prevent it from being
--     unjustifiably associated with a character set, and to be able to
--     store any byte value; to convert existing field from type 'text'
--     to type 'bytea' the following clause may be used:
--         ALTER TABLE quarantine ALTER mail_text TYPE bytea
--           USING decode(replace(mail_text,'\\','\\\\'),'escape');
--   - version of Perl module DBD::Pg 1.48 or higher should be used;
--   - create an amavis username and the database (choose name, e.g. mail)
--       $ createuser -U pgsql --no-adduser --createdb amavis
--       $ createdb -U amavis mail
--   - populate the database using the schema below:
--       $ psql -U amavis mail < amavisd-pg.sql

-- SQLite notes:
--   - use INTEGER PRIMARY KEY AUTOINCREMENT
--     instead of INT UNSIGNED NOT NULL AUTO_INCREMENT;
--   - replace SERIAL by INTEGER;
--   - SQLite is well suited for lookups database, but is not appropriate
--     for @storage_sql_dsn due to coarse lock granularity;

-- local users
CREATE TABLE users (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,  -- unique id
  priority   integer      NOT NULL DEFAULT '7',  -- sort field, 0 is low prior.
  policy_id  integer unsigned NOT NULL DEFAULT '1',  -- JOINs with policy.id
  email      varchar(255) NOT NULL UNIQUE,
  fullname   varchar(255) DEFAULT NULL,    -- not used by amavisd-new
  local      char(1)      -- Y/N  (optional field, see note further down)
);

-- any e-mail address (non- rfc2822-quoted), external or local,
-- used as senders in wblist
CREATE TABLE mailaddr (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  priority   integer      NOT NULL DEFAULT '7',  -- 0 is low priority
  email      varchar(255) NOT NULL UNIQUE
);

-- per-recipient whitelist and/or blacklist,
-- puts sender and recipient in relation wb  (white or blacklisted sender)
CREATE TABLE wblist (
  rid        integer unsigned NOT NULL,  -- recipient: users.id
  sid        integer unsigned NOT NULL,  -- sender: mailaddr.id
  wb         varchar(10)  NOT NULL,  -- W or Y / B or N / space=neutral / score
  PRIMARY KEY (rid,sid)
);

CREATE TABLE policy (
  id  INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                                    -- 'id' this is the _only_ required field
  policy_name      varchar(32),     -- not used by amavisd-new, a comment

  virus_lover          char(1) default NULL,     -- Y/N
  spam_lover           char(1) default NULL,     -- Y/N
  banned_files_lover   char(1) default NULL,     -- Y/N
  bad_header_lover     char(1) default NULL,     -- Y/N

  bypass_virus_checks  char(1) default NULL,     -- Y/N
  bypass_spam_checks   char(1) default NULL,     -- Y/N
  bypass_banned_checks char(1) default NULL,     -- Y/N
  bypass_header_checks char(1) default NULL,     -- Y/N

  spam_modifies_subj   char(1) default NULL,     -- Y/N

  virus_quarantine_to      varchar(64) default NULL,
  spam_quarantine_to       varchar(64) default NULL,
  banned_quarantine_to     varchar(64) default NULL,
  bad_header_quarantine_to varchar(64) default NULL,
  clean_quarantine_to      varchar(64) default NULL,
  other_quarantine_to      varchar(64) default NULL,

  spam_tag_level  float default NULL, -- higher score inserts spam info headers
  spam_tag2_level float default NULL, -- inserts 'declared spam' header fields
  spam_kill_level float default NULL, -- higher score triggers evasive actions
                                      -- e.g. reject/drop, quarantine, ...
                                     -- (subject to final_spam_destiny setting)
  spam_dsn_cutoff_level        float default NULL,
  spam_quarantine_cutoff_level float default NULL,

  addr_extension_virus      varchar(64) default NULL,
  addr_extension_spam       varchar(64) default NULL,
  addr_extension_banned     varchar(64) default NULL,
  addr_extension_bad_header varchar(64) default NULL,

  warnvirusrecip      char(1)     default NULL, -- Y/N
  warnbannedrecip     char(1)     default NULL, -- Y/N
  warnbadhrecip       char(1)     default NULL, -- Y/N
  newvirus_admin      varchar(64) default NULL,
  virus_admin         varchar(64) default NULL,
  banned_admin        varchar(64) default NULL,
  bad_header_admin    varchar(64) default NULL,
  spam_admin          varchar(64) default NULL,
  spam_subject_tag    varchar(64) default NULL,
  spam_subject_tag2   varchar(64) default NULL,
  message_size_limit  integer     default NULL, -- max size in bytes, 0 disable
  banned_rulenames    varchar(64) default NULL  -- comma-separated list of ...
        -- names mapped through %banned_rules to actual banned_filename tables
);



-- R/W part of the dataset (optional)
--   May reside in the same or in a separate database as lookups database;
--   REQUIRES SUPPORT FOR TRANSACTIONS; specified in @storage_sql_dsn
--
--   MySQL note ( http://dev.mysql.com/doc/mysql/en/storage-engines.html ):
--     ENGINE is the preferred term, but cannot be used before MySQL 4.0.18.
--     TYPE is available beginning with MySQL 3.23.0, the first version of
--     MySQL for which multiple storage engines were available. If you omit
--     the ENGINE or TYPE option, the default storage engine is used.
--     By default this is MyISAM.
--
--  Please create additional indexes on keys when needed, or drop suggested
--  ones as appropriate to optimize queries needed by a management application.
--  See your database documentation for further optimization hints. With MySQL
--  see Chapter 15 of the reference manual. For example the chapter 15.17 says:
--  InnoDB does not keep an internal count of rows in a table. To process a
--  SELECT COUNT(*) FROM T statement, InnoDB must scan an index of the table,
--  which takes some time if the index is not entirely in the buffer pool.


-- provide unique id for each e-mail address, avoids storing copies
CREATE TABLE maddr (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  email      varchar(255) NOT NULL UNIQUE, -- full mail address
  domain     varchar(255) NOT NULL     -- only domain part of the email address
                                       -- with subdomain fields in reverse
) ENGINE=InnoDB;

-- information pertaining to each processed message as a whole;
-- NOTE: records with NULL msgs.content should be ignored by utilities,
--   as such records correspond to messages just being processes, or were lost
-- NOTE: with PostgreSQL, instead of a character field time_iso, please use:
--   time_iso TIMESTAMP WITH TIME ZONE NOT NULL,
-- NOTE: with MySQL, instead of a character field time_iso, one might prefer:
--   time_iso TIMESTAMP NOT NULL DEFAULT 0,
--   but the following MUST then be set in amavisd.conf: $timestamp_fmt_mysql=1
CREATE TABLE msgs (
  mail_id    varchar(12)   NOT NULL PRIMARY KEY,  -- long-term unique mail id
  secret_id  varchar(12)   DEFAULT '',  -- authorizes release of mail_id
  am_id      varchar(20)   NOT NULL,    -- id used in the log
  time_num   integer unsigned NOT NULL, -- rx_time: seconds since Unix epoch
  time_iso   char(16)      NOT NULL,    -- rx_time: ISO8601 UTC ascii time
  sid        integer unsigned NOT NULL, -- sender: maddr.id
  policy     varchar(255)  DEFAULT '',  -- policy bank path (like macro %p)
  client_addr varchar(255) DEFAULT '',  -- SMTP client IP address (IPv4 or v6)
  size       integer unsigned NOT NULL, -- message size in bytes
  content    char(1),                   -- content type: V/B/S/s/M/H/O/C:
                                        -- virus/banned/spam(kill)/spammy(tag2)
                                        -- /bad mime/bad header/oversized/clean
                                        -- is NULL on partially processed mail
  quar_type  char(1),                   -- quarantined as: ' '/F/Z/B/Q/M
                                        --  none/file/zipfile/bsmtp/sql/mailbox
  quar_loc   varchar(255)  DEFAULT '',  -- quarantine location (e.g. file)
  dsn_sent   char(1),                   -- was DSN sent? Y/N/q (q=quenched)
  spam_level float,                     -- SA spam level (no boosts)
  message_id varchar(255)  DEFAULT '',  -- mail Message-ID header field
  from_addr  varchar(255)  DEFAULT '',  -- mail From header field,    UTF8
  subject    varchar(255)  DEFAULT '',  -- mail Subject header field, UTF8
  host       varchar(255)  NOT NULL,    -- hostname where amavisd is running
  FOREIGN KEY (sid) REFERENCES maddr(id) ON DELETE RESTRICT
) ENGINE=InnoDB;
CREATE INDEX msgs_idx_sid      ON msgs (sid);
CREATE INDEX msgs_idx_time_num ON msgs (time_num);
-- alternatively when purging based on time_iso (instead of msgs_idx_time_num):
-- CREATE INDEX msgs_idx_time_iso ON msgs (time_iso);

-- per-recipient information related to each processed message;
-- NOTE: records in msgrcpt without corresponding msgs.mail_id record are
--  orphaned and should be ignored and eventually deleted by external utilities
CREATE TABLE msgrcpt (
  mail_id    varchar(12)   NOT NULL,     -- (must allow duplicates)
  rid        integer unsigned NOT NULL,  -- recipient: maddr.id (dupl. allowed)
  ds         char(1)       NOT NULL,     -- delivery status: P/R/B/D/T
                                         -- pass/reject/bounce/discard/tempfail
  rs         char(1)       NOT NULL,     -- release status: initialized to ' '
  bl         char(1)       DEFAULT ' ',  -- sender blacklisted by this recip
  wl         char(1)       DEFAULT ' ',  -- sender whitelisted by this recip
  bspam_level float,                     -- spam level + per-recip boost
  smtp_resp  varchar(255)  DEFAULT '',   -- SMTP response given to MTA
  FOREIGN KEY (rid)     REFERENCES maddr(id)     ON DELETE RESTRICT,
  FOREIGN KEY (mail_id) REFERENCES msgs(mail_id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE INDEX msgrcpt_idx_mail_id  ON msgrcpt (mail_id);
CREATE INDEX msgrcpt_idx_rid      ON msgrcpt (rid);

-- mail quarantine in SQL, enabled by $*_quarantine_method='sql:'
-- NOTE: records in quarantine without corresponding msgs.mail_id record are
--  orphaned and should be ignored and eventually deleted by external utilities
CREATE TABLE quarantine (
  mail_id    varchar(12)   NOT NULL,    -- long-term unique mail id
  chunk_ind  integer unsigned NOT NULL, -- chunk number, starting with 1
  mail_text  blob NOT NULL,  -- store mail as chunks (in PostgreSQL use: bytea)
  PRIMARY KEY (mail_id,chunk_ind),
  FOREIGN KEY (mail_id) REFERENCES msgs(mail_id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- field msgrcpt.rs is primarily intended for use by quarantine management
-- software; the value assigned by amavisd is a space;
-- a short _preliminary_ list of possible values:
--   'V' => viewed (marked as read)
--   'R' => released (delivered) to this recipient
--   'p' => pending (a status given to messages when the admin received the
--                   request but not yet released; targeted to banned parts)
--   'D' => marked for deletion; a cleanup script may delete it


-- =====================
-- Example data follows:
-- =====================
INSERT INTO users VALUES ( 1, 9, 5, 'user1+foo@y.example.com','Name1 Surname1', 'Y');
INSERT INTO users VALUES ( 2, 7, 5, 'user1@y.example.com', 'Name1 Surname1', 'Y');
INSERT INTO users VALUES ( 3, 7, 2, 'user2@y.example.com', 'Name2 Surname2', 'Y');
INSERT INTO users VALUES ( 4, 7, 7, 'user3@z.example.com', 'Name3 Surname3', 'Y');
INSERT INTO users VALUES ( 5, 7, 7, 'user4@example.com',   'Name4 Surname4', 'Y');
INSERT INTO users VALUES ( 6, 7, 1, 'user5@example.com',   'Name5 Surname5', 'Y');
INSERT INTO users VALUES ( 7, 5, 0, '@sub1.example.com', NULL, 'Y');
INSERT INTO users VALUES ( 8, 5, 7, '@sub2.example.com', NULL, 'Y');
INSERT INTO users VALUES ( 9, 5, 5, '@example.com',      NULL, 'Y');
INSERT INTO users VALUES (10, 3, 8, 'userA', 'NameA SurnameA anywhere', 'Y');
INSERT INTO users VALUES (11, 3, 9, 'userB', 'NameB SurnameB', 'Y');
INSERT INTO users VALUES (12, 3,10, 'userC', 'NameC SurnameC', 'Y');
INSERT INTO users VALUES (13, 3,11, 'userD', 'NameD SurnameD', 'Y');
INSERT INTO users VALUES (14, 3, 0, '@sub1.example.net', NULL, 'Y');
INSERT INTO users VALUES (15, 3, 7, '@sub2.example.net', NULL, 'Y');
INSERT INTO users VALUES (16, 3, 5, '@example.net',      NULL, 'Y');
INSERT INTO users VALUES (17, 7, 5, 'u1@example.org',    'u1', 'Y');
INSERT INTO users VALUES (18, 7, 6, 'u2@example.org',    'u2', 'Y');
INSERT INTO users VALUES (19, 7, 3, 'u3@example.org',    'u3', 'Y');

-- INSERT INTO users VALUES (20, 0, 5, '@.',             NULL, 'N');  -- catchall

INSERT INTO policy (id, policy_name,
  virus_lover, spam_lover, banned_files_lover, bad_header_lover,
  bypass_virus_checks, bypass_spam_checks,
  bypass_banned_checks, bypass_header_checks, spam_modifies_subj,
  spam_tag_level, spam_tag2_level, spam_kill_level) VALUES
  (1, 'Non-paying',    'N','N','N','N', 'Y','Y','Y','N', 'Y', 3.0,   7, 10),
  (2, 'Uncensored',    'Y','Y','Y','Y', 'N','N','N','N', 'N', 3.0, 999, 999),
  (3, 'Wants all spam','N','Y','N','N', 'N','N','N','N', 'Y', 3.0, 999, 999),
  (4, 'Wants viruses', 'Y','N','Y','Y', 'N','N','N','N', 'Y', 3.0, 6.9, 6.9),
  (5, 'Normal',        'N','N','N','N', 'N','N','N','N', 'Y', 3.0, 6.9, 6.9),
  (6, 'Trigger happy', 'N','N','N','N', 'N','N','N','N', 'Y', 3.0,   5, 5),
  (7, 'Permissive',    'N','N','N','Y', 'N','N','N','N', 'Y', 3.0,  10, 20),
  (8, '6.5/7.8',       'N','N','N','N', 'N','N','N','N', 'N', 3.0, 6.5, 7.8),
  (9, 'userB',         'N','N','N','Y', 'N','N','N','N', 'Y', 3.0, 6.3, 6.3),
  (10,'userC',         'N','N','N','N', 'N','N','N','N', 'N', 3.0, 6.0, 6.0),
  (11,'userD',         'Y','N','Y','Y', 'N','N','N','N', 'N', 3.0,   7, 7);

-- sender envelope addresses needed for white/blacklisting
INSERT INTO mailaddr VALUES (1, 5, '@example.com');
INSERT INTO mailaddr VALUES (2, 9, 'owner-postfix-users@postfix.org');
INSERT INTO mailaddr VALUES (3, 9, 'amavis-user-admin@lists.sourceforge.net');
INSERT INTO mailaddr VALUES (4, 9, 'makemoney@example.com');
INSERT INTO mailaddr VALUES (5, 5, '@example.net');
INSERT INTO mailaddr VALUES (6, 9, 'spamassassin-talk-admin@lists.sourceforge.net');
INSERT INTO mailaddr VALUES (7, 9, 'spambayes-bounces@python.org');

-- whitelist for user 14, i.e. default for recipients in domain sub1.example.net
INSERT INTO wblist VALUES (14, 1, 'W');
INSERT INTO wblist VALUES (14, 3, 'W');

-- whitelist and blacklist for user 17, i.e. u1@example.org
INSERT INTO wblist VALUES (17, 2, 'W');
INSERT INTO wblist VALUES (17, 3, 'W');
INSERT INTO wblist VALUES (17, 6, 'W');
INSERT INTO wblist VALUES (17, 7, 'W');
INSERT INTO wblist VALUES (17, 5, 'B');
INSERT INTO wblist VALUES (17, 4, 'B');

-- $sql_select_policy setting in amavisd.conf tells amavisd
-- how to fetch per-recipient policy settings.
-- See comments there. Example:
--
-- SELECT *,users.id FROM users,policy
--   WHERE (users.policy_id=policy.id) AND (users.email IN (%k))
--   ORDER BY users.priority DESC;
--
-- $sql_select_white_black_list in amavisd.conf tells amavisd
-- how to check sender in per-recipient whitelist/blacklist.
-- See comments there. Example:
--
-- SELECT wb FROM wblist,mailaddr
--   WHERE (wblist.rid=?) AND (wblist.sid=mailaddr.id) AND (mailaddr.email IN (%k))
--   ORDER BY mailaddr.priority DESC;



-- NOTE: the SELECT, INSERT and UPDATE clauses as used by the amavisd-new
-- program are configurable through %sql_clause; see amavisd.conf-default



Some examples of a query:

-- mail from last two minutes (MySQL):
SELECT
  UNIX_TIMESTAMP()-msgs.time_num AS age, SUBSTRING(policy,1,2) as pb,
  content AS c, dsn_sent as dsn, ds, bspam_level AS level, size,
  SUBSTRING(sender.email,1,18) AS s,
  SUBSTRING(recip.email,1,18)  AS r,
  SUBSTRING(msgs.subject,1,10) AS subj
  FROM msgs LEFT JOIN msgrcpt         ON msgs.mail_id=msgrcpt.mail_id
            LEFT JOIN maddr AS sender ON msgs.sid=sender.id
            LEFT JOIN maddr AS recip  ON msgrcpt.rid=recip.id
  WHERE content IS NOT NULL AND UNIX_TIMESTAMP()-msgs.time_num < 120
  ORDER BY msgs.time_num DESC;

-- mail from last two minutes (PostgreSQL):
SELECT
  now()-time_iso AS age, SUBSTRING(policy,1,2) as pb,
  content AS c, dsn_sent as dsn, ds, bspam_level AS level, size,
  SUBSTRING(sender.email,1,18) AS s,
  SUBSTRING(recip.email,1,18)  AS r,
  SUBSTRING(msgs.subject,1,10) AS subj
  FROM msgs LEFT JOIN msgrcpt         ON msgs.mail_id=msgrcpt.mail_id
            LEFT JOIN maddr AS sender ON msgs.sid=sender.id
            LEFT JOIN maddr AS recip  ON msgrcpt.rid=recip.id
  WHERE content IS NOT NULL AND now() - time_iso < INTERVAL '2 minutes'
  ORDER BY msgs.time_num DESC;

-- clean messages ordered by count, grouped by domain:
SELECT count(*) as cnt, avg(bspam_level), sender.domain
  FROM msgs
  LEFT JOIN msgrcpt ON msgs.mail_id=msgrcpt.mail_id
  LEFT JOIN maddr AS sender ON msgs.sid=sender.id
  LEFT JOIN maddr AS recip ON msgrcpt.rid=recip.id
  WHERE content='C'
  GROUP BY sender.domain ORDER BY cnt DESC LIMIT 50;

-- top spamy domains with >10 messages, sorted by spam average,
-- grouped by domain:
SELECT count(*) as cnt, avg(bspam_level) as spam_avg, sender.domain
  FROM msgs
  LEFT JOIN msgrcpt ON msgs.mail_id=msgrcpt.mail_id
  LEFT JOIN maddr AS sender ON msgs.sid=sender.id
  LEFT JOIN maddr AS recip ON msgrcpt.rid=recip.id
  WHERE bspam_level IS NOT NULL
  GROUP BY sender.domain HAVING count(*) > 10
  ORDER BY spam_avg DESC LIMIT 50;

-- sender domains with >100 messages, sorted on sender.domain:
SELECT count(*) as cnt, avg(bspam_level) as spam_avg, sender.domain
  FROM msgs
  LEFT JOIN msgrcpt ON msgs.mail_id=msgrcpt.mail_id
  LEFT JOIN maddr AS sender ON msgs.sid=sender.id
  LEFT JOIN maddr AS recip ON msgrcpt.rid=recip.id
  GROUP BY sender.domain HAVING count(*) > 100
  ORDER BY sender.domain DESC LIMIT 100;




Upgrading from pre 2.4.0 amavisd-new SQL schema to the 2.4.0 schema requires
adding column 'quar_loc' to table msgs, and creating FOREIGN KEY constraint
to facilitate deletion of expired records.

The following clauses should be executed for upgrading pre-2.4.0 amavisd-new
SQL schema to the 2.4.0 schema:

-- mandatory change:
  ALTER TABLE msgs ADD quar_loc varchar(255) DEFAULT '';

-- optional but highly recommended:
  ALTER TABLE quarantine
    ADD FOREIGN KEY (mail_id) REFERENCES msgs(mail_id) ON DELETE CASCADE;
  ALTER TABLE msgrcpt
    ADD FOREIGN KEY (mail_id) REFERENCES msgs(mail_id) ON DELETE CASCADE;

-- the following two ALTERs are not essential; if data type of maddr.id is
-- incompatible with msgs.sid and msgs.rid (e.g. BIGINT vs. INT) and MySQL
-- complains, don't bother to apply the constraint:
  ALTER TABLE msgs
    ADD FOREIGN KEY (sid) REFERENCES maddr(id) ON DELETE RESTRICT;
  ALTER TABLE msgrcpt
    ADD FOREIGN KEY (rid) REFERENCES maddr(id) ON DELETE RESTRICT;


BRIEF MySQL EXAMPLE of a log/report/quarantine database housekeeping
====================================================================

DELETE FROM msgs WHERE time_num < UNIX_TIMESTAMP() - 14*24*60*60;
DELETE FROM msgs WHERE time_num < UNIX_TIMESTAMP() - 60*60 AND content IS NULL;
DELETE FROM maddr
  WHERE NOT EXISTS (SELECT 1 FROM msgs    WHERE sid=id)
    AND NOT EXISTS (SELECT 1 FROM msgrcpt WHERE rid=id);


BRIEF MySQL EQUIVALENT EXAMPLE based on time_iso if its data type is TIMESTAMPS
===============================================================================
(don't forget to set: $timestamp_fmt_mysql=1 in amavisd.conf)

DELETE FROM msgs WHERE time_iso < UTC_TIMESTAMP() - INTERVAL 14 day;
DELETE FROM msgs WHERE time_iso < UTC_TIMESTAMP() - INTERVAL 1 hour
  AND content IS NULL;
DELETE FROM maddr
  WHERE NOT EXISTS (SELECT 1 FROM msgs    WHERE sid=id)
    AND NOT EXISTS (SELECT 1 FROM msgrcpt WHERE rid=id);


BRIEF PostgreSQL EXAMPLE of a log/report/quarantine database housekeeping
=========================================================================

DELETE FROM msgs WHERE time_iso < now() - INTERVAL '14 days';
DELETE FROM msgs WHERE time_iso < now() - INTERVAL '1 h' AND content IS NULL;
DELETE FROM maddr
  WHERE NOT EXISTS (SELECT 1 FROM msgs    WHERE sid=id)
    AND NOT EXISTS (SELECT 1 FROM msgrcpt WHERE rid=id);


COMMENTED LONGER EXAMPLE of a log/report/quarantine database housekeeping
=========================================================================

--  discarding indexes makes deletion faster; if we expect a large proportion
--  of records to be deleted it may be quicker to discard index, do deletions,
--  and re-create index (not necessary with PostgreSQL, may benefit MySQL);
--  for daily maintenance this does not pay off
--DROP INDEX msgs_idx_sid         ON msgs;
--DROP INDEX msgrcpt_idx_rid      ON msgrcpt;
--DROP INDEX msgrcpt_idx_mail_id  ON msgrcpt;

--  delete old msgs records based on timestamps only (for time_iso see next),
--  and delete leftover msgs records from aborted mail checking operations
DELETE FROM msgs WHERE time_num < UNIX_TIMESTAMP()-14*24*60*60;
DELETE FROM msgs WHERE time_num < UNIX_TIMESTAMP()-60*60 AND content IS NULL;

--  provided the time_iso field was created as type TIMESTAMP DEFAULT 0 (MySQL)
--  or TIMESTAMP WITH TIME ZONE (PostgreSQL), instead of purging based on
--  numerical Unix timestamp as above, one may select records based on ISO 8601
--  UTC timestamps. This is particularly suitable for PostgreSQL:
--DELETE FROM msgs WHERE time_iso < now() - INTERVAL '14 days';
--DELETE FROM msgs WHERE time_iso < now() - INTERVAL '1 h' AND content IS NULL;
and is also possible with MySQL, using slightly different format:
--DELETE FROM msgs
--  WHERE time_iso < UTC_TIMESTAMP() - INTERVAL 14 day;
--DELETE FROM msgs
--  WHERE time_iso < UTC_TIMESTAMP() - INTERVAL 1 hour AND content IS NULL;

--  optionally certain content types may be given shorter lifetime
--DELETE FROM msgs WHERE time_num < UNIX_TIMESTAMP()-7*24*60*60
--  AND (content='V' OR (content='S' AND spam_level>20));

--  (optional) just in case the ON DELETE CASCADE did not do its job, we may
--  explicitly delete orphaned records (with no corresponding msgs entry);
--  if ON DELETE CASCADE did work, there should be no deletions at this step
DELETE FROM quarantine
  WHERE NOT EXISTS (SELECT 1 FROM msgs WHERE mail_id=quarantine.mail_id);
DELETE FROM msgrcpt
  WHERE NOT EXISTS (SELECT 1 FROM msgs WHERE mail_id=msgrcpt.mail_id);

--  re-create indexes (if they were removed in the first step):
--CREATE INDEX msgs_idx_sid        ON msgs    (sid);
--CREATE INDEX msgrcpt_idx_rid     ON msgrcpt (rid);
--CREATE INDEX msgrcpt_idx_mail_id ON msgrcpt (mail_id);

--  delete unreferenced e-mail addresses
DELETE FROM maddr
  WHERE NOT EXISTS (SELECT 1 FROM msgs    WHERE sid=id)
    AND NOT EXISTS (SELECT 1 FROM msgrcpt WHERE rid=id);

--  (optional) optimize tables once in a while
--OPTIMIZE TABLE msgs, msgrcpt, quarantine, maddr;