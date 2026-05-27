-- Лаба 7: все задания. Запуск: psql shop_lab7 -f sql/lab7_all.sql

-- ========== Задание 1 — Отчёт по зависшим заказам ==========
CREATE OR REPLACE PROCEDURE shop_report_stale_orders(p_hours INT)
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

CALL shop_report_stale_orders(24);

-- ========== Задание 2 — Возраст заказа в часах ==========
CREATE OR REPLACE FUNCTION shop_get_order_age_hours(p_order_id INT)
RETURNS NUMERIC
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

SELECT shop_get_order_age_hours(1);

-- ========== Задание 3 — Безопасная отмена заказа ==========
CREATE OR REPLACE PROCEDURE shop_cancel_order(
  p_order_id INT,
  OUT result_message TEXT
)
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

-- Демо и скрины для задания 3: sql/lab7_z3_screenshot.sql (pending → cancelled)

-- ========== Задание 4 — Позиции проданные по бренду ==========
CREATE OR REPLACE FUNCTION shop_get_brand_sales_count(p_brand_id INT)
RETURNS INT
LANGUAGE sql
AS $$
  SELECT COUNT(*)::INT
  FROM shop_orderitem oi
  JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
  JOIN shop_product p ON p.id = pv.product_id
  WHERE p.brand_id = p_brand_id;
$$;

SELECT shop_get_brand_sales_count(1);

-- ========== Задание 5 — Апгрейд самой дешёвой позиции ==========
CREATE OR REPLACE PROCEDURE shop_upgrade_cheapest_item(
  p_order_id INT,
  p_max_surcharge NUMERIC,
  OUT msg TEXT
)
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

-- Демо и скрины для задания 5: sql/lab7_z5_screenshot.sql

-- ========== Задание 6 — Массовая отмена при закрытии склада ==========
CREATE OR REPLACE PROCEDURE shop_close_warehouse_until(p_until TIMESTAMPTZ)
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

CALL shop_close_warehouse_until(NOW() + INTERVAL '7 days');

-- ========== Задание 7 — Средняя скидка по категории ==========
CREATE OR REPLACE FUNCTION shop_avg_discount_by_category(p_category_id INT)
RETURNS NUMERIC
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

SELECT shop_avg_discount_by_category(1);

-- ========== Задание 8 — Вывод бренда из ассортимента ==========
CREATE OR REPLACE PROCEDURE shop_decommission_brand(p_brand_id INT)
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

  -- Снять позиции заказов и каталог товара бренда, иначе DELETE бренда упадёт на FK
  DELETE FROM shop_orderitem oi
  USING shop_productvariant pv, shop_product p
  WHERE oi.product_variant_id = pv.id
    AND pv.product_id = p.id
    AND p.brand_id = p_brand_id;

  DELETE FROM shop_producttag
  WHERE product_id IN (SELECT id FROM shop_product WHERE brand_id = p_brand_id);

  DELETE FROM shop_productsimilar
  WHERE from_product_id IN (SELECT id FROM shop_product WHERE brand_id = p_brand_id)
     OR to_product_id IN (SELECT id FROM shop_product WHERE brand_id = p_brand_id);

  DELETE FROM shop_product_available_sizes
  WHERE product_id IN (SELECT id FROM shop_product WHERE brand_id = p_brand_id);

  DELETE FROM shop_product_available_colors
  WHERE product_id IN (SELECT id FROM shop_product WHERE brand_id = p_brand_id);

  DELETE FROM shop_productvariant pv
  USING shop_product p
  WHERE pv.product_id = p.id AND p.brand_id = p_brand_id;

  DELETE FROM shop_product WHERE brand_id = p_brand_id;

  DELETE FROM shop_brand WHERE id = p_brand_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Бренд % не найден', p_brand_id;
  END IF;

  RAISE NOTICE 'Бренд % выведен из ассортимента', p_brand_id;
END;
$$;

-- Демо и скрины: sql/lab7_z8_screenshot.sql (бренд «LAB7 Тренировочный»)

-- ========== Задание 9 — Чётные элементы массива ==========
DO $$
DECLARE
  src INT[] := ARRAY[10, 20, 30, 40, 50, 60];
  even_only INT[] := '{}';
  i INT;
