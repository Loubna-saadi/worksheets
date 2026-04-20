-- Un module d’export (JSON / XML / scripts SQL/Excel)
CREATE OR REPLACE PACKAGE PKG_EXPORT_ANOMALIES AS
    -- Utilitaire de conversion pour le téléchargement sécurisé via ORDS
    FUNCTION CLOB_TO_BLOB(p_clob CLOB) RETURN BLOB;

    -- Export JSON pour le Web
    FUNCTION TO_JSON(p_op_id IN NUMBER) RETURN CLOB;
    
    -- Export XML pour l'interopérabilité
    FUNCTION TO_XML(p_op_id IN NUMBER) RETURN CLOB;
    
    -- Export CSV (ouvrable par Excel)
    FUNCTION TO_CSV(p_op_id IN NUMBER) RETURN CLOB;
    
    -- Export SQL (Scripts d'insertion)
    FUNCTION TO_SQL_INSERTS(p_op_id IN NUMBER) RETURN CLOB;
END PKG_EXPORT_ANOMALIES;
/

CREATE OR REPLACE PACKAGE BODY PKG_EXPORT_ANOMALIES AS

    -------------------------------------------------------
    -- UTILITAIRE : CONVERSION CLOB VERS BLOB (UTF-8)
    -------------------------------------------------------
    FUNCTION CLOB_TO_BLOB(p_clob CLOB) RETURN BLOB AS
        v_blob          BLOB;
        v_dest_offset   NUMBER := 1;
        v_src_offset    NUMBER := 1;
        v_lang_context  NUMBER := DBMS_LOB.DEFAULT_LANG_CTX;
        v_warning       NUMBER;
    BEGIN
        IF p_clob IS NULL THEN RETURN NULL; END IF;
        
        DBMS_LOB.CREATETEMPORARY(v_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob    => v_blob,
            src_clob    => p_clob,
            amount      => DBMS_LOB.LOBMAXSIZE,
            dest_offset => v_dest_offset,
            src_offset  => v_src_offset,
            blob_csid   => DBMS_LOB.DEFAULT_CSID,
            lang_context=> v_lang_context,
            warning     => v_warning
        );
        RETURN v_blob;
    END CLOB_TO_BLOB;

    -------------------------------------------------------
    -- 1. EXPORT JSON
    -------------------------------------------------------
    FUNCTION TO_JSON(p_op_id IN NUMBER) RETURN CLOB AS
        v_json CLOB;
    BEGIN
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'id'              VALUE id,
                'nom_table'       VALUE nom_table,
                'cle_pivot'       VALUE cle,
                'valeur_source'   VALUE valeur_source,
                'valeur_cible'    VALUE valeur_cible,
                'type_diff'       VALUE type_difference,
                'alerte'          VALUE alerte_statut,
                'date_creation'   VALUE TO_CHAR(dateCreation, 'DD/MM/YYYY HH24:MI')
                NULL ON NULL
            ) RETURNING CLOB
        ) INTO v_json
        FROM ANOMALIE
        WHERE operation_id = p_op_id;
        
        RETURN NVL(v_json, '[]');
    END TO_JSON;

    -------------------------------------------------------
    -- 2. EXPORT XML
    -------------------------------------------------------
    FUNCTION TO_XML(p_op_id IN NUMBER) RETURN CLOB AS
        v_xml XMLTYPE;
    BEGIN
        SELECT XMLELEMENT("Anomalies",
            XMLATTRIBUTES(p_op_id AS "OperationID"),
            XMLAGG(
                XMLELEMENT("Ecart",
                    XMLFOREST(
                        nom_table AS "Table",
                        cle AS "Cle",
                        valeur_source AS "Source",
                        valeur_cible AS "Cible",
                        type_difference AS "TypeDiff",
                        alerte_statut AS "Statut"
                    )
                )
            )
        ) INTO v_xml
        FROM ANOMALIE
        WHERE operation_id = p_op_id;
        
        RETURN CASE WHEN v_xml IS NOT NULL THEN v_xml.getClobVal() ELSE '<Anomalies/>' END;
    END TO_XML;

    -------------------------------------------------------
    -- 3. EXPORT CSV (Excel)
    -------------------------------------------------------
    FUNCTION TO_CSV(p_op_id IN NUMBER) RETURN CLOB AS
        v_csv CLOB := 'ID;TABLE;CLE;SOURCE;CIBLE;TYPE;STATUT' || CHR(10);
    BEGIN
        FOR rec IN (SELECT * FROM ANOMALIE WHERE operation_id = p_op_id ORDER BY id) LOOP
            v_csv := v_csv || 
                     rec.id || ';' || 
                     rec.nom_table || ';' || 
                     rec.cle || ';' || 
                     rec.valeur_source || ';' || 
                     rec.valeur_cible || ';' || 
                     rec.type_difference || ';' || 
                     rec.alerte_statut || CHR(10);
        END LOOP;
        RETURN v_csv;
    END TO_CSV;

    -------------------------------------------------------
    -- 4. EXPORT SQL
    -------------------------------------------------------
