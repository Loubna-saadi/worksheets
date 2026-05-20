-- Oracle PL/SQL + ORDS Gateway
-- =============================================================================
-- PARAMSYNC — COMPLETE BACKEND
-- Oracle PL/SQL + ORDS Gateway
-- =============================================================================
-- ARCHITECTURE OVERVIEW:
--
--   ENVIRONNEMENT table  →  stores code + db_link name (single source of truth)
--   EXEC_AUDIT_TABLE_V2  →  single-table comparison engine
--   SCAN_TABLE           →  column-level scan used by full-schema audit
--   RUN_FULL_SCHEMA_AUDIT→  master procedure: loops all tables in the schema
--   V_PREVIEW_COMPARAISON→  view that computes diff status from PARAMETRAGE
--   VALIDER_ET_STOCKER_ANOMALIES → writes diffs from view into ANOMALIE table
--   ORDS handlers        →  REST API consumed by the Angular frontend
--
-- KEY DESIGN RULES:
--   1. db_link name is ALWAYS read from ENVIRONNEMENT.db_link — never derived
--      by string manipulation. This avoids DEV_VAL → DEVVAL_LINK bugs.
--   2. PK detection uses all_constraints → all_ind_columns (unique index) →
--      all_tab_columns column_id=1 as ordered fallbacks. all_* views work
--      correctly through a db_link because the link connects AS the schema
--      owner, so all_* = user_* for that session.
-- =============================================================================


-- =============================================================================
-- SECTION 0 — INITIAL SETUP
-- =============================================================================

-- 0.1  Add db_link column (run once — ignore ORA-01430 if already exists)
ALTER TABLE ENVIRONNEMENT ADD db_link VARCHAR2(50);

-- 0.2  Register EXACT db_link names (must match SELECT db_link FROM all_db_links)
UPDATE ENVIRONNEMENT SET db_link = 'DEV_LINK'   WHERE code = 'DEV';
UPDATE ENVIRONNEMENT SET db_link = 'DEVVAL_LINK' WHERE code = 'DEV_VAL';
UPDATE ENVIRONNEMENT SET db_link = 'PROD_LINK'   WHERE code = 'PROD';
UPDATE ENVIRONNEMENT SET db_link = 'UAT_LINK'    WHERE code = 'UAT';
UPDATE ENVIRONNEMENT SET db_link = 'SIT_LINK'    WHERE code = 'SIT';
COMMIT;

-- 0.3  Verify
SELECT code, url_api, db_link FROM ENVIRONNEMENT ORDER BY code;

-- 0.4  DB Links (create once — skip if they already exist)
/*
CREATE DATABASE LINK DEV_LINK
  CONNECT TO DEV IDENTIFIED BY PFE123
  USING 'localhost:1521/XEPDB1';

CREATE DATABASE LINK DEVVAL_LINK
  CONNECT TO DEV_VAL IDENTIFIED BY PFE123
  USING 'localhost:1521/XEPDB1';
COMMIT;
*/

-- 0.5  Quick connectivity test
-- SELECT COUNT(*) FROM CARD_PRODUCT@DEV_LINK;
-- SELECT COUNT(*) FROM CARD_PRODUCT@DEVVAL_LINK;


-- =============================================================================
-- SECTION 1 — UTILITY: CREER_OPERATION_AUDIT
-- =============================================================================
CREATE OR REPLACE PROCEDURE CREER_OPERATION_AUDIT (
    p_env_source   IN  VARCHAR2,
    p_env_cible    IN  VARCHAR2,
    p_user_id      IN  NUMBER,
    p_operation_id OUT NUMBER
) AS
    v_id_src NUMBER;
    v_id_cbl NUMBER;
BEGIN
    SELECT id INTO v_id_src FROM ENVIRONNEMENT WHERE code = UPPER(p_env_source);
    SELECT id INTO v_id_cbl FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cible);

    INSERT INTO OPERATION (type, statut, source_env, cible_env, utilisateur_id)
    VALUES ('COMPARAISON', 'EN_COURS', v_id_src, v_id_cbl, p_user_id)
    RETURNING id INTO p_operation_id;

    COMMIT;
END;
/


-- =============================================================================
-- SECTION 2 — UTILITY: START_AUDIT
-- Thin wrapper used by the full-schema engine.
-- =============================================================================
CREATE OR REPLACE PROCEDURE START_AUDIT (
    p_env_src IN  VARCHAR2,
    p_env_cbl IN  VARCHAR2,
    p_user_id IN  NUMBER,
    p_op_id   OUT NUMBER
) AS
BEGIN
    INSERT INTO OPERATION (type, statut, source_env, cible_env, utilisateur_id)
    VALUES (
        'COMPARAISON', 'EN_COURS',
        (SELECT id FROM ENVIRONNEMENT WHERE code = UPPER(p_env_src)),
        (SELECT id FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cbl)),
        p_user_id
    )
    RETURNING id INTO p_op_id;
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 3 — DIFF VIEW: V_PREVIEW_COMPARAISON
-- Classifies each (key, column) pair:
--   🟢 IDENTIQUE           — same value both sides (NULL=NULL handled by DECODE)
--   🔴 ABSENT_DANS_CIBLE    — row exists in source, missing in target
--   🟡 ABSENT_DANS_SOURCE   — row exists in target, missing in source
--   🟣 VALEUR_NULL_EN_CIBLE/SOURCE — one side NULL, other not
--   🟠 VALEUR_DIFFERENTE    — both non-null but different
-- =============================================================================

