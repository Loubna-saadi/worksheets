--SIMULATION ---2
-- =============================================================================
-- PARAMSYNC — SIMULATION ENGINE
-- Oracle PL/SQL + ORDS Gateway
-- =============================================================================
-- WHAT THIS FILE ADDS:
--   SIMULATE_CORRECTION_SCRIPT(op_id, direction) — runs INSERT/UPDATE inside a
--     SAVEPOINT, captures before/after snapshots, then ROLLBACK TO SAVEPOINT.
--     DELETEs are never executed (they are only described).
--   ORDS POST /audit/simulate-script — REST entry point consumed by Angular.
--
-- FLOW:
--   1. Angular calls POST /audit/simulate-script {operation_id, direction}
--   2. Server opens SAVEPOINT sim_point
--   3. For each anomaly group (non-DELETE):
--        a. Snapshot BEFORE: SELECT row JSON from target table via db_link
--        b. Execute INSERT or UPDATE
--        c. Snapshot AFTER:  SELECT row JSON from target table via db_link
--        d. Append diff record to result JSON
--   4. ROLLBACK TO SAVEPOINT sim_point  ← always, no matter what
--   5. Return JSON array of diff records to Angular
--
-- RESULT FORMAT (one element per affected DB row):
--   {
--     "table":    "CARD_PRODUCT",
--     "key":      "BANK_CODE=BNC001, PRODUCT_CODE=VISA",
--     "action":   "UPDATE" | "INSERT",
--     "status":   "ok" | "error",
--     "error":    "ORA-xxxxx ..." (only on error),
--     "before":   { "COL1": "old_val", ... } | null (null for INSERT),
--     "after":    { "COL1": "new_val", ... }
--   }
-- =============================================================================


-- =============================================================================
-- SECTION 1 — HELPER: ROW_TO_JSON
-- Fetches a single row from a table (via optional db_link) by WHERE clause
-- and returns it as a JSON object string.
-- Uses all_tab_columns to discover columns dynamically.
-- Returns NULL if no row found.
-- =============================================================================

CREATE OR REPLACE FUNCTION ROW_TO_JSON (
    p_table     IN VARCHAR2,
    p_where     IN VARCHAR2,    -- e.g. "BANK_CODE='BNC001' AND PRODUCT_CODE='VISA'"
    p_db_link   IN VARCHAR2 DEFAULT NULL   -- NULL = local schema
) RETURN CLOB AS
    TYPE ref_cursor IS REF CURSOR;
    v_sql       VARCHAR2(32767);
    v_col_list  VARCHAR2(32767) := '';
    v_col_name  VARCHAR2(100);
    v_val       VARCHAR2(4000);
    v_json      CLOB := '{';
    v_first     BOOLEAN := TRUE;
    c_cols      ref_cursor;
    c_row       ref_cursor;
    v_col_count NUMBER := 0;
    TYPE t_cols IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
    v_cols      t_cols;
    v_link_sfx  VARCHAR2(60) := CASE WHEN p_db_link IS NOT NULL THEN '@' || p_db_link ELSE '' END;