BEGIN
  FOR i IN 2..cardinality(src) BY 2 LOOP
    even_only := even_only || src[i];
  END LOOP;
  RAISE NOTICE 'FOR: %', even_only;

  even_only := '{}';
  i := 2;
  WHILE i <= cardinality(src) LOOP
    even_only := even_only || src[i];
    i := i + 2;
  END LOOP;
  RAISE NOTICE 'WHILE: %', even_only;
END $$;

-- ========== Задание 10 — Первые N простых чисел ==========
CREATE OR REPLACE FUNCTION shop_first_n_primes(n INT)
RETURNS INT[]
LANGUAGE plpgsql
AS $$
DECLARE
  primes INT[] := '{}';
  candidate INT := 2;
  is_prime BOOLEAN;
  d INT;
BEGIN
  WHILE cardinality(primes) < n LOOP
    is_prime := TRUE;
    d := 2;
    WHILE d * d <= candidate LOOP
      IF candidate % d = 0 THEN
        is_prime := FALSE;
        EXIT;
      END IF;
      d := d + 1;
    END LOOP;
    IF is_prime THEN
      primes := primes || candidate;
    END IF;
    candidate := candidate + 1;
  END LOOP;
  RETURN primes;
END;
$$;

SELECT shop_first_n_primes(10);

-- ========== Задание 11 — Уникальный код заказа ==========
CREATE OR REPLACE FUNCTION shop_generate_order_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  code TEXT;
  exists_flag BOOLEAN;
BEGIN
  WHILE TRUE LOOP
    code := 'ORD-' || upper(substr(md5(random()::text), 1, 8));
    SELECT EXISTS(SELECT 1 FROM shop_order WHERE customer_email = code)
    INTO exists_flag;
    EXIT WHEN NOT exists_flag;
  END LOOP;
  RETURN code;
END;
$$;

SELECT shop_generate_order_code();

