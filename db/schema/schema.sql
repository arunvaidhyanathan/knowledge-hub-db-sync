--
-- PostgreSQL database dump
--

\restrict dbexport


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: cads; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA cads;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: unpartition_all_cads_tables(); Type: PROCEDURE; Schema: cads; Owner: -
--

CREATE PROCEDURE cads.unpartition_all_cads_tables()
    LANGUAGE plpgsql
    AS $$
DECLARE
    parent_rec RECORD;
    child_rec RECORD;
    temp_table_name TEXT;
    original_table_schema TEXT := 'cads'; -- The schema to process
    quoted_parent_table TEXT;
    quoted_temp_table TEXT;
    parent_oid oid;
    child_drop_commands TEXT[]; -- Array to store DROP TABLE commands for children
    child_drop_cmd TEXT;
BEGIN
    RAISE NOTICE '--- Starting Unpartitioning Process for Schema: % ---', original_table_schema;

    -- Find all partitioned tables in the target schema
    FOR parent_rec IN
        SELECT
            c.oid,
            n.nspname AS schema_name,
            c.relname AS table_name
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = original_table_schema
          AND c.relkind = 'p' -- Filter for partitioned tables
    LOOP
        parent_oid := parent_rec.oid;
        quoted_parent_table := pg_catalog.quote_ident(parent_rec.schema_name) || '.' || pg_catalog.quote_ident(parent_rec.table_name);

        RAISE NOTICE 'Processing table: %', quoted_parent_table;

        -- Check if the table actually has partitions before proceeding
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_inherits WHERE inhparent = parent_oid) THEN

            -- Generate a temporary table name
            temp_table_name := parent_rec.table_name || '_unpartitioned_temp_' || md5(random()::text);
            quoted_temp_table := pg_catalog.quote_ident(parent_rec.schema_name) || '.' || pg_catalog.quote_ident(temp_table_name);

            RAISE NOTICE 'Consolidating data from % into temporary table %...', quoted_parent_table, quoted_temp_table;
            BEGIN -- Use a block for EXCEPTION handling per table

                -- --- Step 1: Consolidate data into a new table ---
                RAISE NOTICE 'Creating temporary table %s and copying data...', quoted_temp_table;
                EXECUTE format('CREATE TABLE %s AS SELECT * FROM %s', quoted_temp_table, quoted_parent_table);
                RAISE NOTICE 'Data consolidation complete for %s.', quoted_parent_table;

                -- --- Step 2: Detach all partitions and collect DROP commands ---
                RAISE NOTICE 'Detaching partitions from %s...', quoted_parent_table;
                child_drop_commands := '{}'; -- Initialize the array
                FOR child_rec IN
                    SELECT child_c.relname AS partition_name, child_n.nspname AS partition_schema
                    FROM pg_catalog.pg_inherits i
                    JOIN pg_catalog.pg_class parent_c ON parent_c.oid = i.inhparent
                    JOIN pg_catalog.pg_class child_c ON i.inhrelid = child_c.oid
                    JOIN pg_catalog.pg_namespace child_n ON child_n.oid = child_c.relnamespace
                    WHERE parent_c.oid = parent_oid
                LOOP
                    RAISE NOTICE 'Detaching partition %.%...', child_rec.partition_schema, child_rec.partition_name;
                    EXECUTE format('ALTER TABLE %s DETACH PARTITION %s.%s',
                                   quoted_parent_table,
                                   pg_catalog.quote_ident(child_rec.partition_schema),
                                   pg_catalog.quote_ident(child_rec.partition_name));
                    -- Store the drop command for later
                    child_drop_commands := array_append(child_drop_commands, format('DROP TABLE %s.%s;',
                                                                   pg_catalog.quote_ident(child_rec.partition_schema),
                                                                   pg_catalog.quote_ident(child_rec.partition_name)));
                END LOOP;
                RAISE NOTICE 'All partitions detached for %s.', quoted_parent_table;

                -- --- Step 3: Drop the original parent table ---
                RAISE NOTICE 'Dropping the original partitioned table %s...', quoted_parent_table;
                EXECUTE format('DROP TABLE %s', quoted_parent_table);
                RAISE NOTICE 'Original partitioned table %s dropped.', quoted_parent_table; -- Added table name here for clarity

                -- --- Step 4: Rename the new table to the original table name ---
                RAISE NOTICE 'Renaming %s to %.%...', quoted_temp_table, parent_rec.schema_name, parent_rec.table_name;
                EXECUTE format('ALTER TABLE %s RENAME TO %I', quoted_temp_table, parent_rec.table_name);
                RAISE NOTICE 'Table %.% unpartitioning core steps finished.', parent_rec.schema_name, parent_rec.table_name;

                -- --- Final Notes for this table ---
                -- FIXED: Changed %.% to %s and provided the single quoted_parent_table
                RAISE NOTICE '*** IMPORTANT for %s: This procedure did NOT recreate indexes, constraints (PK, FK, UNIQUE, CHECK), defaults, triggers, permissions, or comments.', quoted_parent_table;
                RAISE NOTICE '*** You MUST manually recreate these objects on the new %s table.', quoted_parent_table;
                -- Added reminder to drop detached partitions
                RAISE NOTICE '*** The following DROP TABLE commands for detached partitions were collected:';
                FOREACH child_drop_cmd IN ARRAY child_drop_commands LOOP
                    RAISE NOTICE '    %s', child_drop_cmd; -- Print each drop command
                END LOOP;
                RAISE NOTICE '*** Execute these commands to drop the old partition tables.';


            EXCEPTION
                WHEN OTHERS THEN
                    RAISE WARNING 'Error processing table %s: %', quoted_parent_table, SQLERRM;
                    -- Decide on rollback strategy if an error occurs mid-process for one table.
                    -- Current behaviour is to continue to the next table.
                    -- If you need atomic operations per table, you might need savepoints
                    -- or separate transactions, which adds complexity.
            END; -- End of per-table exception block
        ELSE
             RAISE NOTICE 'Table %s is marked as partitioned but has no attached partitions. Skipping.', quoted_parent_table;
        END IF;

    END LOOP; -- End of loop through partitioned tables

    RAISE NOTICE '--- Unpartitioning Process for Schema % Finished ---', original_table_schema;
    RAISE NOTICE 'Remember to perform manual post-processing steps for all tables processed (recreate objects, drop detached partitions).';