BEGIN
    -- Discover column names (exclude audit stamps)
    v_sql := 'SELECT column_name FROM all_tab_columns' || v_link_sfx
          || ' WHERE table_name = :1'
          || '   AND column_name NOT IN (''USER_CREATE'',''DATE_CREATE'',''USER_MODIF'',''DATE_MODIF'')'
          || ' ORDER BY column_id';
    OPEN c_cols FOR v_sql USING UPPER(p_table);
    LOOP
        FETCH c_cols INTO v_col_name;
        EXIT WHEN c_cols%NOTFOUND;
        v_col_count := v_col_count + 1;
        v_cols(v_col_count) := v_col_name;
        IF v_col_list IS NOT NULL THEN v_col_list := v_col_list || ','; END IF;
        v_col_list := v_col_list || 'TO_CHAR(' || v_col_name || ')';
    END LOOP;
    CLOSE c_cols;

    IF v_col_count = 0 THEN RETURN NULL; END IF;

    -- Fetch the single row using a pivot-style dynamic SELECT
    -- We select each column individually to build JSON safely
    FOR i IN 1 .. v_col_count LOOP
        v_sql := 'SELECT TO_CHAR(' || v_cols(i) || ')'
              || ' FROM ' || UPPER(p_table) || v_link_sfx
              || ' WHERE ' || p_where
              || ' AND ROWNUM = 1';
        BEGIN
            EXECUTE IMMEDIATE v_sql INTO v_val;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RETURN NULL;   -- row not found
        WHEN OTHERS THEN
            v_val := NULL;
        END;

        IF NOT v_first THEN v_json := v_json || ','; END IF;
        v_json := v_json || '"' || v_cols(i) || '":';
        IF v_val IS NULL THEN
            v_json := v_json || 'null';
        ELSE
            -- Escape JSON string: backslash, double-quote, control chars
            v_json := v_json || '"'
                   || REPLACE(REPLACE(REPLACE(v_val, '\', '\\'), '"', '\"'), CHR(10), '\n')
                   || '"';
        END IF;
        v_first := FALSE;
    END LOOP;

    v_json := v_json || '}';
    RETURN v_json;
END;
/


-- =============================================================================
-- SECTION 2 — MAIN PROCEDURE: SIMULATE_CORRECTION_SCRIPT
-- =============================================================================

CREATE OR REPLACE PROCEDURE SIMULATE_CORRECTION_SCRIPT (
    p_operation_id IN  NUMBER,
    p_direction    IN  VARCHAR2 DEFAULT 'source',   -- 'source' or 'cible'
    p_result_json  OUT CLOB
) AS
    -- Environment resolution
    v_env_src    VARCHAR2(20);
    v_env_cbl    VARCHAR2(20);
    v_link_src   VARCHAR2(50);
    v_link_cbl   VARCHAR2(50);
    v_auth_env   VARCHAR2(20);
    v_auth_link  VARCHAR2(50);
    v_target_env VARCHAR2(20);
    v_target_lnk VARCHAR2(50);  -- db_link of the environment being corrected

    -- Cursor: one row per (table, cle) group with its dominant action
    CURSOR c_groups IS
        SELECT
            nom_table,
            cle,
            -- Classify the group: absent cases → INSERT or DELETE; others → UPDATE
            CASE
                WHEN MAX(CASE WHEN alerte_statut LIKE '%ABSENT_DANS_CIBLE%'  THEN 1 ELSE 0 END) = 1
                  THEN 'ABSENT_DANS_CIBLE'
                WHEN MAX(CASE WHEN alerte_statut LIKE '%ABSENT_DANS_SOURCE%' THEN 1 ELSE 0 END) = 1
                  THEN 'ABSENT_DANS_SOURCE'
                ELSE 'VALUE_DIFF'
            END AS case_type
        FROM ANOMALIE
        WHERE operation_id = p_operation_id
          AND statut       = 'OUVERT'
        GROUP BY nom_table, cle
        ORDER BY nom_table, cle;

    -- Cursor: column-level diffs for UPDATE
    CURSOR c_cols(p_table VARCHAR2, p_cle VARCHAR2) IS
        SELECT type_difference, valeur_source, valeur_cible
        FROM ANOMALIE
        WHERE operation_id = p_operation_id
          AND nom_table    = p_table
          AND cle          = p_cle
          AND alerte_statut NOT LIKE '%ABSENT%';

    v_where_clause VARCHAR2(4000);
    v_before_json  CLOB;
    v_after_json   CLOB;
    v_action       VARCHAR2(20);
    v_set_clause   VARCHAR2(32767);
    v_first_set    BOOLEAN;
    v_exec_sql     VARCHAR2(32767);
    v_val          VARCHAR2(4000);
    v_status       VARCHAR2(10);
    v_error_msg    VARCHAR2(500);
    v_first_rec    BOOLEAN := TRUE;
    v_key_label    VARCHAR2(500);

    -- Simple JSON escape
    FUNCTION jesc(s IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF s IS NULL THEN RETURN 'null'; END IF;
        RETURN '"' || REPLACE(REPLACE(REPLACE(s,'\','\\'),'"','\"'),CHR(10),'\n') || '"';
    END;

    -- Append one simulation record to the output CLOB
    PROCEDURE append_record(
        p_table   IN VARCHAR2,
        p_key     IN VARCHAR2,
        p_action  IN VARCHAR2,
        p_status  IN VARCHAR2,
        p_error   IN VARCHAR2,
        p_before  IN CLOB,
        p_after   IN CLOB
    ) IS
        v_rec VARCHAR2(32767);
    BEGIN
        IF NOT v_first_rec THEN
            DBMS_LOB.WRITEAPPEND(p_result_json, 1, ',');
        END IF;
        v_rec :=
            '{"table":'   || jesc(p_table)
         || ',"key":'     || jesc(p_key)
         || ',"action":'  || jesc(p_action)
         || ',"status":'  || jesc(p_status)
         || ',"error":'   || CASE WHEN p_error IS NULL THEN 'null' ELSE jesc(p_error) END
         || ',"before":';
        DBMS_LOB.WRITEAPPEND(p_result_json, LENGTH(v_rec), v_rec);
        IF p_before IS NULL THEN
            DBMS_LOB.WRITEAPPEND(p_result_json, 4, 'null');
        ELSE
            DBMS_LOB.APPEND(p_result_json, p_before);
        END IF;
        DBMS_LOB.WRITEAPPEND(p_result_json, 9, ',"after":');
        IF p_after IS NULL THEN
            DBMS_LOB.WRITEAPPEND(p_result_json, 4, 'null');
        ELSE
            DBMS_LOB.APPEND(p_result_json, p_after);
        END IF;
        DBMS_LOB.WRITEAPPEND(p_result_json, 1, '}');
        v_first_rec := FALSE;
    END;

BEGIN
    -- Resolve environments
    SELECT e1.code, e1.db_link, e2.code, e2.db_link
    INTO v_env_src, v_link_src, v_env_cbl, v_link_cbl
    FROM OPERATION o
    JOIN ENVIRONNEMENT e1 ON o.source_env = e1.id
    JOIN ENVIRONNEMENT e2 ON o.cible_env  = e2.id
    WHERE o.id = p_operation_id;

    IF LOWER(p_direction) = 'source' THEN
        v_auth_env   := v_env_src;  v_auth_link  := v_link_src;
        v_target_env := v_env_cbl;  v_target_lnk := v_link_cbl;
    ELSE
        v_auth_env   := v_env_cbl;  v_auth_link  := v_link_cbl;
        v_target_env := v_env_src;  v_target_lnk := v_link_src;
    END IF;

    DBMS_LOB.CREATETEMPORARY(p_result_json, TRUE);
    DBMS_LOB.WRITEAPPEND(p_result_json, 1, '[');

    -- ── Open savepoint — NOTHING after this point will be committed ──────────
    SAVEPOINT sim_point;

    FOR grp IN c_groups LOOP
        v_where_clause := JSON_CLE_TO_WHERE(grp.cle);
        v_key_label    := grp.cle;  -- send full JSON to Angular for display
        v_status       := 'ok';
        v_error_msg    := NULL;
        v_before_json  := NULL;
        v_after_json   := NULL;

        -- ── Classify action ──────────────────────────────────────────────────
        IF grp.case_type = 'ABSENT_DANS_CIBLE' THEN
            IF LOWER(p_direction) = 'source' THEN
                v_action := 'INSERT';
            ELSE
                -- DELETE — describe only, never execute in simulation
                append_record(grp.nom_table, v_key_label, 'DELETE_SKIPPED',
                              'skipped', 'DELETEs are not simulated', NULL, NULL);
                CONTINUE;
            END IF;

        ELSIF grp.case_type = 'ABSENT_DANS_SOURCE' THEN
            IF LOWER(p_direction) = 'cible' THEN
                v_action := 'INSERT';
            ELSE
                append_record(grp.nom_table, v_key_label, 'DELETE_SKIPPED',
                              'skipped', 'DELETEs are not simulated', NULL, NULL);
                CONTINUE;
            END IF;

        ELSE
            v_action := 'UPDATE';
        END IF;

        -- ── BEFORE snapshot ──────────────────────────────────────────────────
        BEGIN
            v_before_json := ROW_TO_JSON(grp.nom_table, v_where_clause, v_target_lnk);
        EXCEPTION WHEN OTHERS THEN
            v_before_json := NULL;
        END;

        -- ── Execute INSERT or UPDATE via db_link ─────────────────────────────
        BEGIN
            IF v_action = 'INSERT' THEN
                v_exec_sql :=
                    'INSERT INTO ' || grp.nom_table || '@' || v_target_lnk
                 || ' SELECT * FROM ' || grp.nom_table || '@' || v_auth_link
                 || ' WHERE ' || v_where_clause;
                EXECUTE IMMEDIATE v_exec_sql;

            ELSE  -- UPDATE
                v_set_clause := '';
                v_first_set  := TRUE;
                FOR col_rec IN c_cols(grp.nom_table, grp.cle) LOOP
                    v_val := CASE LOWER(p_direction)
                                 WHEN 'source' THEN col_rec.valeur_source
                                 ELSE               col_rec.valeur_cible
                             END;
                    IF NOT v_first_set THEN v_set_clause := v_set_clause || ', '; END IF;
                    v_set_clause := v_set_clause
                                 || col_rec.type_difference || ' = '
                                 || CASE WHEN v_val IS NULL THEN 'NULL'
                                         ELSE '''' || REPLACE(v_val,'''','''''') || ''''
                                    END;
                    v_first_set := FALSE;
                END LOOP;

                IF v_set_clause IS NOT NULL THEN
                    v_exec_sql :=
                        'UPDATE ' || grp.nom_table || '@' || v_target_lnk
                     || ' SET ' || v_set_clause
                     || ' WHERE ' || v_where_clause;
                    EXECUTE IMMEDIATE v_exec_sql;
                END IF;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_status    := 'error';
            v_error_msg := SUBSTR(SQLERRM, 1, 400);
        END;

        -- ── AFTER snapshot (only if execution succeeded) ──────────────────────
        IF v_status = 'ok' THEN
            BEGIN
                v_after_json := ROW_TO_JSON(grp.nom_table, v_where_clause, v_target_lnk);
            EXCEPTION WHEN OTHERS THEN
                v_after_json := NULL;
            END;
        END IF;

        append_record(grp.nom_table, v_key_label, v_action,
                      v_status, v_error_msg, v_before_json, v_after_json);
    END LOOP;

    -- ── ALWAYS ROLLBACK — simulation never persists ───────────────────────────
    ROLLBACK TO SAVEPOINT sim_point;

    DBMS_LOB.WRITEAPPEND(p_result_json, 1, ']');

EXCEPTION WHEN OTHERS THEN
    -- Safety net: roll back even on unexpected errors
    ROLLBACK TO SAVEPOINT sim_point;
    DBMS_LOB.CREATETEMPORARY(p_result_json, TRUE);
    DBMS_LOB.WRITEAPPEND(p_result_json, LENGTH('[]'), '[]');
    RAISE;
END;
/


-- =============================================================================
-- SECTION 3 — ORDS: POST /audit/simulate-script
-- Body: { operation_id: number, direction: "source"|"cible" }
-- Returns: JSON array of simulation diff records
-- =============================================================================

BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'simulate-script'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name => 'audit_module',
        p_pattern     => 'simulate-script',
        p_method      => 'POST',
        p_source_type => ORDS.source_type_plsql,
        p_source      =>
        'DECLARE
           v_op_id    NUMBER  := :operation_id;
           v_dir      VARCHAR2(10) := NVL(LOWER(:direction), ''source'');
           v_result   CLOB;
         BEGIN
           SIMULATE_CORRECTION_SCRIPT(v_op_id, v_dir, v_result);

           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           :status := 200;
           htp.prn(v_result);
         EXCEPTION WHEN OTHERS THEN
           ROLLBACK TO SAVEPOINT sim_point;
           :status := 500;
           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           htp.prn(''{"error":"'' || REPLACE(SQLERRM,CHR(34),CHR(39)) || ''"}'' );
         END;'
    );
    COMMIT;
END;
/

GRANT EXECUTE ON ROW_TO_JSON               TO ORDS_PUBLIC_USER;
GRANT EXECUTE ON SIMULATE_CORRECTION_SCRIPT TO ORDS_PUBLIC_USER;


-- =============================================================================
-- SECTION 4 — QUICK VERIFICATION
-- =============================================================================

-- Verify routes
SELECT t.uri_template, h.method
FROM user_ords_modules m
JOIN user_ords_templates t ON t.module_id = m.id
JOIN user_ords_handlers  h ON h.template_id = t.id
WHERE m.name = 'audit_module'
ORDER BY t.uri_template;

-- Manual test (replace 42 with a real operation id):
-- SET SERVEROUTPUT ON;
-- DECLARE v_out CLOB; BEGIN SIMULATE_CORRECTION_SCRIPT(42,'source',v_out); DBMS_OUTPUT.PUT_LINE(SUBSTR(v_out,1,4000)); END;