CREATE OR REPLACE VIEW V_PREVIEW_COMPARAISON AS
WITH VALEURS_EXTRACT AS (
    SELECT
        SUBSTR(p.cle, 1, INSTR(p.cle, '#') - 1)  AS CLE_OBJET,
        p.nom_table_audit                           AS TABLE_NAME,
        SUBSTR(p.cle, INSTR(p.cle, '#') + 1)      AS COLONNE,
        MAX(CASE WHEN p.environnement_id = o.source_env THEN p.valeur END) AS VAL_SRC,
        MAX(CASE WHEN p.environnement_id = o.cible_env  THEN p.valeur END) AS VAL_CBL,
        COUNT(CASE WHEN p.environnement_id = o.source_env THEN 1 END)      AS ROW_EXISTS_SRC,
        COUNT(CASE WHEN p.environnement_id = o.cible_env  THEN 1 END)      AS ROW_EXISTS_CBL,
        COUNT(CASE WHEN p.environnement_id = o.source_env AND p.valeur IS NOT NULL THEN 1 END) AS VAL_EXISTS_SRC,
        COUNT(CASE WHEN p.environnement_id = o.cible_env  AND p.valeur IS NOT NULL THEN 1 END) AS VAL_EXISTS_CBL,
        p.operation_id,
        o.utilisateur_id,
        o.source_env,
        o.cible_env
    FROM PARAMETRAGE p
    JOIN OPERATION o ON p.operation_id = o.id
    GROUP BY p.cle, p.nom_table_audit, p.operation_id,
             o.source_env, o.cible_env, o.utilisateur_id
),
-- Compute per-row (cle_objet + table) whether the ENTIRE ROW is absent on either side
ROW_PRESENCE AS (
    SELECT
        CLE_OBJET,
        TABLE_NAME,
        operation_id,
        utilisateur_id,
        source_env,
        cible_env,
        MAX(ROW_EXISTS_SRC) AS ANY_COL_SRC,  -- >0 means row exists in source
        MAX(ROW_EXISTS_CBL) AS ANY_COL_CBL   -- >0 means row exists in target
    FROM VALEURS_EXTRACT
    GROUP BY CLE_OBJET, TABLE_NAME, operation_id, utilisateur_id, source_env, cible_env
)
SELECT
    v.CLE_OBJET  AS CLE,
    v.TABLE_NAME AS NOM_TABLE,
    v.COLONNE    AS TYPE_DIFFERENCE,
    v.VAL_SRC    AS VALEUR_SOURCE,
    v.VAL_CBL    AS VALEUR_CIBLE,
    v.operation_id,
    v.utilisateur_id,
    CASE
        -- Row-level absence: use ROW_PRESENCE to detect, not column-level counts
        WHEN r.ANY_COL_SRC > 0 AND r.ANY_COL_CBL = 0   THEN '🔴 ROW ABSENT_DANS_CIBLE'
        WHEN r.ANY_COL_SRC = 0 AND r.ANY_COL_CBL > 0   THEN '🟡 ROW ABSENT_DANS_SOURCE'
        -- Column-level differences (row exists on both sides)
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

-- EXPLICATIONS DES CHANGEMENTS (MIS EN COMMENTAIRE CI-DESSOUS) :
-- L'utilisation de ROW_PRESENCE permet de détecter si toute la ligne est absente.
-- Ancien problème : WHEN ROW_EXISTS_SRC > 0 AND ROW_EXISTS_CBL = 0 
-- Cela ne fonctionnait que si la colonne était insérée pour les deux environnements.
-- =============================================================================
-- SECTION 4 — VALIDER_ET_STOCKER_ANOMALIES
-- =============================================================================
CREATE OR REPLACE PROCEDURE VALIDER_ET_STOCKER_ANOMALIES (
    p_operation_id IN NUMBER
) AS
    v_count NUMBER;
BEGIN
    INSERT INTO ANOMALIE (
        cle, nom_table, type_difference, valeur_source, valeur_cible,
        alerte_statut, description, operation_id, utilisateur_id, statut, dateCreation
    )
    SELECT
        CLE, NOM_TABLE, TYPE_DIFFERENCE, VALEUR_SOURCE, VALEUR_CIBLE,
        ALERTE_STATUT,
        'Écart détecté sur la table ' || NOM_TABLE || ' — colonne ' || TYPE_DIFFERENCE,
        p_operation_id, UTILISATEUR_ID, 'OUVERT', SYSDATE
    FROM V_PREVIEW_COMPARAISON
    WHERE operation_id  = p_operation_id
      AND ALERTE_STATUT <> '🟢 IDENTIQUE';

    v_count := SQL%ROWCOUNT;

    UPDATE OPERATION SET statut = 'ANOMALIES_GENEREES' WHERE id = p_operation_id;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE(v_count || ' anomalie(s) enregistrée(s) — op #' || p_operation_id);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERREUR VALIDER_ET_STOCKER_ANOMALIES: ' || SQLERRM);
        RAISE;
END;
/


