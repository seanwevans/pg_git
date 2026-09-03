-- pg_git 0.4.0 -> 0.5.0
-- HAND-WRITTEN. This delta removes objects rather than adding them, so unlike
-- the other upgrade scripts it is not assembled from install fragments.
--
-- 0.5.0 drops plpython3u from pg_git's requires so the extension can install on
-- managed PostgreSQL, where plpython3u is unavailable because it is untrusted.
-- The HTTPS transport that needed it now lives in the optional companion
-- extension pg_git_https.
--
-- The three objects below are released from pg_git but deliberately NOT
-- dropped: pggit.credentials holds encrypted credentials that must survive the
-- move. They are left in the database owned by no extension, and
-- CREATE EXTENSION pg_git_https adopts them as-is.
--
-- After this upgrade, a database that used HTTPS should run:
--     CREATE EXTENSION pg_git_https;
-- A database that did not use HTTPS can instead drop the leftovers:
--     DROP FUNCTION pggit.http_fetch(INTEGER, TEXT);
--     DROP FUNCTION pggit.store_credentials(INTEGER, TEXT, TEXT, TEXT);
--     DROP TABLE pggit.credentials;
--
-- The guards matter because not every 0.4.0 install has these objects. A
-- database installed from the released 0.4.0 script does; one that reached
-- 0.4.0 by applying this tree's upgrade chain does not, because the HTTPS
-- fragment is no longer part of any pg_git upgrade script.

DO $release_https$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_depend d
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_class'::regclass
          AND d.objid = to_regclass('pggit.credentials')
          AND d.refclassid = 'pg_extension'::regclass
          AND e.extname = 'pg_git'
    ) THEN
        ALTER EXTENSION pg_git DROP TABLE pggit.credentials;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_depend d
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = to_regprocedure('pggit.store_credentials(integer,text,text,text)')
          AND d.refclassid = 'pg_extension'::regclass
          AND e.extname = 'pg_git'
    ) THEN
        ALTER EXTENSION pg_git DROP FUNCTION pggit.store_credentials(INTEGER, TEXT, TEXT, TEXT);
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_depend d
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = to_regprocedure('pggit.http_fetch(integer,text)')
          AND d.refclassid = 'pg_extension'::regclass
          AND e.extname = 'pg_git'
    ) THEN
        ALTER EXTENSION pg_git DROP FUNCTION pggit.http_fetch(INTEGER, TEXT);
    END IF;
END
$release_https$;