-- ========== Задание 12 — Пауза между заказами варианта ==========
CREATE OR REPLACE FUNCTION shop_find_restock_gap_hours(
  p_variant_id INT,
  p_min_gap_hours INT
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  prev_ts TIMESTAMPTZ := NULL;
  gap_hours NUMERIC;
BEGIN
  FOR r IN
    SELECT o.order_date
    FROM shop_orderitem oi
    JOIN shop_order o ON o.id = oi.order_id
    WHERE oi.product_variant_id = p_variant_id
    ORDER BY o.order_date
  LOOP
    IF prev_ts IS NOT NULL THEN
      gap_hours := EXTRACT(EPOCH FROM (r.order_date - prev_ts)) / 3600;
      IF gap_hours >= p_min_gap_hours THEN
        RETURN ROUND(gap_hours, 2);
      END IF;
    END IF;
    prev_ts := r.order_date;
  END LOOP;
  RETURN NULL;
END;
$$;

SELECT shop_find_restock_gap_hours(1, 48);

-- ========== Задание 13 — Удаление старых cancelled пачками ==========
CREATE OR REPLACE PROCEDURE shop_purge_old_cancelled(p_years INT DEFAULT 2)
LANGUAGE plpgsql
AS $$
DECLARE
  v_left INT;
  v_deleted INT;
BEGIN
  LOOP
    SELECT COUNT(*) INTO v_left
    FROM shop_order
    WHERE status = 'cancelled'
      AND order_date < NOW() - (p_years || ' years')::INTERVAL;

    EXIT WHEN v_left = 0;

    DELETE FROM shop_order
    WHERE id IN (
      SELECT id FROM shop_order
      WHERE status = 'cancelled'
        AND order_date < NOW() - (p_years || ' years')::INTERVAL
      LIMIT 1000
    );

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RAISE NOTICE 'Удалено %', v_deleted;
    COMMIT;
  END LOOP;
END;
$$;

-- ========== Задание 14 — Архив старых позиций ==========
CREATE TABLE IF NOT EXISTS shop_orderitem_archive (
  LIKE shop_orderitem INCLUDING ALL
);

CREATE OR REPLACE PROCEDURE shop_archive_old_items(p_days INT DEFAULT 365)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_moved INT := 0;
BEGIN
  FOR r IN
    SELECT oi.*
    FROM shop_orderitem oi
    JOIN shop_order o ON o.id = oi.order_id
    WHERE o.order_date < NOW() - (p_days || ' days')::INTERVAL
  LOOP
    INSERT INTO shop_orderitem_archive SELECT r.*;
    DELETE FROM shop_orderitem WHERE id = r.id;
    v_moved := v_moved + 1;
  END LOOP;
  RAISE NOTICE 'Перенесено: %', v_moved;
END;
$$;

-- ========== Задание 15 — Отмена при сбое по категории ==========
CREATE OR REPLACE PROCEDURE shop_category_outage_cancel(
  p_category_id INT,
  p_hours INT
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_order_id INT;
BEGIN
  WHILE TRUE LOOP
    SELECT o.id INTO v_order_id
    FROM shop_order o
    WHERE o.status = 'pending'
      AND o.order_date < NOW() + (p_hours || ' hours')::INTERVAL
      AND EXISTS (
        SELECT 1 FROM shop_orderitem oi
        JOIN shop_productvariant pv ON pv.id = oi.product_variant_id
        JOIN shop_product p ON p.id = pv.product_id
        WHERE oi.order_id = o.id AND p.category_id = p_category_id
      )
    ORDER BY o.order_date
    LIMIT 1;

    EXIT WHEN NOT FOUND;

    UPDATE shop_order SET status = 'cancelled' WHERE id = v_order_id;
    RAISE NOTICE 'Отменён заказ %', v_order_id;
  END LOOP;
END;
$$;

-- ========== Задание 16 — Заказ из нескольких товаров ==========
CREATE OR REPLACE FUNCTION shop_get_customers_json(count_limit INT)
RETURNS JSON
LANGUAGE plpgsql
AS $$
DECLARE
  names TEXT[] := ARRAY['Иван Иванов', 'Анна Петрова', 'Дмитрий Сидоров'];
  emails TEXT[] := ARRAY['ivan@test.ru', 'anna@test.ru', 'dmitry@test.ru'];
  res JSONB := '[]'::jsonb;
  i INT;
  n INT;
BEGIN
  n := LEAST(count_limit, cardinality(names));
  FOR i IN 1..n LOOP
    res := res || jsonb_build_object('name', names[i], 'email', emails[i]);
  END LOOP;
  RETURN res::json;
END;
$$;

CREATE OR REPLACE FUNCTION shop_variant_free_stock(p_variant_id INT)
RETURNS INT
LANGUAGE sql
AS $$
  SELECT stock_quantity::INT FROM shop_productvariant WHERE id = p_variant_id;
$$;

CREATE OR REPLACE PROCEDURE shop_create_multi_item_order(
  p_variant_ids INT[],
  p_quantities INT[],
  OUT new_order_id INT
)
LANGUAGE plpgsql
AS $$
DECLARE
  cust JSONB;
  v_name TEXT;
  v_email TEXT;
  i INT;
  vid INT;
  qty INT;
  stock INT;
  line_sum NUMERIC(12,2) := 0;
BEGIN
  IF cardinality(p_variant_ids) <> cardinality(p_quantities) THEN
    RAISE EXCEPTION 'Массивы разной длины';
  END IF;

  cust := shop_get_customers_json(1)::jsonb -> 0;
  v_name := cust ->> 'name';
  v_email := cust ->> 'email';

  INSERT INTO shop_order (customer_name, customer_email, status, total_amount)
  VALUES (v_name, v_email, 'pending', 0)
  RETURNING id INTO new_order_id;

  FOR i IN 1..cardinality(p_variant_ids) LOOP
    vid := p_variant_ids[i];
    qty := p_quantities[i];
    stock := shop_variant_free_stock(vid);

    IF stock < qty THEN
      RAISE EXCEPTION 'Нет на складе: variant %, нужно %, есть %', vid, qty, stock;
    END IF;

    INSERT INTO shop_orderitem (order_id, product_variant_id, quantity, price_at_time)
    SELECT new_order_id, pv.id, qty, p.base_price
    FROM shop_productvariant pv
    JOIN shop_product p ON p.id = pv.product_id
    WHERE pv.id = vid;

    line_sum := line_sum + (
      SELECT p.base_price * qty FROM shop_productvariant pv
      JOIN shop_product p ON p.id = pv.product_id WHERE pv.id = vid
    );
  END LOOP;

  UPDATE shop_order SET total_amount = line_sum WHERE id = new_order_id;
END;
$$;

-- Подставьте реальные id вариантов с остатком >= quantity:
-- CALL shop_create_multi_item_order(ARRAY[1, 2], ARRAY[1, 1], NULL);