END;
$$;


--
-- Name: audit_approval_decision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_approval_decision() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status is distinct from old.status and new.status in ('approved', 'rejected') then
    insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, before, after)
    values (
      new.tenant_id,
      auth.uid(),
      'approval_decided',
      'approval_request',
      new.id,
      jsonb_build_object('status', old.status),
      jsonb_build_object('status', new.status, 'comment', new.comment)
    );
  end if;
  return new;
end;
$$;


--
-- Name: audit_profile_status_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_profile_status_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status is distinct from old.status then
    insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, before, after)
    values (
      new.tenant_id,
      auth.uid(),
      'profile_status_changed',
      'profile',
      new.id,
      jsonb_build_object('status', old.status),
      jsonb_build_object('status', new.status)
    );
  end if;
  return new;
end;
$$;


--
-- Name: audit_workflow_archive(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_workflow_archive() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status is distinct from old.status and new.status = 'archived' then
    insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, before, after)
    values (
      new.tenant_id,
      auth.uid(),
      'workflow_archived',
      'workflow',
      new.id,
      jsonb_build_object('status', old.status),
      jsonb_build_object('status', new.status)
    );
  end if;
  return new;
end;
$$;


--
-- Name: audit_workflow_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_workflow_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, before, after)
  values (
    old.tenant_id,
    auth.uid(),
    'workflow_deleted',
    'workflow',
    old.id,
    jsonb_build_object('name', old.name, 'status', old.status, 'definition_key', old.definition_key),
    null
  );
  return old;
end;
$$;


