-- (a) Tables and seed data
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name TEXT NOT NULL,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- (d) Trigger (installed before loading sales via procedure)
CREATE OR REPLACE FUNCTION tf_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
EXECUTE FUNCTION tf_medicines_stock_audit();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- Seed medicines and 6 valid sales through pr_record_sale
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 15.00, 50),
    ('Amoxicillin 250mg', 45.00, 12),
    ('Ibuprofen 400mg',   25.00, 8);

CALL pr_record_sale(1, 5,  DATE '2026-11-24');
CALL pr_record_sale(2, 4,  DATE '2026-11-24');
CALL pr_record_sale(3, 3,  DATE '2026-11-24');
CALL pr_record_sale(1, 10, DATE '2026-11-23');
CALL pr_record_sale(2, 2,  DATE '2026-11-23');
CALL pr_record_sale(3, 2,  DATE '2026-11-23');

-- (e) View and post-sale query
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- (f) Index and EXPLAIN
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

-- Justification: Putting medicine_id first filters to one medicine, and sold_on
-- in the composite index supports range scans (BETWEEN / >= / <=) without sorting.
EXPLAIN (ANALYZE, BUFFERS)
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-25';

-- (g) Procedure and scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qty INTEGER;
    v_amt NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_qty, v_amt
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_qty, v_amt)
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- pg_cron daily at 00:15 for the previous day
SELECT cron.schedule(
    'q1_refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
);