FUNCTION TO_SQL_INSERTS(p_op_id IN NUMBER) RETURN CLOB AS
    v_sql CLOB;
    v_line VARCHAR2(32767);
BEGIN
    v_sql := '-- Script Export Anomalies Opération ID : ' || p_op_id || CHR(10);
    v_sql := v_sql || '-- Généré le : ' || TO_CHAR(SYSDATE, 'DD/MM/YYYY HH24:MI:SS') || CHR(10) || CHR(10);

    FOR rec IN (SELECT * FROM ANOMALIE WHERE OPERATION_ID = p_op_id) LOOP
        -- On construit l'INSERT avec toutes les colonnes de ton schéma
        v_line := 'INSERT INTO ANOMALIE (DESCRIPTION, STATUT, DATECREATION, OPERATION_ID, UTILISATEUR_ID, CLE, VALEUR_SOURCE, VALEUR_CIBLE, TYPE_DIFFERENCE, NOM_TABLE) VALUES (' ||
            '''' || REPLACE(rec.DESCRIPTION, '''', '''''') || ''', ' ||
            '''' || rec.STATUT || ''', ' ||
            'TO_DATE(''' || TO_CHAR(rec.DATECREATION, 'YYYY-MM-DD HH24:MI:SS') || ''', ''YYYY-MM-DD HH24:MI:SS''), ' ||
            rec.OPERATION_ID || ', ' ||
            NVL(TO_CHAR(rec.UTILISATEUR_ID), 'NULL') || ', ' ||
            '''' || REPLACE(rec.CLE, '''', '''''') || ''', ' ||
            '''' || REPLACE(rec.VALEUR_SOURCE, '''', '''''') || ''', ' ||
            '''' || REPLACE(rec.VALEUR_CIBLE, '''', '''''') || ''', ' ||
            '''' || rec.TYPE_DIFFERENCE || ''', ' ||
            '''' || rec.NOM_TABLE || ''');' || CHR(10);
            
        DBMS_LOB.WRITEAPPEND(v_sql, LENGTH(v_line), v_line);
    END LOOP;

    v_sql := v_sql || CHR(10) || 'COMMIT;';
    RETURN v_sql;
END TO_SQL_INSERTS;
END PKG_EXPORT_ANOMALIES;
/

select *from ANOMALIE;
describe anomalie;
select *from OPERATION;

-- Test JSON
SELECT PKG_EXPORT_ANOMALIES.TO_JSON(86) FROM DUAL;

-- Test CSV
SELECT PKG_EXPORT_ANOMALIES.TO_CSV(86) FROM DUAL;

-- Test XML
SELECT PKG_EXPORT_ANOMALIES.TO_XML(86) FROM DUAL;
-- Test SQL
SELECT PKG_EXPORT_ANOMALIES.TO_SQL_INSERTS(86) FROM DUAL;

  -------------------------------------------------------
  -- 1. CRÉATION DES ROUTES ORDS
  -------------------------------------------------------