--
-- Name: current_role_claim(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_role_claim() RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select (auth.jwt() -> 'app_metadata') ->> 'role'
$$;


--
-- Name: current_tenant_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select ((auth.jwt() -> 'app_metadata') ->> 'tenant_id')::uuid
$$;


--
-- Name: is_current_user_active(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_current_user_active() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(
    (select status = 'active' from public.profiles where id = auth.uid()),
    true
  )
$$;


--
-- Name: FUNCTION is_current_user_active(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_current_user_active() IS 'Governance.html Section 8: true unless the caller has a profiles row with status = deactivated. Used to exclude deactivated users from write-granting RLS policies without touching read policies.';


--
-- Name: match_workflow_embeddings(extensions.vector, text, text, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.match_workflow_embeddings(query_embedding extensions.vector, match_spec text, match_model text, match_count integer DEFAULT 3, exclude_workflow uuid DEFAULT NULL::uuid) RETURNS TABLE(workflow_id uuid, workflow_version_id uuid, name text, summary text, similarity double precision)
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'extensions'
    AS $$
  select e.workflow_id,
         e.workflow_version_id,
         w.name,
         e.summary,
         1 - (e.embedding <=> query_embedding) as similarity
  from public.workflow_embeddings e
  join public.workflows w
    on w.id = e.workflow_id
   and w.current_version_id = e.workflow_version_id
  where e.spec_type = match_spec
    and e.model = match_model
    and w.status <> 'archived'
    and (exclude_workflow is null or e.workflow_id <> exclude_workflow)
    and vector_dims(e.embedding) = vector_dims(query_embedding)
  order by e.embedding <=> query_embedding
  limit least(greatest(match_count, 1), 10)
$$;


--
-- Name: reset_workflow_status_on_new_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_workflow_status_on_new_version() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_tenant_id uuid;
  v_previous_status text;
begin
  select tenant_id, status into v_tenant_id, v_previous_status
  from public.workflows
  where id = new.workflow_id;

  if v_previous_status = 'approved' then
    update public.workflows
    set status = 'draft', updated_at = now()
    where id = new.workflow_id;

    insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, before, after)
    values (
      v_tenant_id,
      auth.uid(),
      'workflow_status_reset_on_edit',
      'workflow',
      new.workflow_id,
      jsonb_build_object('status', 'approved'),
      jsonb_build_object('status', 'draft', 'version_id', new.id)
    );
  end if;

  return new;
end;
$$;


--
-- Name: sync_profile_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_profile_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- Deliberately an UPDATE, not an UPSERT: the profiles row itself is
  -- provisioned by invite-user/admin-set-role (which set email directly at
  -- creation time), not by this trigger. This just keeps it in sync if the
  -- underlying auth.users.email ever changes afterward, and is a safe no-op
  -- for the brief window between an invited auth.users row being created
  -- and its profiles row being provisioned moments later.
  update public.profiles set email = new.email where id = new.id;
  return new;
end;
$$;


--
-- Name: sync_workflow_status_from_approval(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_workflow_status_from_approval() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    if tg_op = 'INSERT' then
        update public.workflows set status = 'pending_approval', updated_at = now()
        where id = new.workflow_id;
    elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
        if new.status = 'approved' then
            update public.workflows set status = 'approved', updated_at = now()
            where id = new.workflow_id;
        elsif new.status = 'rejected' then
            update public.workflows set status = 'draft', updated_at = now()
            where id = new.workflow_id;
        end if;
    end if;
    return new;
end;
$$;


SET default_table_access_method = heap;

--
-- Name: alert_attachments; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_attachments (
    attachment_id integer NOT NULL,
    alert_id integer,
    file_name character varying(255) NOT NULL,
    file_path character varying(255) NOT NULL,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: alert_attachments_attachment_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.alert_attachments_attachment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alert_attachments_attachment_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.alert_attachments_attachment_id_seq OWNED BY cads.alert_attachments.attachment_id;


--
-- Name: alert_audit; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_audit (
    audit_id integer NOT NULL,
    alert_id integer,
    user_id integer,
    action character varying(255),
    details text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: alert_audit_audit_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.alert_audit_audit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alert_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.alert_audit_audit_id_seq OWNED BY cads.alert_audit.audit_id;


--
-- Name: alert_cstm_attributes; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_cstm_attributes (
    alert_id numeric NOT NULL,
    pp_message text NOT NULL,
    created_date timestamp(0) without time zone DEFAULT CURRENT_DATE NOT NULL,
    created_by character varying(15) DEFAULT 'System'::character varying NOT NULL,
    partition_date timestamp(0) without time zone DEFAULT CURRENT_DATE NOT NULL,
    gi_message text,
    last_updated_by character varying(15),
    last_updated_date timestamp(0) without time zone,
    is_post_positive_completed character(1),
    is_early_pp_completed character(1)
)
PARTITION BY RANGE (partition_date);


--
-- Name: alert_det; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_det (
    id numeric NOT NULL,
    alert_id numeric NOT NULL,
    field_name character varying(4000) NOT NULL,
    field_name_alias character varying(100) NOT NULL,
    field_value_offset numeric NOT NULL,
    field_order numeric NOT NULL,
    created_date timestamp(0) without time zone DEFAULT ((clock_timestamp() AT TIME ZONE COALESCE(current_setting('aws_oracle_ext.tz'::text, true), 'UTC'::text)))::timestamp(0) without time zone,
    last_updated_date timestamp(0) without time zone,
    created_by character varying(50) DEFAULT 'System'::character varying NOT NULL,
    last_updated_by character varying(50),
    version numeric,
    partition_date timestamp(0) without time zone DEFAULT CURRENT_DATE NOT NULL,
    field_value character varying(4000),
    is_field_value_clob character(1)
)
PARTITION BY RANGE (partition_date);


--
-- Name: alert_details_mst; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_details_mst (
    alert_detail_id integer NOT NULL,
    alert_id integer,
    detail_description text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: alert_details_mst_alert_detail_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.alert_details_mst_alert_detail_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alert_details_mst_alert_detail_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.alert_details_mst_alert_detail_id_seq OWNED BY cads.alert_details_mst.alert_detail_id;


--
-- Name: alert_mst; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_mst (
    id numeric NOT NULL,
    source_system character varying(250) NOT NULL,
    due_time character varying(50),
    priority numeric,
    alert_type character varying(500),
    business_unit character varying(50) NOT NULL,
    business_user character varying(20),
    rule_set character varying(500),
    txn_id character varying(250) NOT NULL,
    last_updated_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by character varying(50) DEFAULT 'System'::character varying NOT NULL,
    last_updated_by character varying(50),
    amount numeric,
    hit_count numeric,
    currency character varying(3),
    replyto_queue_name character varying(50),
    request_number numeric,
    reply_to_manager character varying(500),
    value_date date,
    branch character varying(500),
    last_transaction_date date,
    closed_date date,
    qa_status character varying(50),
    direction character varying(500),
    receiver character varying(500),
    systemid character varying(500),
    remaining_sanctions_matches numeric,
    steps character varying(50),
    closed_by character varying(50),
    origination_branch character varying(250),
    origination_region character varying(250),
    is_post_positive_completed character(1),
    application_alias_name character varying(500),
    unique_transaction_reference character varying(500),
    country_origination character varying(500),
    country_intermediary character varying(500),
    country_destination character varying(500),
    last_stage character varying(500),
    screening_type character varying(500),
    screening_category character varying(500),
    sector character varying(500),
    business_line character varying(500),
    product character varying(500),
    sub_product character varying(500),
    local_reference character varying(500),
    transaction_date date,
    sender_bic character varying(500),
    receiver_bic character varying(500),
    payment_currency character varying(500),
    queue_transition_date date,
    qa_closed_by character varying(500),
    header_version character(50),
    inquiry_step_identifier character varying(50),
    business_id numeric,
    original_debtor_name character varying(500),
    beneficiary_account character varying(500),
    ordering_customer_account character varying(500),
    product_code character varying(100),
    secondary_site character varying(50),
    derived_step_identifier character varying(250),
    branch_txn_id character varying(250),
    l3_dual_review character(3) DEFAULT 'No'::bpchar,
    research_type character varying(500),
    updated_final_decision character varying(50),
    udf1_datetime date,
    screened_date date,
    org_citi_legal_vehicle character varying(750),
    org_citi_legal_vehicle_type character varying(100),
    dest_citi_legal_vehicle character varying(750),
    dest_citi_legal_vehicle_type character varying(100),
    dr_alert_id numeric,
    uk_sanctions_authority character varying(50),
    auto_dispose_matches character(1),
    lapc_alert character varying(50),
    citi_enabled character(1),
    parent_alert_id numeric,
    rescind_status character varying(50),
    rmp_alert character varying(250),
    rmp_prev_alertid numeric,
    rmp_rules character varying(50),
    rmp_csaw_instance character varying(50),
    bulk_process_req_id numeric,
    rtm_alert_id numeric,
    is_urgent character(1) DEFAULT 'N'::bpchar,
    partition_date date NOT NULL,
    step_identifier character varying(250),
    classification character varying(250),
    created_date date
);


--
-- Name: alert_notes; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.alert_notes (
    note_id integer NOT NULL,
    alert_id integer,
    note_text text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: alert_notes_note_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.alert_notes_note_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alert_notes_note_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.alert_notes_note_id_seq OWNED BY cads.alert_notes.note_id;


--
-- Name: business_on_boarding; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.business_on_boarding (
    onboarding_id integer NOT NULL,
    user_id integer,
    unit_id integer,
    start_date date,
    end_date date,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: business_on_boarding_onboarding_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.business_on_boarding_onboarding_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: business_on_boarding_onboarding_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.business_on_boarding_onboarding_id_seq OWNED BY cads.business_on_boarding.onboarding_id;


--
-- Name: business_role; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.business_role (
    role_id integer NOT NULL,
    role_name character varying(255) NOT NULL,
    description text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: business_role_role_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.business_role_role_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: business_role_role_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.business_role_role_id_seq OWNED BY cads.business_role.role_id;


--
-- Name: business_units; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.business_units (
    unit_id integer NOT NULL,
    unit_name character varying(255) NOT NULL,
    description text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: business_units_unit_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.business_units_unit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: business_units_unit_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.business_units_unit_id_seq OWNED BY cads.business_units.unit_id;


--
-- Name: business_user; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.business_user (
    user_id integer NOT NULL,
    username character varying(255) NOT NULL,
    password character varying(255) NOT NULL,
    email character varying(255),
    role_id integer,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: business_user_user_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.business_user_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: business_user_user_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.business_user_user_id_seq OWNED BY cads.business_user.user_id;


--
-- Name: continents; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.continents (
    continent_id integer NOT NULL,
    continent_name character varying(100) NOT NULL
);


--
-- Name: continents_continent_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.continents_continent_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: continents_continent_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.continents_continent_id_seq OWNED BY cads.continents.continent_id;


--
-- Name: countries; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.countries (
    country_id integer NOT NULL,
    country_name character varying(100) NOT NULL,
    region_id integer
);


--
-- Name: countries_country_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.countries_country_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: countries_country_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.countries_country_id_seq OWNED BY cads.countries.country_id;


--
-- Name: databasechangelog; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.databasechangelog (
    id character varying(255) NOT NULL,
    author character varying(255) NOT NULL,
    filename character varying(255) NOT NULL,
    dateexecuted timestamp without time zone NOT NULL,
    orderexecuted integer NOT NULL,
    exectype character varying(10) NOT NULL,
    md5sum character varying(35),
    description character varying(255),
    comments character varying(255),
    tag character varying(255),
    liquibase character varying(20),
    contexts character varying(255),
    labels character varying(255),
    deployment_id character varying(10)
);


--
-- Name: databasechangeloglock; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.databasechangeloglock (
    id integer NOT NULL,
    locked boolean NOT NULL,
    lockgranted timestamp without time zone,
    lockedby character varying(255)
);


--
-- Name: db_release_info; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.db_release_info (
    id bigint NOT NULL,
    version character varying(50) NOT NULL,
    description character varying(255),
    release_date timestamp without time zone NOT NULL,
    released_by character varying(100)
);


--
-- Name: db_release_info_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

ALTER TABLE cads.db_release_info ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME cads.db_release_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: empty_partitions; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.empty_partitions (
    id bigint NOT NULL,
    dropped_at timestamp(6) without time zone,
    identified_at timestamp(6) without time zone,
    is_dropped boolean NOT NULL,
    partition_name character varying(255),
    table_name character varying(255)
);


--
-- Name: empty_partitions_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.empty_partitions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empty_partitions_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.empty_partitions_id_seq OWNED BY cads.empty_partitions.id;


--
-- Name: enhanced_search_fields; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.enhanced_search_fields (
    field_group character varying(100) NOT NULL,
    field_name character varying(100) NOT NULL,
    field_type character varying(20) NOT NULL,
    display_order numeric NOT NULL,
    gui_identifier character varying(100) NOT NULL,
    created_by character varying(50),
    created_date date,
    updated_by character varying(50),
    updated_date date,
    is_active character(1) NOT NULL,
    partition_date date,
    is_sortable character(1) NOT NULL,
    collection_name character varying(50),
    regex_enabled character varying(1)
);


--
-- Name: gui_label; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.gui_label (
    gui_identifier character varying(100) NOT NULL,
    role_identifier character varying(100) NOT NULL,
    label character varying(1000),
    user_language character varying(100) NOT NULL
);


--
-- Name: hit_match_detail; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.hit_match_detail (
    id numeric NOT NULL,
    match_pattern_value character varying(700) NOT NULL,
    hit_percentage numeric NOT NULL,
    matchable_description character varying(4000),
    category character varying(400),
    created_date timestamp(0) without time zone DEFAULT CURRENT_DATE NOT NULL,
    created_by character varying(50) DEFAULT 'System'::character varying NOT NULL,
    alert_det_id numeric NOT NULL,
    "offset" numeric,
    match_length numeric NOT NULL,
    version numeric,
    last_transitioned_by character varying(50),
    partition_date timestamp(0) without time zone DEFAULT CURRENT_DATE NOT NULL,
    alert_id numeric,
    hit_number numeric(40,0),
    hit_type character varying(250),
    match_text character varying(4000),
    taxonomy_sub_taxonomy_id numeric,
    coverage_area character varying(100),
    specific_coverage_area character varying(255),
    is_final_decision character(1) DEFAULT 'N'::bpchar,
    hit_touch_count numeric(40,0),
    confirmed_false_match character(1) DEFAULT 'N'::bpchar,
    l3_escalation_not_required character(1) DEFAULT 'N'::bpchar,
    category_lookup character varying(40),
    rule_checksum character varying(40),
    repair_checksum character varying(40),
    l3_checker_required character(1) DEFAULT 'N'::bpchar,
    is_default_taxonomy character(1) DEFAULT 'N'::bpchar,
    last_updated_date timestamp(0) without time zone,
    add_matchable_description character varying(4000),
    mid_type character varying(18),
    list_entry_type character varying(50),
    list_entry_type_mg character varying(50),
    is_batch_disposed character(1),
    bulk_process_req_id integer,
    rule_engine_id integer
)
PARTITION BY RANGE (partition_date);


--
-- Name: match_notes; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.match_notes (
    match_note_id integer NOT NULL,
    alert_detail_id integer,
    note_text text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    modified_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: match_notes_match_note_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.match_notes_match_note_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: match_notes_match_note_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.match_notes_match_note_id_seq OWNED BY cads.match_notes.match_note_id;


--
-- Name: notes_audit; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.notes_audit (
    audit_id integer NOT NULL,
    note_id integer,
    user_id integer,
    action character varying(255),
    details text,
    created_date timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc'::text)
);


--
-- Name: notes_audit_audit_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.notes_audit_audit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notes_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.notes_audit_audit_id_seq OWNED BY cads.notes_audit.audit_id;


--
-- Name: regions; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.regions (
    region_id integer NOT NULL,
    region_name character varying(100) NOT NULL,
    continent_id integer
);


--
-- Name: regions_region_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.regions_region_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: regions_region_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.regions_region_id_seq OWNED BY cads.regions.region_id;


--
-- Name: search_config; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.search_config (
    id integer NOT NULL,
    table_name character varying(100),
    column_name character varying(100),
    search_type character varying(50)
);


--
-- Name: search_config_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.search_config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_config_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.search_config_id_seq OWNED BY cads.search_config.id;


--
-- Name: table_list; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.table_list (
    id bigint NOT NULL,
    has_partitions boolean NOT NULL,
    table_name character varying(255),
    table_schema character varying(255)
);


--
-- Name: table_list_id_seq; Type: SEQUENCE; Schema: cads; Owner: -
--

CREATE SEQUENCE cads.table_list_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: table_list_id_seq; Type: SEQUENCE OWNED BY; Schema: cads; Owner: -
--

ALTER SEQUENCE cads.table_list_id_seq OWNED BY cads.table_list.id;


--
-- Name: user_bu_map; Type: TABLE; Schema: cads; Owner: -
--

CREATE TABLE cads.user_bu_map (
    user_identifier character varying(50) NOT NULL,
    bu_identifier character varying(500) NOT NULL,
    created_date timestamp(0) without time zone,
    created_by character varying(100)
);


--
-- Name: approval_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approval_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    workflow_id uuid NOT NULL,
    version_id uuid NOT NULL,
    requested_by uuid,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    approver_id uuid,
    decided_at timestamp with time zone,
    comment text,
    CONSTRAINT approval_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text])))
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    actor_id uuid,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    before jsonb,
    after jsonb,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: deployments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deployments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workflow_version_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    flowable_deployment_id text,
    deployed_by uuid,
    deployed_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    CONSTRAINT deployments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'failed'::text, 'superseded'::text])))
);


--
-- Name: form_schemas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.form_schemas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    form_key text NOT NULL,
    json_schema jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    email text NOT NULL,
    role text NOT NULL,
    invited_by uuid,
    status text DEFAULT 'invited'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    accepted_at timestamp with time zone,
    CONSTRAINT invites_role_check CHECK ((role = ANY (ARRAY['designer'::text, 'tenant_admin'::text, 'approver'::text, 'viewer'::text]))),
    CONSTRAINT invites_status_check CHECK ((status = ANY (ARRAY['invited'::text, 'accepted'::text, 'revoked'::text])))
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    role text NOT NULL,
    display_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    onboarding_dismissed_at timestamp with time zone,
    email text,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['designer'::text, 'tenant_admin'::text, 'approver'::text, 'viewer'::text]))),
    CONSTRAINT profiles_status_check CHECK ((status = ANY (ARRAY['active'::text, 'deactivated'::text])))
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: workflow_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_embeddings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    workflow_id uuid NOT NULL,
    workflow_version_id uuid NOT NULL,
    spec_type text NOT NULL,
    model text NOT NULL,
    content_hash text NOT NULL,
    summary text NOT NULL,
    embedding extensions.vector NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT workflow_embeddings_spec_type_check CHECK ((spec_type = ANY (ARRAY['BPMN'::text, 'CMMN'::text, 'DMN'::text])))
);


