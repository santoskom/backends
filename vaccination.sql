--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4
-- Dumped by pg_dump version 17.4

-- Started on 2025-07-13 02:24:51

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
-- TOC entry 8 (class 2615 OID 77070)
-- Name: vaccination; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA vaccination;


ALTER SCHEMA vaccination OWNER TO postgres;

--
-- TOC entry 5245 (class 0 OID 0)
-- Dependencies: 8
-- Name: SCHEMA vaccination; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA vaccination IS 'Schéma pour l''application de suivi vaccinal du Cameroun';


--
-- TOC entry 3 (class 3079 OID 77033)
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- TOC entry 5246 (class 0 OID 0)
-- Dependencies: 3
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- TOC entry 2 (class 3079 OID 77022)
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- TOC entry 5247 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- TOC entry 306 (class 1255 OID 77359)
-- Name: audit_trigger_function(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.audit_trigger_function() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO vaccination.audit_logs (table_name, record_id, operation, old_values)
        VALUES (TG_TABLE_NAME, OLD.id, TG_OP, row_to_json(OLD));
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO vaccination.audit_logs (table_name, record_id, operation, old_values, new_values)
        VALUES (TG_TABLE_NAME, NEW.id, TG_OP, row_to_json(OLD), row_to_json(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO vaccination.audit_logs (table_name, record_id, operation, new_values)
        VALUES (TG_TABLE_NAME, NEW.id, TG_OP, row_to_json(NEW));
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION vaccination.audit_trigger_function() OWNER TO postgres;

--
-- TOC entry 308 (class 1255 OID 77363)
-- Name: auto_generate_qr_code(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.auto_generate_qr_code() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.qr_code IS NULL THEN
        NEW.qr_code = vaccination.generate_qr_code();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION vaccination.auto_generate_qr_code() OWNER TO postgres;

--
-- TOC entry 315 (class 1255 OID 77464)
-- Name: auto_resolve_if_needed(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.auto_resolve_if_needed() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.followup_type = 'résolution' THEN
        UPDATE vaccination.side_effects
        SET resolved_at = NEW.done_at
        WHERE id = NEW.side_effect_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION vaccination.auto_resolve_if_needed() OWNER TO postgres;

--
-- TOC entry 312 (class 1255 OID 77404)
-- Name: cleanup_expired_ussd_sessions(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.cleanup_expired_ussd_sessions() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM vaccination.ussd_sessions
    WHERE expires_at < CURRENT_TIMESTAMP;
END;
$$;


ALTER FUNCTION vaccination.cleanup_expired_ussd_sessions() OWNER TO postgres;

--
-- TOC entry 311 (class 1255 OID 77370)
-- Name: create_automatic_reminders(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.create_automatic_reminders() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO vaccination.reminders (vaccination_card_id, vaccine_id, reminder_date, reminder_type, message)
    SELECT 
        vc.id as vaccination_card_id,
        v.id as vaccine_id,
        (birth_date + vs.age_in_days - INTERVAL '7 days')::DATE as reminder_date,
        'sms' as reminder_type,
        'Rappel: Vaccination ' || v.vaccine_name || ' prévue dans 7 jours'
    FROM vaccination.vaccination_cards vc
    JOIN (
        SELECT 
            vc.id,
            COALESCE(u.date_of_birth, fm.date_of_birth) as birth_date
        FROM vaccination.vaccination_cards vc
        LEFT JOIN vaccination.users u ON vc.user_id = u.id
        LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
    ) birth_info ON vc.id = birth_info.id
    CROSS JOIN vaccination.vaccination_schedules vs
    JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
    LEFT JOIN vaccination.vaccinations vac ON (
        vac.vaccination_card_id = vc.id 
        AND vac.vaccine_id = v.id 
        AND vac.dose_number = vs.dose_number
    )
    LEFT JOIN vaccination.reminders r ON (
        r.vaccination_card_id = vc.id 
        AND r.vaccine_id = v.id
    )
    WHERE vac.id IS NULL  -- Pas encore vacciné
    AND r.id IS NULL      -- Pas de rappel déjà créé
    AND (birth_info.birth_date + vs.age_in_days - INTERVAL '7 days')::DATE = CURRENT_DATE
    AND v.is_active = TRUE;
END;
$$;


ALTER FUNCTION vaccination.create_automatic_reminders() OWNER TO postgres;

--
-- TOC entry 309 (class 1255 OID 77366)
-- Name: create_vaccination_card(uuid, uuid); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.create_vaccination_card(p_user_id uuid DEFAULT NULL::uuid, p_family_member_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_card_id UUID;
    v_card_number VARCHAR(50);
BEGIN
    -- Générer un numéro de carnet unique
    SELECT 'CARD_' || LPAD(NEXTVAL('vaccination.card_number_seq')::TEXT, 8, '0') INTO v_card_number;
    
    -- Créer le carnet
    INSERT INTO vaccination.vaccination_cards (user_id, family_member_id, card_number)
    VALUES (p_user_id, p_family_member_id, v_card_number)
    RETURNING id INTO v_card_id;
    
    RETURN v_card_id;
END;
$$;


ALTER FUNCTION vaccination.create_vaccination_card(p_user_id uuid, p_family_member_id uuid) OWNER TO postgres;

--
-- TOC entry 307 (class 1255 OID 77362)
-- Name: generate_qr_code(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.generate_qr_code() RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN 'QR_' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 100));
END;
$$;


ALTER FUNCTION vaccination.generate_qr_code() OWNER TO postgres;

--
-- TOC entry 313 (class 1255 OID 77423)
-- Name: get_due_vaccinations(uuid); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.get_due_vaccinations(p_card_id uuid) RETURNS TABLE(vaccine_id integer, vaccine_name character varying, due_date date, dose_number integer, age_in_days integer, health_center_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_birth_date DATE;
    v_person_age_days INTEGER;
BEGIN
    -- Récupérer la date de naissance
    SELECT COALESCE(u.date_of_birth, fm.date_of_birth)
    INTO v_birth_date
    FROM vaccination.vaccination_cards vc
    LEFT JOIN vaccination.users u ON vc.user_id = u.id
    LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
    WHERE vc.id = p_card_id;

    v_person_age_days := CURRENT_DATE - v_birth_date;

    RETURN QUERY
    SELECT 
        v.id AS vaccine_id,
        v.vaccine_name,
        (v_birth_date + vs.age_in_days)::DATE AS due_date,
        vs.dose_number,
        vs.age_in_days,
        COALESCE(u.health_center_id, NULL) AS health_center_id
    FROM vaccination.vaccination_schedules vs
    JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
    LEFT JOIN vaccination.vaccinations vac ON (
        vac.vaccination_card_id = p_card_id 
        AND vac.vaccine_id = v.id 
        AND vac.dose_number = vs.dose_number
    )
    JOIN vaccination.vaccination_cards vc ON vc.id = p_card_id
    LEFT JOIN vaccination.users u ON vc.user_id = u.id
    LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
    WHERE vac.id IS NULL
      AND vs.age_in_days <= v_person_age_days
      AND v.is_active = TRUE
    ORDER BY vs.age_in_days;
END;
$$;


ALTER FUNCTION vaccination.get_due_vaccinations(p_card_id uuid) OWNER TO postgres;

--
-- TOC entry 314 (class 1255 OID 77447)
-- Name: handle_health_prof_deletion(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.handle_health_prof_deletion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    replacement_id UUID;
    user_type_code TEXT;
BEGIN
    -- Vérifier le type d'utilisateur
    SELECT type_code INTO user_type_code
    FROM vaccination.user_types
    WHERE id = OLD.user_type_id;

    -- Si ce n’est pas un professionnel de santé, laisser passer
    IF user_type_code IS DISTINCT FROM 'HEALTH_PROF' THEN
        RETURN OLD;
    END IF;

    -- Cherche un autre professionnel actif dans le même centre
    SELECT id INTO replacement_id
    FROM vaccination.users
    WHERE health_center_id = OLD.health_center_id
      AND user_type_id = OLD.user_type_id
      AND id != OLD.id
      AND is_active = TRUE
    LIMIT 1;

    IF replacement_id IS NOT NULL THEN
        -- Réassigner ses responsabilités
        UPDATE vaccination.vaccinations
        SET administered_by = replacement_id
        WHERE administered_by = OLD.id;

        UPDATE vaccination.vaccine_stocks
        SET updated_by = replacement_id
        WHERE updated_by = OLD.id;

        -- Autoriser la suppression
        RETURN OLD;
    ELSE
        -- Sinon : désactiver le compte au lieu de le supprimer
        UPDATE vaccination.users SET is_active = FALSE WHERE id = OLD.id;

        -- Annuler la suppression
        RAISE EXCEPTION 'Aucun remplaçant trouvé : le compte est désactivé au lieu d’être supprimé';
    END IF;
END;
$$;


ALTER FUNCTION vaccination.handle_health_prof_deletion() OWNER TO postgres;

--
-- TOC entry 310 (class 1255 OID 77369)
-- Name: record_vaccination(uuid, integer, integer, uuid, date, integer, character varying, date, text); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.record_vaccination(p_card_id uuid, p_vaccine_id integer, p_health_center_id integer, p_administered_by uuid, p_vaccination_date date, p_dose_number integer, p_batch_number character varying DEFAULT NULL::character varying, p_expiry_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_vaccination_id UUID;
    v_stock_id UUID;
BEGIN
    -- Vérifier le stock
    SELECT id INTO v_stock_id
    FROM vaccination.vaccine_stocks
    WHERE vaccine_id = p_vaccine_id 
    AND health_center_id = p_health_center_id
    AND quantity > 0
    AND expiry_date > CURRENT_DATE
    ORDER BY expiry_date ASC
    LIMIT 1;
    
    IF v_stock_id IS NULL THEN
        RAISE EXCEPTION 'Stock insuffisant pour ce vaccin dans ce centre de santé';
    END IF;
    
    -- Enregistrer la vaccination
    INSERT INTO vaccination.vaccinations (
        vaccination_card_id, vaccine_id, health_center_id, 
        administered_by, vaccination_date, dose_number, 
        batch_number, expiry_date, notes
    )
    VALUES (
        p_card_id, p_vaccine_id, p_health_center_id,
        p_administered_by, p_vaccination_date, p_dose_number,
        p_batch_number, p_expiry_date, p_notes
    )
    RETURNING id INTO v_vaccination_id;
    
    -- Décrémenter le stock
    UPDATE vaccination.vaccine_stocks
    SET quantity = quantity - 1,
        last_updated = CURRENT_TIMESTAMP
    WHERE id = v_stock_id;
    
    RETURN v_vaccination_id;
END;
$$;


ALTER FUNCTION vaccination.record_vaccination(p_card_id uuid, p_vaccine_id integer, p_health_center_id integer, p_administered_by uuid, p_vaccination_date date, p_dose_number integer, p_batch_number character varying, p_expiry_date date, p_notes text) OWNER TO postgres;

--
-- TOC entry 5253 (class 0 OID 0)
-- Dependencies: 310
-- Name: FUNCTION record_vaccination(p_card_id uuid, p_vaccine_id integer, p_health_center_id integer, p_administered_by uuid, p_vaccination_date date, p_dose_number integer, p_batch_number character varying, p_expiry_date date, p_notes text); Type: COMMENT; Schema: vaccination; Owner: postgres
--

COMMENT ON FUNCTION vaccination.record_vaccination(p_card_id uuid, p_vaccine_id integer, p_health_center_id integer, p_administered_by uuid, p_vaccination_date date, p_dose_number integer, p_batch_number character varying, p_expiry_date date, p_notes text) IS 'Fonction pour enregistrer une nouvelle vaccination';


--
-- TOC entry 316 (class 1255 OID 77466)
-- Name: resolve_side_effect(uuid); Type: PROCEDURE; Schema: vaccination; Owner: postgres
--

CREATE PROCEDURE vaccination.resolve_side_effect(IN effect_id uuid)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE vaccination.side_effects
    SET resolved_at = CURRENT_DATE
    WHERE id = effect_id;
END;
$$;


ALTER PROCEDURE vaccination.resolve_side_effect(IN effect_id uuid) OWNER TO postgres;

--
-- TOC entry 305 (class 1255 OID 77355)
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: vaccination; Owner: postgres
--

CREATE FUNCTION vaccination.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION vaccination.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 240 (class 1259 OID 77340)
-- Name: audit_logs; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.audit_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    table_name character varying(100) NOT NULL,
    record_id uuid NOT NULL,
    operation character varying(100),
    old_values jsonb,
    new_values jsonb,
    changed_by uuid,
    changed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT audit_logs_operation_check CHECK (((operation)::text = ANY ((ARRAY['INSERT'::character varying, 'UPDATE'::character varying, 'DELETE'::character varying])::text[])))
);


ALTER TABLE vaccination.audit_logs OWNER TO postgres;

--
-- TOC entry 245 (class 1259 OID 77431)
-- Name: campaigns; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    start_date date NOT NULL,
    end_date date NOT NULL,
    location character varying(255),
    target_population text,
    status character varying(50) DEFAULT 'scheduled'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE vaccination.campaigns OWNER TO postgres;

--
-- TOC entry 241 (class 1259 OID 77367)
-- Name: card_number_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.card_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.card_number_seq OWNER TO postgres;

--
-- TOC entry 225 (class 1259 OID 77094)
-- Name: districts; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.districts (
    id integer NOT NULL,
    district_code character varying(100) NOT NULL,
    district_name character varying(100) NOT NULL,
    region_id integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vaccination.districts OWNER TO postgres;

--
-- TOC entry 224 (class 1259 OID 77093)
-- Name: districts_id_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.districts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.districts_id_seq OWNER TO postgres;

--
-- TOC entry 5259 (class 0 OID 0)
-- Dependencies: 224
-- Name: districts_id_seq; Type: SEQUENCE OWNED BY; Schema: vaccination; Owner: postgres
--

ALTER SEQUENCE vaccination.districts_id_seq OWNED BY vaccination.districts.id;


--
-- TOC entry 233 (class 1259 OID 77182)
-- Name: family_members; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.family_members (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid,
    first_name character varying(100) NOT NULL,
    last_name character varying(100) NOT NULL,
    date_of_birth date NOT NULL,
    gender character varying(100),
    relationship character varying(50) NOT NULL,
    cin character varying(100),
    qr_code character varying(100),
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT family_members_gender_check CHECK (((gender)::text = ANY ((ARRAY['M'::character varying, 'F'::character varying])::text[])))
);


ALTER TABLE vaccination.family_members OWNER TO postgres;

--
-- TOC entry 5261 (class 0 OID 0)
-- Dependencies: 233
-- Name: TABLE family_members; Type: COMMENT; Schema: vaccination; Owner: postgres
--

COMMENT ON TABLE vaccination.family_members IS 'Table des membres de famille suivis par un utilisateur';


--
-- TOC entry 227 (class 1259 OID 77109)
-- Name: health_centers; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.health_centers (
    id integer NOT NULL,
    center_code character varying(30) NOT NULL,
    center_name character varying(100) NOT NULL,
    district_id integer,
    address text,
    latitude numeric(10,8),
    longitude numeric(11,8),
    contact_phone character varying(100),
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vaccination.health_centers OWNER TO postgres;

--
-- TOC entry 226 (class 1259 OID 77108)
-- Name: health_centers_id_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.health_centers_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.health_centers_id_seq OWNER TO postgres;

--
-- TOC entry 5264 (class 0 OID 0)
-- Dependencies: 226
-- Name: health_centers_id_seq; Type: SEQUENCE OWNED BY; Schema: vaccination; Owner: postgres
--

ALTER SEQUENCE vaccination.health_centers_id_seq OWNED BY vaccination.health_centers.id;


--
-- TOC entry 223 (class 1259 OID 77084)
-- Name: regions; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.regions (
    id integer NOT NULL,
    region_code character varying(100) NOT NULL,
    region_name character varying(100) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vaccination.regions OWNER TO postgres;

--
-- TOC entry 222 (class 1259 OID 77083)
-- Name: regions_id_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.regions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.regions_id_seq OWNER TO postgres;

--
-- TOC entry 5267 (class 0 OID 0)
-- Dependencies: 222
-- Name: regions_id_seq; Type: SEQUENCE OWNED BY; Schema: vaccination; Owner: postgres
--

ALTER SEQUENCE vaccination.regions_id_seq OWNED BY vaccination.regions.id;


--
-- TOC entry 237 (class 1259 OID 77282)
-- Name: reminders; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.reminders (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    vaccination_card_id uuid,
    vaccine_id integer,
    reminder_date date NOT NULL,
    reminder_type character varying(100),
    message text,
    is_sent boolean DEFAULT false,
    sent_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    is_archived boolean DEFAULT false NOT NULL,
    vaccination_id uuid,
    CONSTRAINT reminders_reminder_type_check CHECK (((reminder_type)::text = ANY ((ARRAY['sms'::character varying, 'push'::character varying, 'ussd'::character varying])::text[])))
);


ALTER TABLE vaccination.reminders OWNER TO postgres;

--
-- TOC entry 234 (class 1259 OID 77201)
-- Name: vaccination_cards; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.vaccination_cards (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid,
    family_member_id uuid,
    card_number character varying(50) NOT NULL,
    qr_code character varying(100),
    is_digital boolean DEFAULT true,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    health_center_id integer,
    CONSTRAINT check_user_or_family CHECK ((((user_id IS NOT NULL) AND (family_member_id IS NULL)) OR ((user_id IS NULL) AND (family_member_id IS NOT NULL))))
);


ALTER TABLE vaccination.vaccination_cards OWNER TO postgres;

--
-- TOC entry 5270 (class 0 OID 0)
-- Dependencies: 234
-- Name: TABLE vaccination_cards; Type: COMMENT; Schema: vaccination; Owner: postgres
--

COMMENT ON TABLE vaccination.vaccination_cards IS 'Table des carnets de vaccination';


--
-- TOC entry 231 (class 1259 OID 77142)
-- Name: vaccination_schedules; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.vaccination_schedules (
    id integer NOT NULL,
    vaccine_id integer,
    age_in_days integer NOT NULL,
    dose_number integer NOT NULL,
    is_booster boolean DEFAULT false,
    interval_from_previous integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vaccination.vaccination_schedules OWNER TO postgres;

--
-- TOC entry 235 (class 1259 OID 77226)
-- Name: vaccinations; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.vaccinations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    vaccination_card_id uuid,
    vaccine_id integer,
    health_center_id integer,
    administered_by uuid,
    vaccination_date date NOT NULL,
    dose_number integer NOT NULL,
    batch_number character varying(50),
    expiry_date date,
    notes text,
    is_verified boolean DEFAULT false,
    verification_date timestamp without time zone,
    verified_by uuid,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    vaccine_stock_id uuid,
    vaccination_time time without time zone,
    poids_enfant numeric(5,2),
    arm_vaccinated character varying(10),
    status character varying(20),
    child_weight numeric(5,2),
    CONSTRAINT vaccinations_arm_vaccinated_check CHECK (((arm_vaccinated)::text = ANY ((ARRAY['gauche'::character varying, 'droit'::character varying])::text[]))),
    CONSTRAINT vaccinations_status_check CHECK (((status)::text = ANY ((ARRAY['complete'::character varying, 'annule'::character varying, 'en_attente'::character varying])::text[])))
);


ALTER TABLE vaccination.vaccinations OWNER TO postgres;

--
-- TOC entry 5273 (class 0 OID 0)
-- Dependencies: 235
-- Name: TABLE vaccinations; Type: COMMENT; Schema: vaccination; Owner: postgres
--

COMMENT ON TABLE vaccination.vaccinations IS 'Table des vaccinations effectuées';


--
-- TOC entry 229 (class 1259 OID 77127)
-- Name: vaccines; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.vaccines (
    id integer NOT NULL,
    vaccine_code character varying(100) NOT NULL,
    vaccine_name character varying(100) NOT NULL,
    manufacturer character varying(100),
    description text,
    min_age_days integer,
    max_age_days integer,
    dose_number integer,
    is_mandatory boolean DEFAULT false,
    storage_temperature_min numeric(5,2),
    storage_temperature_max numeric(5,2),
    expiry_alert_days integer DEFAULT 30,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vaccination.vaccines OWNER TO postgres;

--
-- TOC entry 244 (class 1259 OID 77409)
-- Name: series_completion; Type: VIEW; Schema: vaccination; Owner: postgres
--

CREATE VIEW vaccination.series_completion AS
 SELECT vc.id AS vaccination_card_id,
    COALESCE(vc.user_id, fm.user_id) AS user_id,
    v.id AS vaccine_id,
    v.vaccine_name,
    count(DISTINCT vac.id) AS doses_administrees,
    count(DISTINCT vs.dose_number) AS doses_requises,
        CASE
            WHEN (count(DISTINCT vac.id) = count(DISTINCT vs.dose_number)) THEN true
            ELSE false
        END AS is_series_complete
   FROM ((((vaccination.vaccination_cards vc
     LEFT JOIN vaccination.family_members fm ON ((vc.family_member_id = fm.id)))
     CROSS JOIN vaccination.vaccines v)
     JOIN vaccination.vaccination_schedules vs ON ((vs.vaccine_id = v.id)))
     LEFT JOIN vaccination.vaccinations vac ON (((vac.vaccine_id = v.id) AND (vac.vaccination_card_id = vc.id))))
  GROUP BY vc.id, COALESCE(vc.user_id, fm.user_id), v.id, v.vaccine_name;


ALTER VIEW vaccination.series_completion OWNER TO postgres;

--
-- TOC entry 246 (class 1259 OID 77449)
-- Name: side_effect_followups; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.side_effect_followups (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    side_effect_id uuid NOT NULL,
    followup_type character varying(50),
    notes text,
    done_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT side_effect_followups_followup_type_check CHECK (((followup_type)::text = ANY ((ARRAY['appel'::character varying, 'visite'::character varying, 'message'::character varying, 'traitement'::character varying, 'résolution'::character varying])::text[])))
);


ALTER TABLE vaccination.side_effect_followups OWNER TO postgres;

--
-- TOC entry 236 (class 1259 OID 77261)
-- Name: side_effects; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.side_effects (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    vaccination_id uuid,
    reported_by uuid,
    effect_description text NOT NULL,
    severity character varying(100),
    onset_date date,
    resolution_date date,
    action_taken text,
    is_serious boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    resolved_at date,
    CONSTRAINT side_effects_severity_check CHECK (((severity)::text = ANY ((ARRAY['mild'::character varying, 'moderate'::character varying, 'severe'::character varying])::text[])))
);


ALTER TABLE vaccination.side_effects OWNER TO postgres;

--
-- TOC entry 232 (class 1259 OID 77155)
-- Name: users; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.users (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_type_id integer,
    email character varying(255),
    phone character varying(100),
    password_hash character varying(255),
    first_name character varying(100) NOT NULL,
    last_name character varying(100) NOT NULL,
    date_of_birth date,
    gender character varying(100),
    cin character varying(100),
    health_center_id integer,
    preferred_language character varying(100) DEFAULT 'fr'::character varying,
    is_active boolean DEFAULT true,
    email_verified boolean DEFAULT false,
    phone_verified boolean DEFAULT false,
    last_login timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT users_gender_check CHECK (((gender)::text = ANY ((ARRAY['M'::character varying, 'F'::character varying])::text[])))
);


ALTER TABLE vaccination.users OWNER TO postgres;

--
-- TOC entry 5277 (class 0 OID 0)
-- Dependencies: 232
-- Name: TABLE users; Type: COMMENT; Schema: vaccination; Owner: postgres
--

COMMENT ON TABLE vaccination.users IS 'Table des utilisateurs du système';


--
-- TOC entry 247 (class 1259 OID 77467)
-- Name: side_effect_monitoring; Type: VIEW; Schema: vaccination; Owner: postgres
--

CREATE VIEW vaccination.side_effect_monitoring AS
 SELECT se.id,
    se.vaccination_id,
    v.vaccine_name,
    vac.batch_number,
        CASE
            WHEN (u.id IS NOT NULL) THEN concat(u.first_name, ' ', u.last_name)
            WHEN (fm.id IS NOT NULL) THEN concat(fm.first_name, ' ', fm.last_name)
            ELSE 'Inconnu'::text
        END AS patient_name,
    se.effect_description,
    se.severity,
    se.onset_date,
    se.resolution_date AS resolved_at,
    se.created_at,
    ( SELECT count(*) AS count
           FROM vaccination.side_effect_followups f
          WHERE (f.side_effect_id = se.id)) AS follow_up_count,
    ( SELECT max(f.done_at) AS max
           FROM vaccination.side_effect_followups f
          WHERE (f.side_effect_id = se.id)) AS last_follow_up,
        CASE
            WHEN (se.resolution_date IS NOT NULL) THEN 'resolved'::text
            ELSE 'active'::text
        END AS status
   FROM (((((vaccination.side_effects se
     JOIN vaccination.vaccinations vac ON ((vac.id = se.vaccination_id)))
     JOIN vaccination.vaccines v ON ((v.id = vac.vaccine_id)))
     JOIN vaccination.vaccination_cards vc ON ((vc.id = vac.vaccination_card_id)))
     LEFT JOIN vaccination.users u ON ((vc.user_id = u.id)))
     LEFT JOIN vaccination.family_members fm ON ((vc.family_member_id = fm.id)));


ALTER VIEW vaccination.side_effect_monitoring OWNER TO postgres;

--
-- TOC entry 238 (class 1259 OID 77303)
-- Name: vaccine_stocks; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.vaccine_stocks (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    vaccine_id integer,
    health_center_id integer,
    batch_number character varying(50) NOT NULL,
    quantity integer NOT NULL,
    expiry_date date NOT NULL,
    temperature_log text,
    last_updated timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_by uuid
);


ALTER TABLE vaccination.vaccine_stocks OWNER TO postgres;

--
-- TOC entry 243 (class 1259 OID 77376)
-- Name: stock_status; Type: VIEW; Schema: vaccination; Owner: postgres
--

CREATE VIEW vaccination.stock_status AS
 SELECT hc.center_name,
    d.district_name,
    r.region_name,
    v.vaccine_name,
    sum(vs.quantity) AS total_quantity,
    min(vs.expiry_date) AS earliest_expiry,
    count(
        CASE
            WHEN (vs.expiry_date <= (CURRENT_DATE + '30 days'::interval)) THEN 1
            ELSE NULL::integer
        END) AS expiring_soon
   FROM ((((vaccination.health_centers hc
     JOIN vaccination.districts d ON ((hc.district_id = d.id)))
     JOIN vaccination.regions r ON ((d.region_id = r.id)))
     JOIN vaccination.vaccine_stocks vs ON ((hc.id = vs.health_center_id)))
     JOIN vaccination.vaccines v ON ((vs.vaccine_id = v.id)))
  GROUP BY hc.center_name, d.district_name, r.region_name, v.vaccine_name;


ALTER VIEW vaccination.stock_status OWNER TO postgres;

--
-- TOC entry 221 (class 1259 OID 77072)
-- Name: user_types; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.user_types (
    id integer NOT NULL,
    type_code character varying(100) NOT NULL,
    type_name character varying(100) NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vaccination.user_types OWNER TO postgres;

--
-- TOC entry 220 (class 1259 OID 77071)
-- Name: user_types_id_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.user_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.user_types_id_seq OWNER TO postgres;

--
-- TOC entry 5282 (class 0 OID 0)
-- Dependencies: 220
-- Name: user_types_id_seq; Type: SEQUENCE OWNED BY; Schema: vaccination; Owner: postgres
--

ALTER SEQUENCE vaccination.user_types_id_seq OWNED BY vaccination.user_types.id;


--
-- TOC entry 239 (class 1259 OID 77327)
-- Name: ussd_sessions; Type: TABLE; Schema: vaccination; Owner: postgres
--

CREATE TABLE vaccination.ussd_sessions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    session_id character varying(100) NOT NULL,
    phone_number character varying(100) NOT NULL,
    current_step character varying(50),
    session_data jsonb,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamp without time zone DEFAULT (CURRENT_TIMESTAMP + '00:05:00'::interval)
);


ALTER TABLE vaccination.ussd_sessions OWNER TO postgres;

--
-- TOC entry 242 (class 1259 OID 77371)
-- Name: vaccination_coverage_stats; Type: VIEW; Schema: vaccination; Owner: postgres
--

CREATE VIEW vaccination.vaccination_coverage_stats AS
 SELECT r.region_name,
    d.district_name,
    v.vaccine_name,
    count(DISTINCT vc.id) AS total_cards,
    count(DISTINCT vac.vaccination_card_id) AS vaccinated_cards,
    round((((count(DISTINCT vac.vaccination_card_id))::numeric * 100.0) / (NULLIF(count(DISTINCT vc.id), 0))::numeric), 2) AS coverage_percentage
   FROM (((((vaccination.regions r
     JOIN vaccination.districts d ON ((r.id = d.region_id)))
     JOIN vaccination.health_centers hc ON ((d.id = hc.district_id)))
     JOIN vaccination.vaccinations vac ON ((vac.health_center_id = hc.id)))
     JOIN vaccination.vaccination_cards vc ON ((vac.vaccination_card_id = vc.id)))
     JOIN vaccination.vaccines v ON ((vac.vaccine_id = v.id)))
  WHERE (v.is_active = true)
  GROUP BY r.region_name, d.district_name, v.vaccine_name;


ALTER VIEW vaccination.vaccination_coverage_stats OWNER TO postgres;

--
-- TOC entry 230 (class 1259 OID 77141)
-- Name: vaccination_schedules_id_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.vaccination_schedules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.vaccination_schedules_id_seq OWNER TO postgres;

--
-- TOC entry 5286 (class 0 OID 0)
-- Dependencies: 230
-- Name: vaccination_schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: vaccination; Owner: postgres
--

ALTER SEQUENCE vaccination.vaccination_schedules_id_seq OWNED BY vaccination.vaccination_schedules.id;


--
-- TOC entry 228 (class 1259 OID 77126)
-- Name: vaccines_id_seq; Type: SEQUENCE; Schema: vaccination; Owner: postgres
--

CREATE SEQUENCE vaccination.vaccines_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vaccination.vaccines_id_seq OWNER TO postgres;

--
-- TOC entry 5288 (class 0 OID 0)
-- Dependencies: 228
-- Name: vaccines_id_seq; Type: SEQUENCE OWNED BY; Schema: vaccination; Owner: postgres
--

ALTER SEQUENCE vaccination.vaccines_id_seq OWNED BY vaccination.vaccines.id;


--
-- TOC entry 4893 (class 2604 OID 77097)
-- Name: districts id; Type: DEFAULT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.districts ALTER COLUMN id SET DEFAULT nextval('vaccination.districts_id_seq'::regclass);


--
-- TOC entry 4895 (class 2604 OID 77112)
-- Name: health_centers id; Type: DEFAULT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.health_centers ALTER COLUMN id SET DEFAULT nextval('vaccination.health_centers_id_seq'::regclass);


--
-- TOC entry 4891 (class 2604 OID 77087)
-- Name: regions id; Type: DEFAULT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.regions ALTER COLUMN id SET DEFAULT nextval('vaccination.regions_id_seq'::regclass);


--
-- TOC entry 4889 (class 2604 OID 77075)
-- Name: user_types id; Type: DEFAULT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.user_types ALTER COLUMN id SET DEFAULT nextval('vaccination.user_types_id_seq'::regclass);


--
-- TOC entry 4903 (class 2604 OID 77145)
-- Name: vaccination_schedules id; Type: DEFAULT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_schedules ALTER COLUMN id SET DEFAULT nextval('vaccination.vaccination_schedules_id_seq'::regclass);


--
-- TOC entry 4898 (class 2604 OID 77130)
-- Name: vaccines id; Type: DEFAULT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccines ALTER COLUMN id SET DEFAULT nextval('vaccination.vaccines_id_seq'::regclass);


--
-- TOC entry 5236 (class 0 OID 77340)
-- Dependencies: 240
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.audit_logs (id, table_name, record_id, operation, old_values, new_values, changed_by, changed_at) FROM stdin;
985ae021-2f6a-42e9-8c33-6c237653fd1f	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	INSERT	\N	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": null, "updated_at": "2025-07-10T13:44:47.330416", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 13:44:47.330416
5cd786c5-9e4c-408f-9c42-4075d146ae79	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": null, "updated_at": "2025-07-10T13:44:47.330416", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:15:34.639504", "updated_at": "2025-07-10T14:15:34.639504", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 14:15:34.639504
9c38caf3-58bf-4b98-ac82-c46d2af87a90	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:15:34.639504", "updated_at": "2025-07-10T14:15:34.639504", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:15:52.416393", "updated_at": "2025-07-10T14:15:52.416393", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 14:15:52.416393
f0af118e-ae72-476c-9692-4e87af6784b1	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:15:52.416393", "updated_at": "2025-07-10T14:15:52.416393", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:23:07.846298", "updated_at": "2025-07-10T14:23:07.846298", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 14:23:07.846298
c3fb5e59-9b05-490f-be12-69baa3786046	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:23:07.846298", "updated_at": "2025-07-10T14:23:07.846298", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:23:11.149835", "updated_at": "2025-07-10T14:23:11.149835", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 14:23:11.149835
36ce050c-44fe-47b3-9bd9-478ef4778b2f	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:23:11.149835", "updated_at": "2025-07-10T14:23:11.149835", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:24:10.800335", "updated_at": "2025-07-10T14:24:10.800335", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 14:24:10.800335
f16a0765-3b46-4030-adc7-ea3a1986f33a	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:24:10.800335", "updated_at": "2025-07-10T14:24:10.800335", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:50:54.492905", "updated_at": "2025-07-10T14:50:54.492905", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-10 14:50:54.492905
7c3c8519-a6cc-47f1-b686-810542c7297b	vaccinations	63a61b33-6c5b-4365-b932-1f40fc23e35c	INSERT	\N	{"id": "63a61b33-6c5b-4365-b932-1f40fc23e35c", "notes": "Aucun effet secondaire", "created_at": "2025-07-10T17:39:39.408948", "vaccine_id": 1, "dose_number": 1, "expiry_date": "2026-07-10", "is_verified": true, "verified_by": null, "batch_number": "BATCH1234", "administered_by": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "health_center_id": 1, "vaccination_date": "2025-07-10", "verification_date": null, "vaccination_card_id": "6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2"}	\N	2025-07-10 17:39:39.408948
43da3aa6-a4ad-466f-b155-130d65b84037	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-10T14:50:54.492905", "updated_at": "2025-07-10T14:50:54.492905", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-11T09:06:21.284381", "updated_at": "2025-07-11T09:06:21.284381", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-11 09:06:21.284381
06c06ba9-d979-4718-8444-f4ea53168c62	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "dfsjbj", "created_at": "2025-07-10T13:44:47.330416", "first_name": "jbjj", "last_login": "2025-07-11T09:06:21.284381", "updated_at": "2025-07-11T09:06:21.284381", "user_type_id": 1, "date_of_birth": "2025-07-05", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyen", "last_login": "2025-07-11T09:06:21.284381", "updated_at": "2025-07-11T10:17:25.483473", "user_type_id": 1, "date_of_birth": "2015-01-08", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-11 10:17:25.483473
5df58958-0fb1-4f34-a426-76e1ee5fa171	users	9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2	INSERT	\N	{"id": "9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2", "cin": "77777777777777777", "email": "profsante@exemple.com", "phone": "69999999", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:29:29.305653", "first_name": "cameroun", "last_login": null, "updated_at": "2025-07-11T14:29:29.305653", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$cUKppOzDK0pvKD4UIwMuzOKArSoQdqkoUNJANEhrcglxSLc2yn0f.", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 14:29:29.305653
0ae5259d-93df-48fc-9d15-06fd29b891fd	users	2fce9530-b137-4a58-8aa5-609d722646bc	INSERT	\N	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": null, "updated_at": "2025-07-11T14:46:12.784012", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 14:46:12.784012
6465db55-2c39-41f4-9d0d-6f7ed1f44d9b	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": null, "updated_at": "2025-07-11T14:46:12.784012", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T15:42:52.497308", "updated_at": "2025-07-11T15:42:52.497308", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 15:42:52.497308
7fdba3a3-0b1d-4c5f-81c0-1735cf1b4fb7	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T15:42:52.497308", "updated_at": "2025-07-11T15:42:52.497308", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T15:54:28.875293", "updated_at": "2025-07-11T15:54:28.875293", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 15:54:28.875293
4d02f7f8-5e1d-4403-8068-79b09cec14fa	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyen", "last_login": "2025-07-11T09:06:21.284381", "updated_at": "2025-07-11T10:17:25.483473", "user_type_id": 1, "date_of_birth": "2015-01-08", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyen", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T06:43:19.736378", "user_type_id": 1, "date_of_birth": "2015-01-08", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-12 06:43:19.736378
d8f86630-9683-4fef-95af-02232670a449	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T15:54:28.875293", "updated_at": "2025-07-11T15:54:28.875293", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:19:59.546756", "updated_at": "2025-07-11T16:19:59.546756", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:19:59.546756
3fc13420-4e2c-44bc-bd4e-abf313ccf9bf	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:19:59.546756", "updated_at": "2025-07-11T16:19:59.546756", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:21:19.010265", "updated_at": "2025-07-11T16:21:19.010265", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:21:19.010265
5e05eaab-8055-4fbf-9505-8af44dc224d9	users	9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2	UPDATE	{"id": "9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2", "cin": "77777777777777777", "email": "profsante@exemple.com", "phone": "69999999", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:29:29.305653", "first_name": "cameroun", "last_login": null, "updated_at": "2025-07-11T14:29:29.305653", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$cUKppOzDK0pvKD4UIwMuzOKArSoQdqkoUNJANEhrcglxSLc2yn0f.", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2", "cin": "77777777777777777", "email": "profsante@exemple.com", "phone": "69999999", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:29:29.305653", "first_name": "cameroun", "last_login": "2025-07-11T16:23:04.032641", "updated_at": "2025-07-11T16:23:04.032641", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$cUKppOzDK0pvKD4UIwMuzOKArSoQdqkoUNJANEhrcglxSLc2yn0f.", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:23:04.032641
8b0270c8-3a53-4df8-a980-c74b5cedff72	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:21:19.010265", "updated_at": "2025-07-11T16:21:19.010265", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:28:19.00432", "updated_at": "2025-07-11T16:28:19.00432", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:28:19.00432
3a029a3d-d70b-44d3-a8a5-74779fb53dba	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:28:19.00432", "updated_at": "2025-07-11T16:28:19.00432", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:31:29.859673", "updated_at": "2025-07-11T16:31:29.859673", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:31:29.859673
c92ebe04-b511-4c83-b26c-a11697a1b91b	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:31:29.859673", "updated_at": "2025-07-11T16:31:29.859673", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:32:01.923116", "updated_at": "2025-07-11T16:32:01.923116", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:32:01.923116
2c07ed82-ed90-4ae9-9198-3649cf0c5a81	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:32:01.923116", "updated_at": "2025-07-11T16:32:01.923116", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:38:58.050015", "updated_at": "2025-07-11T16:38:58.050015", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:38:58.050015
c71671f9-162d-43d0-b13d-8d740865d0b3	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:38:58.050015", "updated_at": "2025-07-11T16:38:58.050015", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:55:22.297636", "updated_at": "2025-07-11T16:55:22.297636", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:55:22.297636
be872f58-6b81-425f-9543-cc736af4a5ee	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:55:22.297636", "updated_at": "2025-07-11T16:55:22.297636", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:59:38.025247", "updated_at": "2025-07-11T16:59:38.025247", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 16:59:38.025247
bf1b2e38-47fe-44a0-a94f-868770eeef7e	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T16:59:38.025247", "updated_at": "2025-07-11T16:59:38.025247", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T17:04:10.216841", "updated_at": "2025-07-11T17:04:10.216841", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 17:04:10.216841
8043e254-207f-4cfd-b9e7-5a68b7c1744b	vaccinations	e3e25194-4301-4818-a478-a4fd13ff4fa4	INSERT	\N	{"id": "e3e25194-4301-4818-a478-a4fd13ff4fa4", "notes": "kk,", "status": "complete", "created_at": "2025-07-11T17:26:00.861387", "vaccine_id": 1, "dose_number": 1, "expiry_date": null, "is_verified": false, "verified_by": null, "batch_number": "097b03dc-0d63-453a-b82c-d4d61cd5ae05", "child_weight": 3.20, "poids_enfant": null, "arm_vaccinated": "gauche", "administered_by": "9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2", "health_center_id": 10, "vaccination_date": "2025-07-12", "vaccination_time": null, "vaccine_stock_id": null, "verification_date": null, "vaccination_card_id": "6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2"}	\N	2025-07-11 17:26:00.861387
99da0940-f9b0-499c-9629-4f11dcd52dce	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T17:04:10.216841", "updated_at": "2025-07-11T17:04:10.216841", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-11T21:33:42.572004", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-11 21:33:42.572004
307bec3e-f604-4822-adba-7dd9da829ba3	vaccinations	8c92481b-3357-4cfc-81ec-f8dac8b311ba	INSERT	\N	{"id": "8c92481b-3357-4cfc-81ec-f8dac8b311ba", "notes": "hhhhhhhhhhhh", "status": "complete", "created_at": "2025-07-13T02:21:24.418094", "vaccine_id": 1, "dose_number": 2, "expiry_date": null, "is_verified": false, "verified_by": null, "batch_number": null, "child_weight": 2.60, "poids_enfant": null, "arm_vaccinated": "gauche", "administered_by": "2fce9530-b137-4a58-8aa5-609d722646bc", "health_center_id": 12, "vaccination_date": "2025-07-11", "vaccination_time": "02:21:00", "vaccine_stock_id": "097b03dc-0d63-453a-b82c-d4d61cd5ae05", "verification_date": null, "vaccination_card_id": "6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2"}	\N	2025-07-13 02:21:24.418094
966b6624-66eb-489f-960f-17fa047de7a7	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-11T21:33:42.572004", "user_type_id": 2, "date_of_birth": "1993-01-14", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T00:34:27.176276", "user_type_id": 2, "date_of_birth": "1993-01-13", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 00:34:27.176276
5a83809f-5abf-494b-8c0c-6b0ecbb864d2	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T00:34:27.176276", "user_type_id": 2, "date_of_birth": "1993-01-13", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T00:36:23.256327", "user_type_id": 2, "date_of_birth": "1993-01-12", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 00:36:23.256327
0ee8bbbc-c4a8-42d8-870b-9b605ac0869a	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T00:36:23.256327", "user_type_id": 2, "date_of_birth": "1993-01-12", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T00:36:58.206566", "user_type_id": 2, "date_of_birth": "1993-01-12", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 00:36:58.206566
8fa8d5a1-2dba-4bab-9b50-3090786b6740	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T00:36:58.206566", "user_type_id": 2, "date_of_birth": "1993-01-12", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T06:22:51.70872", "user_type_id": 2, "date_of_birth": "1993-01-11", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 06:22:51.70872
f606eca2-c97e-4bb2-935a-cd5e0c6c5e01	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T06:22:51.70872", "user_type_id": 2, "date_of_birth": "1993-01-11", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T06:23:44.229535", "user_type_id": 2, "date_of_birth": "1993-01-11", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 06:23:44.229535
dec1458f-092e-4ae0-8f6f-d8f413a4cb04	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T06:23:44.229535", "user_type_id": 2, "date_of_birth": "1993-01-11", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T06:28:44.053133", "user_type_id": 2, "date_of_birth": "1993-01-10", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 06:28:44.053133
a7aa1bb7-e804-4790-9759-f5a75ff8a89d	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyen", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T06:43:19.736378", "user_type_id": 1, "date_of_birth": "2015-01-08", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyen", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T07:11:55.568326", "user_type_id": 1, "date_of_birth": "2025-07-18", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-12 07:11:55.568326
0339b9ad-d11e-4b47-98b6-d2131cf37543	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyen", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T07:11:55.568326", "user_type_id": 1, "date_of_birth": "2025-07-18", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyens", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T07:28:58.870889", "user_type_id": 1, "date_of_birth": "2025-07-17", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-12 07:28:58.870889
4b3031b7-ea80-4b49-8a22-81fc8792867b	users	07811cc8-ea40-4776-b27a-e3f1000ead6c	UPDATE	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyens", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T07:28:58.870889", "user_type_id": 1, "date_of_birth": "2025-07-17", "password_hash": "$2b$10$vQuvfmixBftrR9fAVGHDrediKkIJgNhaYLRUY4bQjpubhuEh2YlPi", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	{"id": "07811cc8-ea40-4776-b27a-e3f1000ead6c", "cin": "4444", "email": "citoyen@exemple.com", "phone": "691178267", "gender": "M", "is_active": true, "last_name": "camerounais ", "created_at": "2025-07-10T13:44:47.330416", "first_name": "citoyens", "last_login": "2025-07-12T06:43:19.736378", "updated_at": "2025-07-12T08:46:13.291101", "user_type_id": 1, "date_of_birth": "2025-07-17", "password_hash": "$2b$10$dMJGSKQJcAIWIvhfZOBgQe..FZjZ1Ajkl39oUYkeHnOIQQNvdbYfe", "email_verified": false, "phone_verified": false, "health_center_id": null, "preferred_language": "fr"}	\N	2025-07-12 08:46:13.291101
4b606e15-2e4f-4345-86c7-44e39fbd9473	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-11T21:33:42.572004", "updated_at": "2025-07-12T06:28:44.053133", "user_type_id": 2, "date_of_birth": "1993-01-10", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-12T09:02:15.642715", "updated_at": "2025-07-12T09:02:15.642715", "user_type_id": 2, "date_of_birth": "1993-01-10", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 09:02:15.642715
3a3ef173-22bb-426d-9627-5dc978899328	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-12T09:02:15.642715", "updated_at": "2025-07-12T09:02:15.642715", "user_type_id": 2, "date_of_birth": "1993-01-10", "password_hash": "$2b$10$2gpboU0fBvRNQmmiybYUEuawBg3s/gNI8RhIpspG3lLzGqMeq7tqy", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-12T09:02:15.642715", "updated_at": "2025-07-12T09:24:43.591014", "user_type_id": 2, "date_of_birth": "1993-01-10", "password_hash": "$2b$10$y2HWcYgOvFAdwPHE0xJZK.MH4q/KkgKWoQCDcP0X2Gzbz/rk/CGTG", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 09:24:43.591014
9d9ddd00-feb4-49a9-8e8e-3a91de253f35	vaccine_stocks	097b03dc-0d63-453a-b82c-d4d61cd5ae05	UPDATE	\N	{"reason": "", "quantity": 99, "updated_at": "2025-07-12T09:41:06.026Z"}	2fce9530-b137-4a58-8aa5-609d722646bc	2025-07-12 10:41:06.030198
4110beae-d12f-4a8f-b20b-7f40920d43c8	users	2fce9530-b137-4a58-8aa5-609d722646bc	UPDATE	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-12T09:02:15.642715", "updated_at": "2025-07-12T09:24:43.591014", "user_type_id": 2, "date_of_birth": "1993-01-10", "password_hash": "$2b$10$y2HWcYgOvFAdwPHE0xJZK.MH4q/KkgKWoQCDcP0X2Gzbz/rk/CGTG", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	{"id": "2fce9530-b137-4a58-8aa5-609d722646bc", "cin": "77777777777777777", "email": "prof@exemple.com", "phone": "65555567", "gender": "F", "is_active": true, "last_name": "professionnel", "created_at": "2025-07-11T14:46:12.784012", "first_name": "cameroun", "last_login": "2025-07-12T09:02:15.642715", "updated_at": "2025-07-12T20:17:04.055479", "user_type_id": 2, "date_of_birth": "1993-01-09", "password_hash": "$2b$10$y2HWcYgOvFAdwPHE0xJZK.MH4q/KkgKWoQCDcP0X2Gzbz/rk/CGTG", "email_verified": false, "phone_verified": false, "health_center_id": 13, "preferred_language": "fr"}	\N	2025-07-12 20:17:04.055479
\.


--
-- TOC entry 5238 (class 0 OID 77431)
-- Dependencies: 245
-- Data for Name: campaigns; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.campaigns (id, title, description, start_date, end_date, location, target_population, status, created_at, updated_at) FROM stdin;
16d21f59-69c1-483b-abf6-962c38adffbf	iohr	grgereferfer	2025-07-27	2025-07-31	vnvrjvnrjnrv	4	scheduled	2025-07-12 09:50:12.082099+01	2025-07-12 09:50:12.082099+01
cffeb2fa-778d-4012-bcf2-33cf5fcfb5b7	jjbjbn	knigr	2025-07-25	2025-07-16	jjjv	0 a 5	scheduled	2025-07-12 20:15:58.268773+01	2025-07-12 20:15:58.268773+01
\.


--
-- TOC entry 5221 (class 0 OID 77094)
-- Dependencies: 225
-- Data for Name: districts; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.districts (id, district_code, district_name, region_id, created_at) FROM stdin;
1	NGD	Ngaoundéré	1	2025-07-10 10:02:40.103334
2	TIB	Tibati	1	2025-07-10 10:02:40.103334
3	YDE1	Yaoundé I	2	2025-07-10 10:02:40.103334
4	YDE2	Yaoundé II	2	2025-07-10 10:02:40.103334
5	BAT	Bertoua	3	2025-07-10 10:02:40.103334
6	BAT2	Batouri	3	2025-07-10 10:02:40.103334
7	MAR	Maroua	4	2025-07-10 10:02:40.103334
8	KOU	Kousséri	4	2025-07-10 10:02:40.103334
9	DLA1	Douala I	5	2025-07-10 10:02:40.103334
10	DLA5	Douala V	5	2025-07-10 10:02:40.103334
11	GAR	Garoua	6	2025-07-10 10:02:40.103334
12	GUI	Guider	6	2025-07-10 10:02:40.103334
13	BAM	Bamenda	7	2025-07-10 10:02:40.103334
14	FUN	Fundong	7	2025-07-10 10:02:40.103334
15	BAF	Bafoussam	8	2025-07-10 10:02:40.103334
16	FOU	Foumban	8	2025-07-10 10:02:40.103334
17	EBO	Ebolowa	9	2025-07-10 10:02:40.103334
18	KRIBI	Kribi	9	2025-07-10 10:02:40.103334
19	LIM	Limbe	10	2025-07-10 10:02:40.103334
20	BUA	Buea	10	2025-07-10 10:02:40.103334
\.


--
-- TOC entry 5229 (class 0 OID 77182)
-- Dependencies: 233
-- Data for Name: family_members; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.family_members (id, user_id, first_name, last_name, date_of_birth, gender, relationship, cin, qr_code, is_active, created_at, updated_at) FROM stdin;
28fd7547-e4d3-442d-8ca7-5b3f9e3839d6	07811cc8-ea40-4776-b27a-e3f1000ead6c	Marie	Dupont	1982-05-12	F	Spouse	CIN654321	QR654321	t	2025-07-10 16:40:54.507434	2025-07-10 16:40:54.507434
06490fb7-e4c0-4b91-9838-4d44d8853fcb	07811cc8-ea40-4776-b27a-e3f1000ead6c	Lucas	Dupont	2010-08-15	M	Son	CIN789012	QR789012	t	2025-07-10 16:40:54.507434	2025-07-10 16:40:54.507434
4f09772e-fb05-4ba0-b01e-d57490eb587a	07811cc8-ea40-4776-b27a-e3f1000ead6c	n	 kom	2025-07-11	M	Enfant	55	QR_58B11DF849C05EE5A25CF324A46ED92C	t	2025-07-10 20:22:34.708036	2025-07-10 20:22:46.673167
fe9ea729-4024-4303-ade2-ad7e2dfec1ba	07811cc8-ea40-4776-b27a-e3f1000ead6c	Jean	Dupont	1980-01-01	M	Self	CIN123456	QR123456	f	2025-07-10 16:40:54.507434	2025-07-10 20:22:55.868782
\.


--
-- TOC entry 5223 (class 0 OID 77109)
-- Dependencies: 227
-- Data for Name: health_centers; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.health_centers (id, center_code, center_name, district_id, address, latitude, longitude, contact_phone, is_active, created_at) FROM stdin;
1	HC-NGD-001	Centre de Santé Ngaoundéré 1	1	Quartier Central, Ngaoundéré	7.32740000	13.58470000	+237690000001	t	2025-07-10 10:04:14.331958
2	HC-TIB-001	Hôpital de District Tibati	2	Avenue de l’Hôpital, Tibati	6.46670000	12.61670000	+237690000002	t	2025-07-10 10:04:14.331958
3	HC-YDE1-001	CSI Yaoundé I - Mvog Ada	3	Mvog Ada, Yaoundé	3.86670000	11.51670000	+237690000003	t	2025-07-10 10:04:14.331958
4	HC-YDE2-001	Hôpital de District Yaoundé II	4	Essos, Yaoundé	3.88890000	11.51110000	+237690000004	t	2025-07-10 10:04:14.331958
5	HC-BAT-001	Centre Médical Bertoua	5	Quartier Mokolo, Bertoua	4.56670000	13.68330000	+237690000005	t	2025-07-10 10:04:14.331958
6	HC-BAT2-001	Centre de Santé Batouri	6	Carrefour Principal, Batouri	4.43330000	14.36670000	+237690000006	t	2025-07-10 10:04:14.331958
7	HC-MAR-001	Hôpital Régional de Maroua	7	Domayo, Maroua	10.59560000	14.32470000	+237690000007	t	2025-07-10 10:04:14.331958
8	HC-KOU-001	CSI Kousséri	8	Centre Ville, Kousséri	12.07690000	15.03060000	+237690000008	t	2025-07-10 10:04:14.331958
9	HC-DLA1-001	Centre de Santé Douala I	9	Bonanjo, Douala	4.05000000	9.70000000	+237690000009	t	2025-07-10 10:04:14.331958
10	HC-DLA5-001	Hôpital de District Douala V	10	Logbaba, Douala	4.05010000	9.76500000	+237690000010	t	2025-07-10 10:04:14.331958
11	HC-GAR-001	Centre Régional Garoua	11	Plateau, Garoua	9.30000000	13.40000000	+237690000011	t	2025-07-10 10:04:14.331958
12	HC-BAM-001	Hôpital Régional Bamenda	13	Upstation, Bamenda	5.96310000	10.15910000	+237690000012	t	2025-07-10 10:04:14.331958
13	HC-BAF-001	CSI Bafoussam	15	Marché A, Bafoussam	5.47830000	10.41730000	+237690000013	t	2025-07-10 10:04:14.331958
14	HC-EBO-001	Centre de Santé Ebolowa	17	Centre-ville, Ebolowa	2.90000000	11.15000000	+237690000014	t	2025-07-10 10:04:14.331958
15	HC-BUA-001	Hôpital de District Buea	20	Great Soppo, Buea	4.16670000	9.23330000	+237690000015	t	2025-07-10 10:04:14.331958
\.


--
-- TOC entry 5219 (class 0 OID 77084)
-- Dependencies: 223
-- Data for Name: regions; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.regions (id, region_code, region_name, created_at) FROM stdin;
1	AD	Adamaoua	2025-07-09 16:54:35.63711
2	CE	Centre	2025-07-09 16:54:35.63711
3	ES	Est	2025-07-09 16:54:35.63711
4	EN	Extrême-Nord	2025-07-09 16:54:35.63711
5	LT	Littoral	2025-07-09 16:54:35.63711
6	NO	Nord	2025-07-09 16:54:35.63711
7	NW	Nord-Ouest	2025-07-09 16:54:35.63711
8	OU	Ouest	2025-07-09 16:54:35.63711
9	SU	Sud	2025-07-09 16:54:35.63711
10	SW	Sud-Ouest	2025-07-09 16:54:35.63711
\.


--
-- TOC entry 5233 (class 0 OID 77282)
-- Dependencies: 237
-- Data for Name: reminders; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.reminders (id, vaccination_card_id, vaccine_id, reminder_date, reminder_type, message, is_sent, sent_at, created_at, is_archived, vaccination_id) FROM stdin;
\.


--
-- TOC entry 5239 (class 0 OID 77449)
-- Dependencies: 246
-- Data for Name: side_effect_followups; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.side_effect_followups (id, side_effect_id, followup_type, notes, done_at) FROM stdin;
dcb72e69-0dbc-4938-96ea-a57763f147ec	d9f3ef07-c3df-4bac-8f2e-49754fdc3273	message	Signalement au district sanitaire	2025-07-12 19:38:59.125046
\.


--
-- TOC entry 5232 (class 0 OID 77261)
-- Dependencies: 236
-- Data for Name: side_effects; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.side_effects (id, vaccination_id, reported_by, effect_description, severity, onset_date, resolution_date, action_taken, is_serious, created_at, resolved_at) FROM stdin;
6399a292-8876-4aa2-9922-4933a5b4a1aa	e3e25194-4301-4818-a478-a4fd13ff4fa4	\N	vhvhe	mild	2025-07-12	2025-07-12	ruhruhrvurhvr	f	2025-07-12 17:13:31.032242	\N
d9f3ef07-c3df-4bac-8f2e-49754fdc3273	e3e25194-4301-4818-a478-a4fd13ff4fa4	\N	hbhbhb	moderate	2025-07-17	2025-07-17	ntntj(jnhy	f	2025-07-12 17:57:19.581715	\N
\.


--
-- TOC entry 5217 (class 0 OID 77072)
-- Dependencies: 221
-- Data for Name: user_types; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.user_types (id, type_code, type_name, description, created_at) FROM stdin;
1	CITIZEN	Citoyen	Citoyen ordinaire	2025-07-09 16:54:35.63711
2	HEALTH_PROF	Professionnel de santé	Médecin, infirmier, pharmacien	2025-07-09 16:54:35.63711
3	COMMUNITY_AGENT	Agent communautaire	Agent de terrain pour campagnes	2025-07-09 16:54:35.63711
4	HEALTH_AUTHORITY	Autorité sanitaire	Ministère, district sanitaire	2025-07-09 16:54:35.63711
5	INTERNATIONAL_PARTNER	Partenaire international	OMS, UNICEF, GAVI	2025-07-09 16:54:35.63711
6	ADMIN	Administrateur	Administrateur système	2025-07-09 16:54:35.63711
\.


--
-- TOC entry 5228 (class 0 OID 77155)
-- Dependencies: 232
-- Data for Name: users; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.users (id, user_type_id, email, phone, password_hash, first_name, last_name, date_of_birth, gender, cin, health_center_id, preferred_language, is_active, email_verified, phone_verified, last_login, created_at, updated_at) FROM stdin;
2fce9530-b137-4a58-8aa5-609d722646bc	2	prof@exemple.com	65555567	$2b$10$y2HWcYgOvFAdwPHE0xJZK.MH4q/KkgKWoQCDcP0X2Gzbz/rk/CGTG	cameroun	professionnel	1993-01-09	F	77777777777777777	13	fr	t	f	f	2025-07-12 09:02:15.642715	2025-07-11 14:46:12.784012	2025-07-12 20:17:04.055479
9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2	2	profsante@exemple.com	69999999	$2b$10$cUKppOzDK0pvKD4UIwMuzOKArSoQdqkoUNJANEhrcglxSLc2yn0f.	cameroun	professionnel	1993-01-14	F	77777777777777777	13	fr	t	f	f	2025-07-11 16:23:04.032641	2025-07-11 14:29:29.305653	2025-07-11 16:23:04.032641
07811cc8-ea40-4776-b27a-e3f1000ead6c	1	citoyen@exemple.com	691178267	$2b$10$dMJGSKQJcAIWIvhfZOBgQe..FZjZ1Ajkl39oUYkeHnOIQQNvdbYfe	citoyens	camerounais 	2025-07-17	M	4444	\N	fr	t	f	f	2025-07-12 06:43:19.736378	2025-07-10 13:44:47.330416	2025-07-12 08:46:13.291101
\.


--
-- TOC entry 5235 (class 0 OID 77327)
-- Dependencies: 239
-- Data for Name: ussd_sessions; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.ussd_sessions (id, session_id, phone_number, current_step, session_data, is_active, created_at, expires_at) FROM stdin;
\.


--
-- TOC entry 5230 (class 0 OID 77201)
-- Dependencies: 234
-- Data for Name: vaccination_cards; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.vaccination_cards (id, user_id, family_member_id, card_number, qr_code, is_digital, is_active, created_at, updated_at, health_center_id) FROM stdin;
6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2	07811cc8-ea40-4776-b27a-e3f1000ead6c	\N	CARD_00000001	QR_CA92204923C2BF872D24A75F322AE06D	t	t	2025-07-10 13:44:47.442007	2025-07-10 13:44:47.442007	\N
895c8e4b-f42f-4bdf-ad08-7f9f58e0f723	\N	4f09772e-fb05-4ba0-b01e-d57490eb587a	CARD_00000002	QR_5F5B0C5FC7FFE7D490618420E7ADD549	t	t	2025-07-10 20:22:34.75181	2025-07-10 20:22:34.75181	\N
\.


--
-- TOC entry 5227 (class 0 OID 77142)
-- Dependencies: 231
-- Data for Name: vaccination_schedules; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.vaccination_schedules (id, vaccine_id, age_in_days, dose_number, is_booster, interval_from_previous, created_at) FROM stdin;
1	1	0	1	f	\N	2025-07-09 16:54:35.63711
2	2	42	1	f	\N	2025-07-09 16:54:35.63711
3	2	84	2	f	\N	2025-07-09 16:54:35.63711
4	2	126	3	f	\N	2025-07-09 16:54:35.63711
5	3	42	1	f	\N	2025-07-09 16:54:35.63711
6	3	84	2	f	\N	2025-07-09 16:54:35.63711
7	3	126	3	f	\N	2025-07-09 16:54:35.63711
8	5	42	1	f	\N	2025-07-09 16:54:35.63711
9	5	84	2	f	\N	2025-07-09 16:54:35.63711
10	5	126	3	f	\N	2025-07-09 16:54:35.63711
11	6	42	1	f	\N	2025-07-09 16:54:35.63711
12	6	84	2	f	\N	2025-07-09 16:54:35.63711
13	7	270	1	f	\N	2025-07-09 16:54:35.63711
14	7	450	2	f	\N	2025-07-09 16:54:35.63711
15	8	270	1	f	\N	2025-07-09 16:54:35.63711
16	9	270	1	f	\N	2025-07-09 16:54:35.63711
\.


--
-- TOC entry 5231 (class 0 OID 77226)
-- Dependencies: 235
-- Data for Name: vaccinations; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.vaccinations (id, vaccination_card_id, vaccine_id, health_center_id, administered_by, vaccination_date, dose_number, batch_number, expiry_date, notes, is_verified, verification_date, verified_by, created_at, vaccine_stock_id, vaccination_time, poids_enfant, arm_vaccinated, status, child_weight) FROM stdin;
63a61b33-6c5b-4365-b932-1f40fc23e35c	6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2	1	1	07811cc8-ea40-4776-b27a-e3f1000ead6c	2025-07-10	1	BATCH1234	2026-07-10	Aucun effet secondaire	t	\N	\N	2025-07-10 17:39:39.408948	\N	\N	\N	\N	\N	\N
e3e25194-4301-4818-a478-a4fd13ff4fa4	6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2	1	10	9d69d2b1-c4c1-4ccd-8430-3b3dbb0308b2	2025-07-12	1	097b03dc-0d63-453a-b82c-d4d61cd5ae05	\N	kk,	f	\N	\N	2025-07-11 17:26:00.861387	\N	\N	\N	gauche	complete	3.20
8c92481b-3357-4cfc-81ec-f8dac8b311ba	6c40ca87-bd62-4bd3-b1d6-7ceb9925f4f2	1	12	2fce9530-b137-4a58-8aa5-609d722646bc	2025-07-11	2	\N	\N	hhhhhhhhhhhh	f	\N	\N	2025-07-13 02:21:24.418094	097b03dc-0d63-453a-b82c-d4d61cd5ae05	02:21:00	\N	gauche	complete	2.60
\.


--
-- TOC entry 5234 (class 0 OID 77303)
-- Dependencies: 238
-- Data for Name: vaccine_stocks; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.vaccine_stocks (id, vaccine_id, health_center_id, batch_number, quantity, expiry_date, temperature_log, last_updated, updated_by) FROM stdin;
097b03dc-0d63-453a-b82c-d4d61cd5ae05	1	1	LOT-BCG-001	98	2025-12-31	Température stable entre 2-8°C	2025-07-12 10:41:06.010241	2fce9530-b137-4a58-8aa5-609d722646bc
\.


--
-- TOC entry 5225 (class 0 OID 77127)
-- Dependencies: 229
-- Data for Name: vaccines; Type: TABLE DATA; Schema: vaccination; Owner: postgres
--

COPY vaccination.vaccines (id, vaccine_code, vaccine_name, manufacturer, description, min_age_days, max_age_days, dose_number, is_mandatory, storage_temperature_min, storage_temperature_max, expiry_alert_days, is_active, created_at) FROM stdin;
1	BCG	Bacille Calmette-Guérin	Divers	\N	0	365	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
2	DTC_HEP_HIB	DTC-Hépatite B-Hib	Divers	\N	42	10095	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
3	POLIO_ORAL	Polio Oral	Divers	\N	42	10095	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
4	POLIO_INJECTABLE	Polio Injectable	Divers	\N	42	10095	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
5	PNEUMO	Pneumocoque	Divers	\N	42	10095	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
6	ROTA	Rotavirus	Divers	\N	42	365	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
7	ROR	Rougeole-Oreillons-Rubéole	Divers	\N	270	10095	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
8	FIEVRE_JAUNE	Fièvre Jaune	Divers	\N	270	\N	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
9	MENINGITE	Méningite A	Divers	\N	270	\N	\N	t	\N	\N	30	t	2025-07-09 16:54:35.63711
10	HPV	Papillomavirus Humain	Divers	\N	3285	4380	\N	f	\N	\N	30	t	2025-07-09 16:54:35.63711
\.


--
-- TOC entry 5290 (class 0 OID 0)
-- Dependencies: 241
-- Name: card_number_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.card_number_seq', 2, true);


--
-- TOC entry 5291 (class 0 OID 0)
-- Dependencies: 224
-- Name: districts_id_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.districts_id_seq', 1, false);


--
-- TOC entry 5292 (class 0 OID 0)
-- Dependencies: 226
-- Name: health_centers_id_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.health_centers_id_seq', 1, false);


--
-- TOC entry 5293 (class 0 OID 0)
-- Dependencies: 222
-- Name: regions_id_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.regions_id_seq', 10, true);


--
-- TOC entry 5294 (class 0 OID 0)
-- Dependencies: 220
-- Name: user_types_id_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.user_types_id_seq', 6, true);


--
-- TOC entry 5295 (class 0 OID 0)
-- Dependencies: 230
-- Name: vaccination_schedules_id_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.vaccination_schedules_id_seq', 16, true);


--
-- TOC entry 5296 (class 0 OID 0)
-- Dependencies: 228
-- Name: vaccines_id_seq; Type: SEQUENCE SET; Schema: vaccination; Owner: postgres
--

SELECT pg_catalog.setval('vaccination.vaccines_id_seq', 10, true);


--
-- TOC entry 5020 (class 2606 OID 77349)
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- TOC entry 5024 (class 2606 OID 77441)
-- Name: campaigns campaigns_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.campaigns
    ADD CONSTRAINT campaigns_pkey PRIMARY KEY (id);


--
-- TOC entry 4964 (class 2606 OID 77102)
-- Name: districts districts_district_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.districts
    ADD CONSTRAINT districts_district_code_key UNIQUE (district_code);


--
-- TOC entry 4966 (class 2606 OID 77100)
-- Name: districts districts_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.districts
    ADD CONSTRAINT districts_pkey PRIMARY KEY (id);


--
-- TOC entry 4985 (class 2606 OID 77193)
-- Name: family_members family_members_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.family_members
    ADD CONSTRAINT family_members_pkey PRIMARY KEY (id);


--
-- TOC entry 4987 (class 2606 OID 77195)
-- Name: family_members family_members_qr_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.family_members
    ADD CONSTRAINT family_members_qr_code_key UNIQUE (qr_code);


--
-- TOC entry 4968 (class 2606 OID 77120)
-- Name: health_centers health_centers_center_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.health_centers
    ADD CONSTRAINT health_centers_center_code_key UNIQUE (center_code);


--
-- TOC entry 4970 (class 2606 OID 77118)
-- Name: health_centers health_centers_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.health_centers
    ADD CONSTRAINT health_centers_pkey PRIMARY KEY (id);


--
-- TOC entry 4960 (class 2606 OID 77090)
-- Name: regions regions_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.regions
    ADD CONSTRAINT regions_pkey PRIMARY KEY (id);


--
-- TOC entry 4962 (class 2606 OID 77092)
-- Name: regions regions_region_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.regions
    ADD CONSTRAINT regions_region_code_key UNIQUE (region_code);


--
-- TOC entry 5008 (class 2606 OID 77292)
-- Name: reminders reminders_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.reminders
    ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);


--
-- TOC entry 5026 (class 2606 OID 77458)
-- Name: side_effect_followups side_effect_followups_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.side_effect_followups
    ADD CONSTRAINT side_effect_followups_pkey PRIMARY KEY (id);


--
-- TOC entry 5004 (class 2606 OID 77271)
-- Name: side_effects side_effects_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.side_effects
    ADD CONSTRAINT side_effects_pkey PRIMARY KEY (id);


--
-- TOC entry 4956 (class 2606 OID 77080)
-- Name: user_types user_types_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.user_types
    ADD CONSTRAINT user_types_pkey PRIMARY KEY (id);


--
-- TOC entry 4958 (class 2606 OID 77082)
-- Name: user_types user_types_type_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.user_types
    ADD CONSTRAINT user_types_type_code_key UNIQUE (type_code);


--
-- TOC entry 4981 (class 2606 OID 77171)
-- Name: users users_email_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- TOC entry 4983 (class 2606 OID 77169)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- TOC entry 5016 (class 2606 OID 77337)
-- Name: ussd_sessions ussd_sessions_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.ussd_sessions
    ADD CONSTRAINT ussd_sessions_pkey PRIMARY KEY (id);


--
-- TOC entry 5018 (class 2606 OID 77339)
-- Name: ussd_sessions ussd_sessions_session_id_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.ussd_sessions
    ADD CONSTRAINT ussd_sessions_session_id_key UNIQUE (session_id);


--
-- TOC entry 4993 (class 2606 OID 77213)
-- Name: vaccination_cards vaccination_cards_card_number_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_cards
    ADD CONSTRAINT vaccination_cards_card_number_key UNIQUE (card_number);


--
-- TOC entry 4995 (class 2606 OID 77211)
-- Name: vaccination_cards vaccination_cards_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_cards
    ADD CONSTRAINT vaccination_cards_pkey PRIMARY KEY (id);


--
-- TOC entry 4997 (class 2606 OID 77215)
-- Name: vaccination_cards vaccination_cards_qr_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_cards
    ADD CONSTRAINT vaccination_cards_qr_code_key UNIQUE (qr_code);


--
-- TOC entry 4976 (class 2606 OID 77149)
-- Name: vaccination_schedules vaccination_schedules_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_schedules
    ADD CONSTRAINT vaccination_schedules_pkey PRIMARY KEY (id);


--
-- TOC entry 5002 (class 2606 OID 77235)
-- Name: vaccinations vaccinations_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_pkey PRIMARY KEY (id);


--
-- TOC entry 5012 (class 2606 OID 77311)
-- Name: vaccine_stocks vaccine_stocks_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccine_stocks
    ADD CONSTRAINT vaccine_stocks_pkey PRIMARY KEY (id);


--
-- TOC entry 4972 (class 2606 OID 77138)
-- Name: vaccines vaccines_pkey; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccines
    ADD CONSTRAINT vaccines_pkey PRIMARY KEY (id);


--
-- TOC entry 4974 (class 2606 OID 77140)
-- Name: vaccines vaccines_vaccine_code_key; Type: CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccines
    ADD CONSTRAINT vaccines_vaccine_code_key UNIQUE (vaccine_code);


--
-- TOC entry 5021 (class 1259 OID 77397)
-- Name: idx_audit_changed_at; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_audit_changed_at ON vaccination.audit_logs USING btree (changed_at);


--
-- TOC entry 5022 (class 1259 OID 77396)
-- Name: idx_audit_table_record; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_audit_table_record ON vaccination.audit_logs USING btree (table_name, record_id);


--
-- TOC entry 4988 (class 1259 OID 77385)
-- Name: idx_family_members_qr_code; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_family_members_qr_code ON vaccination.family_members USING btree (qr_code);


--
-- TOC entry 4989 (class 1259 OID 77384)
-- Name: idx_family_members_user_id; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_family_members_user_id ON vaccination.family_members USING btree (user_id);


--
-- TOC entry 5005 (class 1259 OID 77390)
-- Name: idx_reminders_date; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_reminders_date ON vaccination.reminders USING btree (reminder_date);


--
-- TOC entry 5006 (class 1259 OID 77391)
-- Name: idx_reminders_sent; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_reminders_sent ON vaccination.reminders USING btree (is_sent);


--
-- TOC entry 5009 (class 1259 OID 77393)
-- Name: idx_stocks_expiry; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_stocks_expiry ON vaccination.vaccine_stocks USING btree (expiry_date);


--
-- TOC entry 5010 (class 1259 OID 77392)
-- Name: idx_stocks_vaccine_center; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_stocks_vaccine_center ON vaccination.vaccine_stocks USING btree (vaccine_id, health_center_id);


--
-- TOC entry 4977 (class 1259 OID 77383)
-- Name: idx_users_cin; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_users_cin ON vaccination.users USING btree (cin);


--
-- TOC entry 4978 (class 1259 OID 77382)
-- Name: idx_users_email; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_users_email ON vaccination.users USING btree (email);


--
-- TOC entry 4979 (class 1259 OID 77381)
-- Name: idx_users_phone; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_users_phone ON vaccination.users USING btree (phone);


--
-- TOC entry 5013 (class 1259 OID 77395)
-- Name: idx_ussd_phone; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_ussd_phone ON vaccination.ussd_sessions USING btree (phone_number);


--
-- TOC entry 5014 (class 1259 OID 77394)
-- Name: idx_ussd_session_id; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_ussd_session_id ON vaccination.ussd_sessions USING btree (session_id);


--
-- TOC entry 4990 (class 1259 OID 77422)
-- Name: idx_vaccination_cards_health_center_id; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_vaccination_cards_health_center_id ON vaccination.vaccination_cards USING btree (health_center_id);


--
-- TOC entry 4991 (class 1259 OID 77386)
-- Name: idx_vaccination_cards_qr_code; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_vaccination_cards_qr_code ON vaccination.vaccination_cards USING btree (qr_code);


--
-- TOC entry 4998 (class 1259 OID 77387)
-- Name: idx_vaccinations_card_id; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_vaccinations_card_id ON vaccination.vaccinations USING btree (vaccination_card_id);


--
-- TOC entry 4999 (class 1259 OID 77389)
-- Name: idx_vaccinations_date; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_vaccinations_date ON vaccination.vaccinations USING btree (vaccination_date);


--
-- TOC entry 5000 (class 1259 OID 77388)
-- Name: idx_vaccinations_vaccine_id; Type: INDEX; Schema: vaccination; Owner: postgres
--

CREATE INDEX idx_vaccinations_vaccine_id ON vaccination.vaccinations USING btree (vaccine_id);


--
-- TOC entry 5052 (class 2620 OID 77360)
-- Name: users audit_users; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER audit_users AFTER INSERT OR DELETE OR UPDATE ON vaccination.users FOR EACH ROW EXECUTE FUNCTION vaccination.audit_trigger_function();


--
-- TOC entry 5059 (class 2620 OID 77361)
-- Name: vaccinations audit_vaccinations; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER audit_vaccinations AFTER INSERT OR DELETE OR UPDATE ON vaccination.vaccinations FOR EACH ROW EXECUTE FUNCTION vaccination.audit_trigger_function();


--
-- TOC entry 5055 (class 2620 OID 77364)
-- Name: family_members auto_qr_family_members; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER auto_qr_family_members BEFORE INSERT ON vaccination.family_members FOR EACH ROW EXECUTE FUNCTION vaccination.auto_generate_qr_code();


--
-- TOC entry 5057 (class 2620 OID 77365)
-- Name: vaccination_cards auto_qr_vaccination_cards; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER auto_qr_vaccination_cards BEFORE INSERT ON vaccination.vaccination_cards FOR EACH ROW EXECUTE FUNCTION vaccination.auto_generate_qr_code();


--
-- TOC entry 5053 (class 2620 OID 77448)
-- Name: users protect_health_prof_deletion; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER protect_health_prof_deletion BEFORE DELETE ON vaccination.users FOR EACH ROW EXECUTE FUNCTION vaccination.handle_health_prof_deletion();


--
-- TOC entry 5060 (class 2620 OID 77465)
-- Name: side_effect_followups trg_auto_resolve; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER trg_auto_resolve AFTER INSERT ON vaccination.side_effect_followups FOR EACH ROW EXECUTE FUNCTION vaccination.auto_resolve_if_needed();


--
-- TOC entry 5056 (class 2620 OID 77357)
-- Name: family_members update_family_members_updated_at; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER update_family_members_updated_at BEFORE UPDATE ON vaccination.family_members FOR EACH ROW EXECUTE FUNCTION vaccination.update_updated_at_column();


--
-- TOC entry 5054 (class 2620 OID 77356)
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON vaccination.users FOR EACH ROW EXECUTE FUNCTION vaccination.update_updated_at_column();


--
-- TOC entry 5058 (class 2620 OID 77358)
-- Name: vaccination_cards update_vaccination_cards_updated_at; Type: TRIGGER; Schema: vaccination; Owner: postgres
--

CREATE TRIGGER update_vaccination_cards_updated_at BEFORE UPDATE ON vaccination.vaccination_cards FOR EACH ROW EXECUTE FUNCTION vaccination.update_updated_at_column();


--
-- TOC entry 5050 (class 2606 OID 77350)
-- Name: audit_logs audit_logs_changed_by_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.audit_logs
    ADD CONSTRAINT audit_logs_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES vaccination.users(id);


--
-- TOC entry 5027 (class 2606 OID 77103)
-- Name: districts districts_region_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.districts
    ADD CONSTRAINT districts_region_id_fkey FOREIGN KEY (region_id) REFERENCES vaccination.regions(id);


--
-- TOC entry 5032 (class 2606 OID 77196)
-- Name: family_members family_members_user_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.family_members
    ADD CONSTRAINT family_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES vaccination.users(id) ON DELETE CASCADE;


--
-- TOC entry 5028 (class 2606 OID 77121)
-- Name: health_centers health_centers_district_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.health_centers
    ADD CONSTRAINT health_centers_district_id_fkey FOREIGN KEY (district_id) REFERENCES vaccination.districts(id);


--
-- TOC entry 5044 (class 2606 OID 77293)
-- Name: reminders reminders_vaccination_card_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.reminders
    ADD CONSTRAINT reminders_vaccination_card_id_fkey FOREIGN KEY (vaccination_card_id) REFERENCES vaccination.vaccination_cards(id);


--
-- TOC entry 5045 (class 2606 OID 77442)
-- Name: reminders reminders_vaccination_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.reminders
    ADD CONSTRAINT reminders_vaccination_id_fkey FOREIGN KEY (vaccination_id) REFERENCES vaccination.vaccinations(id);


--
-- TOC entry 5046 (class 2606 OID 77298)
-- Name: reminders reminders_vaccine_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.reminders
    ADD CONSTRAINT reminders_vaccine_id_fkey FOREIGN KEY (vaccine_id) REFERENCES vaccination.vaccines(id);


--
-- TOC entry 5051 (class 2606 OID 77459)
-- Name: side_effect_followups side_effect_followups_side_effect_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.side_effect_followups
    ADD CONSTRAINT side_effect_followups_side_effect_id_fkey FOREIGN KEY (side_effect_id) REFERENCES vaccination.side_effects(id) ON DELETE CASCADE;


--
-- TOC entry 5042 (class 2606 OID 77277)
-- Name: side_effects side_effects_reported_by_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.side_effects
    ADD CONSTRAINT side_effects_reported_by_fkey FOREIGN KEY (reported_by) REFERENCES vaccination.users(id);


--
-- TOC entry 5043 (class 2606 OID 77272)
-- Name: side_effects side_effects_vaccination_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.side_effects
    ADD CONSTRAINT side_effects_vaccination_id_fkey FOREIGN KEY (vaccination_id) REFERENCES vaccination.vaccinations(id);


--
-- TOC entry 5030 (class 2606 OID 77177)
-- Name: users users_health_center_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.users
    ADD CONSTRAINT users_health_center_id_fkey FOREIGN KEY (health_center_id) REFERENCES vaccination.health_centers(id);


--
-- TOC entry 5031 (class 2606 OID 77172)
-- Name: users users_user_type_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.users
    ADD CONSTRAINT users_user_type_id_fkey FOREIGN KEY (user_type_id) REFERENCES vaccination.user_types(id);


--
-- TOC entry 5033 (class 2606 OID 77221)
-- Name: vaccination_cards vaccination_cards_family_member_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_cards
    ADD CONSTRAINT vaccination_cards_family_member_id_fkey FOREIGN KEY (family_member_id) REFERENCES vaccination.family_members(id);


--
-- TOC entry 5034 (class 2606 OID 77417)
-- Name: vaccination_cards vaccination_cards_health_center_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_cards
    ADD CONSTRAINT vaccination_cards_health_center_id_fkey FOREIGN KEY (health_center_id) REFERENCES vaccination.health_centers(id);


--
-- TOC entry 5035 (class 2606 OID 77216)
-- Name: vaccination_cards vaccination_cards_user_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_cards
    ADD CONSTRAINT vaccination_cards_user_id_fkey FOREIGN KEY (user_id) REFERENCES vaccination.users(id);


--
-- TOC entry 5029 (class 2606 OID 77150)
-- Name: vaccination_schedules vaccination_schedules_vaccine_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccination_schedules
    ADD CONSTRAINT vaccination_schedules_vaccine_id_fkey FOREIGN KEY (vaccine_id) REFERENCES vaccination.vaccines(id);


--
-- TOC entry 5036 (class 2606 OID 77251)
-- Name: vaccinations vaccinations_administered_by_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_administered_by_fkey FOREIGN KEY (administered_by) REFERENCES vaccination.users(id);


--
-- TOC entry 5037 (class 2606 OID 77246)
-- Name: vaccinations vaccinations_health_center_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_health_center_id_fkey FOREIGN KEY (health_center_id) REFERENCES vaccination.health_centers(id);


--
-- TOC entry 5038 (class 2606 OID 77236)
-- Name: vaccinations vaccinations_vaccination_card_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_vaccination_card_id_fkey FOREIGN KEY (vaccination_card_id) REFERENCES vaccination.vaccination_cards(id);


--
-- TOC entry 5039 (class 2606 OID 77241)
-- Name: vaccinations vaccinations_vaccine_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_vaccine_id_fkey FOREIGN KEY (vaccine_id) REFERENCES vaccination.vaccines(id);


--
-- TOC entry 5040 (class 2606 OID 77424)
-- Name: vaccinations vaccinations_vaccine_stock_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_vaccine_stock_id_fkey FOREIGN KEY (vaccine_stock_id) REFERENCES vaccination.vaccine_stocks(id);


--
-- TOC entry 5041 (class 2606 OID 77256)
-- Name: vaccinations vaccinations_verified_by_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccinations
    ADD CONSTRAINT vaccinations_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES vaccination.users(id);


--
-- TOC entry 5047 (class 2606 OID 77317)
-- Name: vaccine_stocks vaccine_stocks_health_center_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccine_stocks
    ADD CONSTRAINT vaccine_stocks_health_center_id_fkey FOREIGN KEY (health_center_id) REFERENCES vaccination.health_centers(id);


--
-- TOC entry 5048 (class 2606 OID 77322)
-- Name: vaccine_stocks vaccine_stocks_updated_by_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccine_stocks
    ADD CONSTRAINT vaccine_stocks_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES vaccination.users(id);


--
-- TOC entry 5049 (class 2606 OID 77312)
-- Name: vaccine_stocks vaccine_stocks_vaccine_id_fkey; Type: FK CONSTRAINT; Schema: vaccination; Owner: postgres
--

ALTER TABLE ONLY vaccination.vaccine_stocks
    ADD CONSTRAINT vaccine_stocks_vaccine_id_fkey FOREIGN KEY (vaccine_id) REFERENCES vaccination.vaccines(id);


--
-- TOC entry 5214 (class 3256 OID 77402)
-- Name: family_members family_member_own_data; Type: POLICY; Schema: vaccination; Owner: postgres
--

CREATE POLICY family_member_own_data ON vaccination.family_members TO vaccination_citizen USING ((user_id = (current_setting('app.current_user_id'::text))::uuid));


--
-- TOC entry 5211 (class 0 OID 77182)
-- Dependencies: 233
-- Name: family_members; Type: ROW SECURITY; Schema: vaccination; Owner: postgres
--

ALTER TABLE vaccination.family_members ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 5213 (class 3256 OID 77401)
-- Name: users user_own_data; Type: POLICY; Schema: vaccination; Owner: postgres
--

CREATE POLICY user_own_data ON vaccination.users TO vaccination_citizen USING ((id = (current_setting('app.current_user_id'::text))::uuid));


--
-- TOC entry 5210 (class 0 OID 77155)
-- Dependencies: 232
-- Name: users; Type: ROW SECURITY; Schema: vaccination; Owner: postgres
--

ALTER TABLE vaccination.users ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 5215 (class 3256 OID 77403)
-- Name: vaccination_cards vaccination_card_own_data; Type: POLICY; Schema: vaccination; Owner: postgres
--

CREATE POLICY vaccination_card_own_data ON vaccination.vaccination_cards TO vaccination_citizen USING (((user_id = (current_setting('app.current_user_id'::text))::uuid) OR (family_member_id IN ( SELECT family_members.id
   FROM vaccination.family_members
  WHERE (family_members.user_id = (current_setting('app.current_user_id'::text))::uuid)))));


--
-- TOC entry 5212 (class 0 OID 77201)
-- Dependencies: 234
-- Name: vaccination_cards; Type: ROW SECURITY; Schema: vaccination; Owner: postgres
--

ALTER TABLE vaccination.vaccination_cards ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 5248 (class 0 OID 0)
-- Dependencies: 306
-- Name: FUNCTION audit_trigger_function(); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.audit_trigger_function() TO vaccination_admin;


--
-- TOC entry 5249 (class 0 OID 0)
-- Dependencies: 308
-- Name: FUNCTION auto_generate_qr_code(); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.auto_generate_qr_code() TO vaccination_admin;


--
-- TOC entry 5250 (class 0 OID 0)
-- Dependencies: 311
-- Name: FUNCTION create_automatic_reminders(); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.create_automatic_reminders() TO vaccination_admin;


--
-- TOC entry 5251 (class 0 OID 0)
-- Dependencies: 309
-- Name: FUNCTION create_vaccination_card(p_user_id uuid, p_family_member_id uuid); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.create_vaccination_card(p_user_id uuid, p_family_member_id uuid) TO vaccination_admin;


--
-- TOC entry 5252 (class 0 OID 0)
-- Dependencies: 307
-- Name: FUNCTION generate_qr_code(); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.generate_qr_code() TO vaccination_admin;


--
-- TOC entry 5254 (class 0 OID 0)
-- Dependencies: 310
-- Name: FUNCTION record_vaccination(p_card_id uuid, p_vaccine_id integer, p_health_center_id integer, p_administered_by uuid, p_vaccination_date date, p_dose_number integer, p_batch_number character varying, p_expiry_date date, p_notes text); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.record_vaccination(p_card_id uuid, p_vaccine_id integer, p_health_center_id integer, p_administered_by uuid, p_vaccination_date date, p_dose_number integer, p_batch_number character varying, p_expiry_date date, p_notes text) TO vaccination_admin;


--
-- TOC entry 5255 (class 0 OID 0)
-- Dependencies: 305
-- Name: FUNCTION update_updated_at_column(); Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON FUNCTION vaccination.update_updated_at_column() TO vaccination_admin;


--
-- TOC entry 5256 (class 0 OID 0)
-- Dependencies: 240
-- Name: TABLE audit_logs; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.audit_logs TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.audit_logs TO vaccination_admin;


--
-- TOC entry 5257 (class 0 OID 0)
-- Dependencies: 241
-- Name: SEQUENCE card_number_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.card_number_seq TO vaccination_admin;


--
-- TOC entry 5258 (class 0 OID 0)
-- Dependencies: 225
-- Name: TABLE districts; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.districts TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.districts TO vaccination_admin;


--
-- TOC entry 5260 (class 0 OID 0)
-- Dependencies: 224
-- Name: SEQUENCE districts_id_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.districts_id_seq TO vaccination_admin;


--
-- TOC entry 5262 (class 0 OID 0)
-- Dependencies: 233
-- Name: TABLE family_members; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.family_members TO vaccination_citizen;
GRANT SELECT ON TABLE vaccination.family_members TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.family_members TO vaccination_admin;


--
-- TOC entry 5263 (class 0 OID 0)
-- Dependencies: 227
-- Name: TABLE health_centers; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.health_centers TO vaccination_citizen;
GRANT SELECT ON TABLE vaccination.health_centers TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.health_centers TO vaccination_admin;


--
-- TOC entry 5265 (class 0 OID 0)
-- Dependencies: 226
-- Name: SEQUENCE health_centers_id_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.health_centers_id_seq TO vaccination_admin;


--
-- TOC entry 5266 (class 0 OID 0)
-- Dependencies: 223
-- Name: TABLE regions; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.regions TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.regions TO vaccination_admin;


--
-- TOC entry 5268 (class 0 OID 0)
-- Dependencies: 222
-- Name: SEQUENCE regions_id_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.regions_id_seq TO vaccination_admin;


--
-- TOC entry 5269 (class 0 OID 0)
-- Dependencies: 237
-- Name: TABLE reminders; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.reminders TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.reminders TO vaccination_admin;


--
-- TOC entry 5271 (class 0 OID 0)
-- Dependencies: 234
-- Name: TABLE vaccination_cards; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.vaccination_cards TO vaccination_citizen;
GRANT SELECT ON TABLE vaccination.vaccination_cards TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.vaccination_cards TO vaccination_admin;


--
-- TOC entry 5272 (class 0 OID 0)
-- Dependencies: 231
-- Name: TABLE vaccination_schedules; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.vaccination_schedules TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.vaccination_schedules TO vaccination_admin;


--
-- TOC entry 5274 (class 0 OID 0)
-- Dependencies: 235
-- Name: TABLE vaccinations; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.vaccinations TO vaccination_citizen;
GRANT SELECT,INSERT,UPDATE ON TABLE vaccination.vaccinations TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.vaccinations TO vaccination_admin;


--
-- TOC entry 5275 (class 0 OID 0)
-- Dependencies: 229
-- Name: TABLE vaccines; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.vaccines TO vaccination_citizen;
GRANT SELECT ON TABLE vaccination.vaccines TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.vaccines TO vaccination_admin;


--
-- TOC entry 5276 (class 0 OID 0)
-- Dependencies: 236
-- Name: TABLE side_effects; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE vaccination.side_effects TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.side_effects TO vaccination_admin;


--
-- TOC entry 5278 (class 0 OID 0)
-- Dependencies: 232
-- Name: TABLE users; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.users TO vaccination_citizen;
GRANT SELECT ON TABLE vaccination.users TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.users TO vaccination_admin;


--
-- TOC entry 5279 (class 0 OID 0)
-- Dependencies: 238
-- Name: TABLE vaccine_stocks; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT,UPDATE ON TABLE vaccination.vaccine_stocks TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.vaccine_stocks TO vaccination_admin;


--
-- TOC entry 5280 (class 0 OID 0)
-- Dependencies: 243
-- Name: TABLE stock_status; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.stock_status TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.stock_status TO vaccination_admin;


--
-- TOC entry 5281 (class 0 OID 0)
-- Dependencies: 221
-- Name: TABLE user_types; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.user_types TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.user_types TO vaccination_admin;


--
-- TOC entry 5283 (class 0 OID 0)
-- Dependencies: 220
-- Name: SEQUENCE user_types_id_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.user_types_id_seq TO vaccination_admin;


--
-- TOC entry 5284 (class 0 OID 0)
-- Dependencies: 239
-- Name: TABLE ussd_sessions; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.ussd_sessions TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.ussd_sessions TO vaccination_admin;


--
-- TOC entry 5285 (class 0 OID 0)
-- Dependencies: 242
-- Name: TABLE vaccination_coverage_stats; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT SELECT ON TABLE vaccination.vaccination_coverage_stats TO vaccination_health_professional;
GRANT ALL ON TABLE vaccination.vaccination_coverage_stats TO vaccination_admin;


--
-- TOC entry 5287 (class 0 OID 0)
-- Dependencies: 230
-- Name: SEQUENCE vaccination_schedules_id_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.vaccination_schedules_id_seq TO vaccination_admin;


--
-- TOC entry 5289 (class 0 OID 0)
-- Dependencies: 228
-- Name: SEQUENCE vaccines_id_seq; Type: ACL; Schema: vaccination; Owner: postgres
--

GRANT ALL ON SEQUENCE vaccination.vaccines_id_seq TO vaccination_admin;


-- Completed on 2025-07-13 02:24:52

--
-- PostgreSQL database dump complete
--