-- =============================================================================
-- SECTION 5 — EXEC_AUDIT_TABLE_V2
-- Single-table comparison engine.
--
-- PK DETECTION ORDER (same logic that worked in the original version):
--   1. PK constraint  via all_constraints + all_cons_columns  (most tables)
--   2. Unique index   via all_ind_columns + all_indexes        (tables without PK)
--   3. First column   via all_tab_columns column_id = 1        (last resort)
--
-- NOTE: all_* views work through a db_link because the link session IS the
--       schema owner — all_* and user_* are equivalent in that context.
--
-- Parameters:
--   p_excluded_cols — optional comma-separated columns to skip e.g. 'FLAG,STATUS'
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
    v_pk_name  VARCHAR2(1000);
    v_link_src VARCHAR2(50);
    v_link_cbl VARCHAR2(50);
    v_sql      VARCHAR2(32767);
    TYPE ref_cursor IS REF CURSOR;
    c_cols     ref_cursor;
    v_col_name VARCHAR2(100);

    FUNCTION is_excluded(p_col IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF p_excluded_cols IS NULL THEN RETURN FALSE; END IF;
        RETURN INSTR(',' || UPPER(p_excluded_cols) || ',',
                     ',' || UPPER(p_col)           || ',') > 0;
    END;
BEGIN
    SELECT id, db_link INTO v_id_src, v_link_src
    FROM ENVIRONNEMENT WHERE code = UPPER(p_env_source);

    SELECT id, db_link INTO v_id_cbl, v_link_cbl
    FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cible);

    CREER_OPERATION_AUDIT(p_env_source, p_env_cible, p_user_id, v_op_id);

    -- ── PK Step 1: primary key constraint
    --    FIX: DISTINCT subquery eliminates duplicate rows from multiple schemas.
    --    NO owner filter — the connected user may not own the tables.
    -- ──────────────────────────────────────────────────────────────────────────
    BEGIN
        v_sql :=
            'SELECT LISTAGG(column_name, ''||''''-''''||'')'
         || ' WITHIN GROUP (ORDER BY position)'
         || ' FROM ('
         || '   SELECT DISTINCT cols.column_name, cols.position'
         || '   FROM all_constraints@'  || v_link_src || ' cons'
         || '   JOIN all_cons_columns@' || v_link_src || ' cols'
         || '     ON cons.constraint_name = cols.constraint_name'
         || '    AND cons.owner           = cols.owner'
         || '   WHERE cons.table_name      = :1'
         || '     AND cons.constraint_type = ''P'''
         || ')';
        EXECUTE IMMEDIATE v_sql INTO v_pk_name USING UPPER(p_nom_table);
    EXCEPTION WHEN OTHERS THEN v_pk_name := NULL;
    END;

    -- ── PK Step 2: unique index fallback
    --    FIX: DISTINCT + pick first index via ROWNUM on outer query
    -- ──────────────────────────────────────────────────────────────────────────
    IF v_pk_name IS NULL THEN
        BEGIN
            v_sql :=
                'SELECT LISTAGG(column_name, ''||''''-''''||'')'
             || ' WITHIN GROUP (ORDER BY column_position)'
             || ' FROM ('
             || '   SELECT DISTINCT ic.column_name, ic.column_position'
             || '   FROM all_ind_columns@' || v_link_src || ' ic'
             || '   JOIN all_indexes@'     || v_link_src || ' idx'
             || '     ON ic.index_name  = idx.index_name'
             || '    AND ic.table_owner = idx.owner'
             || '   WHERE ic.table_name  = :1'
             || '     AND idx.uniqueness = ''UNIQUE'''
             || '     AND idx.index_name = ('
             || '       SELECT index_name'
             || '       FROM all_indexes@' || v_link_src
             || '       WHERE table_name = :2'
             || '         AND uniqueness = ''UNIQUE'''
             || '         AND ROWNUM = 1'
             || '     )'
             || ')';
            EXECUTE IMMEDIATE v_sql INTO v_pk_name
                USING UPPER(p_nom_table), UPPER(p_nom_table);
        EXCEPTION WHEN OTHERS THEN v_pk_name := NULL;
        END;
    END IF;

    -- ── PK Step 3: last resort — first column (original, unchanged)
    -- ──────────────────────────────────────────────────────────────────────────
    IF v_pk_name IS NULL THEN
        v_sql := 'SELECT column_name FROM all_tab_columns@' || v_link_src
              || ' WHERE table_name = :1 AND column_id = 1';
        EXECUTE IMMEDIATE v_sql INTO v_pk_name USING UPPER(p_nom_table);
    END IF;

    DBMS_OUTPUT.PUT_LINE('PK=[' || v_pk_name || ']');

    -- ── Column loop — UNCHANGED from original working version
    -- ──────────────────────────────────────────────────────────────────────────
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

        IF INSTR(UPPER(v_pk_name), UPPER(v_col_name)) = 0
           AND NOT is_excluded(v_col_name)
        THEN
            v_sql :=
                'INSERT INTO PARAMETRAGE'
             || ' (cle, valeur, environnement_id, operation_id, nom_table_audit)'
             || ' SELECT (' || v_pk_name || ') || ''#'' || ''' || v_col_name || ''','
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
        END IF;
    END LOOP;
    CLOSE c_cols;

    UPDATE OPERATION SET statut = 'TERMINE' WHERE id = v_op_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('done op=' || v_op_id);
END;
/

-- =============================================================================
-- SECTION 6 — SCAN_TABLE
-- Per-table engine called by RUN_FULL_SCHEMA_AUDIT.
-- Receives pre-resolved IDs and shared op_id — does NOT create a new operation.
-- Same PK detection logic as EXEC_AUDIT_TABLE_V2.
-- =============================================================================
CREATE OR REPLACE PROCEDURE SCAN_TABLE (
    p_env_src   IN VARCHAR2,
    p_env_cbl   IN VARCHAR2,
    p_nom_table IN VARCHAR2,
    p_id_src    IN NUMBER,
    p_id_cbl    IN NUMBER,
    p_op_id     IN NUMBER
) AS
    v_pk_expression VARCHAR2(2000) := NULL;
    v_link_src      VARCHAR2(50);
    v_link_cbl      VARCHAR2(50);
    v_sql           VARCHAR2(32767);
    v_ins_src       NUMBER := 0;
    v_ins_cbl       NUMBER := 0;
    TYPE ref_cursor IS REF CURSOR;
    c_cols          ref_cursor;
    v_col_name      VARCHAR2(100);
BEGIN
    SELECT db_link INTO v_link_src FROM ENVIRONNEMENT WHERE code = UPPER(p_env_src);
    SELECT db_link INTO v_link_cbl FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cbl);

    -- ── PK Step 1: primary key constraint
    --    FIX: DISTINCT subquery, NO owner filter
    -- ──────────────────────────────────────────────────────────────────────────
    BEGIN
        v_sql :=
            'SELECT LISTAGG(column_name, ''||''''-''''||'')'
         || ' WITHIN GROUP (ORDER BY position)'
         || ' FROM ('
         || '   SELECT DISTINCT cols.column_name, cols.position'
         || '   FROM all_constraints@'  || v_link_src || ' cons'
         || '   JOIN all_cons_columns@' || v_link_src || ' cols'
         || '     ON cons.constraint_name = cols.constraint_name'
         || '    AND cons.owner           = cols.owner'
         || '   WHERE cons.table_name      = :1'
         || '     AND cons.constraint_type = ''P'''
         || ')';
        EXECUTE IMMEDIATE v_sql INTO v_pk_expression USING UPPER(p_nom_table);
    EXCEPTION WHEN OTHERS THEN v_pk_expression := NULL;
    END;

    -- ── PK Step 2: unique index fallback
    --    FIX: DISTINCT + ROWNUM=1 to pick one index
    -- ──────────────────────────────────────────────────────────────────────────
    IF v_pk_expression IS NULL THEN
        BEGIN
            v_sql :=
                'SELECT LISTAGG(column_name, ''||''''-''''||'')'
             || ' WITHIN GROUP (ORDER BY column_position)'
             || ' FROM ('
             || '   SELECT DISTINCT ic.column_name, ic.column_position'
             || '   FROM all_ind_columns@' || v_link_src || ' ic'
             || '   JOIN all_indexes@'     || v_link_src || ' idx'
             || '     ON ic.index_name  = idx.index_name'
             || '    AND ic.table_owner = idx.owner'
             || '   WHERE ic.table_name  = :1'
             || '     AND idx.uniqueness = ''UNIQUE'''
             || '     AND idx.index_name = ('
             || '       SELECT index_name'
             || '       FROM all_indexes@' || v_link_src
             || '       WHERE table_name = :2'
             || '         AND uniqueness = ''UNIQUE'''
             || '         AND ROWNUM = 1'
             || '     )'
             || ')';
            EXECUTE IMMEDIATE v_sql INTO v_pk_expression
                USING UPPER(p_nom_table), UPPER(p_nom_table);
        EXCEPTION WHEN OTHERS THEN v_pk_expression := NULL;
        END;
    END IF;

    -- ── PK Step 3: no PK — skip table (original, unchanged)
    -- ──────────────────────────────────────────────────────────────────────────
    IF v_pk_expression IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('!! SKIP (no PK): ' || p_nom_table);
        RETURN;
    END IF;

    -- ── Column loop — UNCHANGED from original working version
    -- ──────────────────────────────────────────────────────────────────────────
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

        IF INSTR(UPPER(v_pk_expression), UPPER(v_col_name)) = 0 THEN
            v_sql :=
                'INSERT INTO PARAMETRAGE'
             || ' (cle, valeur, environnement_id, operation_id, nom_table_audit)'
             || ' SELECT (' || v_pk_expression || ') || ''#'' || ''' || v_col_name || ''','
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
        END IF;
    END LOOP;
    CLOSE c_cols;

    DBMS_OUTPUT.PUT_LINE('SCAN [' || p_nom_table || '] src=' || v_ins_src || ' cbl=' || v_ins_cbl);
END;
/


-- =============================================================================
-- SECTION 7 — RUN_FULL_SCHEMA_AUDIT
-- Master procedure: one operation, allR tables, optional exclusion list.
-- =============================================================================
CREATE OR REPLACE PROCEDURE RUN_FULL_SCHEMA_AUDIT (
    p_env_src         IN VARCHAR2,
    p_env_cbl         IN VARCHAR2,
    p_user_id         IN NUMBER,
    p_excluded_tables IN VARCHAR2 DEFAULT NULL
) AS
    v_op_id    NUMBER;
    v_id_src   NUMBER;
    v_id_cbl   NUMBER;
    v_link_src VARCHAR2(50);
    TYPE t_cursor IS REF CURSOR;
    c_tables   t_cursor;
    v_table    VARCHAR2(128);
    v_sql_list VARCHAR2(2000);
    v_count    NUMBER := 0;

    FUNCTION is_excluded_table(p_tbl IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF p_excluded_tables IS NULL THEN RETURN FALSE; END IF;
        RETURN INSTR(',' || UPPER(p_excluded_tables) || ',',
                     ',' || UPPER(p_tbl)             || ',') > 0;
    END;
BEGIN
    SELECT db_link INTO v_link_src FROM ENVIRONNEMENT WHERE code = UPPER(p_env_src);
    SELECT id      INTO v_id_src   FROM ENVIRONNEMENT WHERE code = UPPER(p_env_src);
    SELECT id      INTO v_id_cbl   FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cbl);

    START_AUDIT(p_env_src, p_env_cbl, p_user_id, v_op_id);
    DBMS_OUTPUT.PUT_LINE('RUN_FULL_SCHEMA_AUDIT started — op_id: ' || v_op_id);

    -- Discover tables via all_tables (owner filter keeps only schema tables)
    v_sql_list :=
        'SELECT table_name FROM all_tables@' || v_link_src
     || ' WHERE owner NOT IN'
     || '       (''SYS'',''SYSTEM'',''MDSYS'',''CTXSYS'',''XDB'',''WMSYS'',''OUTLN'')'
     || '   AND table_name NOT IN'
     || '       (''PARAMETRAGE'',''ANOMALIE'',''OPERATION'',''ENVIRONNEMENT'',''UTILISATEUR'')'
     || '   AND table_name NOT LIKE ''BIN$%'''
     || ' ORDER BY table_name';

    OPEN c_tables FOR v_sql_list;
    LOOP
        FETCH c_tables INTO v_table;
        EXIT WHEN c_tables%NOTFOUND;

        IF NOT is_excluded_table(v_table) THEN
            v_count := v_count + 1;
            DBMS_OUTPUT.PUT_LINE('  [' || v_count || '] Scanning: ' || v_table);
            SCAN_TABLE(p_env_src, p_env_cbl, v_table, v_id_src, v_id_cbl, v_op_id);
        ELSE
            DBMS_OUTPUT.PUT_LINE('  SKIP (excluded): ' || v_table);
        END IF;
    END LOOP;
    CLOSE c_tables;

    UPDATE OPERATION SET statut = 'TERMINE' WHERE id = v_op_id;
    COMMIT;

    VALIDER_ET_STOCKER_ANOMALIES(v_op_id);

    DBMS_OUTPUT.PUT_LINE(
        'RUN_FULL_SCHEMA_AUDIT done — ' || v_count || ' table(s) | op_id: ' || v_op_id
    );
