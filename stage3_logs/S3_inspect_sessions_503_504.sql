-- READ-ONLY inspection of connections 503 and 504. No DML, no KILL, no COMMIT/ROLLBACK.
-- Run: mysql -u root -p --table -e "source stage3_logs/S3_inspect_sessions_503_504.sql"
-- (non-interactive: the inspecting session ends immediately afterwards)

SELECT '1. threads' AS section;
SELECT t.PROCESSLIST_ID AS conn, t.THREAD_ID AS thread, t.PROCESSLIST_USER AS user, t.PROCESSLIST_HOST AS host,
       t.PROCESSLIST_DB AS db, t.PROCESSLIST_COMMAND AS cmd, t.PROCESSLIST_TIME AS idle_s,
       t.CONNECTION_TYPE AS conn_type, t.RESOURCE_GROUP AS rg
  FROM performance_schema.threads t WHERE t.PROCESSLIST_ID IN (503, 504) ORDER BY 1;

SELECT '2. client connect attributes (PID, program, OS)' AS section;
SELECT a.PROCESSLIST_ID AS conn, a.ATTR_NAME, a.ATTR_VALUE
  FROM performance_schema.session_connect_attrs a WHERE a.PROCESSLIST_ID IN (503, 504)
 ORDER BY 1, 2;

SELECT '3. InnoDB transactions (rows_modified > 0 means uncommitted changes)' AS section;
SELECT trx_mysql_thread_id AS conn, trx_id, trx_state, trx_started, trx_isolation_level,
       trx_tables_in_use, trx_tables_locked, trx_rows_locked, trx_rows_modified, trx_lock_structs,
       trx_is_read_only, trx_autocommit_non_locking
  FROM information_schema.innodb_trx WHERE trx_mysql_thread_id IN (503, 504) ORDER BY 1;

SELECT '4. locks held, by table' AS section;
SELECT t.PROCESSLIST_ID AS conn, l.OBJECT_SCHEMA, l.OBJECT_NAME, l.INDEX_NAME, l.LOCK_TYPE, l.LOCK_MODE,
       l.LOCK_STATUS, COUNT(*) AS n
  FROM performance_schema.data_locks l JOIN performance_schema.threads t ON t.THREAD_ID = l.THREAD_ID
 WHERE t.PROCESSLIST_ID IN (503, 504)
 GROUP BY 1, 2, 3, 4, 5, 6, 7 ORDER BY 1, 2, 3, 4;

SELECT '5. locked records (first 40)' AS section;
SELECT t.PROCESSLIST_ID AS conn, l.OBJECT_NAME, l.INDEX_NAME, l.LOCK_MODE, LEFT(l.LOCK_DATA, 60) AS lock_data
  FROM performance_schema.data_locks l JOIN performance_schema.threads t ON t.THREAD_ID = l.THREAD_ID
 WHERE t.PROCESSLIST_ID IN (503, 504) AND l.LOCK_TYPE = 'RECORD'
 ORDER BY 1, 2, 3 LIMIT 40;

SELECT '6. metadata locks' AS section;
SELECT t.PROCESSLIST_ID AS conn, m.OBJECT_TYPE, m.OBJECT_SCHEMA, m.OBJECT_NAME, m.LOCK_TYPE, m.LOCK_DURATION, m.LOCK_STATUS
  FROM performance_schema.metadata_locks m JOIN performance_schema.threads t ON t.THREAD_ID = m.OWNER_THREAD_ID
 WHERE t.PROCESSLIST_ID IN (503, 504) AND m.OBJECT_TYPE IN ('TABLE', 'SCHEMA')
 ORDER BY 1, 3, 4;

SELECT '7. statement history (last statements per connection)' AS section;
SELECT t.PROCESSLIST_ID AS conn, h.EVENT_ID, LEFT(REPLACE(REPLACE(h.SQL_TEXT, '\n', ' '), '\r', ' '), 150) AS sql_text,
       h.CURRENT_SCHEMA AS db, h.ROWS_AFFECTED, h.MYSQL_ERRNO, h.MESSAGE_TEXT
  FROM performance_schema.events_statements_history h JOIN performance_schema.threads t ON t.THREAD_ID = h.THREAD_ID
 WHERE t.PROCESSLIST_ID IN (503, 504) ORDER BY 1, 2;

SELECT '8. transaction events' AS section;
SELECT t.PROCESSLIST_ID AS conn, x.STATE, x.ACCESS_MODE, x.AUTOCOMMIT, x.ISOLATION_LEVEL, x.TIMER_START
  FROM performance_schema.events_transactions_current x JOIN performance_schema.threads t ON t.THREAD_ID = x.THREAD_ID
 WHERE t.PROCESSLIST_ID IN (503, 504) ORDER BY 1;
