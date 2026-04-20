-- PARAMSYNC — MIGRATION: JSON CLE + SMART CORRECTION SCRIPT
-- =============================================================================
-- WHAT THIS FILE DOES:
--   1. Widens ANOMALIE.cle to VARCHAR2(4000) to hold JSON pk payloads
--   2. Adds ANOMALIE.nom_table (if missing) for table-level context
--   3. Rewrites VALIDER_ET_STOCKER_ANOMALIES to store pk as JSON object
--      e.g.  {"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}
--   4. Adds a helper function: BUILD_WHERE_CLAUSE(json_cle) → SQL fragment
--      e.g.  BANK_CODE='BNC001' AND PRODUCT_CODE='VISA'
--   5. Adds a server-side script generator: GENERATE_CORRECTION_SCRIPT(op_id, direction)
--      that produces a real, executable SQL script using INSERT..SELECT..@link
--   6. New ORDS handler POST /audit/generate-script
-- =============================================================================


-- =============================================================================
-- STEP 1 — SCHEMA CHANGES
-- =============================================================================

-- 1a. Widen cle to hold JSON (run once — ignore ORA-01441 if already wider)
ALTER TABLE ANOMALIE MODIFY cle VARCHAR2(4000);
ALTER TABLE ANOMALIE MODIFY valeur_source VARCHAR2(4000);
ALTER TABLE ANOMALIE MODIFY valeur_cible  VARCHAR2(4000);
COMMIT;

-- 1b. Add nom_table column to ANOMALIE (ignore ORA-01430 if exists)
ALTER TABLE ANOMALIE ADD nom_table VARCHAR2(128);
COMMIT;

-- 1c. Add alerte_statut column to ANOMALIE (ignore ORA-01430 if exists)
ALTER TABLE ANOMALIE ADD alerte_statut VARCHAR2(100);
COMMIT;

-- 1d. Widen PARAMETRAGE.valeur (safety — ignore error if already wide)
ALTER TABLE PARAMETRAGE MODIFY valeur VARCHAR2(4000);
COMMIT;

describe anomalie;
-- =============================================================================
-- STEP 2 — REWRITE EXEC_AUDIT_TABLE_V2
-- KEY CHANGE: the `cle` stored in PARAMETRAGE now has format:
--   JSON_KEY#COLUMN_NAME
-- where JSON_KEY = {"PK_COL1":"val1","PK_COL2":"val2"}
-- This replaces the fragile  val1-val2#COLUMN_NAME  format.
-- =============================================================================

CREATE OR REPLACE PROCEDURE EXEC_AUDIT_TABLE_V2 (
    p_env_source    IN VARCHAR2,
    p_env_cible     IN VARCHAR2,
    p_nom_table     IN VARCHAR2,
    p_user_id       IN NUMBER,
    p_excluded_cols IN VARCHAR2 DEFAULT NULL
) AS
    v_id_src   NUMBER;
    v_id_cbl   NUMBER;
    v_op_id    NUMBER;
    v_link_src VARCHAR2(50);
    v_link_cbl VARCHAR2(50);
    v_sql      VARCHAR2(32767);
    -- PK detection
    TYPE t_pk_cols IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
    v_pk_cols  t_pk_cols;
    v_pk_count NUMBER := 0;
    -- JSON key expression  e.g.  '{"COL1":"'||COL1||'","COL2":"'||COL2||'"}'
    v_pk_json_expr VARCHAR2(4000);
    TYPE ref_cursor IS REF CURSOR;
    c_cols     ref_cursor;
    c_pkcols   ref_cursor;
    v_col_name VARCHAR2(100);

    FUNCTION is_excluded(p_col IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF p_excluded_cols IS NULL THEN RETURN FALSE; END IF;
        RETURN INSTR(',' || UPPER(p_excluded_cols) || ',',
                     ',' || UPPER(p_col)           || ',') > 0;
    END;

    -- Build the JSON expression for the PK columns
    FUNCTION build_json_expr RETURN VARCHAR2 IS
        v_expr VARCHAR2(4000) := '''{'||CHR(39);
        v_first BOOLEAN := TRUE;
    BEGIN
        FOR i IN 1 .. v_pk_count LOOP
            IF NOT v_first THEN
                v_expr := v_expr || '||'',''||';
            ELSE
                v_first := FALSE;
            END IF;
            -- produces: '{"COL":"'||TO_CHAR(COL)||'",...}'
            v_expr := v_expr
                   || '''"' || v_pk_cols(i) || '":"''||'
                   || 'TO_CHAR(' || v_pk_cols(i) || ')'
                   || '||''"''';
        END LOOP;
        v_expr := v_expr || '||''}''';
        RETURN v_expr;
    END;
BEGIN
    SELECT id, db_link INTO v_id_src, v_link_src
    FROM ENVIRONNEMENT WHERE code = UPPER(p_env_source);
    SELECT id, db_link INTO v_id_cbl, v_link_cbl
    FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cible);

    CREER_OPERATION_AUDIT(p_env_source, p_env_cible, p_user_id, v_op_id);

    -- ── PK detection: constraint first ──────────────────────────────────────
    BEGIN
        v_sql :=
            'SELECT cols.column_name'
         || ' FROM all_constraints@'  || v_link_src || ' cons'
         || ' JOIN all_cons_columns@' || v_link_src || ' cols'
         || '   ON cons.constraint_name = cols.constraint_name'
         || ' WHERE cons.table_name     = :1'
         || '   AND cons.constraint_type = ''P'''
         || ' ORDER BY cols.position';
        OPEN c_pkcols FOR v_sql USING UPPER(p_nom_table);
        LOOP
            FETCH c_pkcols INTO v_col_name;
            EXIT WHEN c_pkcols%NOTFOUND;
            v_pk_count := v_pk_count + 1;
            v_pk_cols(v_pk_count) := v_col_name;
        END LOOP;
        CLOSE c_pkcols;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- ── PK fallback: unique index ────────────────────────────────────────────
    IF v_pk_count = 0 THEN
        BEGIN
            v_sql :=
                'SELECT column_name'
             || ' FROM all_ind_columns@' || v_link_src
             || ' WHERE table_name = :1'
             || '   AND index_name = ('
             || '     SELECT index_name FROM all_indexes@' || v_link_src
             || '     WHERE table_name = :2 AND uniqueness = ''UNIQUE'' AND ROWNUM = 1)'
             || ' ORDER BY column_position';
            OPEN c_pkcols FOR v_sql USING UPPER(p_nom_table), UPPER(p_nom_table);
            LOOP
                FETCH c_pkcols INTO v_col_name;
                EXIT WHEN c_pkcols%NOTFOUND;
                v_pk_count := v_pk_count + 1;
                v_pk_cols(v_pk_count) := v_col_name;
            END LOOP;
            CLOSE c_pkcols;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;

    -- ── PK last resort: first column ─────────────────────────────────────────
    IF v_pk_count = 0 THEN
        v_sql := 'SELECT column_name FROM all_tab_columns@' || v_link_src
              || ' WHERE table_name = :1 AND column_id = 1';
        EXECUTE IMMEDIATE v_sql INTO v_col_name USING UPPER(p_nom_table);
        v_pk_count := 1;
        v_pk_cols(1) := v_col_name;
    END IF;

    -- Build the JSON expression used in INSERT INTO PARAMETRAGE
    v_pk_json_expr := build_json_expr();
    DBMS_OUTPUT.PUT_LINE('JSON PK expr: ' || v_pk_json_expr);

    -- ── Iterate auditable columns ────────────────────────────────────────────
    v_sql :=
        'SELECT column_name FROM all_tab_columns@' || v_link_src
     || ' WHERE table_name = :1'
     || '   AND data_type IN ('
     || '       ''VARCHAR2'',''NVARCHAR2'',''CHAR'',''NCHAR'','
     || '       ''NUMBER'',''FLOAT'',''BINARY_FLOAT'',''BINARY_DOUBLE'','
     || '       ''DATE'',''TIMESTAMP'',''TIMESTAMP(6)'',''TIMESTAMP(3)'')'
     || '   AND column_name NOT IN'
     || '       (''USER_CREATE'',''DATE_CREATE'',''USER_MODIF'',''DATE_MODIF'')';

    OPEN c_cols FOR v_sql USING UPPER(p_nom_table);
    LOOP
        FETCH c_cols INTO v_col_name;
        EXIT WHEN c_cols%NOTFOUND;

        -- Skip PK columns themselves (they're in the key, not compared)
        DECLARE v_is_pk BOOLEAN := FALSE;
        BEGIN
            FOR i IN 1 .. v_pk_count LOOP
                IF UPPER(v_col_name) = UPPER(v_pk_cols(i)) THEN
                    v_is_pk := TRUE; EXIT;
                END IF;
            END LOOP;
            IF v_is_pk OR is_excluded(v_col_name) THEN GOTO next_col; END IF;
        END;

        -- cle format:  {"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}#WORDING
        v_sql :=
            'INSERT INTO PARAMETRAGE'
         || ' (cle, valeur, environnement_id, operation_id, nom_table_audit)'
         || ' SELECT ' || v_pk_json_expr || ' || ''#' || v_col_name || ''','
         || '        SUBSTR(TO_CHAR(' || v_col_name || '), 1, 3900),'
         || '        :1, :2, :3'
         || ' FROM ' || UPPER(p_nom_table);

        BEGIN
            EXECUTE IMMEDIATE v_sql || '@' || v_link_src
                USING v_id_src, v_op_id, UPPER(p_nom_table);
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('ERR src [' || v_col_name || ']: ' || SQLERRM);
        END;
        BEGIN
            EXECUTE IMMEDIATE v_sql || '@' || v_link_cbl
                USING v_id_cbl, v_op_id, UPPER(p_nom_table);
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('ERR cbl [' || v_col_name || ']: ' || SQLERRM);
        END;

        <<next_col>> NULL;
    END LOOP;
    CLOSE c_cols;

    UPDATE OPERATION SET statut = 'TERMINE' WHERE id = v_op_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('done op=' || v_op_id);
END;
/


-- =============================================================================
-- STEP 3 — REWRITE SCAN_TABLE (same JSON key change)
-- =============================================================================

CREATE OR REPLACE PROCEDURE SCAN_TABLE (
    p_env_src   IN VARCHAR2,
    p_env_cbl   IN VARCHAR2,
    p_nom_table IN VARCHAR2,
    p_id_src    IN NUMBER,
    p_id_cbl    IN NUMBER,
    p_op_id     IN NUMBER
) AS
    v_link_src     VARCHAR2(50);
    v_link_cbl     VARCHAR2(50);
    v_sql          VARCHAR2(32767);
    v_ins_src      NUMBER := 0;
    v_ins_cbl      NUMBER := 0;
    TYPE t_pk_cols IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
    v_pk_cols      t_pk_cols;
    v_pk_count     NUMBER := 0;
    v_pk_json_expr VARCHAR2(4000);
    TYPE ref_cursor IS REF CURSOR;
    c_cols         ref_cursor;
    c_pkcols       ref_cursor;
    v_col_name     VARCHAR2(100);

    FUNCTION build_json_expr RETURN VARCHAR2 IS
        v_expr VARCHAR2(4000);
        v_first BOOLEAN := TRUE;
    BEGIN
        v_expr := '''{'||CHR(39);
        FOR i IN 1 .. v_pk_count LOOP
            IF NOT v_first THEN
                v_expr := v_expr || '||'',''||';
            ELSE
                v_first := FALSE;
            END IF;
            v_expr := v_expr
                   || '''"' || v_pk_cols(i) || '":"''||'
                   || 'TO_CHAR(' || v_pk_cols(i) || ')'
                   || '||''"''';
        END LOOP;
        v_expr := v_expr || '||''}''';
        RETURN v_expr;
    END;
BEGIN
    SELECT db_link INTO v_link_src FROM ENVIRONNEMENT WHERE code = UPPER(p_env_src);
    SELECT db_link INTO v_link_cbl FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cbl);

    -- PK: constraint
    BEGIN
        v_sql :=
            'SELECT cols.column_name'
         || ' FROM all_constraints@'  || v_link_src || ' cons'
         || ' JOIN all_cons_columns@' || v_link_src || ' cols'
         || '   ON cons.constraint_name = cols.constraint_name'
         || ' WHERE cons.table_name     = :1'
         || '   AND cons.constraint_type = ''P'''
         || ' ORDER BY cols.position';
        OPEN c_pkcols FOR v_sql USING UPPER(p_nom_table);
        LOOP
            FETCH c_pkcols INTO v_col_name;
            EXIT WHEN c_pkcols%NOTFOUND;
            v_pk_count := v_pk_count + 1;
            v_pk_cols(v_pk_count) := v_col_name;
        END LOOP;
        CLOSE c_pkcols;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- PK: unique index fallback
    IF v_pk_count = 0 THEN
        BEGIN
            v_sql :=
                'SELECT column_name'
             || ' FROM all_ind_columns@' || v_link_src
             || ' WHERE table_name = :1'
             || '   AND index_name = ('
             || '     SELECT index_name FROM all_indexes@' || v_link_src
             || '     WHERE table_name = :2 AND uniqueness = ''UNIQUE'' AND ROWNUM = 1)'
             || ' ORDER BY column_position';
            OPEN c_pkcols FOR v_sql USING UPPER(p_nom_table), UPPER(p_nom_table);
            LOOP
                FETCH c_pkcols INTO v_col_name;
                EXIT WHEN c_pkcols%NOTFOUND;
                v_pk_count := v_pk_count + 1;
                v_pk_cols(v_pk_count) := v_col_name;
            END LOOP;
            CLOSE c_pkcols;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;

    IF v_pk_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('!! SKIP (no PK): ' || p_nom_table);
        RETURN;
    END IF;

    v_pk_json_expr := build_json_expr();

    v_sql :=
        'SELECT column_name FROM all_tab_columns@' || v_link_src
     || ' WHERE table_name = :1'
     || '   AND data_type IN ('
     || '       ''VARCHAR2'',''NVARCHAR2'',''CHAR'',''NCHAR'','
     || '       ''NUMBER'',''FLOAT'',''BINARY_FLOAT'',''BINARY_DOUBLE'','
     || '       ''DATE'',''TIMESTAMP'',''TIMESTAMP(6)'',''TIMESTAMP(3)'')'
     || '   AND column_name NOT IN'
     || '       (''USER_CREATE'',''DATE_CREATE'',''USER_MODIF'',''DATE_MODIF'')';

    OPEN c_cols FOR v_sql USING UPPER(p_nom_table);
    LOOP
        FETCH c_cols INTO v_col_name;
        EXIT WHEN c_cols%NOTFOUND;

        DECLARE v_is_pk BOOLEAN := FALSE;
        BEGIN
            FOR i IN 1 .. v_pk_count LOOP
                IF UPPER(v_col_name) = UPPER(v_pk_cols(i)) THEN
                    v_is_pk := TRUE; EXIT;
                END IF;
            END LOOP;
            IF v_is_pk THEN GOTO next_col; END IF;
        END;

        v_sql :=
            'INSERT INTO PARAMETRAGE'
         || ' (cle, valeur, environnement_id, operation_id, nom_table_audit)'
         || ' SELECT ' || v_pk_json_expr || ' || ''#' || v_col_name || ''','
         || '        SUBSTR(TO_CHAR(' || v_col_name || '), 1, 3900),'
         || '        :1, :2, :3'
         || ' FROM ' || UPPER(p_nom_table);

        BEGIN
            EXECUTE IMMEDIATE v_sql || '@' || v_link_src
                USING p_id_src, p_op_id, UPPER(p_nom_table);
            v_ins_src := v_ins_src + SQL%ROWCOUNT;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
            EXECUTE IMMEDIATE v_sql || '@' || v_link_cbl
                USING p_id_cbl, p_op_id, UPPER(p_nom_table);
            v_ins_cbl := v_ins_cbl + SQL%ROWCOUNT;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        <<next_col>> NULL;
    END LOOP;
    CLOSE c_cols;

    DBMS_OUTPUT.PUT_LINE('SCAN [' || p_nom_table || '] src=' || v_ins_src || ' cbl=' || v_ins_cbl);
END;
/


-- =============================================================================
-- STEP 4 — REWRITE V_PREVIEW_COMPARAISON
-- The CLE in PARAMETRAGE now has format:  JSON_OBJECT#COLUMN_NAME
-- We split on the LAST '#' so that JSON values containing '#' are safe.
-- =============================================================================

CREATE OR REPLACE VIEW V_PREVIEW_COMPARAISON AS
WITH VALEURS_EXTRACT AS (
    SELECT
        -- Everything before the last '#' is the JSON key
        SUBSTR(p.cle, 1, INSTR(p.cle, '#', -1) - 1) AS CLE_OBJET,
        p.nom_table_audit                              AS TABLE_NAME,
        -- Everything after the last '#' is the column name
        SUBSTR(p.cle, INSTR(p.cle, '#', -1) + 1)    AS COLONNE,
        MAX(CASE WHEN p.environnement_id = o.source_env THEN p.valeur END) AS VAL_SRC,
        MAX(CASE WHEN p.environnement_id = o.cible_env  THEN p.valeur END) AS VAL_CBL,
        COUNT(CASE WHEN p.environnement_id = o.source_env THEN 1 END)      AS ROW_EXISTS_SRC,
        COUNT(CASE WHEN p.environnement_id = o.cible_env  THEN 1 END)      AS ROW_EXISTS_CBL,
        COUNT(CASE WHEN p.environnement_id = o.source_env
                        AND p.valeur IS NOT NULL THEN 1 END)                AS VAL_EXISTS_SRC,
        COUNT(CASE WHEN p.environnement_id = o.cible_env
                        AND p.valeur IS NOT NULL THEN 1 END)                AS VAL_EXISTS_CBL,
        p.operation_id,
        o.utilisateur_id,
        o.source_env,
        o.cible_env
    FROM PARAMETRAGE p
    JOIN OPERATION o ON p.operation_id = o.id
    GROUP BY p.cle, p.nom_table_audit, p.operation_id,
             o.source_env, o.cible_env, o.utilisateur_id
),
ROW_PRESENCE AS (
    SELECT
        CLE_OBJET, TABLE_NAME, operation_id, utilisateur_id,
        source_env, cible_env,
        MAX(ROW_EXISTS_SRC) AS ANY_COL_SRC,
        MAX(ROW_EXISTS_CBL) AS ANY_COL_CBL
    FROM VALEURS_EXTRACT
    GROUP BY CLE_OBJET, TABLE_NAME, operation_id, utilisateur_id, source_env, cible_env
)
SELECT
    v.CLE_OBJET  AS CLE,       -- JSON object: {"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}
    v.TABLE_NAME AS NOM_TABLE,
    v.COLONNE    AS TYPE_DIFFERENCE,
    v.VAL_SRC    AS VALEUR_SOURCE,
    v.VAL_CBL    AS VALEUR_CIBLE,
    v.operation_id,
    v.utilisateur_id,
    CASE
        WHEN r.ANY_COL_SRC > 0 AND r.ANY_COL_CBL = 0   THEN '🔴 ABSENT_DANS_CIBLE'
        WHEN r.ANY_COL_SRC = 0 AND r.ANY_COL_CBL > 0   THEN '🟡 ABSENT_DANS_SOURCE'
        WHEN DECODE(v.VAL_SRC, v.VAL_CBL, 1, 0) = 1    THEN '🟢 IDENTIQUE'
        WHEN v.VAL_EXISTS_SRC > 0 AND v.VAL_EXISTS_CBL = 0 THEN '🟣 VALEUR_NULL_EN_CIBLE'
        WHEN v.VAL_EXISTS_SRC = 0 AND v.VAL_EXISTS_CBL > 0 THEN '🟣 VALEUR_NULL_EN_SOURCE'
        ELSE '🟠 VALEUR_DIFFERENTE'
    END AS ALERTE_STATUT
FROM VALEURS_EXTRACT v
JOIN ROW_PRESENCE r
  ON  v.CLE_OBJET    = r.CLE_OBJET
  AND v.TABLE_NAME   = r.TABLE_NAME
  AND v.operation_id = r.operation_id;
/


-- =============================================================================
-- STEP 5 — REWRITE VALIDER_ET_STOCKER_ANOMALIES
-- Stores the JSON cle directly into ANOMALIE.cle
-- =============================================================================

CREATE OR REPLACE PROCEDURE VALIDER_ET_STOCKER_ANOMALIES (
    p_operation_id IN NUMBER
) AS
    v_count NUMBER;
BEGIN
    INSERT INTO ANOMALIE (
        cle, nom_table, type_difference,
        valeur_source, valeur_cible,
        alerte_statut, description,
        operation_id, utilisateur_id, statut, dateCreation
    )
    SELECT
        CLE,           -- now a JSON string: {"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}
        NOM_TABLE,
        TYPE_DIFFERENCE,
        VALEUR_SOURCE,
        VALEUR_CIBLE,
        ALERTE_STATUT,
        'Écart sur ' || NOM_TABLE || ' — col ' || TYPE_DIFFERENCE,
        p_operation_id,
        UTILISATEUR_ID,
        'OUVERT',
        SYSDATE
    FROM V_PREVIEW_COMPARAISON
    WHERE operation_id  = p_operation_id
      AND ALERTE_STATUT NOT LIKE '%IDENTIQUE%';

    v_count := SQL%ROWCOUNT;
    UPDATE OPERATION SET statut = 'ANOMALIES_GENEREES' WHERE id = p_operation_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_count || ' anomalie(s) — op #' || p_operation_id);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERREUR: ' || SQLERRM);
        RAISE;
END;
/


-- =============================================================================
-- STEP 6 — HELPER: JSON_CLE_TO_WHERE
-- Converts {"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}
-- into     BANK_CODE='BNC001' AND PRODUCT_CODE='VISA'
-- Pure PL/SQL — no JSON_TABLE needed (works on Oracle 11g+)
-- =============================================================================

CREATE OR REPLACE FUNCTION JSON_CLE_TO_WHERE (
    p_json IN VARCHAR2
) RETURN VARCHAR2 AS
    v_result  VARCHAR2(4000) := '';
    v_work    VARCHAR2(4000);
    v_pair    VARCHAR2(500);
    v_col     VARCHAR2(100);
    v_val     VARCHAR2(500);
    v_pos     NUMBER := 1;
    v_start   NUMBER;
    v_end_col NUMBER;
    v_colon   NUMBER;
    v_first   BOOLEAN := TRUE;
BEGIN
    -- Strip outer braces: {"K":"V","K2":"V2"} → "K":"V","K2":"V2"
    v_work := TRIM(p_json);
    IF SUBSTR(v_work, 1, 1) = '{' THEN
        v_work := SUBSTR(v_work, 2, LENGTH(v_work) - 2);
    END IF;
    -- v_work is now  "BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"
    -- We iterate by finding "key":"value" pairs
    v_pos := 1;
    LOOP
        -- Find opening quote of key
        v_start := INSTR(v_work, '"', v_pos);
        EXIT WHEN v_start = 0;
        -- Find closing quote of key
        v_end_col := INSTR(v_work, '"', v_start + 1);
        EXIT WHEN v_end_col = 0;
        v_col := SUBSTR(v_work, v_start + 1, v_end_col - v_start - 1);

        -- Find colon then opening quote of value
        v_colon := INSTR(v_work, ':', v_end_col);
        v_start  := INSTR(v_work, '"', v_colon);
        EXIT WHEN v_start = 0;
        -- Find closing quote of value (simple — values must not contain escaped quotes)
        v_end_col := INSTR(v_work, '"', v_start + 1);
        EXIT WHEN v_end_col = 0;
        v_val := SUBSTR(v_work, v_start + 1, v_end_col - v_start - 1);

        IF NOT v_first THEN v_result := v_result || ' AND '; END IF;
        v_result := v_result || v_col || '=''' || REPLACE(v_val, '''', '''''') || '''';
        v_first := FALSE;

        v_pos := v_end_col + 1;
    END LOOP;

    RETURN v_result;
END;
/


-- =============================================================================
-- STEP 7 — SERVER-SIDE SCRIPT GENERATOR: GENERATE_CORRECTION_SCRIPT
--
-- Generates a fully executable SQL correction script using:
--   INSERT INTO target_table SELECT * FROM source_table@link WHERE pk_conditions
--   UPDATE target_table SET col=val WHERE pk_conditions
--   DELETE FROM target_table WHERE pk_conditions
--
-- Parameters:
--   p_operation_id — the audit operation to correct
--   p_direction    — 'source' (source env wins) or 'cible' (cible env wins)
--   p_clob_out     — output CLOB with the full SQL script
-- =============================================================================
// hhhhhhhh
CREATE OR REPLACE PROCEDURE GENERATE_CORRECTION_SCRIPT (
    p_operation_id IN  NUMBER,
    p_direction    IN  VARCHAR2 DEFAULT 'source',  -- 'source' or 'cible'
    p_clob_out     OUT CLOB
) AS
    v_env_src    VARCHAR2(20);
    v_env_cbl    VARCHAR2(20);
    v_link_src   VARCHAR2(50);
    v_link_cbl   VARCHAR2(50);
    v_auth_env   VARCHAR2(20);   -- environment that imposes its values
    v_auth_link  VARCHAR2(50);   -- db_link for the authoritative env
    v_target_env VARCHAR2(20);   -- environment to be corrected

    -- Cursor over distinct (table, cle, alerte_statut) groups
    CURSOR c_groups IS
        SELECT DISTINCT
            nom_table,
            cle,   -- JSON string
            CASE
                WHEN alerte_statut LIKE '%ABSENT_DANS_CIBLE%'  THEN 'ABSENT_DANS_CIBLE'
                WHEN alerte_statut LIKE '%ABSENT_DANS_SOURCE%' THEN 'ABSENT_DANS_SOURCE'
                WHEN alerte_statut LIKE '%NULL%'               THEN 'VALUE_DIFF'
                ELSE                                                 'VALUE_DIFF'
            END AS case_type
        FROM ANOMALIE
        WHERE operation_id = p_operation_id
          AND statut       = 'OUVERT'
        ORDER BY nom_table, cle;

    -- Cursor over column-level diffs for a given (table, cle) pair
    CURSOR c_cols (p_table VARCHAR2, p_cle VARCHAR2) IS
        SELECT type_difference, valeur_source, valeur_cible, alerte_statut
        FROM ANOMALIE
        WHERE operation_id   = p_operation_id
          AND nom_table      = p_table
          AND cle            = p_cle
          AND alerte_statut NOT LIKE '%ABSENT%';

    v_where_clause  VARCHAR2(4000);
    v_set_clause    VARCHAR2(32767);
    v_val           VARCHAR2(4000);
    v_first_set     BOOLEAN;
    v_line          VARCHAR2(32767);

    PROCEDURE w(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_LOB.WRITEAPPEND(p_clob_out, LENGTH(p_text || CHR(10)), p_text || CHR(10));
    END;
BEGIN
    -- Resolve envs and links
    SELECT e1.code, e1.db_link, e2.code, e2.db_link
    INTO v_env_src, v_link_src, v_env_cbl, v_link_cbl
    FROM OPERATION o
    JOIN ENVIRONNEMENT e1 ON o.source_env = e1.id
    JOIN ENVIRONNEMENT e2 ON o.cible_env  = e2.id
    WHERE o.id = p_operation_id;

    IF LOWER(p_direction) = 'source' THEN
        v_auth_env   := v_env_src;   v_auth_link  := v_link_src;
        v_target_env := v_env_cbl;
    ELSE
        v_auth_env   := v_env_cbl;   v_auth_link  := v_link_cbl;
        v_target_env := v_env_src;
    END IF;

    -- Initialize CLOB
    DBMS_LOB.CREATETEMPORARY(p_clob_out, TRUE);

    w('-- ================================================================');
    w('-- Correction script — Operation #' || p_operation_id);
    w('-- Generated : ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    w('-- Authority : ' || v_auth_env || ' (' || p_direction || ' wins)');
    w('-- Target    : ' || v_target_env);
    w('-- ⚠  Review every statement before running in PRODUCTION');
    w('-- ================================================================');
    w('');

    FOR grp IN c_groups LOOP
        v_where_clause := JSON_CLE_TO_WHERE(grp.cle);

        IF grp.case_type = 'ABSENT_DANS_CIBLE' THEN
            -- Row exists in source, missing in cible
            IF LOWER(p_direction) = 'source' THEN
                -- Source wins → INSERT missing row into target (cible)
                w('-- ➕ INSERT — key ' || grp.cle);
                w('INSERT INTO ' || v_target_env || '.' || grp.nom_table);
                w('SELECT * FROM ' || grp.nom_table || '@' || v_auth_link);
                w('WHERE ' || v_where_clause || ';');
            ELSE
                -- Cible wins → row absent in cible is correct → DELETE from source
                w('-- 🗑 DELETE — key ' || grp.cle || ' (absent in cible = cible is right)');
                w('DELETE FROM ' || grp.nom_table);
                w('WHERE ' || v_where_clause || ';');
            END IF;
            w('');

        ELSIF grp.case_type = 'ABSENT_DANS_SOURCE' THEN
            -- Row exists in cible, missing in source
            IF LOWER(p_direction) = 'cible' THEN
                -- Cible wins → INSERT missing row into target (source)
                w('-- ➕ INSERT — key ' || grp.cle);
                w('INSERT INTO ' || v_target_env || '.' || grp.nom_table);
                w('SELECT * FROM ' || grp.nom_table || '@' || v_auth_link);
                w('WHERE ' || v_where_clause || ';');
            ELSE
                -- Source wins → extra row in cible must be deleted
                w('-- 🗑 DELETE — key ' || grp.cle || ' (absent in source = source is right)');
                w('DELETE FROM ' || grp.nom_table);
                w('WHERE ' || v_where_clause || ';');
            END IF;
            w('');

        ELSE
            -- VALUE_DIFF: one UPDATE per group
            v_set_clause := '';
            v_first_set  := TRUE;
            FOR col_rec IN c_cols(grp.nom_table, grp.cle) LOOP
                v_val := CASE LOWER(p_direction)
                             WHEN 'source' THEN col_rec.valeur_source
                             ELSE               col_rec.valeur_cible
                         END;
                IF NOT v_first_set THEN v_set_clause := v_set_clause || ',' || CHR(10); END IF;
                v_set_clause := v_set_clause
                             || '    ' || col_rec.type_difference || ' = '
                             || CASE WHEN v_val IS NULL THEN 'NULL'
                                     ELSE '''' || REPLACE(v_val, '''', '''''') || ''''
                                END;
                v_first_set := FALSE;
            END LOOP;

            IF v_set_clause IS NOT NULL THEN
                w('-- ✏️  UPDATE — key ' || grp.cle);
                w('UPDATE ' || grp.nom_table);
                w('SET');
                w(v_set_clause);
                w('WHERE ' || v_where_clause || ';');
                w('');
            END IF;
        END IF;
    END LOOP;

    w('COMMIT;');
END;
/


-- =============================================================================
-- STEP 8 — ORDS: POST /audit/generate-script
-- Body: { operation_id: number, direction: "source"|"cible" }
-- Returns the SQL script as plain text (or saves to SCRIPT table + returns id)
-- =============================================================================

BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'generate-script'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name => 'audit_module',
        p_pattern     => 'generate-script',
        p_method      => 'POST',
        p_source_type => ORDS.source_type_plsql,
        p_source      =>
        'DECLARE
           v_op_id    NUMBER := :operation_id;
           v_dir      VARCHAR2(10) := NVL(LOWER(:direction), ''source'');
           v_script   CLOB;
           v_script_id NUMBER;
         BEGIN
           GENERATE_CORRECTION_SCRIPT(v_op_id, v_dir, v_script);

           -- Persist to SCRIPT table
           INSERT INTO SCRIPT (contenuSQL, dateGeneration, estValide, operation_id)
           VALUES (v_script, SYSDATE, 0, v_op_id)
           RETURNING id INTO v_script_id;
           COMMIT;

           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           :status := 200;
           htp.prn(''{"id":''        || v_script_id
                || '',''
                || ''"operationId":'' || v_op_id
                || '',''
                || ''"direction":"'' || v_dir || ''"''
                || '',''
                || ''"script":''     || apex_json.stringify(v_script)
                || ''}'');
         EXCEPTION WHEN OTHERS THEN
           ROLLBACK;
           :status := 500;
           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           htp.prn(''{"error":"'' || REPLACE(SQLERRM,CHR(34),CHR(39)) || ''"}'' );
         END;'
    );
    COMMIT;
END;
/

GRANT EXECUTE ON JSON_CLE_TO_WHERE          TO ORDS_PUBLIC_USER;
GRANT EXECUTE ON GENERATE_CORRECTION_SCRIPT TO ORDS_PUBLIC_USER;
GRANT SELECT, INSERT, UPDATE ON SCRIPT      TO ORDS_PUBLIC_USER;


-- =============================================================================
-- STEP 9 — VERIFICATION QUERIES
-- =============================================================================

-- After running EXEC_AUDIT_TABLE_V2, check that cle looks like JSON:
SELECT SUBSTR(cle,1,80) FROM PARAMETRAGE WHERE ROWNUM <= 5;
-- Expected:  {"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}#WORDING

-- Check JSON_CLE_TO_WHERE:
SELECT JSON_CLE_TO_WHERE('{"BANK_CODE":"BNC001","PRODUCT_CODE":"VISA"}') FROM DUAL;
-- Expected:  BANK_CODE='BNC001' AND PRODUCT_CODE='VISA'

-- End-to-end test:
SET SERVEROUTPUT ON;
EXEC EXEC_AUDIT_TABLE_V2('DEV','DEV_VAL','CARD_PRODUCT',21,NULL);
EXEC VALIDER_ET_STOCKER_ANOMALIES((SELECT MAX(id) FROM OPERATION));
-- DECLARE v_sql CLOB; BEGIN GENERATE_CORRECTION_SCRIPT((SELECT MAX(id) FROM OPERATION),'source',v_sql); DBMS_OUTPUT.PUT_LINE(SUBSTR(v_sql,1,4000)); END;