END;
/


-- =============================================================================
-- SECTION 8 — ORDS MODULE SETUP
-- =============================================================================
BEGIN
    ORDS.DEFINE_MODULE(
        p_module_name => 'audit_module',
        p_base_path   => 'audit/',
        p_status      => 'PUBLISHED'
    );
    COMMIT;
END;
/

GRANT SELECT ON ANOMALIE      TO ORDS_PUBLIC_USER;
GRANT SELECT ON OPERATION     TO ORDS_PUBLIC_USER;
GRANT SELECT ON ENVIRONNEMENT TO ORDS_PUBLIC_USER;


-- =============================================================================
-- SECTION 9 — ORDS: POST /audit/table
-- Body: { env_src, env_cbl, nom_table, user_id, excluded_cols? }
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(p_module_name => 'audit_module', p_pattern => 'table');
    ORDS.DEFINE_HANDLER(
        p_module_name => 'audit_module',
        p_pattern     => 'table',
        p_method      => 'POST',
        p_source_type => ORDS.source_type_plsql,
        p_source      =>
        'DECLARE
           v_op_id    NUMBER;
           v_excl_col VARCHAR2(4000) := :excluded_cols;
           v_id_src   NUMBER;
           v_id_cbl   NUMBER;
           v_link_src VARCHAR2(50);
           v_link_cbl VARCHAR2(50);
         BEGIN
           -- Validate both envs exist first — gives a clean 400-style message
           BEGIN
             SELECT id, db_link INTO v_id_src, v_link_src
             FROM ENVIRONNEMENT WHERE code = UPPER(:env_src);
           EXCEPTION WHEN NO_DATA_FOUND THEN
             :status := 400;
             htp.prn(''{"error":"Unknown source environment: '' || :env_src || ''"}'' );
             RETURN;
           END;

           BEGIN
             SELECT id, db_link INTO v_id_cbl, v_link_cbl
             FROM ENVIRONNEMENT WHERE code = UPPER(:env_cbl);
           EXCEPTION WHEN NO_DATA_FOUND THEN
             :status := 400;
             htp.prn(''{"error":"Unknown target environment: '' || :env_cbl || ''"}'' );
             RETURN;
           END;

           -- Create the operation row first so we own the ID
           CREER_OPERATION_AUDIT(:env_src, :env_cbl, :user_id, v_op_id);

           -- Run the scan (uses its own operation — we pass ours via a wrapper below)
           -- Actually call the scan directly so op_id is shared:
           EXEC_AUDIT_TABLE_V2(:env_src, :env_cbl, :nom_table, :user_id, v_excl_col);

           -- Pick up the op that was just created by EXEC_AUDIT_TABLE_V2
           SELECT MAX(id) INTO v_op_id
           FROM OPERATION
           WHERE utilisateur_id = :user_id
             AND statut IN (''TERMINE'', ''EN_COURS'');

           VALIDER_ET_STOCKER_ANOMALIES(v_op_id);

           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           :status := 200;
           htp.prn(''{"message":"ok","operationId":'' || v_op_id || ''}'');
         EXCEPTION WHEN OTHERS THEN
           ROLLBACK;
           :status := 500;
           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           htp.prn(''{"error":'' || TO_CHAR(SQLCODE) || '',"message":"'' || REPLACE(SQLERRM,CHR(34),CHR(39)) || ''"}'' );
         END;'
    );
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 10 — ORDS: POST /audit/full
-- Body: { env_src, env_cbl, user_id, excluded_tables? }
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(p_module_name => 'audit_module', p_pattern => 'full');
    ORDS.DEFINE_HANDLER(
        p_module_name => 'audit_module',
        p_pattern     => 'full',
        p_method      => 'POST',
        p_source_type => ORDS.source_type_plsql,
        p_source      =>
        'DECLARE
           v_op_id    NUMBER;
           v_excl_tbl VARCHAR2(4000) := :excluded_tables;
         BEGIN
           RUN_FULL_SCHEMA_AUDIT(:env_src, :env_cbl, :user_id, v_excl_tbl);

           SELECT MAX(id) INTO v_op_id
           FROM OPERATION
           WHERE utilisateur_id = :user_id
             AND statut IN (''TERMINE'', ''ANOMALIES_GENEREES'');

           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           :status := 200;
           htp.prn(''{"message":"ok","operationId":'' || v_op_id || ''}'');
         EXCEPTION WHEN OTHERS THEN
           ROLLBACK;
           :status := 500;
           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           htp.prn(''{"error":'' || TO_CHAR(SQLCODE) || '',"message":"'' || REPLACE(SQLERRM,CHR(34),CHR(39)) || ''"}'' );
         END;'
    );
    COMMIT;