--
-- Name: workflow_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workflow_id uuid NOT NULL,
    version_no integer NOT NULL,
    graph_json jsonb NOT NULL,
    xml_content text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: workflows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    definition_key text NOT NULL,
    name text NOT NULL,
    description text,
    spec_type text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    current_version_id uuid,
    locked_by uuid,
    locked_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT workflows_spec_type_check CHECK ((spec_type = ANY (ARRAY['BPMN'::text, 'CMMN'::text, 'DMN'::text]))),
    CONSTRAINT workflows_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'pending_approval'::text, 'approved'::text, 'deployed'::text, 'archived'::text])))
);


--
-- Name: alert_attachments attachment_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_attachments ALTER COLUMN attachment_id SET DEFAULT nextval('cads.alert_attachments_attachment_id_seq'::regclass);


--
-- Name: alert_audit audit_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_audit ALTER COLUMN audit_id SET DEFAULT nextval('cads.alert_audit_audit_id_seq'::regclass);


--
-- Name: alert_details_mst alert_detail_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_details_mst ALTER COLUMN alert_detail_id SET DEFAULT nextval('cads.alert_details_mst_alert_detail_id_seq'::regclass);


--
-- Name: alert_notes note_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_notes ALTER COLUMN note_id SET DEFAULT nextval('cads.alert_notes_note_id_seq'::regclass);


