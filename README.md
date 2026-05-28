# aws-serverless-orders-etl

A fully serverless, event-driven ETL pipeline on AWS. A nested JSON order file dropped into S3 automatically triggers a Lambda function that flattens it, writes the result as Parquet, and makes it queryable in Athena via the Glue Data Catalog — no servers to manage.

>

---

## Architecture

```
  Upload JSON                                    Query with SQL
       │                                               ▲
       ▼                                               │
┌─────────────┐   event   ┌──────────┐  parquet  ┌──────────┐   reads   ┌─────────┐
│  S3 (raw)   │ ───────▶  │  Lambda  │ ────────▶ │ S3       │ ◀──────── │ Athena  │
│ orders_raw/ │           │ flatten  │           │ curated/ │           │  (SQL)  │
└─────────────┘           └──────────┘           └────┬─────┘           └────┬────┘
                                │                      │                     │
                                │ start crawler        │ scan                │ lookup
                                ▼                      ▼                     │
                          ┌──────────────────────────────────┐              │
                          │      Glue Crawler / Catalog       │ ◀────────────┘
                          │  (table schema + S3 location)     │
                          └──────────────────────────────────┘
```

| Stage | Service | Purpose |
|-------|---------|---------|
| Ingest | **S3** | Landing zone for raw nested JSON files |
| Trigger | **S3 Event Notification** | Fires the Lambda when a new file is uploaded |
| Transform | **AWS Lambda** | Flattens nested JSON, converts to Parquet, writes back to S3 |
| Catalog | **AWS Glue (Crawler + Data Catalog)** | Infers schema and registers the table |
| Query | **Amazon Athena** | Run SQL directly on the Parquet files in S3 |

---

## How it works

1. You upload `orders_etl.json` (nested order data) into the `orders_raw_data/` folder of the S3 bucket.
2. An S3 event notification triggers the Lambda function.
3. The Lambda downloads the JSON, flattens the nested structure (one order with N products becomes N flat rows, with customer info denormalized inline), and converts the result to a Parquet file.
4. The Parquet file is written to the `orders_parquet_datalake/` folder.
5. The Lambda starts the Glue Crawler, which scans the Parquet folder and registers/updates the table in the Glue Data Catalog.
6. The table is now queryable in Athena with standard SQL.

Parquet is used instead of leaving the data as JSON because it is columnar and compressed — Athena scans far less data per query, which is faster and cheaper (Athena bills by data scanned).

---

## Repository contents

```
.
├── lambda_function.py        # The Lambda: flatten JSON → Parquet → start crawler
├── orders_etl.json           # Sample nested order data (12 orders)
├── athena_queries.sql        # Sample analytical queries
└── README.md
```

---

## Prerequisites

- An AWS account (Free Tier is sufficient)
- A single AWS region used consistently for every resource (region mismatch is the most common source of errors)
- The Lambda needs `pandas` and `pyarrow`, available via the AWS-managed layer `AWSSDKPandas-Python312`

---

## Setup

### 1. S3 bucket
Create a bucket (globally unique name) with two folders:
- `orders_raw_data/` — where raw JSON is uploaded
- `orders_parquet_datalake/` — where Lambda writes Parquet output

### 2. Glue database + crawler
- Create a Glue database, e.g. `etl_pipeline_db`.
- Create a crawler named **`etl_pipeline_crawler`** (this exact name is referenced in the Lambda code).
- Point it at `s3://<your-bucket>/orders_parquet_datalake/` and target the `etl_pipeline_db` database. Run on demand.

### 3. Lambda function
- Runtime: Python 3.12, architecture x86_64.
- Paste `lambda_function.py` and deploy.
- Memory: 512 MB, timeout: 2 minutes.
- Attach the `AWSSDKPandas-Python312` layer (specify by ARN).
- Attach these policies to the execution role: `AmazonS3FullAccess`, `AWSGlueConsoleFullAccess` (scope these down for production).

### 4. S3 trigger
On the Lambda, add an S3 trigger:
- Event type: `PUT`
- Prefix: `orders_raw_data/`
- Suffix: `.json`

> The prefix filter is essential. Without it, the Parquet files Lambda writes back to the same bucket would re-trigger the Lambda, creating an infinite loop.

### 5. Run it
Upload `orders_etl.json` to `orders_raw_data/`. Within seconds a Parquet file appears under `orders_parquet_datalake/`, the crawler runs, and the table becomes available in Athena.

### 6. Query it
In Athena (set a query-results S3 location first), run:

```sql
SELECT * FROM etl_pipeline_db.orders_parquet_datalake LIMIT 20;
```

See `athena_queries.sql` for more.

---

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS etl_pipeline_db.orders_parquet_datalake (
    order_id        BIGINT,
    order_date      STRING,
    total_amount    DOUBLE,
    customer_id     BIGINT,
    customer_name   STRING,
    email           STRING,
    address         STRING,
    product_id      STRING,
    product_name    STRING,
    category        STRING,
    price           DOUBLE,
    quantity        BIGINT
)
STORED AS PARQUET
LOCATION 's3://<your-bucket>/orders_parquet_datalake/';
```

This produces the same queryable table without the crawler. It works well when you already know the schema (which you do, since the Lambda produces it).

---

## Extension: normalized star schema

The default pipeline produces one wide table where product details (`product_name`, `category`, `price`) repeat on every row. To reduce redundancy, split into a fact table and a dimension table:

- **`orders_fact`** — one row per order line: `order_id`, `order_date`, `customer_id`, `product_id`, `quantity`, ...
- **`products_dim`** — one row per unique product: `product_id`, `product_name`, `category`, `price`

The relationship between them is **not stored anywhere** — Glue and Athena have no foreign-key concept. The link lives in the query:

```sql
SELECT o.order_id, p.product_name, p.category, p.price * o.quantity AS line_total
FROM etl_pipeline_db.orders_fact o
JOIN etl_pipeline_db.products_dim p
    ON o.product_id = p.product_id;
```

This is the classic data-lake / data-warehouse model: storage describes *what's there*, queries describe *how it connects*. Referential integrity is your responsibility — validate it with a check query rather than relying on the engine to enforce it:

```sql
-- Should return 0; any orphans mean a product_id in orders has no matching product
SELECT COUNT(*) AS orphan_count
FROM etl_pipeline_db.orders_fact o
LEFT JOIN etl_pipeline_db.products_dim p ON o.product_id = p.product_id
WHERE p.product_id IS NULL;
```

### Logical relationships (documented, not enforced)
- `orders_fact.product_id` → `products_dim.product_id`
- `orders_fact.customer_id` → `customers_dim.customer_id` (if you split customers out too)
---
---

## Tech stack

AWS S3 · AWS Lambda (Python 3.13) · AWS Glue · Amazon Athena · pandas · pyarrow · Parquet