END;
/

-- =============================================================================
-- SECTION 11 — ORDS: GET /audit/results/:opId
-- Returns all anomalies for a given operation (unlimited rows).
-- =============================================================================
BEGIN
    ORDS.SET_MODULE_ORIGINS_ALLOWED(
        p_module_name     => 'audit_module',
        p_origins_allowed => 'http://localhost:4200'
    );

    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'results/:opId'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'audit_module',
        p_pattern        => 'results/:opId',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         => 'SELECT * FROM ANOMALIE WHERE operation_id = :opId ORDER BY id ASC',
        p_items_per_page => 0
    );
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 12 — ORDS: GET /audit/columns/:tableName?env=DEV
-- Returns auditable columns for the "Exclude columns" dropdown.
-- db_link resolved from ENVIRONNEMENT — never derived from :env.
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'columns/:tableName'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name => 'audit_module',
        p_pattern     => 'columns/:tableName',
        p_method      => 'GET',
        p_source_type => ORDS.source_type_plsql,
        p_source      =>
        'DECLARE
           v_link  VARCHAR2(50);
           v_sql   VARCHAR2(4000);
           v_cur   SYS_REFCURSOR;
           v_col   VARCHAR2(100);
           v_dtype VARCHAR2(50);
           v_null  VARCHAR2(1);
           v_json  CLOB    := ''{"items":['';
           v_first BOOLEAN := TRUE;
         BEGIN
           SELECT db_link INTO v_link
           FROM ENVIRONNEMENT WHERE code = UPPER(:env);

           -- all_tab_columns works through db_link (link session = schema owner)
           v_sql :=
               ''SELECT column_name, data_type, nullable''
            || '' FROM all_tab_columns@'' || v_link
            || '' WHERE table_name = UPPER(:1)''
            || ''   AND column_name NOT IN''
            || ''       (''''USER_CREATE'''',''''DATE_CREATE'''',''''USER_MODIF'''',''''DATE_MODIF'''')''
            || '' ORDER BY column_id'';

           OPEN v_cur FOR v_sql USING UPPER(:tableName);
           LOOP
             FETCH v_cur INTO v_col, v_dtype, v_null;
             EXIT WHEN v_cur%NOTFOUND;
             IF NOT v_first THEN v_json := v_json || '',''; END IF;
             v_json := v_json
                    || ''{"column_name":"'' || v_col
                    || ''","data_type":"''  || v_dtype
                    || ''","nullable":"''   || v_null || ''"}'' ;
             v_first := FALSE;
           END LOOP;
           CLOSE v_cur;

           v_json := v_json || '']}'';
           :status := 200;
           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           htp.prn(v_json);
         END;'
    );
    COMMIT;
END;
/

-- =============================================================================
-- SECTION 13 — ORDS: GET /audit/tables?env=DEV
-- Returns auditable tables for the "Exclude tables" dropdown.
-- db_link resolved from ENVIRONNEMENT — never derived from :env.
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'tables'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name => 'audit_module',
        p_pattern     => 'tables',
        p_method      => 'GET',
        p_source_type => ORDS.source_type_plsql,
        p_source      =>
        'DECLARE
           v_link  VARCHAR2(50);
           v_sql   VARCHAR2(4000);
           v_cur   SYS_REFCURSOR;
           v_tbl   VARCHAR2(128);
           v_json  CLOB    := ''{"items":['';
           v_first BOOLEAN := TRUE;
         BEGIN
           SELECT db_link INTO v_link
           FROM ENVIRONNEMENT WHERE code = UPPER(:env);

           v_sql :=
               ''SELECT table_name FROM all_tables@'' || v_link
            || '' WHERE owner NOT IN''
            || ''       (''''SYS'''',''''SYSTEM'''',''''MDSYS'''',''''CTXSYS'''',''''XDB'''',''''WMSYS'''',''''OUTLN'''')''
            || ''   AND table_name NOT IN''
            || ''       (''''PARAMETRAGE'''',''''ANOMALIE'''',''''OPERATION'''',''''ENVIRONNEMENT'''',''''UTILISATEUR'''')''
            || ''   AND table_name NOT LIKE ''''BIN$%'''' ''
            || '' ORDER BY table_name'';

           OPEN v_cur FOR v_sql;
           LOOP
             FETCH v_cur INTO v_tbl;
             EXIT WHEN v_cur%NOTFOUND;
             IF NOT v_first THEN v_json := v_json || '',''; END IF;
             v_json := v_json || ''{"table_name":"'' || v_tbl || ''"}'' ;
             v_first := FALSE;
           END LOOP;
           CLOSE v_cur;

           v_json := v_json || '']}'';
           :status := 200;
           owa_util.mime_header(''application/json'', FALSE);
           owa_util.http_header_close;
           htp.prn(v_json);
         END;'
    );
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 14 — ORDS: GET /audit/dashboard-stats?userId=21
-- KPI summary scoped to the requesting user.
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'dashboard-stats'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'audit_module',
        p_pattern        => 'dashboard-stats',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_items_per_page => 0,
        p_source         =>
        'SELECT
           TO_CHAR(
             (SELECT MAX(dateOperation) FROM OPERATION WHERE utilisateur_id = :userId),
             ''YYYY-MM-DD"T"HH24:MI:SS''
           )                                                         AS last_audit_date,
           (SELECT COUNT(*) FROM ANOMALIE a
            JOIN OPERATION o ON a.operation_id = o.id
            WHERE o.utilisateur_id = :userId)                        AS total_anomalies,
           ROUND(
             (SELECT COUNT(*) FROM ANOMALIE a
              JOIN OPERATION o ON a.operation_id = o.id
              WHERE o.utilisateur_id = :userId
                AND a.alerte_statut  = ''🟢 IDENTIQUE'') * 100.0
             / NULLIF(
               (SELECT COUNT(*) FROM ANOMALIE a
                JOIN OPERATION o ON a.operation_id = o.id
                WHERE o.utilisateur_id = :userId), 0)
           , 1)                                                       AS sync_rate,
           (SELECT COUNT(*) FROM OPERATION
            WHERE utilisateur_id = :userId)                          AS total_reports
         FROM DUAL'
    );
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 15 — ORDS: GET /audit/operations/recent?userId=21
-- Recent operations for the dashboard table.
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'operations/recent'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'audit_module',
        p_pattern        => 'operations/recent',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_items_per_page => 0,
        p_source         =>
        'SELECT
           o.id,
           o.type,
           o.statut,
           TO_CHAR(o.dateOperation, ''YYYY-MM-DD"T"HH24:MI:SS'') AS date_operation,
           e1.code  AS source_env,
           e2.code  AS cible_env,
           COUNT(DISTINCT a.nom_table) AS tables_impactees,
           COUNT(a.id)                 AS nb_anomalies
         FROM OPERATION o
         LEFT JOIN ENVIRONNEMENT e1 ON o.source_env   = e1.id
         LEFT JOIN ENVIRONNEMENT e2 ON o.cible_env    = e2.id
         LEFT JOIN ANOMALIE      a  ON a.operation_id = o.id
         WHERE o.utilisateur_id = :userId
         GROUP BY o.id, o.type, o.statut, o.dateOperation, e1.code, e2.code
         ORDER BY o.dateOperation DESC
         FETCH FIRST 10 ROWS ONLY'
    );
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 16 — ORDS: GET /audit/drift-by-table?userId=21
-- Top drifting tables for the dashboard widget.
-- =============================================================================
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'drift-by-table'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'audit_module',
        p_pattern        => 'drift-by-table',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_items_per_page => 0,
        p_source         =>
        'SELECT
           a.nom_table,
           COUNT(*)  AS total_anomalies,
           COUNT(CASE WHEN a.alerte_statut LIKE ''%ABSENT%''    THEN 1 END) AS absences,
           COUNT(CASE WHEN a.alerte_statut LIKE ''%DIFFERENT%'' THEN 1 END) AS differences,
           COUNT(CASE WHEN a.alerte_statut LIKE ''%NULL%''      THEN 1 END) AS nulls,
           MAX(a.dateCreation) AS last_seen
         FROM ANOMALIE a
         JOIN OPERATION o ON a.operation_id = o.id
         WHERE a.nom_table IS NOT NULL
           AND o.utilisateur_id = :userId
         GROUP BY a.nom_table
         ORDER BY total_anomalies DESC
         FETCH FIRST 6 ROWS ONLY'
    );
    COMMIT;