BEGIN
  -------------------------------------------------------
  -- 1. CRÉATION DU MODULE MÉTIER
  -------------------------------------------------------
  ORDS.DEFINE_MODULE(
    p_module_name    => 'data_module',
    p_base_path      => 'data/', 
    p_items_per_page => 0,
    p_status         => 'PUBLISHED'
  );

  -------------------------------------------------------
  -- 2. ROUTE EXPORT JSON
  -------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'data_module',
    p_pattern     => 'export/json/:opId'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'data_module',
    p_pattern     => 'export/json/:opId',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
DECLARE
    v_clob CLOB;
    v_blob BLOB;
BEGIN
    v_clob := PKG_EXPORT_ANOMALIES.TO_JSON(:opId);
    v_blob := PKG_EXPORT_ANOMALIES.CLOB_TO_BLOB(v_clob);

    OWA_UTIL.MIME_HEADER('application/json', FALSE);
    HTP.PRN('Content-Disposition: attachment; filename="audit_' || :opId || '.json"' || CHR(10));
    OWA_UTIL.HTTP_HEADER_CLOSE;

    WPG_DOCLOAD.DOWNLOAD_FILE(v_blob);
END;
]'
  );

  -------------------------------------------------------
  -- 3. ROUTE EXPORT CSV
  -------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'data_module',
    p_pattern     => 'export/csv/:opId'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'data_module',
    p_pattern     => 'export/csv/:opId',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
DECLARE
    v_clob CLOB;
    v_blob BLOB;
BEGIN
    v_clob := PKG_EXPORT_ANOMALIES.TO_CSV(:opId);
    v_blob := PKG_EXPORT_ANOMALIES.CLOB_TO_BLOB(v_clob);

    OWA_UTIL.MIME_HEADER('text/csv', FALSE);
    HTP.PRN('Content-Disposition: attachment; filename="audit_' || :opId || '.csv"' || CHR(10));
    OWA_UTIL.HTTP_HEADER_CLOSE;

    WPG_DOCLOAD.DOWNLOAD_FILE(v_blob);
END;
]'
  );

  -------------------------------------------------------
  -- 4. ROUTE EXPORT SQL
  -------------------------------------------------------
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'data_module',
    p_pattern     => 'export/sql/:opId'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'data_module',
    p_pattern     => 'export/sql/:opId',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
DECLARE
    v_clob CLOB;
    v_blob BLOB;
BEGIN
    v_clob := PKG_EXPORT_ANOMALIES.TO_SQL_INSERTS(:opId);
    v_blob := PKG_EXPORT_ANOMALIES.CLOB_TO_BLOB(v_clob);

    OWA_UTIL.MIME_HEADER('application/sql', FALSE);
    HTP.PRN('Content-Disposition: attachment; filename="audit_' || :opId || '.sql"' || CHR(10));
    OWA_UTIL.HTTP_HEADER_CLOSE;

    WPG_DOCLOAD.DOWNLOAD_FILE(v_blob);
END;
]'
  );

  COMMIT;
END;
/
 -------------------------------------------------------
  -- 5. ROUTE EXPORT XML
  -------------------------------------------------------
BEGIN
 
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'data_module',
    p_pattern     => 'export/xml/:opId'
  );

  ORDS.DEFINE_HANDLER(
    p_module_name => 'data_module',
    p_pattern     => 'export/xml/:opId',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
DECLARE
    v_clob CLOB;
    v_blob BLOB;
BEGIN
    -- Appel de la fonction TO_XML du package
    v_clob := PKG_EXPORT_ANOMALIES.TO_XML(:opId);
    v_blob := PKG_EXPORT_ANOMALIES.CLOB_TO_BLOB(v_clob);

    -- Header spécifique XML
    OWA_UTIL.MIME_HEADER('application/xml', FALSE, 'UTF-8');
    HTP.PRN('Content-Disposition: attachment; filename="audit_' || :opId || '.xml"' || CHR(10));
    OWA_UTIL.HTTP_HEADER_CLOSE;

    WPG_DOCLOAD.DOWNLOAD_FILE(v_blob);
END;
]'
  );

  COMMIT;
END;
/