--
-- PostgreSQL database dump
--

-- Dumped from database version 14.15 (Homebrew)
-- Dumped by pg_dump version 14.15 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: shop_avg_discount_by_category(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shop_avg_discount_by_category(p_category_id integer) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_avg NUMERIC;
BEGIN
  SELECT AVG(o.discount_amount)
  INTO v_avg
  FROM shop_order o
  WHERE EXISTS (
    SELECT 1
    FROM shop_orderitem oi
    JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
    JOIN shop_product p ON p.id = pv.product_id
    WHERE oi.order_id = o.id
      AND p.category_id = p_category_id
  );

  RETURN COALESCE(ROUND(v_avg, 2), 0);
END;
$$;


--
-- Name: shop_cancel_order(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.shop_cancel_order(IN p_order_id integer, OUT result_message text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_status VARCHAR(20);
BEGIN
  SELECT status INTO v_status FROM shop_order WHERE id = p_order_id;

  IF NOT FOUND THEN
    result_message := 'Заказ не найден';
    RETURN;
  END IF;

  IF v_status NOT IN ('pending', 'paid') THEN
    result_message := format('Нельзя отменить: текущий статус %s', v_status);
    RETURN;
  END IF;

  UPDATE shop_order SET status = 'cancelled' WHERE id = p_order_id;
  result_message := 'Заказ отменён';
END;
$$;


--
-- Name: shop_close_warehouse_until(timestamp with time zone); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.shop_close_warehouse_until(IN p_until timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_cnt INT;
BEGIN
  UPDATE shop_order
  SET status = 'cancelled'
  WHERE status = 'pending'
    AND order_date < p_until;

  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  RAISE NOTICE 'Отменено заказов: %', v_cnt;
END;
$$;


--
-- Name: shop_decommission_brand(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.shop_decommission_brand(IN p_brand_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT DISTINCT o.id AS order_id
    FROM shop_order o
    JOIN shop_orderitem oi ON oi.order_id = o.id
    JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
    JOIN shop_product p ON p.id = pv.product_id
    WHERE p.brand_id = p_brand_id
      AND o.status = 'pending'
  LOOP
    UPDATE shop_order SET status = 'cancelled' WHERE id = r.order_id;

    UPDATE shop_order o
    SET total_amount = GREATEST(0, o.total_amount - COALESCE((
      SELECT SUM(oi.price_at_time * oi.quantity)
      FROM shop_orderitem oi
      JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
      JOIN shop_product p ON p.id = pv.product_id
      WHERE oi.order_id = r.order_id AND p.brand_id = p_brand_id
    ), 0))
    WHERE o.id = r.order_id;
  END LOOP;

  DELETE FROM shop_brand WHERE id = p_brand_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Бренд % не найден', p_brand_id;
  END IF;
END;
$$;


--
-- Name: shop_get_brand_sales_count(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shop_get_brand_sales_count(p_brand_id integer) RETURNS integer
    LANGUAGE sql
    AS $$
  SELECT COUNT(*)::INT
  FROM shop_orderitem oi
  JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
  JOIN shop_product p ON p.id = pv.product_id
  WHERE p.brand_id = p_brand_id;
$$;


--
-- Name: shop_get_order_age_hours(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shop_get_order_age_hours(p_order_id integer) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_hours NUMERIC;
BEGIN
  SELECT EXTRACT(EPOCH FROM (NOW() - order_date)) / 3600
  INTO v_hours
  FROM shop_order
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN ROUND(v_hours, 2);
END;
$$;


--
-- Name: shop_report_stale_orders(integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.shop_report_stale_orders(IN p_hours integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id, customer_name, order_date,
           EXTRACT(EPOCH FROM (NOW() - order_date)) / 3600 AS hours_waiting
    FROM shop_order
    WHERE status = 'pending'
      AND order_date < NOW() - (p_hours || ' hours')::INTERVAL
    ORDER BY order_date
  LOOP
    RAISE NOTICE 'Заказ %: %, ждёт % ч', r.id, r.customer_name, ROUND(r.hours_waiting::numeric, 1);
  END LOOP;
END;
$$;


--
-- Name: shop_upgrade_cheapest_item(integer, numeric); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.shop_upgrade_cheapest_item(IN p_order_id integer, IN p_max_surcharge numeric, OUT msg text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_item_id INT;
  v_old_price NUMERIC(10,2);
  v_new_price NUMERIC(10,2);
  v_category_id INT;
  v_surcharge NUMERIC(12,2);
  v_order_total NUMERIC(12,2);
BEGIN
  SELECT oi.id, oi.price_at_time, p.category_id
  INTO v_item_id, v_old_price, v_category_id
  FROM shop_orderitem oi
  JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
  JOIN shop_product p ON p.id = pv.product_id
  WHERE oi.order_id = p_order_id
  ORDER BY oi.price_at_time ASC, oi.id
  LIMIT 1;

  IF NOT FOUND THEN
    msg := 'В заказе нет позиций';
    RETURN;
  END IF;

  SELECT MAX(p.base_price) INTO v_new_price
  FROM shop_product p
  WHERE p.category_id = v_category_id;

  v_surcharge := v_new_price - v_old_price;

  IF v_surcharge > p_max_surcharge THEN
    RAISE EXCEPTION 'Слишком дорогой апгрейд: доплата %', v_surcharge;
  END IF;

  UPDATE shop_orderitem SET price_at_time = v_new_price WHERE id = v_item_id;

  SELECT COALESCE(SUM(price_at_time * quantity), 0)
  INTO v_order_total
  FROM shop_orderitem
  WHERE order_id = p_order_id;

  UPDATE shop_order SET total_amount = v_order_total WHERE id = p_order_id;

  msg := format('Позиция %s: %s → %s', v_item_id, v_old_price, v_new_price);
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: auth_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_group (
    id integer NOT NULL,
    name character varying(150) NOT NULL
);


--
-- Name: auth_group_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.auth_group ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_group_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_group_permissions (
    id bigint NOT NULL,
    group_id integer NOT NULL,
    permission_id integer NOT NULL
);


--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.auth_group_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_permission; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_permission (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    content_type_id integer NOT NULL,
    codename character varying(100) NOT NULL
);


--
-- Name: auth_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.auth_permission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_admin_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_admin_log (
    id integer NOT NULL,
    action_time timestamp with time zone NOT NULL,
    object_id text,
    object_repr character varying(200) NOT NULL,
    action_flag smallint NOT NULL,
    change_message text NOT NULL,
    content_type_id integer,
    user_id bigint NOT NULL,
    CONSTRAINT django_admin_log_action_flag_check CHECK ((action_flag >= 0))
);


--
-- Name: django_admin_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.django_admin_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_admin_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_content_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_content_type (
    id integer NOT NULL,
    app_label character varying(100) NOT NULL,
    model character varying(100) NOT NULL
);


--
-- Name: django_content_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.django_content_type ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_content_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_migrations (
    id bigint NOT NULL,
    app character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    applied timestamp with time zone NOT NULL
);


--
-- Name: django_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.django_migrations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_migrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_session (
    session_key character varying(40) NOT NULL,
    session_data text NOT NULL,
    expire_date timestamp with time zone NOT NULL
);


--
-- Name: shop_brand; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_brand (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text NOT NULL
);


--
-- Name: shop_brand_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_brand ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_brand_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_category (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text NOT NULL
);


--
-- Name: shop_category_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_category ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_color; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_color (
    id bigint NOT NULL,
    name character varying(100) NOT NULL
);


--
-- Name: shop_color_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_color ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_color_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_lab6scratch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_lab6scratch (
    id bigint NOT NULL,
    label character varying(100) NOT NULL,
    link character varying(500) NOT NULL,
    counter integer NOT NULL
);


--
-- Name: shop_lab6scratch_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_lab6scratch ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_lab6scratch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_order; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_order (
    id bigint NOT NULL,
    customer_name character varying(255) NOT NULL,
    customer_email character varying(254) NOT NULL,
    order_date timestamp with time zone NOT NULL,
    status character varying(20) NOT NULL,
    total_amount numeric(12,2) NOT NULL,
    discount_amount numeric(10,2) NOT NULL,
    promo_code_id bigint
);


--
-- Name: shop_order_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_order ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_order_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_orderitem; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_orderitem (
    id bigint NOT NULL,
    quantity integer NOT NULL,
    price_at_time numeric(10,2) NOT NULL,
    order_id bigint NOT NULL,
    product_variant_id bigint NOT NULL,
    CONSTRAINT shop_orderitem_quantity_check CHECK ((quantity >= 0))
);


--
-- Name: shop_orderitem_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_orderitem ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_orderitem_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_product; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_product (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text NOT NULL,
    base_price numeric(10,2) NOT NULL,
    image_url character varying(500) NOT NULL,
    created_at timestamp with time zone NOT NULL,
    brand_id bigint NOT NULL,
    category_id bigint NOT NULL,
    cover_image character varying(100),
    specification_file character varying(100)
);


--
-- Name: shop_product_available_colors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_product_available_colors (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    color_id bigint NOT NULL
);


--
-- Name: shop_product_available_colors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_product_available_colors ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_product_available_colors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_product_available_sizes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_product_available_sizes (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    size_id bigint NOT NULL
);


--
-- Name: shop_product_available_sizes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_product_available_sizes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_product_available_sizes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_product_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_product ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_product_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_productsimilar; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_productsimilar (
    id bigint NOT NULL,
    notes character varying(200) NOT NULL,
    from_product_id bigint NOT NULL,
    to_product_id bigint NOT NULL
);


--
-- Name: shop_productsimilar_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_productsimilar ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_productsimilar_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_producttag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_producttag (
    id bigint NOT NULL,
    sort_order smallint NOT NULL,
    product_id bigint NOT NULL,
    tag_id bigint NOT NULL,
    CONSTRAINT shop_producttag_sort_order_check CHECK ((sort_order >= 0))
);


--
-- Name: shop_producttag_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_producttag ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_producttag_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_productvariant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_productvariant (
    id bigint NOT NULL,
    stock_quantity integer NOT NULL,
    color_id bigint NOT NULL,
    product_id bigint NOT NULL,
    size_id bigint NOT NULL,
    CONSTRAINT shop_productvariant_stock_quantity_check CHECK ((stock_quantity >= 0))
);


--
-- Name: shop_productvariant_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_productvariant ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_productvariant_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_promocode; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_promocode (
    id bigint NOT NULL,
    code character varying(50) NOT NULL,
    discount_type character varying(20) NOT NULL,
    discount_value numeric(10,2) NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    max_uses integer NOT NULL,
    used_count integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT shop_promocode_max_uses_check CHECK ((max_uses >= 0)),
    CONSTRAINT shop_promocode_used_count_check CHECK ((used_count >= 0))
);


--
-- Name: shop_promocode_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_promocode ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_promocode_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_size; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_size (
    id bigint NOT NULL,
    name character varying(50) NOT NULL
);


--
-- Name: shop_size_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_size ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_size_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_tag; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_tag (
    id bigint NOT NULL,
    name character varying(100) NOT NULL,
    icon character varying(100)
);


--
-- Name: shop_tag_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_tag ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_tag_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_user (
    id bigint NOT NULL,
    password character varying(128) NOT NULL,
    last_login timestamp with time zone,
    is_superuser boolean NOT NULL,
    username character varying(150) NOT NULL,
    first_name character varying(150) NOT NULL,
    last_name character varying(150) NOT NULL,
    email character varying(254) NOT NULL,
    is_staff boolean NOT NULL,
    is_active boolean NOT NULL,
    date_joined timestamp with time zone NOT NULL
);


--
-- Name: shop_user_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_user_groups (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    group_id integer NOT NULL
);


--
-- Name: shop_user_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_user_groups ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_user_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_user ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shop_user_user_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_user_user_permissions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    permission_id integer NOT NULL
);


--
-- Name: shop_user_user_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shop_user_user_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shop_user_user_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Data for Name: auth_group; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.auth_group (id, name) FROM stdin;
\.


--
-- Data for Name: auth_group_permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.auth_group_permissions (id, group_id, permission_id) FROM stdin;
\.


--
-- Data for Name: auth_permission; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.auth_permission (id, name, content_type_id, codename) FROM stdin;
1	Can add log entry	1	add_logentry
2	Can change log entry	1	change_logentry
3	Can delete log entry	1	delete_logentry
4	Can view log entry	1	view_logentry
5	Can add permission	3	add_permission
6	Can change permission	3	change_permission
7	Can delete permission	3	delete_permission
8	Can view permission	3	view_permission
9	Can add group	2	add_group
10	Can change group	2	change_group
11	Can delete group	2	delete_group
12	Can view group	2	view_group
13	Can add content type	4	add_contenttype
14	Can change content type	4	change_contenttype
15	Can delete content type	4	delete_contenttype
16	Can view content type	4	view_contenttype
17	Can add session	5	add_session
18	Can change session	5	change_session
19	Can delete session	5	delete_session
20	Can view session	5	view_session
21	Can add Бренд	6	add_brand
22	Can change Бренд	6	change_brand
23	Can delete Бренд	6	delete_brand
24	Can view Бренд	6	view_brand
25	Can add Категория	7	add_category
26	Can change Категория	7	change_category
27	Can delete Категория	7	delete_category
28	Can view Категория	7	view_category
29	Can add Цвет	8	add_color
30	Can change Цвет	8	change_color
31	Can delete Цвет	8	delete_color
32	Can view Цвет	8	view_color
33	Can add Заказ	10	add_order
34	Can change Заказ	10	change_order
35	Can delete Заказ	10	delete_order
36	Can view Заказ	10	view_order
37	Can add Промокод	16	add_promocode
38	Can change Промокод	16	change_promocode
39	Can delete Промокод	16	delete_promocode
40	Can view Промокод	16	view_promocode
41	Can add Размер	17	add_size
42	Can change Размер	17	change_size
43	Can delete Размер	17	delete_size
44	Can view Размер	17	view_size
45	Can add Пользователь (админ)	19	add_user
46	Can change Пользователь (админ)	19	change_user
47	Can delete Пользователь (админ)	19	delete_user
48	Can view Пользователь (админ)	19	view_user
49	Can add Товар	12	add_product
50	Can change Товар	12	change_product
51	Can delete Товар	12	delete_product
52	Can view Товар	12	view_product
53	Can add Вариант товара	15	add_productvariant
54	Can change Вариант товара	15	change_productvariant
55	Can delete Вариант товара	15	delete_productvariant
56	Can view Вариант товара	15	view_productvariant
57	Can add Позиция заказа	11	add_orderitem
58	Can change Позиция заказа	11	change_orderitem
59	Can delete Позиция заказа	11	delete_orderitem
60	Can view Позиция заказа	11	view_orderitem
61	Can add Тег	18	add_tag
62	Can change Тег	18	change_tag
63	Can delete Тег	18	delete_tag
64	Can view Тег	18	view_tag
65	Can add Похожий товар	13	add_productsimilar
66	Can change Похожий товар	13	change_productsimilar
67	Can delete Похожий товар	13	delete_productsimilar
68	Can view Похожий товар	13	view_productsimilar
69	Can add Тег товара	14	add_producttag
70	Can change Тег товара	14	change_producttag
71	Can delete Тег товара	14	delete_producttag
72	Can view Тег товара	14	view_producttag
73	Can add Лаба 6 (scratch)	9	add_lab6scratch
74	Can change Лаба 6 (scratch)	9	change_lab6scratch
75	Can delete Лаба 6 (scratch)	9	delete_lab6scratch
76	Can view Лаба 6 (scratch)	9	view_lab6scratch
\.


--
-- Data for Name: django_admin_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.django_admin_log (id, action_time, object_id, object_repr, action_flag, change_message, content_type_id, user_id) FROM stdin;
\.


--
-- Data for Name: django_content_type; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.django_content_type (id, app_label, model) FROM stdin;
1	admin	logentry
2	auth	group
3	auth	permission
4	contenttypes	contenttype
5	sessions	session
6	shop	brand
7	shop	category
8	shop	color
9	shop	lab6scratch
10	shop	order
11	shop	orderitem
12	shop	product
13	shop	productsimilar
14	shop	producttag
15	shop	productvariant
16	shop	promocode
17	shop	size
18	shop	tag
19	shop	user
\.


--
-- Data for Name: django_migrations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.django_migrations (id, app, name, applied) FROM stdin;
1	contenttypes	0001_initial	2026-05-25 16:24:43.390736+03
2	contenttypes	0002_remove_content_type_name	2026-05-25 16:24:43.393904+03
3	auth	0001_initial	2026-05-25 16:24:43.411968+03
4	auth	0002_alter_permission_name_max_length	2026-05-25 16:24:43.413986+03
5	auth	0003_alter_user_email_max_length	2026-05-25 16:24:43.415869+03
6	auth	0004_alter_user_username_opts	2026-05-25 16:24:43.418877+03
7	auth	0005_alter_user_last_login_null	2026-05-25 16:24:43.420721+03
8	auth	0006_require_contenttypes_0002	2026-05-25 16:24:43.421138+03
9	auth	0007_alter_validators_add_error_messages	2026-05-25 16:24:43.42576+03
10	auth	0008_alter_user_username_max_length	2026-05-25 16:24:43.4283+03
11	auth	0009_alter_user_last_name_max_length	2026-05-25 16:24:43.431958+03
12	auth	0010_alter_group_name_max_length	2026-05-25 16:24:43.440955+03
13	auth	0011_update_proxy_permissions	2026-05-25 16:24:43.443047+03
14	auth	0012_alter_user_first_name_max_length	2026-05-25 16:24:43.446966+03
15	shop	0001_initial_clean	2026-05-25 16:24:43.508923+03
16	admin	0001_initial	2026-05-25 16:24:43.515784+03
17	admin	0002_logentry_remove_auto_add	2026-05-25 16:24:43.518033+03
18	admin	0003_logentry_add_action_flag_choices	2026-05-25 16:24:43.520193+03
19	sessions	0001_initial	2026-05-25 16:24:43.523285+03
20	shop	0002_lab4_tags_and_similar	2026-05-25 16:24:43.541864+03
21	shop	0003_lab5_files_pdf	2026-05-25 16:24:43.547798+03
22	shop	0004_lab6_scratch_cache	2026-05-25 16:24:43.549703+03
\.


--
-- Data for Name: django_session; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.django_session (session_key, session_data, expire_date) FROM stdin;
\.


--
-- Data for Name: shop_brand; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_brand (id, name, description) FROM stdin;
1	Reebok	
2	Nike	Самостоятельно опасность серьезный приличный райком достоинство скрытый терапия. Порядок предоставить мера бочок юный достоинство. Страсть о каюта лиловый светило.
3	Massimo Dutti	Упор сутки витрина решение академик. Передо светило стакан носок развернуться отражение нож. Ночь мучительно легко крутой.
4	Adidas	
5	H&M	Заведение легко торопливый премьера видимо серьезный самостоятельно. Основание манера да привлекать сынок.
6	Calvin Klein	Увеличиваться кольцо функция июнь хлеб. Анализ порог князь народ. Парень плод сверкать механический ход разнообразный.
7	Levi's	
8	Uniqlo	Дыхание встать следовательно скрытый идея монета рис. Мотоцикл умолять зарплата более постоянный.
\.


--
-- Data for Name: shop_category; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_category (id, name, description) FROM stdin;
1	Футболка	Заплакать необычный гулять палка.
2	Брюки	
3	Куртка	
4	Платье	
5	Рубашка	Голубчик второй правление поезд функция изба выбирать.
6	Свитер	Головной висеть труп виднеться избегать идея князь.
7	Джинсы	Рассуждение спорт возбуждение прощение хотеть.
8	Шорты	
\.


--
-- Data for Name: shop_color; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_color (id, name) FROM stdin;
1	Чёрный
2	Белый
3	Серый
4	Синий
5	Красный
6	Зелёный
7	Бежевый
8	Коричневый
\.


--
-- Data for Name: shop_lab6scratch; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_lab6scratch (id, label, link, counter) FROM stdin;
\.


--
-- Data for Name: shop_order; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_order (id, customer_name, customer_email, order_date, status, total_amount, discount_amount, promo_code_id) FROM stdin;
25	Шилова Фёкла Кузьминична	juli2015@example.net	2026-05-23 16:24:44.242541+03	paid	52450.92	5397.23	4
29	Шубин Герасим Гордеевич	aksenovorest@example.com	2026-05-19 16:24:44.248181+03	cancelled	17740.49	0.00	\N
2	Родионов Кирилл Андреевич	mironovavasilisa@example.net	2026-03-31 16:24:44.218047+03	shipped	19457.07	0.00	\N
22	Игнатов Нестор Эдгарович	jmartinov@example.net	2026-05-16 16:24:44.238744+03	shipped	47848.02	381.14	2
7	Дарья Наумовна Козлова	lorasharova@example.com	2026-05-14 16:24:44.223076+03	delivered	20695.12	0.00	\N
3	Галина Павловна Жданова	akulikova@example.org	2026-05-09 16:24:44.219392+03	shipped	89777.94	0.00	\N
24	Васильева Тамара Ефимовна	panovvsevolod@example.com	2026-05-03 16:24:44.240931+03	paid	57552.26	15903.08	5
15	Нестерова Варвара Кузьминична	leonid_2007@example.com	2026-05-03 16:24:44.231019+03	shipped	26074.86	0.00	\N
16	Лавр Валерьянович Григорьев	ykazakova@example.net	2026-04-29 16:24:44.23169+03	cancelled	65929.95	0.00	\N
14	Спиридон Герасимович Громов	qkudrjavtsev@example.com	2026-04-22 16:24:44.230043+03	cancelled	38102.38	0.00	\N
11	Синклитикия Леоновна Субботина	andreevaivanna@example.org	2026-04-17 16:24:44.226135+03	cancelled	64757.76	0.00	\N
27	Ирина Семеновна Мартынова	kirbikov@example.org	2026-04-16 16:24:44.245916+03	cancelled	28007.75	2882.02	4
8	Зинаида Ивановна Яковлева	shcherbakovandre@example.com	2026-04-11 16:24:44.223585+03	delivered	2213.04	0.00	\N
9	Зыков Родион Иларионович	zosima30@example.net	2026-04-10 16:24:44.224146+03	paid	18335.36	0.00	\N
28	Фролова Ираида Леоновна	timur_12@example.org	2026-04-01 16:24:44.246483+03	delivered	70066.84	0.00	\N
17	Дарья Юрьевна Ермакова	onufri80@example.com	2026-03-31 16:24:44.233351+03	delivered	100682.72	289.30	1
5	Тимофеев Михаил Анатольевич	epifan_31@example.com	2026-03-31 16:24:44.221962+03	delivered	8726.68	0.00	\N
23	Рожкова Валентина Олеговна	demjanbragin@example.net	2026-03-27 16:24:44.239694+03	delivered	62599.58	0.00	\N
21	Мухин Юлиан Артёмович	pavel2019@example.net	2026-03-27 16:24:44.237495+03	cancelled	36715.40	4682.05	3
1	Ершова Иванна Сергеевна	ipati2021@example.org	2026-05-06 16:24:44.21585+03	cancelled	64309.32	0.00	\N
20	Селиверстов Измаил Ефстафьевич	evstafikulikov@example.org	2026-05-20 16:24:44.236937+03	cancelled	5065.28	0.00	\N
19	Давыд Архипович Бобров	veronika_2005@example.com	2026-05-18 16:24:44.235911+03	cancelled	38003.39	0.00	\N
4	Доронин Геннадий Алексеевич	fortunat_82@example.com	2026-05-10 16:24:44.221051+03	cancelled	33855.96	0.00	\N
12	Белоусова Александра Борисовна	upahomov@example.com	2026-04-27 16:24:44.227884+03	cancelled	67531.37	0.00	\N
10	Суханов Клавдий Арсеньевич	mili86@example.net	2026-04-21 16:24:44.225137+03	cancelled	44892.90	0.00	\N
6	Надежда Яковлевна Дементьева	zhannaknjazeva@example.org	2026-04-15 16:24:44.222507+03	cancelled	11562.90	1474.53	3
18	Петр Захарьевич Абрамов	prov2008@example.net	2026-04-07 16:24:44.234996+03	cancelled	56903.91	0.00	\N
30	Аксенова Анастасия Григорьевна	xguljaev@example.net	2026-04-05 16:24:44.2491+03	cancelled	48149.18	0.00	\N
26	Трофим Филатович Самсонов	olimpiadasaveleva@example.com	2026-03-31 16:24:44.244131+03	cancelled	55639.78	0.00	\N
13	Сократ Валентинович Блинов	iraklisolovev@example.net	2026-03-26 16:24:44.229488+03	cancelled	15912.01	2029.15	3
\.


--
-- Data for Name: shop_orderitem; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_orderitem (id, quantity, price_at_time, order_id, product_variant_id) FROM stdin;
1	3	6316.89	1	24
2	1	14964.30	1	28
3	3	10131.45	1	150
5	1	2067.43	2	246
6	1	13254.78	2	226
7	1	12423.80	3	252
8	3	14964.30	3	38
9	2	14964.30	3	28
10	1	2532.64	3	78
11	2	3673.20	4	195
12	2	13254.78	4	231
13	1	8726.68	5	51
14	1	13037.43	6	81
15	2	10347.56	7	210
16	2	1106.52	8	119
17	2	3725.29	9	136
18	1	10884.78	9	102
19	1	14964.30	10	37
20	2	14964.30	10	31
21	2	2418.52	11	64
22	3	2067.43	11	240
23	3	10131.45	11	156
24	2	11662.04	11	207
25	1	10296.59	12	166
26	3	3725.29	12	129
27	3	3804.52	12	14
28	3	11548.45	12	47
29	2	8970.58	13	90
30	1	13254.78	14	224
31	2	12423.80	14	252
32	2	13037.43	15	83
33	2	3804.52	16	19
34	2	13254.78	16	233
35	1	11548.45	16	46
36	2	10131.45	16	162
37	3	10347.56	17	212
38	2	14964.30	17	28
39	3	10884.78	17	97
40	2	3673.20	17	186
41	3	10131.45	18	148
42	2	13254.78	18	225
43	3	10131.45	19	160
44	2	3804.52	19	8
45	2	2532.64	20	79
46	1	10347.56	21	213
47	2	12423.80	21	248
48	3	2067.43	21	242
49	2	14964.30	22	36
50	2	9150.28	22	142
51	2	10131.45	23	153
52	3	12423.80	23	251
53	2	2532.64	23	77
54	3	13254.78	24	234
55	2	10296.59	24	165
56	1	10884.78	24	97
57	2	1106.52	24	123
58	1	5369.79	25	198
59	3	2532.64	25	78
60	3	12423.80	25	254
61	2	3804.52	25	19
62	1	3804.52	26	8
63	2	2532.64	26	74
64	2	10347.56	26	210
65	2	13037.43	26	80
66	3	10296.59	27	169
67	1	3804.52	28	19
68	3	14964.30	28	36
69	1	1106.52	28	121
70	2	10131.45	28	148
71	1	10131.45	29	154
72	2	3804.52	29	15
73	3	13254.78	30	221
74	2	2532.64	30	75
75	3	1106.52	30	126
4	2	2067.43	2	241
\.


--
-- Data for Name: shop_product; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_product (id, name, description, base_price, image_url, created_at, brand_id, category_id, cover_image, specification_file) FROM stdin;
1	Шорты бермуды		3804.52		2026-05-25 16:24:43.923523+03	4	2		
2	Кардиган	Выбирать угроза что казнь райком набор горький космос. Руководитель пропадать кидать ломать. Кожа посидеть достоинство назначить.	6316.89		2026-05-25 16:24:43.940017+03	4	1		
3	Рубашка фланелевая		14964.30		2026-05-25 16:24:43.946096+03	7	6		
4	Брюки чинос	Заявление белье холодно построить самостоятельно способ князь. Руководитель июнь шлем мелочь потрясти.	11548.45		2026-05-25 16:24:43.956432+03	1	5		
5	Брюки классические		8726.68		2026-05-25 16:24:43.961154+03	4	1		
6	Джинсы прямые		10239.46		2026-05-25 16:24:43.96593+03	4	5		
7	Куртка утеплённая		2418.52		2026-05-25 16:24:43.972941+03	5	8		
8	Футболка оверсайз	Прошептать лапа тюрьма соответствие порт механический. Находить решение приятель ночь песня левый решение спасть. Космос неожиданно понятный очутиться висеть инструкция демократия.	2532.64		2026-05-25 16:24:43.97981+03	4	4		
9	Футболка поло		13037.43		2026-05-25 16:24:43.983983+03	7	8		
10	Платье летнее		8970.58		2026-05-25 16:24:43.988962+03	1	6		
11	Джинсы с высокой посадкой		10884.78		2026-05-25 16:24:44.099019+03	6	5		
12	Парка	Хотеть через князь пропасть. Означать доставать ленинград.	8541.73		2026-05-25 16:24:44.113205+03	5	1		
13	Водолазка	Смелый спорт вздрогнуть чем передо пробовать. Низкий райком покидать хлеб домашний мелькнуть равнодушный. Сверкающий скользить торговля.	4141.26		2026-05-25 16:24:44.117031+03	4	5		
14	Свитер с воротником		1106.52		2026-05-25 16:24:44.122986+03	6	3		
15	Куртка ветровка	Умирать лететь освобождение забирать стакан доставать. Скользить инструкция монета металл назначить.	3725.29		2026-05-25 16:24:44.130855+03	7	1		
16	Футболка с принтом		9150.28		2026-05-25 16:24:44.137419+03	3	5		
17	Платье макси		10131.45		2026-05-25 16:24:44.142529+03	6	7		
18	Джинсы скинни		10296.59		2026-05-25 16:24:44.150795+03	6	8		
19	Шорты спортивные	Рассуждение строительство сверкающий выразить поговорить да выраженный. Единый набор вариант выраженный зарплата монета коммунизм тута. Покидать исполнять славный выразить миф.	3673.20		2026-05-25 16:24:44.160995+03	1	2		
20	Рубашка с коротким рукавом		5369.79		2026-05-25 16:24:44.169186+03	2	5		
21	Свитер с V-образным вырезом		11662.04		2026-05-25 16:24:44.173762+03	4	7		
22	Худи базовое		10347.56		2026-05-25 16:24:44.177817+03	1	7		
23	Жилетка стёганая		13254.78		2026-05-25 16:24:44.183508+03	8	6		
24	Куртка демисезонная	Разводить прежний чувство блин карандаш легко. Премьера упор палата чувство дыхание.	2067.43		2026-05-25 16:24:44.193342+03	2	3		
25	Брюки карго	Серьезный равнодушный увеличиваться. Чем функция неожиданно поколение.	12423.80		2026-05-25 16:24:44.199599+03	6	1		
\.


--
-- Data for Name: shop_product_available_colors; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_product_available_colors (id, product_id, color_id) FROM stdin;
1	1	2
2	1	3
3	1	4
4	1	5
5	1	6
6	2	8
7	2	4
8	2	6
9	3	1
10	3	5
11	3	7
12	4	2
13	4	6
14	4	7
15	5	2
16	5	3
17	6	1
18	6	2
19	6	3
20	7	2
21	7	6
22	8	8
23	8	7
24	9	3
25	9	7
26	10	1
27	10	2
28	10	5
29	11	8
30	11	1
31	11	3
32	11	6
33	12	2
34	12	6
35	13	8
36	13	1
37	13	2
38	13	3
39	14	2
40	14	3
41	14	5
42	15	8
43	15	4
44	16	5
45	16	7
46	17	8
47	17	3
48	17	4
49	17	7
50	18	8
51	18	2
52	18	3
53	18	7
54	19	8
55	19	5
56	19	6
57	20	2
58	20	6
59	20	7
60	21	3
61	21	6
62	22	5
63	22	7
64	23	1
65	23	3
66	23	5
67	23	6
68	23	8
69	24	1
70	24	2
71	24	4
72	24	5
73	24	7
74	25	2
75	25	3
76	25	4
77	25	5
78	25	8
\.


--
-- Data for Name: shop_product_available_sizes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_product_available_sizes (id, product_id, size_id) FROM stdin;
1	1	1
2	1	2
3	1	4
4	1	7
5	2	4
6	2	6
7	3	1
8	3	2
9	3	7
10	3	8
11	3	9
12	4	4
13	4	5
14	5	8
15	5	2
16	6	8
17	6	9
18	6	2
19	6	1
20	7	2
21	7	4
22	7	7
23	7	8
24	7	9
25	8	8
26	8	2
27	8	5
28	9	3
29	9	7
30	10	1
31	10	2
32	10	7
33	11	2
34	11	5
35	11	7
36	12	3
37	12	5
38	13	2
39	13	7
40	14	8
41	14	1
42	14	2
43	14	6
44	15	2
45	15	5
46	15	6
47	15	7
48	15	9
49	16	8
50	16	5
51	16	6
52	16	7
53	17	9
54	17	2
55	17	3
56	17	6
57	18	2
58	18	3
59	18	5
60	18	6
61	18	9
62	19	1
63	19	4
64	19	7
65	19	8
66	19	9
67	20	9
68	20	3
69	21	8
70	21	7
71	22	2
72	22	3
73	22	5
74	22	6
75	22	8
76	23	9
77	23	5
78	23	1
79	23	7
80	24	5
81	24	7
82	25	6
83	25	7
\.


--
-- Data for Name: shop_productsimilar; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_productsimilar (id, notes, from_product_id, to_product_id) FROM stdin;
1		11	1
2		16	11
3		6	16
4		7	12
5		9	11
6		9	20
7		23	9
8		18	1
9		17	7
10		3	8
11		24	14
12		16	18
13		25	8
14		23	16
15		21	23
16		16	15
17		1	3
18		10	8
19		13	23
20		8	10
\.


--
-- Data for Name: shop_producttag; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_producttag (id, sort_order, product_id, tag_id) FROM stdin;
1	0	1	3
2	1	1	2
3	2	1	6
4	0	2	2
5	1	2	3
6	2	2	6
7	3	2	1
8	0	3	4
9	1	3	5
10	2	3	6
11	3	3	3
12	0	4	5
13	0	5	5
14	1	5	2
15	2	5	3
16	3	5	4
17	0	6	5
18	1	6	2
19	0	7	3
20	1	7	4
21	2	7	5
22	3	7	2
23	0	8	1
24	0	9	3
25	1	9	4
26	2	9	5
27	3	9	1
28	0	10	4
29	1	10	1
30	0	11	5
31	1	11	6
32	2	11	1
33	3	11	4
34	0	12	3
35	1	12	6
36	0	13	2
37	1	13	4
38	2	13	5
39	0	14	5
40	1	14	2
41	2	14	6
42	3	14	1
43	0	15	3
44	1	15	1
45	2	15	6
46	0	16	3
47	1	16	1
48	0	17	2
49	1	17	4
50	0	18	2
51	1	18	6
52	0	19	4
53	1	19	5
54	2	19	6
55	0	20	1
56	1	20	4
57	0	21	4
58	1	21	5
59	2	21	2
60	3	21	6
61	0	22	1
62	0	23	6
63	1	23	1
64	0	24	6
65	1	24	5
66	2	24	1
67	0	25	4
68	1	25	6
69	2	25	3
70	3	25	2
\.


--
-- Data for Name: shop_productvariant; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_productvariant (id, stock_quantity, color_id, product_id, size_id) FROM stdin;
1	49	5	1	2
2	48	4	1	2
3	46	6	1	2
4	9	3	1	2
5	43	2	1	2
6	45	5	1	4
7	15	4	1	4
9	20	3	1	4
10	15	2	1	4
11	34	5	1	7
12	29	4	1	7
13	22	6	1	7
16	40	5	1	1
17	19	4	1	1
18	48	6	1	1
20	8	2	1	1
21	40	8	2	4
22	39	4	2	4
23	21	6	2	4
25	32	4	2	6
26	42	6	2	6
27	21	7	3	2
29	5	1	3	2
30	48	7	3	1
32	48	1	3	1
33	39	7	3	7
34	22	5	3	7
35	46	1	3	7
39	32	7	3	9
40	15	5	3	9
41	34	1	3	9
42	25	6	4	5
43	36	7	4	5
44	6	2	4	5
45	12	6	4	4
48	43	3	5	2
49	32	2	5	2
50	18	3	5	8
52	5	2	6	8
53	9	3	6	8
54	50	1	6	8
55	45	2	6	9
56	8	3	6	9
57	19	1	6	9
58	9	2	6	1
59	7	3	6	1
60	26	1	6	1
61	9	2	6	2
62	37	3	6	2
63	20	1	6	2
65	48	6	7	4
66	46	2	7	8
67	46	6	7	8
68	11	2	7	7
69	8	6	7	7
70	30	2	7	9
71	26	6	7	9
72	11	2	7	2
73	20	6	7	2
76	5	8	8	8
82	18	7	9	7
84	41	2	10	1
85	20	5	10	1
86	42	1	10	1
87	43	2	10	2
88	7	5	10	2
89	44	1	10	2
91	31	5	10	7
92	47	1	10	7
93	39	8	11	5
94	18	3	11	5
95	37	1	11	5
96	21	6	11	5
98	27	3	11	7
99	9	1	11	7
100	20	6	11	7
101	28	8	11	2
103	15	1	11	2
104	33	6	11	2
105	43	2	12	3
106	18	6	12	3
107	50	2	12	5
108	26	6	12	5
109	40	1	13	2
110	5	8	13	2
111	12	3	13	2
112	9	2	13	2
113	49	1	13	7
114	14	8	13	7
115	39	3	13	7
116	7	2	13	7
117	16	2	14	1
118	31	3	14	1
120	16	2	14	6
15	47	2	1	7
38	20	1	3	8
51	38	2	5	8
81	22	3	9	3
119	4	5	14	1
102	22	3	11	2
37	11	5	3	8
31	10	5	3	1
64	6	2	7	4
14	42	3	1	7
47	21	2	4	4
90	8	2	10	7
83	6	3	9	7
8	36	6	1	4
46	27	7	4	4
78	16	8	8	2
74	44	8	8	5
79	13	7	8	2
77	8	7	8	8
97	9	8	11	7
80	15	7	9	3
19	20	3	1	1
75	37	7	8	5
122	31	5	14	6
124	20	3	14	2
125	22	5	14	2
127	49	3	14	8
128	11	5	14	8
130	46	8	15	6
131	37	4	15	5
132	30	8	15	5
133	48	4	15	7
134	39	8	15	7
135	26	4	15	2
137	12	4	15	9
138	21	8	15	9
139	50	7	16	6
140	32	5	16	6
141	5	7	16	7
143	39	7	16	5
144	48	5	16	5
145	47	7	16	8
146	17	5	16	8
147	47	7	17	6
149	48	4	17	6
151	44	7	17	2
152	41	3	17	2
155	40	7	17	9
157	24	4	17	9
158	23	8	17	9
159	18	7	17	3
161	42	4	17	3
163	6	2	18	3
164	7	7	18	3
167	44	2	18	2
168	9	7	18	2
170	31	3	18	2
171	45	2	18	9
172	41	7	18	9
173	17	8	18	9
174	50	3	18	9
175	49	2	18	5
176	29	7	18	5
177	36	8	18	5
178	30	3	18	5
179	20	2	18	6
180	14	7	18	6
181	46	8	18	6
182	49	3	18	6
183	40	8	19	1
184	33	6	19	1
185	15	5	19	1
187	33	6	19	4
188	21	5	19	4
189	20	8	19	7
190	45	6	19	7
191	22	5	19	7
192	38	8	19	9
193	36	6	19	9
194	45	5	19	9
196	22	6	19	8
197	33	5	19	8
199	26	6	20	3
200	39	2	20	3
201	34	7	20	9
202	31	6	20	9
203	8	2	20	9
204	19	6	21	7
205	22	3	21	7
206	32	6	21	8
208	46	7	22	3
209	32	5	22	3
211	34	5	22	8
214	21	7	22	5
215	29	5	22	5
216	25	7	22	6
217	18	5	22	6
218	46	1	23	7
219	7	6	23	7
220	6	5	23	7
222	17	3	23	7
223	6	1	23	5
227	13	3	23	5
228	35	1	23	9
229	47	6	23	9
230	12	5	23	9
232	18	3	23	9
235	21	5	23	1
236	28	8	23	1
237	15	3	23	1
238	41	4	24	5
239	7	1	24	5
226	19	8	23	5
195	18	8	19	8
169	31	8	18	2
136	4	8	15	2
240	24	5	24	5
156	2	3	17	9
207	34	3	21	8
166	34	3	18	3
129	24	4	15	6
224	43	6	23	5
233	32	1	23	1
162	41	8	17	3
212	13	7	22	2
186	33	8	19	4
154	29	8	17	2
225	12	5	23	5
160	29	3	17	3
213	7	5	22	2
153	22	4	17	2
234	46	6	23	1
165	18	8	18	3
123	45	2	14	2
198	30	7	20	3
210	9	7	22	8
121	25	3	14	6
148	24	3	17	6
221	17	8	23	7
126	12	2	14	8
243	47	4	24	7
244	28	1	24	7
245	9	5	24	7
247	46	7	24	7
249	10	4	25	7
250	22	2	25	7
253	34	3	25	6
255	44	2	25	6
256	47	5	25	6
257	29	8	25	6
24	39	8	2	6
150	13	8	17	6
241	37	2	24	5
246	36	2	24	7
231	39	8	23	9
252	17	8	25	7
28	35	5	3	2
248	18	3	25	7
242	29	7	24	5
142	36	5	16	7
251	30	5	25	7
254	38	4	25	6
36	21	7	3	8
\.


--
-- Data for Name: shop_promocode; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_promocode (id, code, discount_type, discount_value, valid_from, valid_until, max_uses, used_count, created_at) FROM stdin;
1	EPXSKC	fixed	289.30	2026-05-09 16:24:44.214252+03	2026-08-10 16:24:44.214262+03	10	0	2026-05-25 16:24:44.214291+03
2	ITTNZP	fixed	381.14	2026-05-17 16:24:44.214713+03	2026-07-08 16:24:44.214715+03	0	0	2026-05-25 16:24:44.214728+03
3	HAQJTQ	percent	11.31	2026-05-02 16:24:44.215024+03	2026-08-11 16:24:44.215026+03	0	0	2026-05-25 16:24:44.215036+03
4	GIQHGV	percent	9.33	2026-05-10 16:24:44.215316+03	\N	10	0	2026-05-25 16:24:44.215329+03
5	JJRSMN	percent	21.65	2026-05-16 16:24:44.215609+03	\N	0	0	2026-05-25 16:24:44.215621+03
\.


--
-- Data for Name: shop_size; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_size (id, name) FROM stdin;
1	XS
2	S
3	M
4	L
5	XL
6	42
7	44
8	46
9	48
\.


--
-- Data for Name: shop_tag; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_tag (id, name, icon) FROM stdin;
1	новинка	
2	скидка	
3	лето	
4	зима	
5	хит	
6	онлайн	
\.


--
-- Data for Name: shop_user; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined) FROM stdin;
\.


--
-- Data for Name: shop_user_groups; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_user_groups (id, user_id, group_id) FROM stdin;
\.


--
-- Data for Name: shop_user_user_permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.shop_user_user_permissions (id, user_id, permission_id) FROM stdin;
\.


--
-- Name: auth_group_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.auth_group_id_seq', 1, false);


--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.auth_group_permissions_id_seq', 1, false);


--
-- Name: auth_permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.auth_permission_id_seq', 76, true);


--
-- Name: django_admin_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.django_admin_log_id_seq', 1, false);


--
-- Name: django_content_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.django_content_type_id_seq', 19, true);


--
-- Name: django_migrations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.django_migrations_id_seq', 22, true);


--
-- Name: shop_brand_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_brand_id_seq', 8, true);


--
-- Name: shop_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_category_id_seq', 8, true);


--
-- Name: shop_color_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_color_id_seq', 8, true);


--
-- Name: shop_lab6scratch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_lab6scratch_id_seq', 1, false);


--
-- Name: shop_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_order_id_seq', 30, true);


--
-- Name: shop_orderitem_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_orderitem_id_seq', 75, true);


--
-- Name: shop_product_available_colors_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_product_available_colors_id_seq', 78, true);


--
-- Name: shop_product_available_sizes_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_product_available_sizes_id_seq', 83, true);


--
-- Name: shop_product_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_product_id_seq', 25, true);


--
-- Name: shop_productsimilar_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_productsimilar_id_seq', 20, true);


--
-- Name: shop_producttag_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_producttag_id_seq', 70, true);


--
-- Name: shop_productvariant_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_productvariant_id_seq', 257, true);


--
-- Name: shop_promocode_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_promocode_id_seq', 5, true);


--
-- Name: shop_size_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_size_id_seq', 9, true);


--
-- Name: shop_tag_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_tag_id_seq', 6, true);


--
-- Name: shop_user_groups_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_user_groups_id_seq', 1, false);


--
-- Name: shop_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_user_id_seq', 1, false);


--
-- Name: shop_user_user_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.shop_user_user_permissions_id_seq', 1, false);


--
-- Name: auth_group auth_group_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_name_key UNIQUE (name);


--
-- Name: auth_group_permissions auth_group_permissions_group_id_permission_id_0cd325b0_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_permission_id_0cd325b0_uniq UNIQUE (group_id, permission_id);


--
-- Name: auth_group_permissions auth_group_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_group auth_group_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_pkey PRIMARY KEY (id);


--
-- Name: auth_permission auth_permission_content_type_id_codename_01ab375a_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_codename_01ab375a_uniq UNIQUE (content_type_id, codename);


--
-- Name: auth_permission auth_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);


--
-- Name: django_admin_log django_admin_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_pkey PRIMARY KEY (id);


--
-- Name: django_content_type django_content_type_app_label_model_76bd3d3b_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_app_label_model_76bd3d3b_uniq UNIQUE (app_label, model);


--
-- Name: django_content_type django_content_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_pkey PRIMARY KEY (id);


--
-- Name: django_migrations django_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_migrations
    ADD CONSTRAINT django_migrations_pkey PRIMARY KEY (id);


--
-- Name: django_session django_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_session
    ADD CONSTRAINT django_session_pkey PRIMARY KEY (session_key);


--
-- Name: shop_brand shop_brand_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_brand
    ADD CONSTRAINT shop_brand_pkey PRIMARY KEY (id);


--
-- Name: shop_category shop_category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_category
    ADD CONSTRAINT shop_category_pkey PRIMARY KEY (id);


--
-- Name: shop_color shop_color_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_color
    ADD CONSTRAINT shop_color_pkey PRIMARY KEY (id);


--
-- Name: shop_lab6scratch shop_lab6scratch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_lab6scratch
    ADD CONSTRAINT shop_lab6scratch_pkey PRIMARY KEY (id);


--
-- Name: shop_order shop_order_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_order
    ADD CONSTRAINT shop_order_pkey PRIMARY KEY (id);


--
-- Name: shop_orderitem shop_orderitem_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_orderitem
    ADD CONSTRAINT shop_orderitem_pkey PRIMARY KEY (id);


--
-- Name: shop_product_available_colors shop_product_available_colors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_colors
    ADD CONSTRAINT shop_product_available_colors_pkey PRIMARY KEY (id);


--
-- Name: shop_product_available_colors shop_product_available_colors_product_id_color_id_e9cacfa1_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_colors
    ADD CONSTRAINT shop_product_available_colors_product_id_color_id_e9cacfa1_uniq UNIQUE (product_id, color_id);


--
-- Name: shop_product_available_sizes shop_product_available_sizes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_sizes
    ADD CONSTRAINT shop_product_available_sizes_pkey PRIMARY KEY (id);


--
-- Name: shop_product_available_sizes shop_product_available_sizes_product_id_size_id_acde2446_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_sizes
    ADD CONSTRAINT shop_product_available_sizes_product_id_size_id_acde2446_uniq UNIQUE (product_id, size_id);


--
-- Name: shop_product shop_product_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product
    ADD CONSTRAINT shop_product_pkey PRIMARY KEY (id);


--
-- Name: shop_productsimilar shop_productsimilar_from_product_id_to_product_id_deeffa3d_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productsimilar
    ADD CONSTRAINT shop_productsimilar_from_product_id_to_product_id_deeffa3d_uniq UNIQUE (from_product_id, to_product_id);


--
-- Name: shop_productsimilar shop_productsimilar_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productsimilar
    ADD CONSTRAINT shop_productsimilar_pkey PRIMARY KEY (id);


--
-- Name: shop_producttag shop_producttag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_producttag
    ADD CONSTRAINT shop_producttag_pkey PRIMARY KEY (id);


--
-- Name: shop_producttag shop_producttag_product_id_tag_id_7dbe3cc9_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_producttag
    ADD CONSTRAINT shop_producttag_product_id_tag_id_7dbe3cc9_uniq UNIQUE (product_id, tag_id);


--
-- Name: shop_productvariant shop_productvariant_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productvariant
    ADD CONSTRAINT shop_productvariant_pkey PRIMARY KEY (id);


--
-- Name: shop_productvariant shop_productvariant_product_id_size_id_color_id_d83cf0b5_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productvariant
    ADD CONSTRAINT shop_productvariant_product_id_size_id_color_id_d83cf0b5_uniq UNIQUE (product_id, size_id, color_id);


--
-- Name: shop_promocode shop_promocode_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_promocode
    ADD CONSTRAINT shop_promocode_code_key UNIQUE (code);


--
-- Name: shop_promocode shop_promocode_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_promocode
    ADD CONSTRAINT shop_promocode_pkey PRIMARY KEY (id);


--
-- Name: shop_size shop_size_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_size
    ADD CONSTRAINT shop_size_pkey PRIMARY KEY (id);


--
-- Name: shop_tag shop_tag_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_tag
    ADD CONSTRAINT shop_tag_name_key UNIQUE (name);


--
-- Name: shop_tag shop_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_tag
    ADD CONSTRAINT shop_tag_pkey PRIMARY KEY (id);


--
-- Name: shop_user_groups shop_user_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_groups
    ADD CONSTRAINT shop_user_groups_pkey PRIMARY KEY (id);


--
-- Name: shop_user_groups shop_user_groups_user_id_group_id_29c349c0_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_groups
    ADD CONSTRAINT shop_user_groups_user_id_group_id_29c349c0_uniq UNIQUE (user_id, group_id);


--
-- Name: shop_user shop_user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user
    ADD CONSTRAINT shop_user_pkey PRIMARY KEY (id);


--
-- Name: shop_user_user_permissions shop_user_user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_user_permissions
    ADD CONSTRAINT shop_user_user_permissions_pkey PRIMARY KEY (id);


--
-- Name: shop_user_user_permissions shop_user_user_permissions_user_id_permission_id_8836bbbf_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_user_permissions
    ADD CONSTRAINT shop_user_user_permissions_user_id_permission_id_8836bbbf_uniq UNIQUE (user_id, permission_id);


--
-- Name: shop_user shop_user_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user
    ADD CONSTRAINT shop_user_username_key UNIQUE (username);


--
-- Name: auth_group_name_a6ea08ec_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_group_name_a6ea08ec_like ON public.auth_group USING btree (name varchar_pattern_ops);


--
-- Name: auth_group_permissions_group_id_b120cbf9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_group_permissions_group_id_b120cbf9 ON public.auth_group_permissions USING btree (group_id);


--
-- Name: auth_group_permissions_permission_id_84c5c92e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_group_permissions_permission_id_84c5c92e ON public.auth_group_permissions USING btree (permission_id);


--
-- Name: auth_permission_content_type_id_2f476e4b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_permission_content_type_id_2f476e4b ON public.auth_permission USING btree (content_type_id);


--
-- Name: django_admin_log_content_type_id_c4bce8eb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_admin_log_content_type_id_c4bce8eb ON public.django_admin_log USING btree (content_type_id);


--
-- Name: django_admin_log_user_id_c564eba6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_admin_log_user_id_c564eba6 ON public.django_admin_log USING btree (user_id);


--
-- Name: django_session_expire_date_a5c62663; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_session_expire_date_a5c62663 ON public.django_session USING btree (expire_date);


--
-- Name: django_session_session_key_c0390e0f_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_session_session_key_c0390e0f_like ON public.django_session USING btree (session_key varchar_pattern_ops);


--
-- Name: shop_order_promo_code_id_bf706ddd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_order_promo_code_id_bf706ddd ON public.shop_order USING btree (promo_code_id);


--
-- Name: shop_orderitem_order_id_2f1b00cf; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_orderitem_order_id_2f1b00cf ON public.shop_orderitem USING btree (order_id);


--
-- Name: shop_orderitem_product_variant_id_40518843; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_orderitem_product_variant_id_40518843 ON public.shop_orderitem USING btree (product_variant_id);


--
-- Name: shop_product_available_colors_color_id_dcf94e36; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_product_available_colors_color_id_dcf94e36 ON public.shop_product_available_colors USING btree (color_id);


--
-- Name: shop_product_available_colors_product_id_afa06096; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_product_available_colors_product_id_afa06096 ON public.shop_product_available_colors USING btree (product_id);


--
-- Name: shop_product_available_sizes_product_id_17b412fd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_product_available_sizes_product_id_17b412fd ON public.shop_product_available_sizes USING btree (product_id);


--
-- Name: shop_product_available_sizes_size_id_c5385605; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_product_available_sizes_size_id_c5385605 ON public.shop_product_available_sizes USING btree (size_id);


--
-- Name: shop_product_brand_id_505fec11; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_product_brand_id_505fec11 ON public.shop_product USING btree (brand_id);


--
-- Name: shop_product_category_id_14d7eea8; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_product_category_id_14d7eea8 ON public.shop_product USING btree (category_id);


--
-- Name: shop_productsimilar_from_product_id_f9628cb8; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_productsimilar_from_product_id_f9628cb8 ON public.shop_productsimilar USING btree (from_product_id);


--
-- Name: shop_productsimilar_to_product_id_ff835ca6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_productsimilar_to_product_id_ff835ca6 ON public.shop_productsimilar USING btree (to_product_id);


--
-- Name: shop_producttag_product_id_379a4947; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_producttag_product_id_379a4947 ON public.shop_producttag USING btree (product_id);


--
-- Name: shop_producttag_tag_id_d1eec258; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_producttag_tag_id_d1eec258 ON public.shop_producttag USING btree (tag_id);


--
-- Name: shop_productvariant_color_id_71b1a3b1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_productvariant_color_id_71b1a3b1 ON public.shop_productvariant USING btree (color_id);


--
-- Name: shop_productvariant_product_id_3268ff6d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_productvariant_product_id_3268ff6d ON public.shop_productvariant USING btree (product_id);


--
-- Name: shop_productvariant_size_id_df472044; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_productvariant_size_id_df472044 ON public.shop_productvariant USING btree (size_id);


--
-- Name: shop_promocode_code_6134ff4a_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_promocode_code_6134ff4a_like ON public.shop_promocode USING btree (code varchar_pattern_ops);


--
-- Name: shop_tag_name_405ccc88_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_tag_name_405ccc88_like ON public.shop_tag USING btree (name varchar_pattern_ops);


--
-- Name: shop_user_groups_group_id_bf3fb67c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_user_groups_group_id_bf3fb67c ON public.shop_user_groups USING btree (group_id);


--
-- Name: shop_user_groups_user_id_252129d6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_user_groups_user_id_252129d6 ON public.shop_user_groups USING btree (user_id);


--
-- Name: shop_user_user_permissions_permission_id_ace4643b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_user_user_permissions_permission_id_ace4643b ON public.shop_user_user_permissions USING btree (permission_id);


--
-- Name: shop_user_user_permissions_user_id_d5f91630; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_user_user_permissions_user_id_d5f91630 ON public.shop_user_user_permissions USING btree (user_id);


--
-- Name: shop_user_username_0b1fc3cb_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shop_user_username_0b1fc3cb_like ON public.shop_user USING btree (username varchar_pattern_ops);


--
-- Name: auth_group_permissions auth_group_permissio_permission_id_84c5c92e_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissio_permission_id_84c5c92e_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_group_permissions auth_group_permissions_group_id_b120cbf9_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_b120cbf9_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_permission auth_permission_content_type_id_2f476e4b_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_2f476e4b_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_content_type_id_c4bce8eb_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_content_type_id_c4bce8eb_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_user_id_c564eba6_fk_shop_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_user_id_c564eba6_fk_shop_user_id FOREIGN KEY (user_id) REFERENCES public.shop_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_order shop_order_promo_code_id_bf706ddd_fk_shop_promocode_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_order
    ADD CONSTRAINT shop_order_promo_code_id_bf706ddd_fk_shop_promocode_id FOREIGN KEY (promo_code_id) REFERENCES public.shop_promocode(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_orderitem shop_orderitem_order_id_2f1b00cf_fk_shop_order_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_orderitem
    ADD CONSTRAINT shop_orderitem_order_id_2f1b00cf_fk_shop_order_id FOREIGN KEY (order_id) REFERENCES public.shop_order(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_orderitem shop_orderitem_product_variant_id_40518843_fk_shop_prod; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_orderitem
    ADD CONSTRAINT shop_orderitem_product_variant_id_40518843_fk_shop_prod FOREIGN KEY (product_variant_id) REFERENCES public.shop_productvariant(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_product_available_colors shop_product_availab_color_id_dcf94e36_fk_shop_colo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_colors
    ADD CONSTRAINT shop_product_availab_color_id_dcf94e36_fk_shop_colo FOREIGN KEY (color_id) REFERENCES public.shop_color(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_product_available_sizes shop_product_availab_product_id_17b412fd_fk_shop_prod; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_sizes
    ADD CONSTRAINT shop_product_availab_product_id_17b412fd_fk_shop_prod FOREIGN KEY (product_id) REFERENCES public.shop_product(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_product_available_colors shop_product_availab_product_id_afa06096_fk_shop_prod; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_colors
    ADD CONSTRAINT shop_product_availab_product_id_afa06096_fk_shop_prod FOREIGN KEY (product_id) REFERENCES public.shop_product(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_product_available_sizes shop_product_available_sizes_size_id_c5385605_fk_shop_size_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product_available_sizes
    ADD CONSTRAINT shop_product_available_sizes_size_id_c5385605_fk_shop_size_id FOREIGN KEY (size_id) REFERENCES public.shop_size(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_product shop_product_brand_id_505fec11_fk_shop_brand_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product
    ADD CONSTRAINT shop_product_brand_id_505fec11_fk_shop_brand_id FOREIGN KEY (brand_id) REFERENCES public.shop_brand(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_product shop_product_category_id_14d7eea8_fk_shop_category_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_product
    ADD CONSTRAINT shop_product_category_id_14d7eea8_fk_shop_category_id FOREIGN KEY (category_id) REFERENCES public.shop_category(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_productsimilar shop_productsimilar_from_product_id_f9628cb8_fk_shop_product_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productsimilar
    ADD CONSTRAINT shop_productsimilar_from_product_id_f9628cb8_fk_shop_product_id FOREIGN KEY (from_product_id) REFERENCES public.shop_product(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_productsimilar shop_productsimilar_to_product_id_ff835ca6_fk_shop_product_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productsimilar
    ADD CONSTRAINT shop_productsimilar_to_product_id_ff835ca6_fk_shop_product_id FOREIGN KEY (to_product_id) REFERENCES public.shop_product(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_producttag shop_producttag_product_id_379a4947_fk_shop_product_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_producttag
    ADD CONSTRAINT shop_producttag_product_id_379a4947_fk_shop_product_id FOREIGN KEY (product_id) REFERENCES public.shop_product(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_producttag shop_producttag_tag_id_d1eec258_fk_shop_tag_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_producttag
    ADD CONSTRAINT shop_producttag_tag_id_d1eec258_fk_shop_tag_id FOREIGN KEY (tag_id) REFERENCES public.shop_tag(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_productvariant shop_productvariant_color_id_71b1a3b1_fk_shop_color_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productvariant
    ADD CONSTRAINT shop_productvariant_color_id_71b1a3b1_fk_shop_color_id FOREIGN KEY (color_id) REFERENCES public.shop_color(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_productvariant shop_productvariant_product_id_3268ff6d_fk_shop_product_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productvariant
    ADD CONSTRAINT shop_productvariant_product_id_3268ff6d_fk_shop_product_id FOREIGN KEY (product_id) REFERENCES public.shop_product(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_productvariant shop_productvariant_size_id_df472044_fk_shop_size_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_productvariant
    ADD CONSTRAINT shop_productvariant_size_id_df472044_fk_shop_size_id FOREIGN KEY (size_id) REFERENCES public.shop_size(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_user_groups shop_user_groups_group_id_bf3fb67c_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_groups
    ADD CONSTRAINT shop_user_groups_group_id_bf3fb67c_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_user_groups shop_user_groups_user_id_252129d6_fk_shop_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_groups
    ADD CONSTRAINT shop_user_groups_user_id_252129d6_fk_shop_user_id FOREIGN KEY (user_id) REFERENCES public.shop_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_user_user_permissions shop_user_user_permi_permission_id_ace4643b_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_user_permissions
    ADD CONSTRAINT shop_user_user_permi_permission_id_ace4643b_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: shop_user_user_permissions shop_user_user_permissions_user_id_d5f91630_fk_shop_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_user_user_permissions
    ADD CONSTRAINT shop_user_user_permissions_user_id_d5f91630_fk_shop_user_id FOREIGN KEY (user_id) REFERENCES public.shop_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- PostgreSQL database dump complete
--