--
-- Name: business_on_boarding onboarding_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_on_boarding ALTER COLUMN onboarding_id SET DEFAULT nextval('cads.business_on_boarding_onboarding_id_seq'::regclass);


--
-- Name: business_role role_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_role ALTER COLUMN role_id SET DEFAULT nextval('cads.business_role_role_id_seq'::regclass);


--
-- Name: business_units unit_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_units ALTER COLUMN unit_id SET DEFAULT nextval('cads.business_units_unit_id_seq'::regclass);


--
-- Name: business_user user_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_user ALTER COLUMN user_id SET DEFAULT nextval('cads.business_user_user_id_seq'::regclass);


--
-- Name: continents continent_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.continents ALTER COLUMN continent_id SET DEFAULT nextval('cads.continents_continent_id_seq'::regclass);


--
-- Name: countries country_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.countries ALTER COLUMN country_id SET DEFAULT nextval('cads.countries_country_id_seq'::regclass);


--
-- Name: empty_partitions id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.empty_partitions ALTER COLUMN id SET DEFAULT nextval('cads.empty_partitions_id_seq'::regclass);


--
-- Name: match_notes match_note_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.match_notes ALTER COLUMN match_note_id SET DEFAULT nextval('cads.match_notes_match_note_id_seq'::regclass);