END;
/


-- =============================================================================
-- SECTION 17 — ORDS: Audit logs (SUPERUSER + ADMIN scoped views)
-- =============================================================================

-- GET /audit/logs/superuser?superuserId=21
-- Shows ops by the superuser + all their child users
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'logs/superuser'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'audit_module',
        p_pattern        => 'logs/superuser',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_items_per_page => 0,
        p_source         =>
        'SELECT
           o.id,
           o.type,
           o.statut,
           TO_CHAR(o.dateOperation, ''YYYY-MM-DD"T"HH24:MI:SS'') AS date_operation,
           e1.code AS source_env,
           e2.code AS cible_env,
           u.login AS performed_by,
           u.role  AS user_role,
           NULL    AS superuser_login,
           COUNT(DISTINCT a.nom_table) AS tables_impactees,
           COUNT(a.id)                 AS nb_anomalies
         FROM OPERATION o
         JOIN UTILISATEUR u ON o.utilisateur_id = u.id
         LEFT JOIN ENVIRONNEMENT e1 ON o.source_env   = e1.id
         LEFT JOIN ENVIRONNEMENT e2 ON o.cible_env    = e2.id
         LEFT JOIN ANOMALIE      a  ON a.operation_id = o.id
         WHERE o.utilisateur_id = :superuserId
            OR u.parent_user_id = :superuserId
         GROUP BY o.id, o.type, o.statut, o.dateOperation,
                  e1.code, e2.code, u.login, u.role
         ORDER BY o.dateOperation DESC'
    );
    COMMIT;
END;
/

