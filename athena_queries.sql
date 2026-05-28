-- 1. Sanity check — preview the data
SELECT *
FROM etl_pipeline_db.orders_parquet_datalake
LIMIT 20;
 
 
-- 2. Row count
SELECT COUNT(*) AS total_rows
FROM etl_pipeline_db.orders_parquet_datalake;
 
 
-- 3. Total revenue and units per product
SELECT
    product_id,
    product_name,
    SUM(price * quantity) AS revenue,
    SUM(quantity)         AS units_sold
FROM etl_pipeline_db.orders_parquet_datalake
GROUP BY product_id, product_name
ORDER BY revenue DESC;
 
 
-- 4. Top 5 customers by spend
SELECT
    customer_id,
    customer_name,
    SUM(price * quantity) AS total_spend
FROM etl_pipeline_db.orders_parquet_datalake
GROUP BY customer_id, customer_name
ORDER BY total_spend DESC
LIMIT 5;
 
 
-- 5. Daily order volume and revenue
SELECT
    order_date,
    COUNT(DISTINCT order_id) AS num_orders,
    SUM(price * quantity)    AS daily_revenue
FROM etl_pipeline_db.orders_parquet_datalake
GROUP BY order_date
ORDER BY order_date;
 
 
-- 6. Category mix
SELECT
    category,
    COUNT(DISTINCT order_id) AS orders_with_category,
    SUM(quantity)            AS total_units,
    SUM(price * quantity)    AS category_revenue
FROM etl_pipeline_db.orders_parquet_datalake
GROUP BY category
ORDER BY category_revenue DESC;
 
 
-- 7. Repeat customers (more than one order)
SELECT
    customer_id,
    customer_name,
    COUNT(DISTINCT order_id) AS order_count
FROM etl_pipeline_db.orders_parquet_datalake
GROUP BY customer_id, customer_name
HAVING COUNT(DISTINCT order_id) > 1
ORDER BY order_count DESC;
 