--
-- Name: notes_audit audit_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.notes_audit ALTER COLUMN audit_id SET DEFAULT nextval('cads.notes_audit_audit_id_seq'::regclass);


--
-- Name: regions region_id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.regions ALTER COLUMN region_id SET DEFAULT nextval('cads.regions_region_id_seq'::regclass);


--
-- Name: search_config id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.search_config ALTER COLUMN id SET DEFAULT nextval('cads.search_config_id_seq'::regclass);


--
-- Name: table_list id; Type: DEFAULT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.table_list ALTER COLUMN id SET DEFAULT nextval('cads.table_list_id_seq'::regclass);


--
-- Name: alert_attachments alert_attachments_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_attachments
    ADD CONSTRAINT alert_attachments_pkey PRIMARY KEY (attachment_id);


--
-- Name: alert_audit alert_audit_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_audit
    ADD CONSTRAINT alert_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: alert_details_mst alert_details_mst_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_details_mst
    ADD CONSTRAINT alert_details_mst_pkey PRIMARY KEY (alert_detail_id);


--
-- Name: alert_notes alert_notes_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.alert_notes
    ADD CONSTRAINT alert_notes_pkey PRIMARY KEY (note_id);


--
-- Name: business_on_boarding business_on_boarding_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_on_boarding
    ADD CONSTRAINT business_on_boarding_pkey PRIMARY KEY (onboarding_id);


--
-- Name: business_role business_role_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_role
    ADD CONSTRAINT business_role_pkey PRIMARY KEY (role_id);


--
-- Name: business_role business_role_role_name_key; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_role
    ADD CONSTRAINT business_role_role_name_key UNIQUE (role_name);


--
-- Name: business_units business_units_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_units
    ADD CONSTRAINT business_units_pkey PRIMARY KEY (unit_id);


--
-- Name: business_user business_user_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_user
    ADD CONSTRAINT business_user_pkey PRIMARY KEY (user_id);


--
-- Name: business_user business_user_username_key; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_user
    ADD CONSTRAINT business_user_username_key UNIQUE (username);


--
-- Name: continents continents_continent_name_key; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.continents
    ADD CONSTRAINT continents_continent_name_key UNIQUE (continent_name);


--
-- Name: continents continents_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.continents
    ADD CONSTRAINT continents_pkey PRIMARY KEY (continent_id);


--
-- Name: countries countries_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.countries
    ADD CONSTRAINT countries_pkey PRIMARY KEY (country_id);


--
-- Name: databasechangeloglock databasechangeloglock_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.databasechangeloglock
    ADD CONSTRAINT databasechangeloglock_pkey PRIMARY KEY (id);


--
-- Name: db_release_info db_release_info_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.db_release_info
    ADD CONSTRAINT db_release_info_pkey PRIMARY KEY (id);


--
-- Name: empty_partitions empty_partitions_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.empty_partitions
    ADD CONSTRAINT empty_partitions_pkey PRIMARY KEY (id);


--
-- Name: match_notes match_notes_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.match_notes
    ADD CONSTRAINT match_notes_pkey PRIMARY KEY (match_note_id);


--
-- Name: notes_audit notes_audit_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.notes_audit
    ADD CONSTRAINT notes_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: regions regions_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.regions
    ADD CONSTRAINT regions_pkey PRIMARY KEY (region_id);


--
-- Name: search_config search_config_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.search_config
    ADD CONSTRAINT search_config_pkey PRIMARY KEY (id);


--
-- Name: table_list table_list_pkey; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.table_list
    ADD CONSTRAINT table_list_pkey PRIMARY KEY (id);


--
-- Name: user_bu_map user_bu_map_pk; Type: CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.user_bu_map
    ADD CONSTRAINT user_bu_map_pk PRIMARY KEY (user_identifier, bu_identifier);


--
-- Name: approval_requests approval_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: deployments deployments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deployments
    ADD CONSTRAINT deployments_pkey PRIMARY KEY (id);


--
-- Name: form_schemas form_schemas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_schemas
    ADD CONSTRAINT form_schemas_pkey PRIMARY KEY (id);


--
-- Name: form_schemas form_schemas_tenant_id_form_key_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_schemas
    ADD CONSTRAINT form_schemas_tenant_id_form_key_version_key UNIQUE (tenant_id, form_key, version);


--
-- Name: invites invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_slug_key UNIQUE (slug);


--
-- Name: workflow_embeddings workflow_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_embeddings
    ADD CONSTRAINT workflow_embeddings_pkey PRIMARY KEY (id);


--
-- Name: workflow_embeddings workflow_embeddings_workflow_version_id_model_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_embeddings
    ADD CONSTRAINT workflow_embeddings_workflow_version_id_model_key UNIQUE (workflow_version_id, model);


--
-- Name: workflow_versions workflow_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_versions
    ADD CONSTRAINT workflow_versions_pkey PRIMARY KEY (id);


--
-- Name: workflow_versions workflow_versions_workflow_id_version_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_versions
    ADD CONSTRAINT workflow_versions_workflow_id_version_no_key UNIQUE (workflow_id, version_no);


--
-- Name: workflows workflows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_pkey PRIMARY KEY (id);


--
-- Name: workflows workflows_tenant_key_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_tenant_key_unique UNIQUE (tenant_id, definition_key);