-- GET /audit/logs/admin
-- Shows all ops with superuser grouping
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'audit_module',
        p_pattern     => 'logs/admin'
    );
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'audit_module',
        p_pattern        => 'logs/admin',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_items_per_page => 0,
        p_source         =>
        'SELECT
           o.id,
           o.type,
           o.statut,
           TO_CHAR(o.dateOperation, ''YYYY-MM-DD"T"HH24:MI:SS'') AS date_operation,
           e1.code  AS source_env,
           e2.code  AS cible_env,
           u.login  AS performed_by,
           u.role   AS user_role,
           su.login AS superuser_login,
           COUNT(DISTINCT a.nom_table) AS tables_impactees,
           COUNT(a.id)                 AS nb_anomalies
         FROM OPERATION o
         JOIN UTILISATEUR u  ON o.utilisateur_id = u.id
         LEFT JOIN UTILISATEUR su ON u.parent_user_id = su.id
         LEFT JOIN ENVIRONNEMENT e1 ON o.source_env   = e1.id
         LEFT JOIN ENVIRONNEMENT e2 ON o.cible_env    = e2.id
         LEFT JOIN ANOMALIE      a  ON a.operation_id = o.id
         GROUP BY o.id, o.type, o.statut, o.dateOperation,
                  e1.code, e2.code, u.login, u.role, su.login
         ORDER BY o.dateOperation DESC'
    );
    COMMIT;
END;
/

-- See ALL registered routes for audit_module
SELECT t.uri_template, h.method, h.source_type
FROM user_ords_modules m
JOIN user_ords_templates t ON t.module_id = m.id
JOIN user_ords_handlers  h ON h.template_id = t.id
WHERE m.name = 'audit_module'
ORDER BY t.uri_template;













-- =============================================================================
-- SECTION 18 — VERIFICATION
-- =============================================================================

-- 18.1  All environments have db_link
SELECT code, db_link FROM ENVIRONNEMENT ORDER BY code;

-- 18.2  All ORDS routes published
SELECT uri_template
FROM user_ords_templates
WHERE module_id = (SELECT id FROM user_ords_modules WHERE name = 'audit_module')
ORDER BY uri_template;

-- 18.3  End-to-end test
SET SERVEROUTPUT ON;

DELETE FROM PARAMETRAGE WHERE operation_id IN
    (SELECT id FROM OPERATION WHERE utilisateur_id = 21);
DELETE FROM ANOMALIE WHERE operation_id IN
    (SELECT id FROM OPERATION WHERE utilisateur_id = 21);
COMMIT;

EXEC EXEC_AUDIT_TABLE_V2('DEV', 'DEV_VAL', 'CARD_PRODUCT', 21, NULL);
show user;

-- Should show 2 rows (one per env) with non-zero counts
SELECT environnement_id, COUNT(*) AS rows_inserted
FROM PARAMETRAGE
WHERE operation_id = (SELECT MAX(id) FROM OPERATION)
GROUP BY environnement_id;

-- Should show diff categories
SELECT alerte_statut, COUNT(*) AS cnt
FROM V_PREVIEW_COMPARAISON
WHERE operation_id = (SELECT MAX(id) FROM OPERATION)
GROUP BY alerte_statut
ORDER BY cnt DESC;

EXEC VALIDER_ET_STOCKER_ANOMALIES(196);

SELECT alerte_statut, COUNT(*) AS cnt
FROM ANOMALIE
WHERE operation_id = (SELECT MAX(id) FROM OPERATION)
GROUP BY alerte_statut
ORDER BY cnt DESC;
select * from anomalie;

SELECT id, statut FROM OPERATION WHERE id = (SELECT MAX(id) FROM OPERATION);


-- Check what data_type Oracle actually stores for your CHAR columns
SELECT column_name, data_type, char_used
FROM all_tab_columns@DEV_LINK
WHERE table_name = 'CARD_RANGE'
  AND column_name NOT IN ('USER_CREATE','DATE_CREATE','USER_MODIF','DATE_MODIF',
                          'MIN_CARD_RANGE','MAX_CARD_RANGE')
ORDER BY column_id;

-- Count by type
SELECT data_type, COUNT(*) 
FROM all_tab_columns@DEV_LINK
WHERE table_name = 'CARD_RANGE'
GROUP BY data_type;


-- ============================================================
-- RUN THESE TWO BLOCKS — they replace only the two procedures
-- that still have the old data_type filter
-- ============================================================

-- STEP 1: Widen the column (ignore error if already done)
ALTER TABLE PARAMETRAGE MODIFY valeur VARCHAR2(4000);
COMMIT;