--
-- Name: alert_det_alert_id_idx; Type: INDEX; Schema: cads; Owner: -
--

CREATE INDEX alert_det_alert_id_idx ON ONLY cads.alert_det USING btree (alert_id);


--
-- Name: idx_business_user_username; Type: INDEX; Schema: cads; Owner: -
--

CREATE INDEX idx_business_user_username ON cads.business_user USING btree (username);


--
-- Name: audit_logs_tenant_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_tenant_occurred_idx ON public.audit_logs USING btree (tenant_id, occurred_at DESC);


--
-- Name: idx_deployments_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deployments_tenant ON public.deployments USING btree (tenant_id);


--
-- Name: idx_deployments_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deployments_version ON public.deployments USING btree (workflow_version_id);


--
-- Name: idx_form_schemas_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_form_schemas_tenant ON public.form_schemas USING btree (tenant_id);


--
-- Name: idx_workflow_versions_workflow; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflow_versions_workflow ON public.workflow_versions USING btree (workflow_id);


--
-- Name: idx_workflows_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflows_tenant ON public.workflows USING btree (tenant_id);


--
-- Name: invites_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invites_tenant_idx ON public.invites USING btree (tenant_id, created_at DESC);


--
-- Name: workflow_embeddings_tenant_spec_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workflow_embeddings_tenant_spec_model ON public.workflow_embeddings USING btree (tenant_id, spec_type, model);


--
-- Name: approval_requests approval_requests_audit_decision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER approval_requests_audit_decision AFTER UPDATE ON public.approval_requests FOR EACH ROW EXECUTE FUNCTION public.audit_approval_decision();


--
-- Name: approval_requests approval_requests_sync_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER approval_requests_sync_status AFTER INSERT OR UPDATE ON public.approval_requests FOR EACH ROW EXECUTE FUNCTION public.sync_workflow_status_from_approval();


--
-- Name: profiles profiles_audit_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_audit_status AFTER UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_profile_status_change();


--
-- Name: workflow_versions workflow_versions_reset_status_after_approval; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workflow_versions_reset_status_after_approval AFTER INSERT ON public.workflow_versions FOR EACH ROW EXECUTE FUNCTION public.reset_workflow_status_on_new_version();


--
-- Name: workflows workflows_audit_archive; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workflows_audit_archive AFTER UPDATE ON public.workflows FOR EACH ROW EXECUTE FUNCTION public.audit_workflow_archive();


--
-- Name: workflows workflows_audit_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workflows_audit_delete AFTER DELETE ON public.workflows FOR EACH ROW EXECUTE FUNCTION public.audit_workflow_delete();


--
-- Name: business_on_boarding business_on_boarding_unit_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_on_boarding
    ADD CONSTRAINT business_on_boarding_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES cads.business_units(unit_id);


--
-- Name: business_on_boarding business_on_boarding_user_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_on_boarding
    ADD CONSTRAINT business_on_boarding_user_id_fkey FOREIGN KEY (user_id) REFERENCES cads.business_user(user_id);


--
-- Name: business_user business_user_role_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.business_user
    ADD CONSTRAINT business_user_role_id_fkey FOREIGN KEY (role_id) REFERENCES cads.business_role(role_id);


--
-- Name: countries countries_region_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.countries
    ADD CONSTRAINT countries_region_id_fkey FOREIGN KEY (region_id) REFERENCES cads.regions(region_id) ON DELETE CASCADE;


--
-- Name: match_notes match_notes_alert_detail_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.match_notes
    ADD CONSTRAINT match_notes_alert_detail_id_fkey FOREIGN KEY (alert_detail_id) REFERENCES cads.alert_details_mst(alert_detail_id);


--
-- Name: notes_audit notes_audit_note_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.notes_audit
    ADD CONSTRAINT notes_audit_note_id_fkey FOREIGN KEY (note_id) REFERENCES cads.alert_notes(note_id);


--
-- Name: regions regions_continent_id_fkey; Type: FK CONSTRAINT; Schema: cads; Owner: -
--

ALTER TABLE ONLY cads.regions
    ADD CONSTRAINT regions_continent_id_fkey FOREIGN KEY (continent_id) REFERENCES cads.continents(continent_id) ON DELETE CASCADE;


--
-- Name: approval_requests approval_requests_approver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_approver_id_fkey FOREIGN KEY (approver_id) REFERENCES public.profiles(id);


--
-- Name: approval_requests approval_requests_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES public.profiles(id);


--
-- Name: approval_requests approval_requests_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: approval_requests approval_requests_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_version_id_fkey FOREIGN KEY (version_id) REFERENCES public.workflow_versions(id);


--
-- Name: approval_requests approval_requests_workflow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES public.workflows(id);


--
-- Name: audit_logs audit_logs_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id);


--
-- Name: audit_logs audit_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: deployments deployments_deployed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deployments
    ADD CONSTRAINT deployments_deployed_by_fkey FOREIGN KEY (deployed_by) REFERENCES public.profiles(id);


--
-- Name: deployments deployments_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deployments
    ADD CONSTRAINT deployments_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: deployments deployments_workflow_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deployments
    ADD CONSTRAINT deployments_workflow_version_id_fkey FOREIGN KEY (workflow_version_id) REFERENCES public.workflow_versions(id);


--
-- Name: form_schemas form_schemas_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_schemas
    ADD CONSTRAINT form_schemas_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: invites invites_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.profiles(id);


--
-- Name: invites invites_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE RESTRICT;


--
-- Name: workflow_embeddings workflow_embeddings_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_embeddings
    ADD CONSTRAINT workflow_embeddings_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: workflow_embeddings workflow_embeddings_workflow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_embeddings
    ADD CONSTRAINT workflow_embeddings_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES public.workflows(id) ON DELETE CASCADE;


--
-- Name: workflow_embeddings workflow_embeddings_workflow_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_embeddings
    ADD CONSTRAINT workflow_embeddings_workflow_version_id_fkey FOREIGN KEY (workflow_version_id) REFERENCES public.workflow_versions(id) ON DELETE CASCADE;


--
-- Name: workflow_versions workflow_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_versions
    ADD CONSTRAINT workflow_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: workflow_versions workflow_versions_workflow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_versions
    ADD CONSTRAINT workflow_versions_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES public.workflows(id) ON DELETE CASCADE;


--
-- Name: workflows workflows_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: workflows workflows_current_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_current_version_fk FOREIGN KEY (current_version_id) REFERENCES public.workflow_versions(id) ON DELETE SET NULL;


--
-- Name: workflows workflows_locked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_locked_by_fkey FOREIGN KEY (locked_by) REFERENCES public.profiles(id);


--
-- Name: workflows workflows_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: approval_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.approval_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_requests approval_requests admin decide; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "approval_requests admin decide" ON public.approval_requests FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'approver'::text) AND public.is_current_user_active() AND (requested_by IS DISTINCT FROM auth.uid()))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (requested_by IS DISTINCT FROM auth.uid())));


--
-- Name: approval_requests approval_requests designer insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "approval_requests designer insert" ON public.approval_requests FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active() AND (workflow_id IN ( SELECT workflows.id
   FROM public.workflows
  WHERE (workflows.tenant_id = public.current_tenant_id())))));


--
-- Name: approval_requests approval_requests tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "approval_requests tenant read" ON public.approval_requests FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: audit_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_logs audit_logs tenant_admin read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "audit_logs tenant_admin read" ON public.audit_logs FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'tenant_admin'::text)));


--
-- Name: deployments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.deployments ENABLE ROW LEVEL SECURITY;

--
-- Name: deployments deployments designer insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "deployments designer insert" ON public.deployments FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active()));


--
-- Name: deployments deployments tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "deployments tenant read" ON public.deployments FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: workflow_embeddings embeddings designer insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "embeddings designer insert" ON public.workflow_embeddings FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active() AND (workflow_id IN ( SELECT workflows.id
   FROM public.workflows
  WHERE (workflows.tenant_id = public.current_tenant_id())))));


--
-- Name: workflow_embeddings embeddings designer update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "embeddings designer update" ON public.workflow_embeddings FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active())) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (workflow_id IN ( SELECT workflows.id
   FROM public.workflows
  WHERE (workflows.tenant_id = public.current_tenant_id())))));


--
-- Name: workflow_embeddings embeddings tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "embeddings tenant read" ON public.workflow_embeddings FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: form_schemas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.form_schemas ENABLE ROW LEVEL SECURITY;

--
-- Name: form_schemas forms designer update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "forms designer update" ON public.form_schemas FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active())) WITH CHECK ((tenant_id = public.current_tenant_id()));


--
-- Name: form_schemas forms designer write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "forms designer write" ON public.form_schemas FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active()));


--
-- Name: form_schemas forms tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "forms tenant read" ON public.form_schemas FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: invites; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invites ENABLE ROW LEVEL SECURITY;

--
-- Name: invites invites tenant_admin read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "invites tenant_admin read" ON public.invites FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'tenant_admin'::text)));


--
-- Name: invites invites tenant_admin revoke; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "invites tenant_admin revoke" ON public.invites FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'tenant_admin'::text) AND (status = 'invited'::text) AND public.is_current_user_active())) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (status = 'revoked'::text)));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles admin update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "profiles admin update" ON public.profiles FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'tenant_admin'::text) AND public.is_current_user_active())) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'tenant_admin'::text)));


--
-- Name: profiles profiles self update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "profiles self update" ON public.profiles FOR UPDATE USING ((id = auth.uid())) WITH CHECK (((id = auth.uid()) AND (role = ( SELECT p.role
   FROM public.profiles p
  WHERE (p.id = auth.uid()))) AND (tenant_id = ( SELECT p.tenant_id
   FROM public.profiles p
  WHERE (p.id = auth.uid()))) AND (NOT (email IS DISTINCT FROM ( SELECT p.email
   FROM public.profiles p
  WHERE (p.id = auth.uid()))))));


--
-- Name: profiles profiles tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "profiles tenant read" ON public.profiles FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: tenants tenant self read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "tenant self read" ON public.tenants FOR SELECT USING ((id = public.current_tenant_id()));


--
-- Name: tenants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

--
-- Name: workflow_versions versions designer insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "versions designer insert" ON public.workflow_versions FOR INSERT WITH CHECK (((public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active() AND (workflow_id IN ( SELECT workflows.id
   FROM public.workflows
  WHERE (workflows.tenant_id = public.current_tenant_id())))));


--
-- Name: workflow_versions versions tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "versions tenant read" ON public.workflow_versions FOR SELECT USING ((workflow_id IN ( SELECT workflows.id
   FROM public.workflows
  WHERE (workflows.tenant_id = public.current_tenant_id()))));


--
-- Name: workflow_embeddings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workflow_embeddings ENABLE ROW LEVEL SECURITY;

--
-- Name: workflow_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workflow_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: workflows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workflows ENABLE ROW LEVEL SECURITY;

--
-- Name: workflows workflows admin delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "workflows admin delete" ON public.workflows FOR DELETE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = 'tenant_admin'::text) AND public.is_current_user_active()));


--
-- Name: workflows workflows designer update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "workflows designer update" ON public.workflows FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active())) WITH CHECK ((tenant_id = public.current_tenant_id()));


--
-- Name: workflows workflows designer write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "workflows designer write" ON public.workflows FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public.current_role_claim() = ANY (ARRAY['designer'::text, 'tenant_admin'::text])) AND public.is_current_user_active()));


--
-- Name: workflows workflows tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "workflows tenant read" ON public.workflows FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- PostgreSQL database dump complete
--

\unrestrict dbexport