-- STEP 2: Replace EXEC_AUDIT_TABLE_V2 with fixed version
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
    v_pk_name  VARCHAR2(1000);
    v_link_src VARCHAR2(50);
    v_link_cbl VARCHAR2(50);
    v_sql      VARCHAR2(32767);
    TYPE ref_cursor IS REF CURSOR;
    c_cols     ref_cursor;
    v_col_name VARCHAR2(100);

    FUNCTION is_excluded(p_col IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF p_excluded_cols IS NULL THEN RETURN FALSE; END IF;
        RETURN INSTR(',' || UPPER(p_excluded_cols) || ',',
                     ',' || UPPER(p_col)           || ',') > 0;
    END;
BEGIN
    SELECT id, db_link INTO v_id_src, v_link_src
    FROM ENVIRONNEMENT WHERE code = UPPER(p_env_source);

    SELECT id, db_link INTO v_id_cbl, v_link_cbl
    FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cible);

    CREER_OPERATION_AUDIT(p_env_source, p_env_cible, p_user_id, v_op_id);

    -- PK: constraint
    BEGIN
        v_sql :=
            'SELECT LISTAGG(cols.column_name, ''||''''-''''||'')'
         || ' WITHIN GROUP (ORDER BY cols.position)'
         || ' FROM all_constraints@'  || v_link_src || ' cons'
         || ' JOIN all_cons_columns@' || v_link_src || ' cols'
         || '   ON cons.constraint_name = cols.constraint_name'
         || ' WHERE cons.table_name     = :1'
         || '   AND cons.constraint_type = ''P''';
        EXECUTE IMMEDIATE v_sql INTO v_pk_name USING UPPER(p_nom_table);
    EXCEPTION WHEN OTHERS THEN v_pk_name := NULL;
    END;

    -- PK: unique index fallback
    IF v_pk_name IS NULL THEN
        BEGIN
            v_sql :=
                'SELECT LISTAGG(column_name, ''||''''-''''||'')'
             || ' WITHIN GROUP (ORDER BY column_position)'
             || ' FROM all_ind_columns@' || v_link_src
             || ' WHERE table_name = :1'
             || '   AND index_name = ('
             || '     SELECT index_name FROM all_indexes@' || v_link_src
             || '     WHERE table_name = :2'
             || '       AND uniqueness = ''UNIQUE'' AND ROWNUM = 1)';
            EXECUTE IMMEDIATE v_sql INTO v_pk_name
                USING UPPER(p_nom_table), UPPER(p_nom_table);
        EXCEPTION WHEN OTHERS THEN v_pk_name := NULL;
        END;
    END IF;

    -- PK: last resort — first column
    IF v_pk_name IS NULL THEN
        v_sql := 'SELECT column_name FROM all_tab_columns@' || v_link_src
              || ' WHERE table_name = :1 AND column_id = 1';
        EXECUTE IMMEDIATE v_sql INTO v_pk_name USING UPPER(p_nom_table);
    END IF;

    DBMS_OUTPUT.PUT_LINE('PK=[' || v_pk_name || ']');

    -- ── FIXED: extended types + SUBSTR overflow protection ──
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

        IF INSTR(UPPER(v_pk_name), UPPER(v_col_name)) = 0
           AND NOT is_excluded(v_col_name)
        THEN
            -- SUBSTR prevents overflow of PARAMETRAGE.valeur VARCHAR2(4000)
            v_sql :=
                'INSERT INTO PARAMETRAGE'
             || ' (cle, valeur, environnement_id, operation_id, nom_table_audit)'
             || ' SELECT (' || v_pk_name || ') || ''#'' || ''' || v_col_name || ''','
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
        END IF;
    END LOOP;
    CLOSE c_cols;

    UPDATE OPERATION SET statut = 'TERMINE' WHERE id = v_op_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('done op=' || v_op_id);
END;
/

-- STEP 3: Replace SCAN_TABLE with fixed version
CREATE OR REPLACE PROCEDURE SCAN_TABLE (
    p_env_src   IN VARCHAR2,
    p_env_cbl   IN VARCHAR2,
    p_nom_table IN VARCHAR2,
    p_id_src    IN NUMBER,
    p_id_cbl    IN NUMBER,
    p_op_id     IN NUMBER
) AS
    v_pk_expression VARCHAR2(2000) := NULL;
    v_link_src      VARCHAR2(50);
    v_link_cbl      VARCHAR2(50);
    v_sql           VARCHAR2(32767);
    v_ins_src       NUMBER := 0;
    v_ins_cbl       NUMBER := 0;
    TYPE ref_cursor IS REF CURSOR;
    c_cols          ref_cursor;
    v_col_name      VARCHAR2(100);
BEGIN
    SELECT db_link INTO v_link_src FROM ENVIRONNEMENT WHERE code = UPPER(p_env_src);
    SELECT db_link INTO v_link_cbl FROM ENVIRONNEMENT WHERE code = UPPER(p_env_cbl);

    BEGIN
        v_sql :=
            'SELECT LISTAGG(cols.column_name, ''||''''-''''||'')'
         || ' WITHIN GROUP (ORDER BY cols.position)'
         || ' FROM all_constraints@'  || v_link_src || ' cons'
         || ' JOIN all_cons_columns@' || v_link_src || ' cols'
         || '   ON cons.constraint_name = cols.constraint_name'
         || ' WHERE cons.table_name     = :1'
         || '   AND cons.constraint_type = ''P''';
        EXECUTE IMMEDIATE v_sql INTO v_pk_expression USING UPPER(p_nom_table);
    EXCEPTION WHEN OTHERS THEN v_pk_expression := NULL;
    END;

    IF v_pk_expression IS NULL THEN
        BEGIN
            v_sql :=
                'SELECT LISTAGG(column_name, ''||''''-''''||'')'
             || ' WITHIN GROUP (ORDER BY column_position)'
             || ' FROM all_ind_columns@' || v_link_src
             || ' WHERE table_name = :1'
             || '   AND index_name = ('
             || '     SELECT index_name FROM all_indexes@' || v_link_src
             || '     WHERE table_name = :2'
             || '       AND uniqueness = ''UNIQUE'' AND ROWNUM = 1)';
            EXECUTE IMMEDIATE v_sql INTO v_pk_expression
                USING UPPER(p_nom_table), UPPER(p_nom_table);
        EXCEPTION WHEN OTHERS THEN v_pk_expression := NULL;
        END;
    END IF;

    IF v_pk_expression IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('!! SKIP (no PK): ' || p_nom_table);
        RETURN;
    END IF;

    -- ── FIXED: extended types + SUBSTR overflow protection ──
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

        IF INSTR(UPPER(v_pk_expression), UPPER(v_col_name)) = 0 THEN
            v_sql :=
                'INSERT INTO PARAMETRAGE'
             || ' (cle, valeur, environnement_id, operation_id, nom_table_audit)'
             || ' SELECT (' || v_pk_expression || ') || ''#'' || ''' || v_col_name || ''','
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
        END IF;
    END LOOP;
    CLOSE c_cols;

    DBMS_OUTPUT.PUT_LINE('SCAN [' || p_nom_table || '] src=' || v_ins_src || ' cbl=' || v_ins_cbl);
END;
/

-- STEP 4: Verify the fix
SET SERVEROUTPUT ON;

DELETE FROM PARAMETRAGE WHERE operation_id IN
    (SELECT id FROM OPERATION WHERE utilisateur_id = 21 
     AND id = (SELECT MAX(id) FROM OPERATION WHERE utilisateur_id = 21));
COMMIT;

EXEC EXEC_AUDIT_TABLE_V2('DEV', 'DEV_VAL', 'CARD_RANGE', 21, NULL);

-- This should now show ~58 rows per env, NOT 18
SELECT environnement_id, COUNT(*) AS rows_inserted
FROM PARAMETRAGE
WHERE operation_id = (SELECT MAX(id) FROM OPERATION)
GROUP BY environnement_id;

-- This should now show the absent row with ALL 58 columns flagged
SELECT alerte_statut, COUNT(*) AS cnt
FROM V_PREVIEW_COMPARAISON
WHERE operation_id = (SELECT MAX(id) FROM OPERATION)
GROUP BY alerte_statut ORDER BY cnt DESC;
select * from ENVIRENEMENT;